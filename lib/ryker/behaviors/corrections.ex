defmodule Ryker.Behaviors.Corrections do
  @moduledoc "Explicit, source-backed corrections kept as scoped guidance, never action authority."
  alias Ryker.AdvisoryLock
  alias Ryker.Behaviors
  alias Ryker.Behaviors.{Behavior, StandingAssignmentRun}
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Memories
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.RoutingExamples
  alias Ryker.Slack
  alias Ryker.StateTools

  @doc "Save the exact correction of a current authorized human, with host-owned source and scope."
  def remember(binding, arguments, authorize) when is_function(authorize, 1) do
    Repo.transaction(fn ->
      Repo.lock_timeout!(1_000)

      # This first lookup only chooses source locks. The binding and exact
      # source are reloaded and authorized after review, Episode and Session.
      with {:ok, candidate} <- fetch_source(binding, arguments["source_event_ref"]),
           :ok <- lock_source(candidate),
           :ok <- Memories.Reviews.lock_review_maintenance!(),
           {:ok, current} <- StateTools.Binding.fetch_and_lock_current_with_episode(binding),
           :ok <- live(current.episode),
           {:ok, entry} <- fetch_source(current, arguments["source_event_ref"]),
           true <- Ingress.Inbox.Entry.same_source?(candidate, entry),
           :ok <- authorize_source(entry, authorize),
           :ok <- current_words(entry),
           :ok <- quoted(entry, arguments["instruction"]),
           :ok <-
             Slack.ChannelFence.authorize_in_transaction(
               entry.destination_transport,
               entry.destination_conversation_ref
             ),
           {:ok, assignment} <- assignment(current.episode.id, arguments["assignment_ref"]),
           {:ok, subject} <- replacement(current, entry, arguments),
           :ok <- capacity(current.episode, subject, arguments),
           {:ok, result} <- persist(current, entry, subject, assignment, arguments) do
        result
      else
        false -> Repo.rollback(:correction_source_stale)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def remember(_binding, _arguments, _authorize), do: {:error, :correction_unauthorized}

  defp fetch_source(binding, event_ref) do
    with {:ok, event} <- current_source(binding, event_ref),
         {:ok, entry} <- source_entry(binding, event),
         :ok <- source_scope(binding.episode, entry),
         do: {:ok, entry}
  end

  defp live(%Episodes.Episode{execution_mode: :live}), do: :ok
  defp live(_episode), do: {:error, :correction_unauthorized}

  defp current_source(binding, event_ref) do
    context = get_in(binding.turn.submission || %{}, ["context"]) || %{}

    items =
      if context["mode"] == "continuation",
        do: get_in(context, ["current_inputs", "items"]) || [],
        else: Enum.filter(get_in(context, ["inputs", "items"]) || [], &(&1["current"] == true))

    with {:ok, ^event_ref} <- Ecto.UUID.cast(event_ref),
         true <- Enum.any?(items, &(&1["source_event_id"] == event_ref)),
         {:ok, %Episodes.Event{episode_id: id, kind: :input_admitted} = event} <-
           Repo.fetch(Episodes.Event.Query.by_id(event_ref)),
         true <- id == binding.episode.id do
      active_source(binding, event)
    else
      _ -> {:error, :correction_unauthorized}
    end
  end

  defp active_source(binding, event) do
    if event.dedupe_key in binding.episode.active_input_refs,
      do: {:ok, event},
      else: {:error, :correction_source_stale}
  end

  defp source_entry(binding, %Episodes.Event{
         payload: %{
           "payload" =>
             %{
               "source" => %{"kind" => _, "ref" => _},
               "event_ref" => _,
               "native_input_id" => _,
               "revision" => _
             } = source
         }
       }) do
    query =
      Ingress.Inbox.Entry.Query.by_episode_id(binding.episode.id)
      |> Ingress.Inbox.Entry.Query.by_work_source(source)

    case Repo.fetch(query) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:error, :correction_unauthorized}
    end
  end

  defp source_entry(_binding, _event), do: {:error, :correction_unauthorized}

  defp source_scope(episode, entry) do
    if episode.destination_transport == entry.destination_transport and
         episode.destination_conversation_ref == entry.destination_conversation_ref,
       do: :ok,
       else: {:error, :correction_unauthorized}
  end

  defp authorize_source(
         %Ingress.Inbox.Entry{
           actor_kind: :user,
           event_kind: kind,
           operational_pruned_at: nil,
           execution_mode: :live
         } = entry,
         authorize
       )
       when kind in [:message, :edit] do
    if authorize.(entry) == true, do: :ok, else: {:error, :correction_unauthorized}
  end

  defp authorize_source(_entry, _authorize), do: {:error, :correction_unauthorized}

  defp current_words(entry) do
    changed =
      entry
      |> Ingress.Inbox.Entry.Query.later_revisions_of()
      |> Repo.all()
      |> Enum.any?(&RoutingExamples.takes_back_words?/1)

    if changed, do: {:error, :correction_source_stale}, else: :ok
  end

  defp quoted(entry, instruction) do
    text = Ingress.MessageText.authored(entry.content)

    if is_binary(instruction) and String.trim(instruction) != "" and
         String.contains?(text, instruction), do: :ok, else: {:error, :correction_not_quoted}
  end

  defp assignment(_episode_id, nil), do: {:ok, nil}

  defp assignment(episode_id, reference) do
    matched =
      episode_id
      |> StandingAssignmentRun.Query.decided_for_episode()
      |> Repo.all()
      |> Enum.find(fn {_run, behavior} -> behavior.ref == reference end)

    case matched do
      {_run, %Behavior{status: :active} = behavior} -> {:ok, behavior}
      _ -> {:error, :correction_assignment_mismatch}
    end
  end

  defp replacement(binding, entry, arguments) do
    operation = operation(entry, arguments)

    query =
      binding.episode.id
      |> Records.Record.Query.by_episode_id()
      |> Records.Record.Query.by_operation_id(operation)

    case Repo.fetch(query) do
      {:ok, record} ->
        duplicate_correction(record, arguments)

      {:error, :not_found} ->
        replacement_target(binding, arguments)
    end
  end

  defp duplicate_correction(record, arguments) do
    case Repo.fetch(Behavior.Query.by_offer_record_id(record.id)) do
      {:ok, %Behavior{status: :active} = behavior} ->
        if behavior.payload["correction_request_sha256"] == CanonicalJSON.digest(arguments),
          do: {:ok, {:duplicate, behavior}},
          else: {:error, :state_record_operation_conflict}

      _ ->
        {:error, :correction_guidance_stale}
    end
  end

  defp replacement_target(binding, %{
         "guidance_ref" => nil,
         "expected_revision" => nil,
         "subject" => subject
       }) do
    existing =
      Behavior.Query.by_kind(:guidance)
      |> Behavior.Query.by_workspace(Episodes.Scope.workspace_ref(binding.episode))
      |> Behavior.Query.scoped_to(:conversation, binding.episode.destination_conversation_ref)
      |> Behavior.Query.by_identity_key(subject)
      |> Behavior.Query.by_status(:active)

    if Repo.exists?(existing), do: {:error, :correction_guidance_stale}, else: {:ok, subject}
  end

  defp replacement_target(binding, %{"guidance_ref" => reference, "expected_revision" => revision})
       when is_binary(reference) and is_integer(revision) do
    query =
      reference
      |> Behavior.Query.by_ref()
      |> Behavior.Query.by_kind(:guidance)
      |> Behavior.Query.lock_for_update()

    case Repo.fetch(query) do
      {:ok, %Behavior{status: :active, scope_kind: :conversation, revision: ^revision} = behavior} ->
        if behavior.scope_ref == binding.episode.destination_conversation_ref and
             behavior.workspace_ref == Episodes.Scope.workspace_ref(binding.episode),
           do: {:ok, behavior.identity_key},
           else: {:error, :correction_unauthorized}

      _ ->
        {:error, :correction_guidance_stale}
    end
  end

  defp replacement_target(_binding, _arguments), do: {:error, :correction_guidance_stale}

  defp capacity(_episode, {:duplicate, _behavior}, _arguments), do: :ok

  # Final outcomes carry at most 64 record references. Leave room for the
  # evidence and ordinary work, and bound retained correction briefing bytes.
  # The review-maintenance lock serializes concurrent changes to this scope.
  defp capacity(episode, subject, arguments) do
    existing =
      Behavior.Query.by_kind(:guidance)
      |> Behavior.Query.by_workspace(Episodes.Scope.workspace_ref(episode))
      |> Behavior.Query.scoped_to(:conversation, episode.destination_conversation_ref)
      |> Behavior.Query.by_status([:active, :disabled])
      |> Behavior.Query.unexpired()
      |> Repo.all()
      |> Enum.reject(&(&1.identity_key == subject))
      |> Enum.filter(
        &(is_map(&1.payload["correction_source"]) or
            List.wrap(&1.payload["requirements"]) != [])
      )

    documents = [
      %{"text" => arguments["instruction"], "requirements" => arguments["requirements"]}
      | Enum.map(existing, &Map.take(&1.payload, ~w(text requirements)))
    ]

    outputs = Enum.sum(Enum.map(documents, &length(&1["requirements"] || [])))
    bytes = documents |> CanonicalJSON.encode!() |> byte_size()

    if length(documents) <= 16 and outputs <= 16 and bytes <= 32_768,
      do: :ok,
      else: {:error, :correction_capacity_reached}
  end

  defp persist(_binding, _entry, {:duplicate, behavior}, _assignment, _arguments),
    do: {:ok, result(behavior, "duplicate")}

  defp persist(binding, entry, subject, assignment, arguments) do
    operation = operation(entry, arguments)

    payload = %{
      "expires_in" => "365d",
      "repository" => nil,
      "scope" => "conversation",
      "subject" => subject,
      "summary" => String.slice(arguments["instruction"], 0, 500),
      "text" => arguments["instruction"],
      "visibility" => "conversation"
    }

    with {:ok, record} <-
           Records.create(binding.state_token, operation, "guidance_offer", payload) do
      case Repo.fetch(Behavior.Query.by_offer_record_id(record.id)) do
        {:ok, behavior} -> {:ok, result(behavior, "duplicate")}
        {:error, :not_found} -> save(binding, entry, record, assignment, arguments)
      end
    end
  end

  defp save(binding, entry, record, assignment, arguments) do
    source = %{
      "input_id" => entry.id,
      "native_input_id" => entry.native_input_id,
      "revision" => entry.revision,
      "fingerprint" => entry.event_fingerprint,
      "episode_id" => entry.episode_id,
      "actor_ref" => entry.actor_ref
    }

    metadata = %{
      "correction_source" => source,
      "correction_request_sha256" => CanonicalJSON.digest(arguments),
      "requirements" => Enum.uniq(arguments["requirements"]),
      "assignment_ref" => assignment && assignment.ref,
      "assignment_identity" => assignment && assignment.identity_key
    }

    attributes = %{
      actor_ref: entry.actor_ref,
      confirmation_ref: "correction:#{entry.id}",
      occurred_at: Repo.now!(),
      target: %{
        transport: entry.destination_transport,
        conversation_ref: entry.destination_conversation_ref,
        thread_ref: entry.destination_thread_ref,
        message_ref: entry.source_item_ref || entry.native_input_id
      }
    }

    case Behaviors.keep_correction_in_transaction(record, binding.episode, attributes, metadata) do
      %{behavior: behavior} -> {:ok, result(behavior, "remembered")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp operation(entry, arguments),
    do: "correction:" <> CanonicalJSON.digest([entry.id, arguments["guidance_ref"]])

  defp result(behavior, status) do
    offer = behavior.offer_record_id |> Records.Record.Query.by_id() |> Repo.fetch!()

    %{
      "record_ref" => offer.ref,
      "behavior_ref" => behavior.ref,
      "revision" => behavior.revision,
      "status" => status,
      "scope" => "conversation",
      "instruction" => behavior.payload["text"],
      "requirements" => behavior.payload["requirements"],
      "assignment_ref" => behavior.payload["assignment_ref"]
    }
  end

  @doc "Called before ingress takes the memory review and conversation locks."
  def revoke_source(%Ingress.Inbox.Entry{event_kind: kind} = entry)
      when kind in [:edit, :delete] do
    :ok = lock_source(entry)
    query = Behavior.Query.corrections_before_revision(entry)

    if Repo.exists?(query) do
      Memories.Reviews.lock_review_maintenance!()

      behaviors = query |> Behavior.Query.lock_for_update() |> Repo.all()
      Enum.each(behaviors, &Behaviors.redact!(&1, :deleted, "correction_revised_payload_sha256"))

      behaviors
      |> Enum.map(& &1.workspace_ref)
      |> Enum.uniq()
      |> Enum.each(&Memories.Reviews.dismiss_orphan_reviews("system:correction-revision", &1))
    end

    :ok
  end

  def revoke_source(_entry), do: :ok

  defp lock_source(entry) do
    :ok = Memories.lock_answer_source_in_transaction(entry)

    AdvisoryLock.hold!(
      "correction-source:" <>
        CanonicalJSON.digest([
          entry.destination_transport,
          entry.destination_conversation_ref,
          entry.native_input_id
        ])
    )
  end
end
