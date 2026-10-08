defmodule Ryker.Behaviors.StandingRules do
  @moduledoc """
  Standing rules meeting the messages Ryker receives: whether a channel's rule
  matches one (`standing_match?/1`), the run each matching rule starts, the
  run's outcome once routing decides, and the inventory of every rule a
  message was checked against, kept as evidence for the request's trace.

  `Ryker.Behaviors` is the context's public boundary and forwards here.
  """
  alias Ryker.Behaviors
  alias Ryker.Behaviors.Behavior
  alias Ryker.Behaviors.StandingAssignmentRun
  alias Ryker.Behaviors.StandingRuleInventory
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Waits

  @runtime_candidate_limit 100

  @doc "Returns true only when an active channel assignment matches trusted source identity and event shape."
  @spec standing_match?(Ingress.Input.t()) :: boolean()
  def standing_match?(%Ingress.Input{} = input), do: matching_assignments(input, false) != []

  def standing_match?(_input), do: false

  @doc """
  Records every standing rule that existed in this input's workspace, with the
  verdict each one got.

  This is observation, not scheduling. It reads a wider set than
  `matching_assignments/2` deliberately -- including rules in other
  conversations, paused rules and expired rules -- and none of what it reads
  can start work. Routing the enumerated matches into scheduling would turn an
  inspection change into a behaviour change, which is how observability breaks
  production.

  It is also optional. A failure here loses a diagnosis; failing the input
  would lose the answer the operator asked for, so errors are swallowed and the
  absent row honestly reads as "not recorded".
  """
  @spec record_rule_inventory(Ingress.Input.t(), String.t()) ::
          {:ok, StandingRuleInventory.t()} | {:error, term()}
  def record_rule_inventory(%Ingress.Input{} = input, input_ref) when is_binary(input_ref) do
    with :ok <- reference(input_ref, :input_ref) do
      # Its own short transaction: in production a failure here rolls back
      # nothing else, and under a test sandbox it is a savepoint, so a poisoned
      # statement cannot abort the caller's transaction either way.
      Repo.transaction(fn -> record_rule_inventory_locked(input, input_ref) end)
    end
  rescue
    error -> {:error, {:standing_rule_inventory_failed, error.__struct__}}
  end

  def record_rule_inventory(_input, _input_ref),
    do: {:error, {:invalid_standing_rule_inventory, :input}}

  @doc "Recorded inventories for many inputs in one query, keyed by input reference."
  @spec rule_inventories([String.t()]) :: %{String.t() => StandingRuleInventory.t()}
  def rule_inventories([]), do: %{}

  def rule_inventories(input_refs) when is_list(input_refs) do
    refs = Enum.filter(input_refs, &is_binary/1)

    refs
    |> StandingRuleInventory.Query.by_source_input_refs()
    |> Repo.all()
    |> Map.new(&{&1.source_input_ref, &1})
  end

  @doc false
  @spec observe_input(Ingress.Input.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def observe_input(%Ingress.Input{} = input, input_ref) do
    with :ok <- reference(input_ref, :input_ref) do
      transaction(fn -> observe_input_locked(input, input_ref) end)
    end
  end

  def observe_input(_input, _input_ref), do: {:error, {:invalid_behavior_run, :input}}

  @doc false
  @spec finalize_assignment_runs_in_transaction(
          String.t(),
          :start_episode | :continue_episode | :reply | :quick_reply | :react | :ignore,
          String.t(),
          Episodes.Episode.t() | nil,
          :decided | :superseded
        ) :: :ok | {:error, term()}
  def finalize_assignment_runs_in_transaction(
        input_ref,
        action,
        decision_ref,
        episode,
        outcome
      )
      when action in [:start_episode, :continue_episode, :reply, :quick_reply, :react, :ignore] and
             outcome in [:decided, :superseded] do
    with true <- Repo.in_transaction?(),
         :ok <- reference(input_ref, :input_ref),
         :ok <- reference(decision_ref, :decision_ref),
         :ok <- valid_final_episode(action, episode) do
      finalize_assignment_runs_locked(input_ref, action, decision_ref, episode, outcome)
    else
      false -> {:error, :behavior_run_transaction_required}
      {:error, reason} -> {:error, reason}
    end
  end

  def finalize_assignment_runs_in_transaction(
        _input_ref,
        _action,
        _decision_ref,
        _episode,
        _outcome
      ),
      do: {:error, {:invalid_behavior_run, :decision}}

  defp record_rule_inventory_locked(input, input_ref) do
    now = Repo.now!()

    workspace =
      Episodes.Scope.workspace_ref(
        input.destination.transport,
        input.destination.conversation_ref
      )

    rules = workspace_rules(workspace)

    considered =
      input
      |> runtime_candidates(now)
      |> Behavior.Query.select_ids()
      |> Repo.all()
      |> MapSet.new()

    entries = Enum.map(rules, &inventory_entry(&1, input, now, considered))

    case Repo.insert(
           %StandingRuleInventory{
             source_input_ref: input_ref,
             source_event_ref: input.event_ref,
             workspace_ref: workspace,
             conversation_ref: input.destination.conversation_ref,
             rule_count: length(rules),
             matched_count: Enum.count(entries, &(&1["verdict"] == "matched")),
             entries: entries,
             recorded_at: now
           },
           on_conflict: :nothing,
           conflict_target: :source_input_ref
         ) do
      {:ok, inventory} -> inventory
      {:error, changeset} -> Repo.rollback({:standing_rule_inventory_failed, changeset.errors})
    end
  end

  # Deliberately wider than the scheduling query: a reader needs to see the rule
  # that did not fire and why, and a rule scoped to another channel is a reason,
  # not an absence.
  defp workspace_rules(workspace) do
    Behavior.Query.by_kind(:standing_assignment)
    |> Behavior.Query.by_workspace(workspace)
    |> Behavior.Query.without_status([:deleted, :superseded])
    |> Behavior.Query.ordered_by_oldest()
    |> Repo.all()
  end

  defp inventory_entry(behavior, input, now, considered) do
    {verdict, reason} = inventory_verdict(behavior, input, now, considered)

    entry = %{
      "ref" => behavior.ref,
      "status" => Atom.to_string(behavior.status),
      "revision" => behavior.revision,
      "verdict" => verdict,
      "reason" => reason
    }

    # Another channel's rule is a reason, not a copy: its title, channel and
    # filter were copied into every message of the workspace, where deleting
    # that channel could not reach them (2026-10-04 review).
    if verdict == "out_of_scope" do
      entry
    else
      Map.merge(entry, %{
        "title" => behavior.payload["title"],
        "scope_ref" => behavior.scope_ref,
        "criteria" => assignment_criteria(behavior.payload),
        "evidence" =>
          if(verdict in ["matched", "not_matched"],
            do: assignment_evidence(behavior.payload, input)
          )
      })
    end
  end

  # What the rule looked for, frozen with its verdict so a later edit cannot
  # rewrite what this message was checked against.
  defp assignment_criteria(payload),
    do: %{"filter" => payload["filter"], "source_kind" => payload["source_kind"]}

  # What the check found in this message, one result per condition, so a
  # reader can see which condition decided the verdict. Every condition is
  # evaluated here even where the matcher itself stops at the first failure.
  defp assignment_evidence(payload, input),
    do: %{
      "filter_matches" => Waits.SourceEventMatcher.matches?(payload["filter"], input.content),
      "source_kind" => input.source.kind,
      "source_matches" => payload["source_kind"] == input.source.kind
    }

  defp inventory_verdict(%Behavior{status: :disabled}, _input, _now, _considered),
    do: {"disabled", "This rule was paused when the message was processed."}

  defp inventory_verdict(%Behavior{status: :expired}, _input, _now, _considered),
    do: {"expired", "This rule expired before the message arrived."}

  defp inventory_verdict(%Behavior{status: status}, _input, _now, _considered)
       when status != :active,
       do: {Atom.to_string(status), "This rule was #{status} when the message was processed."}

  defp inventory_verdict(
         %Behavior{expires_at: %DateTime{} = expires_at} = behavior,
         input,
         now,
         considered
       ) do
    if DateTime.compare(expires_at, now) == :gt,
      do: inventory_verdict(%{behavior | expires_at: nil}, input, now, considered),
      else: {"expired", "This rule expired before the message arrived."}
  end

  defp inventory_verdict(%Behavior{scope_kind: scope_kind}, _input, _now, _considered)
       when scope_kind != :conversation,
       do: {"out_of_scope", "This rule does not apply to this conversation."}

  defp inventory_verdict(%Behavior{scope_ref: scope_ref} = behavior, input, _now, considered) do
    cond do
      scope_ref != input.destination.conversation_ref ->
        {"out_of_scope", "This rule applies to another channel."}

      # Outside the runtime's candidate window the predicate was never run.
      # Calling such a rule "matched" would credit it with an engagement it
      # could not have caused.
      not MapSet.member?(considered, behavior.id) ->
        {"not_considered",
         "Only the first #{@runtime_candidate_limit} applicable rules are evaluated. This rule's trigger was not checked."}

      assignment_matches?(behavior.payload, input) ->
        {"matched", "The recorded source and event filter matched this message."}

      true ->
        {"not_matched", "The recorded source and event filter did not match this message."}
    end
  end

  defp matching_assignments(input, lock?) do
    query = runtime_candidates(input, Repo.now!())
    query = if lock?, do: Behavior.Query.lock_for_share(query), else: query

    query
    |> Repo.all()
    |> Enum.filter(&assignment_matches?(&1.payload, input))
  end

  # The exact rules the runtime considers for one input. Shared with the
  # inventory recorder so "not considered" there means precisely "outside this
  # window", never a second opinion about eligibility.
  defp runtime_candidates(input, now) do
    workspace =
      Episodes.Scope.workspace_ref(
        input.destination.transport,
        input.destination.conversation_ref
      )

    # Every standing rule is confirmed in a conversation and scoped to it.
    Behavior.Query.by_kind(:standing_assignment)
    |> Behavior.Query.by_status(:active)
    |> Behavior.Query.by_workspace(workspace)
    |> Behavior.Query.scoped_to(:conversation, input.destination.conversation_ref)
    |> Behavior.Query.unexpired_at(now)
    |> Behavior.Query.ordered_by_oldest()
    |> Behavior.Query.limit_to(@runtime_candidate_limit)
  end

  defp observe_input_locked(input, input_ref) do
    assignments = matching_assignments(input, true)
    Enum.each(assignments, &insert_assignment_run!(&1, input, input_ref))

    length(assignments)
  end

  defp insert_assignment_run!(assignment, input, input_ref) do
    existing =
      StandingAssignmentRun.Query.by_assignment_id(assignment.id)
      |> StandingAssignmentRun.Query.by_source_input_ref(input_ref)
      |> StandingAssignmentRun.Query.lock_for_update()
      |> Repo.one()

    case existing do
      %StandingAssignmentRun{source_event_ref: event_ref}
      when event_ref == input.event_ref ->
        :ok

      %StandingAssignmentRun{} ->
        Repo.rollback(:standing_assignment_run_conflict)

      nil ->
        digest = CanonicalJSON.digest([assignment.id, input_ref])

        case Repo.insert(
               StandingAssignmentRun.Changeset.insert(%{
                 assignment_id: assignment.id,
                 id: Repo.generate_id(),
                 outcome: :pending,
                 ref: "assignment-run:#{digest}",
                 source_event_ref: input.event_ref,
                 source_input_ref: input_ref
               })
             ) do
          {:ok, _run} ->
            Behaviors.broadcast_behavior_updated(assignment.id)

          {:error, changeset} ->
            Repo.rollback({:standing_assignment_run_failed, changeset.errors})
        end
    end
  end

  defp finalize_assignment_runs_locked(input_ref, action, decision_ref, episode, outcome) do
    now = Repo.now!()
    episode_id = if action in [:start_episode, :continue_episode, :reply], do: episode.id

    StandingAssignmentRun.Query.by_source_input_ref(input_ref)
    |> StandingAssignmentRun.Query.ordered_by_oldest()
    |> StandingAssignmentRun.Query.lock_for_update()
    |> Repo.all()
    |> Enum.each(fn run ->
      desired = %{
        decision_action: action,
        decision_ref: decision_ref,
        episode_id: episode_id,
        outcome: outcome
      }

      finalize_assignment_run(run, desired, now)
    end)

    :ok
  end

  defp finalize_assignment_run(%StandingAssignmentRun{outcome: :pending} = run, desired, now) do
    changeset = StandingAssignmentRun.Changeset.finalize(run, desired)

    case Repo.update(changeset) do
      {:ok, _updated} -> increment_assignment_use(run.assignment_id, now)
      {:error, changeset} -> Repo.rollback({:standing_assignment_run_failed, changeset.errors})
    end
  end

  defp finalize_assignment_run(%StandingAssignmentRun{} = existing, desired, _now) do
    if Map.take(existing, [:decision_action, :decision_ref, :episode_id, :outcome]) == desired,
      do: :ok,
      else: Repo.rollback(:standing_assignment_run_conflict)
  end

  defp increment_assignment_use(assignment_id, now) do
    _count =
      assignment_id
      |> Behavior.Query.by_id()
      |> Repo.update_all(inc: [use_count: 1], set: [last_used_at: now])

    Behaviors.broadcast_behavior_updated(assignment_id)
  end

  defp valid_final_episode(action, %Episodes.Episode{})
       when action in [:start_episode, :continue_episode, :reply],
       do: :ok

  defp valid_final_episode(action, nil) when action in [:quick_reply, :react, :ignore], do: :ok
  defp valid_final_episode(_action, _episode), do: {:error, {:invalid_behavior_run, :episode}}

  defp transaction(callback) do
    if Repo.in_transaction?() do
      {:ok, callback.()}
    else
      Repo.transaction(callback)
    end
  end

  defp assignment_matches?(%{"source_kind" => source_kind, "filter" => filter}, input) do
    source_kind == input.source.kind and Waits.SourceEventMatcher.matches?(filter, input.content)
  end

  defp reference(value, field),
    do: Reference.check(value, field, :invalid_behavior_confirmation)
end
