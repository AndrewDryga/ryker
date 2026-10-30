defmodule Ryker.Records.TaskInstruction do
  @moduledoc "The current source instruction behind an automatic task start."
  alias Ryker.Behaviors
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Repo
  alias Ryker.RoutingExamples
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
         %{"payload" => %{"source" => %{}, "event_ref" => _} = source} <- event.payload,
         {:ok, entry} <-
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
      authority(binding, entry, event, assignment_ref, repository)
    else
      _ -> {:error, :task_instruction_not_authorized}
    end
  end

  defp authority(
         _binding,
         %{actor_kind: :user, event_kind: kind} = entry,
         event,
         nil,
         _repository
       )
       when kind in [:message, :edit],
       do: {:ok, {entry, event.payload["actor_ref"]}}

  defp authority(binding, entry, _event, assignment_ref, repository)
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
