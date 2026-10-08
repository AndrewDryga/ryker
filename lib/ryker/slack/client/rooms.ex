defmodule Ryker.Slack.Client.Rooms do
  @moduledoc """
  A conversation Ryker creates and sets up: the channel itself, the people
  invited into it, its topic and its pinned message; and leaving a channel
  when a person removes Ryker from it.

  Creating is idempotent: when Slack says the name is taken, or the create's
  reply is lost, the channel this exact request created is found instead. The
  channel list is read only then: walked before every create, it cost up to a
  hundred pages of a rate-limited method per room.
  Someone already in the room, or a message already pinned, is the state that
  was asked for.
  """
  alias Ryker.Slack.Client.{Fields, Pagination, Transport}

  @conversation_page_size 200

  def ensure_conversation(client, workspace_ref, name, private, creator_ref, requested_at) do
    with :ok <- Fields.slack_id(workspace_ref),
         :ok <- Fields.conversation_name(name),
         true <- is_boolean(private),
         :ok <- Fields.slack_id(creator_ref),
         :ok <- Fields.utc_datetime(requested_at) do
      create_conversation(client, workspace_ref, name, private, creator_ref, requested_at)
    else
      false -> {:error, {:invalid_slack_api_request, :private}}
      {:error, reason} -> {:error, reason}
    end
  end

  def invite_users(_client, _channel_ref, []), do: :ok

  def invite_users(client, channel_ref, users) do
    with :ok <- Fields.slack_id(channel_ref),
         :ok <- Fields.unique_slack_ids(users) do
      Enum.reduce_while(users, :ok, fn user_ref, :ok ->
        invite_user(client, channel_ref, user_ref)
      end)
    end
  end

  def set_topic(client, channel_ref, topic) do
    with :ok <- Fields.slack_id(channel_ref),
         :ok <- Fields.bounded_text(topic, 250),
         {:ok, response} <-
           Transport.request(client, :post, "/conversations.setTopic", %{
             "channel" => channel_ref,
             "topic" => topic
           }),
         {:ok, _body} <- Transport.response(response) do
      :ok
    end
  end

  # Slack answers ok, with not_in_channel set, when Ryker is already out,
  # which is what was asked for.
  def leave_conversation(client, channel_ref) do
    with :ok <- Fields.slack_id(channel_ref),
         {:ok, response} <-
           Transport.request(client, :post, "/conversations.leave", %{"channel" => channel_ref}) do
      response |> Transport.response() |> Transport.success()
    end
  end

  def pin_message(client, channel_ref, message_ref) do
    with :ok <- Fields.slack_id(channel_ref),
         :ok <- Fields.text(message_ref) do
      document = %{"channel" => channel_ref, "timestamp" => message_ref}

      case Transport.request(client, :post, "/pins.add", document) do
        {:ok, %{body: %{"error" => "already_pinned", "ok" => false}, status: 200}} -> :ok
        {:ok, response} -> response |> Transport.response() |> Transport.success()
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- the channel ----------------------------------------------------------

  defp find_conversation(client, name, private, creator_ref, requested_at) do
    parameters = [
      {"exclude_archived", false},
      {"limit", @conversation_page_size},
      {"types", "public_channel,private_channel"}
    ]

    Pagination.find(
      client,
      &Pagination.query("/conversations.list", parameters, &1),
      &search_page/1,
      &matching_conversation(&1, name, private, creator_ref, requested_at),
      @conversation_page_size
    )
  end

  # A create whose reply was lost, or that Slack refused because the name is
  # taken, is reconciled by finding the channel this exact request created.
  defp create_conversation(client, workspace_ref, name, private, creator_ref, requested_at) do
    document = %{"is_private" => private, "name" => name, "team_id" => workspace_ref}

    case Transport.request(client, :post, "/conversations.create", document) do
      {:ok, %{body: %{"error" => "name_taken", "ok" => false}, status: 200}} ->
        reconcile_created_conversation(client, name, private, creator_ref, requested_at)

      {:ok, response} ->
        with {:ok, body} <- Transport.response(response) do
          created_conversation(body, name, private, creator_ref)
        end

      {:error, _reason} ->
        reconcile_created_conversation(client, name, private, creator_ref, requested_at)
    end
  end

  defp reconcile_created_conversation(client, name, private, creator_ref, requested_at) do
    case find_conversation(client, name, private, creator_ref, requested_at) do
      {:ok, channel_ref} -> {:ok, channel_ref}
      :not_found -> {:error, {:slack_reconciliation_pending, :conversation}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A conversations.list page, raw, for finding one channel by name.
  defp search_page(%{"channels" => channels} = body) when is_list(channels) do
    case Pagination.next_cursor(body) do
      {:ok, cursor} -> {:ok, channels, cursor}
      {:error, _reason} -> {:error, {:slack_protocol_error, :conversations}}
    end
  end

  defp search_page(_body), do: {:error, {:slack_protocol_error, :conversations}}

  # The channel on a page that `ensure_conversation` created or would have:
  # same name, privacy and creator, created within the request's window.
  defp matching_conversation(channels, name, private, creator_ref, requested_at) do
    earliest = DateTime.add(requested_at, -300, :second) |> DateTime.to_unix()
    latest = DateTime.add(requested_at, 3_600, :second) |> DateTime.to_unix()

    Enum.reduce_while(channels, :not_found, fn
      %{
        "created" => created,
        "creator" => ^creator_ref,
        "id" => channel_ref,
        "is_private" => ^private,
        "name" => ^name
      },
      :not_found
      when is_integer(created) and created >= earliest and created <= latest ->
        if Fields.slack_id(channel_ref) == :ok,
          do: {:halt, {:ok, channel_ref}},
          else: {:halt, {:error, {:slack_protocol_error, :conversation}}}

      %{}, :not_found ->
        {:cont, :not_found}

      _invalid, :not_found ->
        {:halt, {:error, {:slack_protocol_error, :conversation}}}
    end)
  end

  # The channel ref of a conversations.create reply that matches what was asked for.
  defp created_conversation(
         %{
           "channel" => %{
             "creator" => creator_ref,
             "id" => channel_ref,
             "is_private" => private,
             "name" => name
           }
         },
         name,
         private,
         creator_ref
       ) do
    case Fields.slack_id(channel_ref) do
      :ok -> {:ok, channel_ref}
      {:error, _reason} -> {:error, {:slack_protocol_error, :conversation}}
    end
  end

  defp created_conversation(_body, _name, _private, _creator_ref),
    do: {:error, {:slack_protocol_error, :conversation}}

  # --- members --------------------------------------------------------------

  defp invite_user(client, channel_ref, user_ref) do
    document = %{"channel" => channel_ref, "users" => user_ref}

    case invitation_response(Transport.request(client, :post, "/conversations.invite", document)) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  # Someone already in the room, or Ryker itself, is invited by definition.
  defp invitation_response({:ok, %{body: %{"error" => error, "ok" => false}, status: 200}})
       when error in ["already_in_channel", "cant_invite_self"],
       do: :ok

  defp invitation_response({:ok, response}),
    do: response |> Transport.response() |> Transport.success()

  defp invitation_response({:error, _reason} = error), do: error
end
