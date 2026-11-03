defmodule Ryker.Records.TaskInstruction do
  @moduledoc "The current source instruction behind an automatic task start."
  alias Ryker.Behaviors
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Memories
  alias Ryker.Records.IncidentInstruction
  alias Ryker.Repo
  alias Ryker.RoutingExamples
  alias Ryker.Slack
  alias Ryker.Waits

  @doc "Resolve a frozen current input to its authenticated ingress and task grant."
  def fetch(binding, reference, assignment_ref, repository) do
    context = (binding.turn.submission || %{})["context"] || %{}

    inputs =
      case context["mode"] do
        "continuation" -> get_in(context, ["current_inputs", "items"]) || []
        _ -> Enum.filter(get_in(context, ["inputs", "items"]) || [], & &1["current"])
      end

    with true <- binding.episode.execution_mode == :live,
         {:ok, ^reference} <- Ecto.UUID.cast(reference),
         true <- Enum.any?(inputs, &(&1["source_event_id"] == reference)),
         {:ok, %Episodes.Event{kind: :input_admitted} = event} <-
           Repo.fetch(Episodes.Event.Query.by_id(reference)),
         true <- event.episode_id == binding.episode.id,
         true <- event.dedupe_key in binding.episode.active_input_refs,
         {:ok, source} <- source(binding, event) do
      authority(binding, source, event, assignment_ref, repository)
    else
      _ -> {:error, :task_instruction_not_authorized}
    end
  end

  defp source(binding, %Episodes.Event{
         payload: %{"payload" => %{"source" => %{}, "event_ref" => _} = source}
       }) do
    with {:ok, entry} <-
           Repo.fetch(
             Ingress.Inbox.Entry.Query.by_episode_id(binding.episode.id)
             |> Ingress.Inbox.Entry.Query.by_work_source(source)
           ),
         true <- entry.execution_mode == :live and is_nil(entry.operational_pruned_at),
         true <- entry.destination_transport == binding.episode.destination_transport,
         true <-
           entry.destination_conversation_ref == binding.episode.destination_conversation_ref,
         false <-
           Enum.any?(
             Repo.all(Ingress.Inbox.Entry.Query.later_revisions_of(entry)),
             &RoutingExamples.takes_back_words?/1
           ) do
      {:ok, entry}
    else
      _ -> {:error, :task_instruction_not_authorized}
    end
  end

  defp source(binding, event), do: IncidentInstruction.fetch(binding, event)

  @doc "Lock the authenticated source and any incident relationship before the episode."
  def lock_source(%Ingress.Inbox.Entry{} = entry) do
    with :ok <- Memories.lock_answer_source_in_transaction(entry),
         do: IncidentInstruction.lock_room_in_transaction(entry.destination_conversation_ref)
  end

  def lock_source(%IncidentInstruction{} = source),
    do: IncidentInstruction.lock_in_transaction(source)

  def lock_source(_source), do: {:error, :task_instruction_not_authorized}

  @doc "Whether reauthorization still names the same authenticated instruction."
  def same_source?(%Ingress.Inbox.Entry{} = first, %Ingress.Inbox.Entry{} = second),
    do: Ingress.Inbox.Entry.same_source?(first, second)

  def same_source?(%IncidentInstruction{} = first, %IncidentInstruction{} = second),
    do: first == second

  def same_source?(_first, _second), do: false

  defp authority(_binding, entry, event, nil, _repository) do
    if Slack.TaskAccess.proactive?(entry),
      do: {:ok, {entry, "system:proactive:" <> entry.destination_conversation_ref}},
      else: human_authority(entry, event)
  end

  defp authority(binding, %Ingress.Inbox.Entry{} = entry, _event, assignment_ref, repository)
       when is_binary(assignment_ref) do
    assignments =
      get_in(binding.turn.submission, ["context", "operator_context", "standing_assignments"]) ||
        []

    frozen = Enum.find(assignments, &(&1["assignment_ref"] == assignment_ref))

    run =
      Behaviors.StandingAssignmentRun.Query.decided_for_source(
        binding.episode.id,
        assignment_ref,
        Ingress.Inbox.ref(entry),
        entry.event_ref
      )
      |> Repo.fetch()

    with %{
           "authority_ceiling" => "repository_write",
           "repository" => ^repository,
           "revision" => revision
         } <- frozen,
         {:ok, {_run, %Behaviors.Behavior{status: :active, revision: ^revision} = assignment}} <-
           run,
         true <-
           assignment.payload["start_tasks"] == true and
             assignment.payload["repository"] == repository,
         true <- assignment.payload["source_kind"] == entry.source_kind,
         true <- Waits.SourceEventMatcher.matches?(assignment.payload["filter"], entry.content),
         true <-
           assignment.scope_kind == :conversation and
             assignment.scope_ref == entry.destination_conversation_ref,
         true <-
           is_nil(assignment.expires_at) or
             DateTime.compare(assignment.expires_at, Repo.now!()) == :gt do
      {:ok, {entry, "system:assignment:" <> assignment.ref}}
    else
      _ -> {:error, :task_instruction_not_authorized}
    end
  end

  defp authority(_binding, _entry, _event, _assignment_ref, _repository),
    do: {:error, :task_instruction_not_authorized}

  defp human_authority(%{actor_kind: :user, event_kind: kind} = entry, event)
       when kind in [:message, :edit],
       do: {:ok, {entry, event.payload["actor_ref"]}}

  defp human_authority(_entry, _event), do: {:error, :task_instruction_not_authorized}

  @doc "Fence a saved assignment against revocation before starting work."
  def lock_assignment(nil), do: :ok

  def lock_assignment(reference) do
    reference
    |> Behaviors.Behavior.Query.by_ref()
    |> Behaviors.Behavior.Query.lock_for_update()
    |> Repo.all()

    :ok
  end
end
