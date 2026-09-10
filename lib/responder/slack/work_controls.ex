defmodule Responder.Slack.WorkControls do
  @moduledoc """
  Executes one authenticated control against its exact durable Slack work card.

  The interaction value is only an opaque lookup key. This module reloads the
  card, episode, Work custody, and destination before any transition or network
  request. Copied and stale controls therefore grant no authority.
  """

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Publication.Custody, as: PublicationCustody
  alias Responder.Publication.{Followups, Operator, Publication}
  alias Responder.Repo
  alias Responder.Slack.{Client, WorkDiff, WorkRecord, WorkTarget}
  alias Responder.Work.{Custody, Session, Turn}

  @control_fields [:actor_ref, :occurred_at, :request_ref, :target, :work_ref]
  @page_fields @control_fields ++ [:patch_offset, :snapshot_digest]
  @publication_fields @control_fields ++ [:publication_ref]
  @publication_recovery_fields @publication_fields ++ [:expected_generation]
  @record_fields @control_fields ++ [:record_kind]

  @spec stop(map()) :: {:ok, map()} | {:error, term()}
  def stop(attributes) do
    with {:ok, attributes} <- attributes(attributes, @control_fields),
         {:ok, resolved} <- WorkTarget.resolve(attributes.work_ref, attributes.target),
         {:ok, turn_ref} <- stoppable_turn(resolved.episode),
         {:ok, result} <-
           Custody.request_stop(
             resolved.episode.id,
             resolved.episode.key,
             turn_ref,
             attributes.request_ref,
             "The operator stopped the current run. Reply in the same thread to continue this work."
           ) do
      {:ok,
       %{
         outcome: if(result.status == :settled, do: :stopped, else: :stopping),
         turn: result.turn,
         work_ref: resolved.work_ref
       }}
    end
  end

  @spec close(map()) :: {:ok, map()} | {:error, term()}
  def close(attributes) do
    with {:ok, attributes} <- attributes(attributes, @control_fields),
         {:ok, resolved} <- WorkTarget.resolve(attributes.work_ref, attributes.target) do
      close_resolved(resolved, attributes)
    end
  end

  @spec show_diff(map(), map()) :: {:ok, map()} | {:error, term()}
  def show_diff(attributes, options) when is_map(options) do
    with {:ok, attributes} <- attributes(attributes, @control_fields),
         {:ok, options} <- presentation_options(options),
         {:ok, resolved} <- WorkTarget.resolve(attributes.work_ref, attributes.target),
         {:ok, session} <- bound_session(resolved.episode.id),
         {:ok, changes} <-
           options.coop_api.get_changes_page(
             options.coop_client,
             session.coop_session_id,
             0,
             WorkDiff.page_bytes()
           ),
         {:ok, document} <- WorkDiff.render(resolved.work_ref, changes),
         {:ok, message_ref} <-
           publish(
             resolved,
             document,
             "work-diff:#{resolved.work_ref}",
             options
           ) do
      {:ok, %{message_ref: message_ref, outcome: :shown, work_ref: resolved.work_ref}}
    end
  end

  def show_diff(_attributes, _options), do: {:error, :invalid_work_control}

  @spec show_diff_page(map(), map()) :: {:ok, map()} | {:error, term()}
  def show_diff_page(attributes, options) when is_map(options) do
    with {:ok, attributes} <- attributes(attributes, @page_fields),
         {:ok, options} <- presentation_options(options),
         {:ok, resolved} <- WorkTarget.resolve_thread(attributes.work_ref, attributes.target),
         delivery_ref = "work-diff:#{resolved.work_ref}",
         {:ok, message_ref} <-
           exact_published_message(resolved, attributes.target.message_ref, delivery_ref, options),
         {:ok, session} <- bound_session(resolved.episode.id),
         {:ok, document} <-
           diff_document(
             resolved.work_ref,
             session.coop_session_id,
             attributes.snapshot_digest,
             attributes.patch_offset,
             options
           ),
         :ok <-
           options.slack_api.update_message(
             options.slack_client,
             resolved.channel_ref,
             message_ref,
             document,
             delivery_ref
           ) do
      {:ok, %{message_ref: message_ref, outcome: :shown, work_ref: resolved.work_ref}}
    end
  end

  def show_diff_page(_attributes, _options), do: {:error, :invalid_work_control}

  @spec show_record(map(), map()) :: {:ok, map()} | {:error, term()}
  def show_record(attributes, options) when is_map(options) do
    with {:ok, attributes} <- attributes(attributes, @record_fields),
         {:ok, options} <- record_options(options),
         {:ok, resolved} <- WorkTarget.resolve(attributes.work_ref, attributes.target),
         {:ok, document} <-
           options.work_record.build(
             resolved.work_ref,
             attributes.target,
             attributes.record_kind
           ),
         {:ok, message_ref} <-
           publish(
             resolved,
             document,
             "work-record:#{resolved.work_ref}:#{attributes.record_kind}",
             options
           ) do
      {:ok,
       %{
         message_ref: message_ref,
         outcome: :shown,
         record_kind: attributes.record_kind,
         work_ref: resolved.work_ref
       }}
    end
  end

  def show_record(_attributes, _options), do: {:error, :invalid_work_control}

  @spec approve_publication(map()) :: {:ok, map()} | {:error, term()}
  def approve_publication(attributes) do
    with {:ok, attributes} <- attributes(attributes, @publication_fields),
         {:ok, %{kind: :task} = resolved} <-
           WorkTarget.resolve(attributes.work_ref, attributes.target),
         {:ok, publication} <-
           publication(resolved.episode.id, attributes.publication_ref, :reviewed),
         {:ok, target} <- publication_review_target(publication),
         {:ok, approval} <-
           PublicationCustody.approve(%{
             actor_ref: attributes.actor_ref,
             approval_ref: attributes.request_ref,
             occurred_at: attributes.occurred_at,
             publication_ref: attributes.publication_ref,
             target: target
           }) do
      {:ok,
       %{
         outcome: approval.status,
         publication_ref: approval.publication.ref,
         work_ref: resolved.work_ref
       }}
    else
      {:ok, _non_task} -> {:error, :task_publication_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @spec check_publication(map()) :: {:ok, map()} | {:error, term()}
  def check_publication(attributes) do
    with {:ok, attributes} <- attributes(attributes, @publication_fields),
         {:ok, %{kind: :task} = resolved} <-
           WorkTarget.resolve(attributes.work_ref, attributes.target),
         {:ok, publication} <-
           publication(resolved.episode.id, attributes.publication_ref, :published),
         {:ok, check} <- Followups.request_check(publication.ref, attributes.request_ref) do
      {:ok,
       %{
         outcome: check.status,
         publication_ref: publication.ref,
         work_ref: resolved.work_ref
       }}
    else
      {:ok, _non_task} -> {:error, :task_publication_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @spec recover_publication(map(), :retry | :update | :discard) ::
          {:ok, map()} | {:error, term()}
  def recover_publication(attributes, action) when action in [:retry, :update, :discard] do
    with {:ok, attributes} <- attributes(attributes, @publication_recovery_fields),
         {:ok, %{kind: :task} = resolved} <-
           WorkTarget.resolve(attributes.work_ref, attributes.target),
         {:ok, publication} <-
           publication(resolved.episode.id, attributes.publication_ref),
         {:ok, receipt} <-
           Operator.recover(
             publication.ref,
             action,
             attributes.expected_generation,
             actor_ref: attributes.actor_ref,
             action_ref: attributes.request_ref
           ) do
      {:ok,
       %{
         outcome: String.to_existing_atom(receipt.outcome["status"]),
         publication_ref: publication.ref,
         work_ref: resolved.work_ref
       }}
    else
      {:ok, _non_task} -> {:error, :task_publication_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def recover_publication(_attributes, _action), do: {:error, :invalid_work_control}

  defp close_resolved(%{episode: %{state: state}} = resolved, _attributes)
       when state in [:complete, :cancelled] do
    {:ok, %{outcome: :closed, work_ref: resolved.work_ref}}
  end

  defp close_resolved(%{episode: %{state: :working, owner_kind: :delivery}}, _attributes),
    do: {:error, :work_delivery_must_settle}

  defp close_resolved(
         %{episode: %{state: :working, owner_kind: :turn, owner_ref: turn_ref} = episode} =
           resolved,
         attributes
       ) do
    with {:ok, result} <-
           Custody.request_cancel(
             episode.id,
             episode.key,
             turn_ref,
             attributes.request_ref,
             "Closed by #{attributes.actor_ref} from the exact Slack work card."
           ) do
      {:ok,
       %{
         outcome: if(result.status == :settled, do: :closed, else: :closing),
         work_ref: resolved.work_ref
       }}
    end
  end

  defp close_resolved(
         %{episode: %{state: state, owner_kind: owner_kind, owner_ref: owner_ref} = episode} =
           resolved,
         attributes
       )
       when state in [:waiting_for_input, :waiting_for_event] and owner_kind in [:input, :event] do
    command = %Command.CancelEpisode{
      cancel_ref: attributes.request_ref,
      episode_key: episode.key,
      expected_owner: %{kind: owner_kind, ref: owner_ref},
      occurred_at: attributes.occurred_at,
      reason: "Closed by #{attributes.actor_ref} from the exact Slack work card."
    }

    with {:ok, _transition} <- Episodes.apply(command) do
      {:ok, %{outcome: :closed, work_ref: resolved.work_ref}}
    end
  end

  defp close_resolved(_resolved, _attributes), do: {:error, :work_control_stale}

  defp stoppable_turn(%{state: :working, owner_kind: :turn, owner_ref: turn_ref, id: id}) do
    case Repo.get_by(Turn, episode_id: id, turn_ref: turn_ref) do
      %Turn{status: :pending} -> {:ok, turn_ref}
      %Turn{status: :cancel_pending} -> {:error, :work_control_stale}
      %Turn{status: :blocked} -> {:error, :work_control_stale}
      %Turn{} -> {:error, :work_control_stale}
      nil -> {:error, :work_control_stale}
    end
  end

  defp stoppable_turn(_episode), do: {:error, :work_control_stale}

  defp bound_session(episode_id) do
    case Repo.one(
           from(session in Session,
             where: session.episode_id == ^episode_id and not is_nil(session.coop_session_id),
             order_by: [desc: session.generation],
             limit: 1
           )
         ) do
      %Session{} = session -> {:ok, session}
      nil -> {:error, :work_changes_not_available}
    end
  end

  defp publication(episode_id, publication_ref, expected_status) do
    case Repo.get_by(Publication, episode_id: episode_id, ref: publication_ref) do
      %Publication{status: ^expected_status} = publication -> {:ok, publication}
      %Publication{} -> {:error, :task_publication_not_ready}
      nil -> {:error, :task_publication_mismatch}
    end
  end

  defp publication(episode_id, publication_ref) do
    case Repo.get_by(Publication, episode_id: episode_id, ref: publication_ref) do
      %Publication{} = publication -> {:ok, publication}
      nil -> {:error, :task_publication_mismatch}
    end
  end

  defp publication_review_target(%Publication{review_delivery_receipt: receipt})
       when is_map(receipt),
       do: publication_target(receipt)

  defp publication_review_target(_publication), do: {:error, :task_publication_not_ready}

  defp publication_target(receipt) do
    target = %{
      conversation_ref: receipt["conversation_ref"],
      message_ref: receipt["message_ref"],
      thread_ref: receipt["thread_ref"],
      transport: receipt["transport"]
    }

    if Enum.all?([target.conversation_ref, target.message_ref, target.transport], &is_binary/1),
      do: {:ok, target},
      else: {:error, :task_publication_not_ready}
  end

  defp publish(resolved, document, delivery_ref, options) do
    case options.slack_api.find_message(
           options.slack_client,
           resolved.channel_ref,
           resolved.output_thread_ref,
           delivery_ref
         ) do
      {:ok, message_ref} ->
        with :ok <-
               options.slack_api.update_message(
                 options.slack_client,
                 resolved.channel_ref,
                 message_ref,
                 document,
                 delivery_ref
               ) do
          {:ok, message_ref}
        end

      :not_found ->
        options.slack_api.post_message(
          options.slack_client,
          resolved.channel_ref,
          resolved.output_thread_ref,
          document,
          delivery_ref
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp exact_published_message(resolved, target_message_ref, delivery_ref, options) do
    case options.slack_api.find_message(
           options.slack_client,
           resolved.channel_ref,
           resolved.output_thread_ref,
           delivery_ref
         ) do
      {:ok, ^target_message_ref} -> {:ok, target_message_ref}
      {:ok, _other_message_ref} -> {:error, :work_diff_message_mismatch}
      :not_found -> {:error, :work_diff_message_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp diff_document(work_ref, session_id, snapshot_digest, patch_offset, options) do
    with {:ok, first} <-
           options.coop_api.get_changes_page(
             options.coop_client,
             session_id,
             0,
             WorkDiff.page_bytes()
           ),
         {:ok, first_document} <- WorkDiff.render(work_ref, first) do
      if refresh_diff?(first, snapshot_digest, patch_offset),
        do: {:ok, first_document},
        else:
          requested_diff_document(
            work_ref,
            session_id,
            snapshot_digest,
            patch_offset,
            first_document,
            options
          )
    end
  end

  defp refresh_diff?(first, snapshot_digest, patch_offset) do
    patch_offset == 0 or first["patch_digest"] != snapshot_digest or
      patch_offset > first["patch_bytes"]
  end

  defp requested_diff_document(
         work_ref,
         session_id,
         snapshot_digest,
         patch_offset,
         first_document,
         options
       ) do
    with {:ok, requested} <-
           options.coop_api.get_changes_page(
             options.coop_client,
             session_id,
             patch_offset,
             WorkDiff.page_bytes()
           ),
         {:ok, requested_document} <- WorkDiff.render(work_ref, requested) do
      exact_diff_document(
        requested,
        requested_document,
        snapshot_digest,
        patch_offset,
        first_document
      )
    end
  end

  defp exact_diff_document(requested, requested_document, snapshot_digest, patch_offset, fallback) do
    if requested["patch_digest"] == snapshot_digest and requested["patch_offset"] == patch_offset,
      do: {:ok, requested_document},
      else: {:ok, fallback}
  end

  defp attributes(%{} = attributes, fields) do
    valid =
      Enum.all?([
        Map.keys(attributes) |> Enum.sort() == Enum.sort(fields),
        present_binary?(Map.get(attributes, :actor_ref)),
        present_binary?(Map.get(attributes, :request_ref)),
        present_binary?(Map.get(attributes, :work_ref)),
        match?(%DateTime{}, Map.get(attributes, :occurred_at)),
        is_map(Map.get(attributes, :target)),
        valid_patch_offset?(attributes, fields),
        valid_snapshot_digest?(attributes, fields),
        valid_expected_generation?(attributes, fields),
        valid_publication_ref?(attributes, fields),
        valid_record_ref?(attributes, fields),
        valid_record_kind?(attributes, fields)
      ])

    if valid do
      {:ok, attributes}
    else
      {:error, :invalid_work_control}
    end
  end

  defp attributes(_attributes, _fields), do: {:error, :invalid_work_control}

  defp present_binary?(value), do: is_binary(value) and value != ""

  defp valid_patch_offset?(attributes, fields) do
    :patch_offset not in fields or
      (is_integer(Map.get(attributes, :patch_offset)) and Map.get(attributes, :patch_offset) >= 0)
  end

  defp valid_snapshot_digest?(attributes, fields) do
    :snapshot_digest not in fields or digest?(Map.get(attributes, :snapshot_digest))
  end

  defp valid_expected_generation?(attributes, fields) do
    :expected_generation not in fields or
      (is_integer(Map.get(attributes, :expected_generation)) and
         Map.get(attributes, :expected_generation) > 0)
  end

  defp valid_publication_ref?(attributes, fields) do
    :publication_ref not in fields or
      reference?(
        Map.get(attributes, :publication_ref),
        ~r/\Apublication:[A-Za-z0-9_.:-]{1,240}\z/
      )
  end

  defp valid_record_ref?(attributes, fields) do
    :record_ref not in fields or
      reference?(
        Map.get(attributes, :record_ref),
        ~r/\Arecord:publication_offer:[A-Za-z0-9_.:-]{1,220}\z/
      )
  end

  defp valid_record_kind?(attributes, fields) do
    :record_kind not in fields or
      Map.get(attributes, :record_kind) in [:timeline, :evidence, :handoff, :postmortem]
  end

  defp digest?(value), do: reference?(value, ~r/\A[0-9a-f]{64}\z/)
  defp reference?(value, regex), do: is_binary(value) and Regex.match?(regex, value)

  defp presentation_options(%{} = options) do
    required = [:coop_api, :coop_client, :slack_api, :slack_client]

    if Map.keys(options) |> Enum.sort() == Enum.sort(required) and
         is_atom(options.coop_api) and Code.ensure_loaded?(options.coop_api) and
         function_exported?(options.coop_api, :get_changes_page, 4) and
         slack_api?(options.slack_api) do
      {:ok, options}
    else
      {:error, :invalid_work_control_options}
    end
  end

  defp record_options(%{} = options) do
    options = Map.put_new(options, :work_record, WorkRecord)
    required = [:slack_api, :slack_client, :work_record]

    if Map.keys(options) |> Enum.sort() == Enum.sort(required) and
         is_atom(options.work_record) and Code.ensure_loaded?(options.work_record) and
         function_exported?(options.work_record, :build, 3) and slack_api?(options.slack_api) do
      {:ok, options}
    else
      {:error, :invalid_work_control_options}
    end
  end

  defp slack_api?(api) do
    is_atom(api) and Code.ensure_loaded?(api) and function_exported?(api, :find_message, 4) and
      function_exported?(api, :post_message, 5) and function_exported?(api, :update_message, 5)
  end

  @doc false
  def production_options(coop_api, coop_client, slack_client) do
    %{
      coop_api: coop_api,
      coop_client: coop_client,
      slack_api: Client,
      slack_client: slack_client
    }
  end
end
