defmodule Responder.ControlPlane.CardLabDelivery do
  @moduledoc """
  Explicit native Slack specimen delivery with frozen payloads and fenced custody.

  Only joined, non-shared channels in the configured workspace are eligible.
  A stable metadata marker reconciles unknown post outcomes; state changes
  update the same message. Specimen controls cannot enter production actions.
  """
  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.{CardLab, CardLabPost}
  alias Responder.Repo
  alias Responder.Slack.{ChannelMembership, Client}

  @lease_seconds 120

  def settings do
    configuration = Application.get_env(:responder, :slack)
    configuration = if is_list(configuration), do: Map.new(configuration), else: configuration

    case configuration do
      %{identity: %{workspace_ref: workspace}, bot_client: %Client{} = client} ->
        {:ok, %{api: Client, client: client, workspace_ref: workspace}}

      _missing ->
        {:error, :card_lab_slack_not_configured}
    end
  end

  def snapshot(card_id) do
    case settings() do
      {:ok, options} ->
        channels =
          Repo.all(
            from(channel in ChannelMembership,
              where:
                channel.workspace_ref == ^options.workspace_ref and channel.status == :joined and
                  channel.external_shared == false,
              order_by: channel.channel_ref,
              select: channel.channel_ref,
              limit: 100
            )
          )

        posts =
          Repo.all(
            from(post in CardLabPost,
              where: post.card_id == ^card_id and post.workspace_ref == ^options.workspace_ref,
              order_by: [desc: post.inserted_at, desc: post.id],
              limit: 30
            )
          )

        %{available: true, channels: channels, posts: posts, workspace_ref: options.workspace_ref}

      {:error, _} ->
        %{available: false, channels: [], posts: [], workspace_ref: nil}
    end
  end

  def describe_target(workspace, channel, options \\ nil) do
    with {:ok, options} <- options(options),
         {:ok, channel} <- resolve_channel(workspace, channel, options),
         :ok <- local_destination(workspace, channel, options),
         {:ok, info} <- options.api.conversation_info(options.client, channel),
         true <-
           info["id"] == channel and info["is_member"] == true and
             info["is_archived"] == false and info["is_ext_shared"] == false do
      {:ok,
       %{workspace_ref: workspace, channel_ref: channel, channel_name: info["name"] || channel}}
    else
      false -> {:error, :card_lab_destination_not_allowed}
      {:error, _} = error -> error
    end
  end

  def enqueue(card, state, workspace, channel, request_id, options \\ nil) do
    with {:ok, id} <- uuid(request_id),
         {:ok, payload} <- CardLab.slack_message(card, state),
         {:ok, target} <- describe_target(workspace, channel, options) do
      fingerprint = CanonicalJSON.digest(payload)

      request_fingerprint =
        CanonicalJSON.digest([card, state, workspace, target.channel_ref, fingerprint])

      now = DateTime.utc_now()

      specimen = %CardLabPost{
        id: id,
        card_id: card,
        state_id: state,
        workspace_ref: workspace,
        channel_ref: target.channel_ref,
        channel_name: target.channel_name,
        payload: payload,
        fingerprint: fingerprint,
        request_fingerprint: request_fingerprint,
        next_attempt_at: now
      }

      Repo.transaction(fn -> enqueue_locked(specimen) end)
    end
  end

  defp enqueue_locked(specimen) do
    Repo.insert!(specimen, on_conflict: :nothing)
    post = Repo.get!(CardLabPost, specimen.id)

    if post.request_fingerprint == specimen.request_fingerprint,
      do: post,
      else: Repo.rollback(:card_lab_request_conflict)
  end

  def transition(id, state, expected_revision, options \\ nil) do
    with {:ok, options} <- options(options),
         {:ok, id} <- uuid(id) do
      Repo.transaction(fn -> transition_locked(id, state, expected_revision, options) end)
    end
  end

  defp transition_locked(id, state, expected_revision, options) do
    post = locked!(id, options)
    available!(post)
    unless post.revision == expected_revision, do: Repo.rollback(:card_lab_stale_revision)

    case CardLab.slack_message(post.card_id, state) do
      {:ok, payload} ->
        update!(post, %{
          state_id: state,
          payload: payload,
          fingerprint: CanonicalJSON.digest(payload),
          revision: post.revision + 1,
          status: :pending,
          attempt_count: 0,
          last_error: nil,
          next_attempt_at: DateTime.utc_now()
        })

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  def retry(id, expected_revision, options \\ nil) do
    with {:ok, options} <- options(options), {:ok, id} <- uuid(id) do
      Repo.transaction(fn -> retry_locked(id, expected_revision, options) end)
    end
  end

  defp retry_locked(id, expected_revision, options) do
    post = locked!(id, options)
    available!(post)
    unless post.revision == expected_revision, do: Repo.rollback(:card_lab_stale_revision)

    update!(post, %{
      status: :pending,
      attempt_count: 0,
      last_error: nil,
      next_attempt_at: DateTime.utc_now()
    })
  end

  def fetch(id) do
    with {:ok, id} <- uuid(id) do
      case Repo.get(CardLabPost, id) do
        nil -> {:error, :card_lab_post_not_found}
        post -> {:ok, post}
      end
    end
  end

  def run_once(options \\ nil) do
    with {:ok, options} <- options(options),
         {:ok, post} <- claim_next(options) do
      case post do
        %{status: :pending} -> settle(post, bounded_delivery(post, options))
        _ -> {:ok, post}
      end
    end
  end

  defp bounded_delivery(post, options) do
    task =
      Task.async(fn ->
        try do
          deliver(post, options)
        rescue
          _ -> {:error, :card_lab_transport_failure}
        catch
          _, _ -> {:error, :card_lab_transport_failure}
        end
      end)

    # Stop local execution before custody expires. Unknown remote outcomes remain
    # pending and are reconciled by the same durable metadata identity.
    timeout = options |> Map.get(:delivery_timeout_ms, 90_000) |> max(1) |> min(90_000)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :card_lab_execution_timed_out}
    end
  end

  defp claim_next(options) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      post =
        Repo.one(
          from(post in CardLabPost,
            where:
              post.workspace_ref == ^options.workspace_ref and post.status == :pending and
                post.next_attempt_at <= ^now and
                (is_nil(post.lease_expires_at) or post.lease_expires_at <= ^now),
            order_by: [asc: post.next_attempt_at, asc: post.id],
            limit: 1,
            lock: "FOR UPDATE SKIP LOCKED"
          )
        )

      claim(post, now)
    end)
  end

  defp claim(nil, _now), do: nil

  defp claim(%{attempt_count: count} = post, _now) when count >= 8,
    do:
      update!(post, %{
        status: :blocked,
        lease_ref: nil,
        lease_expires_at: nil,
        last_error: "Delivery attempt limit reached. Review the existing message before retrying."
      })

  defp claim(post, now),
    do:
      update!(post, %{
        lease_ref: Ecto.UUID.generate(),
        lease_expires_at: DateTime.add(now, @lease_seconds, :second),
        attempt_count: post.attempt_count + 1
      })

  defp deliver(post, options) do
    with {:ok, _target} <- describe_target(post.workspace_ref, post.channel_ref, options),
         :ok <- current_lease(post) do
      deliver_message(post, options)
    end
  end

  defp deliver_message(%{message_ref: message} = post, options) when is_binary(message),
    do: update_message(post, message, options)

  defp deliver_message(post, options) do
    case options.api.find_card_specimen(
           options.client,
           post.channel_ref,
           marker(post),
           post.inserted_at
         ) do
      {:ok, message} ->
        update_message(post, message, options)

      :not_found ->
        with :ok <- current_lease(post) do
          options.api.post_card_specimen(
            options.client,
            post.channel_ref,
            nil,
            post.payload,
            marker(post)
          )
        end

      {:error, _} = error ->
        error
    end
  end

  defp update_message(post, message, options) do
    with :ok <- current_lease(post),
         :ok <-
           options.api.update_card_specimen(
             options.client,
             post.channel_ref,
             message,
             post.payload,
             marker(post)
           ) do
      {:ok, message}
    end
  end

  defp settle(claim, result) do
    Repo.transaction(fn ->
      post = Repo.one(from(post in CardLabPost, where: post.id == ^claim.id, lock: "FOR UPDATE"))
      now = DateTime.utc_now()

      unless post && post.lease_ref == claim.lease_ref &&
               DateTime.compare(post.lease_expires_at, now) == :gt,
             do: Repo.rollback(:card_lab_lease_lost)

      attributes =
        case result do
          {:ok, message} ->
            %{
              status: :posted,
              message_ref: message,
              delivered_state_id: claim.state_id,
              delivered_fingerprint: claim.fingerprint,
              last_error: nil
            }

          {:error, reason} ->
            %{
              status: if(post.attempt_count >= 8, do: :blocked, else: :pending),
              last_error: error_message(reason),
              next_attempt_at: DateTime.add(now, retry_seconds(reason), :second)
            }
        end

      update!(post, Map.merge(attributes, %{lease_ref: nil, lease_expires_at: nil}))
    end)
  end

  defp current_lease(post) do
    now = DateTime.utc_now()

    if Repo.exists?(
         from(saved in CardLabPost,
           where:
             saved.id == ^post.id and
               saved.lease_ref == ^post.lease_ref and saved.lease_expires_at > ^now
         )
       ), do: :ok, else: {:error, :card_lab_lease_lost}
  end

  defp locked!(id, options) do
    case Repo.one(from(post in CardLabPost, where: post.id == ^id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback(:card_lab_post_not_found)

      post ->
        case local_destination(post.workspace_ref, post.channel_ref, options) do
          :ok -> post
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp available!(%{lease_expires_at: %DateTime{} = expires}) do
    if DateTime.compare(expires, DateTime.utc_now()) == :gt,
      do: Repo.rollback(:card_lab_delivery_busy)
  end

  defp available!(_post), do: :ok

  defp resolve_channel(workspace, channel, %{workspace_ref: workspace} = options)
       when is_binary(channel) do
    if String.starts_with?(channel, "#"),
      do: find_channel(String.trim_leading(channel, "#"), options, nil, 5),
      else: {:ok, channel}
  end

  defp resolve_channel(_, _, _), do: {:error, :card_lab_destination_not_allowed}

  defp find_channel(_name, _options, _cursor, 0),
    do: {:error, :card_lab_destination_not_allowed}

  defp find_channel(name, options, cursor, remaining) do
    request = %{
      "limit" => 200,
      "exclude_archived" => true,
      "types" => ["public_channel", "private_channel"]
    }

    request = if cursor, do: Map.put(request, "cursor", cursor), else: request

    with {:ok, page} <- options.api.list_conversations(options.client, request) do
      case Enum.find(page["conversations"], &(&1["name"] == name)) do
        %{"channel_ref" => channel} -> {:ok, channel}
        nil -> next_channel_page(name, options, page["cursor"], cursor, remaining)
      end
    end
  end

  defp next_channel_page(name, options, next, previous, remaining)
       when is_binary(next) and next != "" and next != previous,
       do: find_channel(name, options, next, remaining - 1)

  defp next_channel_page(_, _, _, _, _), do: {:error, :card_lab_destination_not_allowed}

  defp local_destination(workspace, channel, %{workspace_ref: workspace})
       when is_binary(channel) do
    if Repo.exists?(
         from(member in ChannelMembership,
           where:
             member.workspace_ref == ^workspace and
               member.channel_ref == ^channel and member.status == :joined and
               member.external_shared == false
         )
       ), do: :ok, else: {:error, :card_lab_destination_not_allowed}
  end

  defp local_destination(_workspace, _channel, _options),
    do: {:error, :card_lab_destination_not_allowed}

  defp options(nil), do: settings()

  defp options(%{api: api, client: _, workspace_ref: workspace} = options)
       when is_atom(api) and is_binary(workspace), do: {:ok, options}

  defp options(_options), do: {:error, :card_lab_slack_not_configured}

  defp uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :card_lab_post_not_found}
    end
  end

  defp marker(post), do: "card-lab:#{post.id}"
  defp update!(post, attributes), do: post |> Ecto.Changeset.change(attributes) |> Repo.update!()

  defp retry_seconds({:delivery_rate_limited, seconds, _}) when is_integer(seconds),
    do: max(seconds, 1)

  defp retry_seconds(_reason), do: 10

  defp error_message(:card_lab_destination_not_allowed),
    do: "The Slack destination is no longer eligible."

  defp error_message(:card_lab_lease_lost),
    do: "Delivery custody changed; reconciliation is required."

  defp error_message({:delivery_rate_limited, seconds, _reason}) when is_integer(seconds),
    do:
      "Slack rate limited this specimen. Retry is deferred for at least #{max(seconds, 1)} seconds."

  defp error_message({:delivery_rate_limited, _seconds, _reason}),
    do: "Slack rate limited this specimen. Automatic retry is deferred."

  defp error_message({:slack_api_error, code}) when is_binary(code) do
    if Regex.match?(~r/\A[a-z_]{1,80}\z/, code),
      do: "Slack refused the specimen: #{code}.",
      else: "Slack refused the specimen."
  end

  defp error_message(_reason),
    do: "Slack delivery was not confirmed. The next attempt reconciles the same message."
end
