defmodule Responder.State.Records do
  @moduledoc """
  Durable, episode-scoped state-tool records.

  The opaque turn token is a narrow capability for inert record creation. It
  remains valid only while that exact Work turn owns the episode and has not
  entered cancellation or delivery custody.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Emisar.Approvals
  alias Responder.Episodes.Episode
  alias Responder.Ingress.Input
  alias Responder.Repo

  alias Responder.State.{
    DerivedContext,
    EventSubscriptions,
    EventWaitTiming,
    InvestigationPayload,
    Record,
    RecordChangeset,
    RecordPayload,
    SourceEventMatcher
  }

  alias Responder.Work.Turn

  @operation_id ~r/\A[A-Za-z0-9_.:-]{1,80}\z/
  @maximum_records_per_turn 64
  @maximum_model_records 64
  @maximum_working_goals 3
  @terminal_goal_states ~w(completed excluded cancelled)
  @excluded_goal_states ~w(excluded cancelled)
  @goal_stages InvestigationPayload.goal_stages()
  @satisfied_prerequisite_states ~w(completed excluded)
  @shadow_record_kinds ~w(evidence coverage finding progress alert_assessment)
  @confirmation_offer_kinds ~w(task_offer publication_offer schedule_offer automation_change_offer memory_offer preference_offer guidance_offer standing_assignment_offer)

  @spec token(Turn.t()) :: String.t()
  def token(%Turn{id: id}) when is_binary(id), do: "state:" <> id

  @spec create(String.t(), String.t(), String.t(), map()) ::
          {:ok, Record.t()} | {:error, term()}
  def create(state_token, operation_id, kind, payload, options \\ []) do
    with {:ok, turn_id} <- turn_id(state_token),
         :ok <- operation_id(operation_id),
         :ok <- known_kind(kind),
         {:ok, parallel_goal_limit} <- create_options(options),
         {:ok, episode_id} <- episode_id(turn_id) do
      Repo.transaction(fn ->
        create_locked(
          episode_id,
          turn_id,
          operation_id,
          kind,
          payload,
          parallel_goal_limit
        )
      end)
      |> transaction_result()
    end
  end

  defp create_locked(
         episode_id,
         turn_id,
         operation_id,
         kind,
         payload,
         parallel_goal_limit
       ) do
    with {:ok, episode} <- lock_episode(episode_id),
         {:ok, turn} <- lock_turn(turn_id, episode_id),
         :ok <- authorize(episode, turn, kind),
         ref <- record_ref(turn.id, operation_id, kind),
         {:ok, prepared} <- RecordPayload.prepare(kind, payload, ref),
         {:ok, record} <-
           create_or_reconcile(
             episode,
             turn,
             operation_id,
             kind,
             ref,
             prepared,
             parallel_goal_limit
           ),
         :ok <- validate_timer(record),
         :ok <- Approvals.ensure_registered_in_transaction(record) do
      record
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_timer(%Record{
         kind: "event_wait",
         inserted_at: inserted_at,
         payload: %{"event_matcher" => %{"type" => type} = trigger, "deadline_at" => deadline}
       })
       when type in ["after", "at"] do
    # Use the saved record, including on idempotent retries. Anchoring a delay
    # to acceptance or reconciliation would silently move its promised wakeup.
    with {:ok, due_at} <- EventWaitTiming.due_at(trigger, inserted_at),
         {:ok, deadline_at, 0} <- DateTime.from_iso8601(deadline),
         :lt <- DateTime.compare(due_at, deadline_at) do
      :ok
    else
      _invalid -> {:error, {:invalid_state_record, :timer_deadline}}
    end
  end

  defp validate_timer(_record), do: :ok

  @spec validation_records(Ecto.UUID.t()) :: map()
  def validation_records(episode_id) do
    Repo.all(
      from(record in Record,
        where:
          record.episode_id == ^episode_id and
            record.status in [:open, :confirmed],
        order_by: [asc: record.sequence]
      )
    )
    |> Map.new(fn record ->
      {record.ref, %{"continuation" => record.continuation, "kind" => record.kind}}
    end)
  end

  @doc "Read-only retained history for operator projections, not a model disclosure."
  @spec retained_records(Ecto.UUID.t()) :: [map()]
  def retained_records(episode_id) do
    Repo.all(
      from(record in Record,
        where:
          record.episode_id == ^episode_id and
            record.status in [:open, :confirmed],
        order_by: [desc: record.sequence],
        limit: @maximum_model_records
      )
    )
    |> Enum.reverse()
    |> Enum.map(fn record ->
      %{
        "kind" => record.kind,
        "payload" => record.payload,
        "ref" => record.ref,
        "status" => Atom.to_string(record.status)
      }
    end)
  end

  @spec model_records(Episode.t(), String.t() | nil) :: [map()]
  def model_records(%Episode{} = destination, repository) do
    destination.id
    |> retained_records()
    |> Enum.map(&DerivedContext.record/1)
    |> DerivedContext.filter(destination, repository)
    |> Enum.map(& &1["document"])
  end

  @spec open_required_goals(Ecto.UUID.t()) :: [map()]
  def open_required_goals(episode_id) when is_binary(episode_id) do
    Repo.all(
      from(record in Record,
        where:
          record.episode_id == ^episode_id and record.kind in ["goal", "goal_state"] and
            record.status in [:open, :confirmed],
        order_by: [asc: record.sequence]
      )
    )
    |> current_required_goals()
  end

  def open_required_goals(_episode_id), do: []

  @spec goals(Ecto.UUID.t()) :: [map()]
  def goals(episode_id) when is_binary(episode_id) do
    episode_id
    |> goal_records()
    |> goals_from_records()
  end

  def goals(_episode_id), do: []

  @doc """
  The current plan, grouped by the lifecycle stage each goal belongs to.

  Counts only current logical leaves: a parent heading, a superseded attempt
  and another stage's goals are never counted in a stage's subtask total.
  """
  @spec plan(Ecto.UUID.t()) :: map()
  def plan(episode_id) when is_binary(episode_id) do
    episode_id
    |> goal_records()
    |> plan_from_records()
  end

  def plan(_episode_id), do: plan_from_records([])

  @doc false
  @spec plan_from_records([Record.t()]) :: map()
  def plan_from_records(records) do
    goals = goals_from_records(records)
    parents = MapSet.new(goals, & &1["parent_goal_id"]) |> MapSet.delete(nil)
    superseded = MapSet.new(goals, & &1["successor_of"]) |> MapSet.delete(nil)

    current =
      goals
      |> Enum.reject(&MapSet.member?(superseded, &1["id"]))
      |> Enum.map(&Map.put(&1, "leaf", not MapSet.member?(parents, &1["id"])))

    Map.new(@goal_stages ++ ["unassigned"], fn stage ->
      key = if stage == "unassigned", do: nil, else: stage
      {stage, stage_bucket(Enum.filter(current, &(&1["stage"] == key)))}
    end)
  end

  defp stage_bucket(goals) do
    leaves = Enum.filter(goals, & &1["leaf"])
    excluded = Enum.filter(leaves, &(&1["state"] in @excluded_goal_states))

    %{
      "changed_at" => goals |> Enum.map(& &1["changed_at"]) |> latest_datetime(),
      "completed" => Enum.count(leaves, &(&1["state"] == "completed")),
      "excluded" => length(excluded),
      "goals" => goals,
      "leaves" => leaves,
      "total" => length(leaves) - length(excluded)
    }
  end

  defp latest_datetime(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  @spec repository_write_goals(Ecto.UUID.t()) :: [map()]
  def repository_write_goals(episode_id) when is_binary(episode_id) do
    goal_records(episode_id)
    |> goals_from_records()
    |> Enum.filter(&(&1["authority"] == "repository_write"))
    |> Enum.map(&Map.take(&1, ~w(id required state writable_repository)))
  end

  def repository_write_goals(_episode_id), do: []

  @spec fetch_many([String.t()]) :: {:ok, [Record.t()]} | {:error, term()}
  def fetch_many(refs) when is_list(refs), do: fetch_records(refs, nil)
  def fetch_many(_refs), do: {:error, :state_record_not_found}

  @spec fetch_for_episode(Ecto.UUID.t(), [String.t()]) ::
          {:ok, [Record.t()]} | {:error, term()}
  def fetch_for_episode(episode_id, refs) when is_binary(episode_id) and is_list(refs),
    do: fetch_records(refs, episode_id)

  def fetch_for_episode(_episode_id, _refs), do: {:error, :state_record_not_found}

  @doc false
  @spec resolve_wait_in_transaction(String.t()) :: :ok | {:error, term()}
  def resolve_wait_in_transaction(wait_ref) when is_binary(wait_ref) do
    if Repo.in_transaction?() do
      query =
        from(record in Record,
          where:
            record.ref == ^wait_ref and record.kind in ["input_request", "event_wait"] and
              record.status == :open,
          update: [set: [status: :answered, updated_at: fragment("clock_timestamp()")]]
        )

      _resolved = Repo.update_all(query, [])
      EventSubscriptions.resolve_wait_in_transaction(wait_ref, :input)
    else
      {:error, :state_record_transaction_required}
    end
  end

  def resolve_wait_in_transaction(_wait_ref), do: {:error, :state_record_not_found}

  @doc false
  @spec user_resumable_wait?(String.t()) :: boolean()
  def user_resumable_wait?(wait_ref) when is_binary(wait_ref) do
    not Repo.exists?(
      from(record in Record,
        where:
          record.ref == ^wait_ref and record.kind == "emisar_approval" and
            record.status == :open
      )
    )
  end

  def user_resumable_wait?(_wait_ref), do: false

  @doc false
  @spec user_resumable_wait?(String.t(), Input.t()) :: boolean()
  def user_resumable_wait?(wait_ref, %Input{} = input) when is_binary(wait_ref) do
    # A question owns its wait until admission resumes the episode, even after a
    # native choice already marked the record answered. Only a person may consume it.
    case Repo.one(
           from(record in Record,
             where:
               record.ref == ^wait_ref and
                 (record.status == :open or record.kind == "input_request"),
             select: %{kind: record.kind, payload: record.payload}
           )
         ) do
      %{kind: "emisar_approval"} -> false
      %{kind: "event_wait"} when input.actor.kind == :user -> true
      %{kind: "event_wait", payload: payload} -> event_wait_matches?(payload, input)
      %{kind: "input_request"} -> input.actor.kind == :user
      nil -> true
      _other_record -> false
    end
  end

  def user_resumable_wait?(_wait_ref, _input), do: false

  defp event_wait_matches?(%{"event_matcher" => %{"type" => "source_event"} = trigger}, input) do
    source_matches?(trigger["source_kind"], input.source.kind) and
      SourceEventMatcher.matches?(trigger["match"], input.content)
  end

  defp event_wait_matches?(_legacy_or_timer, _input), do: true

  defp source_matches?(nil, _actual), do: true
  defp source_matches?(expected, actual), do: expected == actual

  defp fetch_records(refs, episode_id) do
    unique = Enum.uniq(refs)

    records =
      if unique == [] do
        []
      else
        query = from(record in Record, where: record.ref in ^unique)

        query =
          if episode_id,
            do: from(record in query, where: record.episode_id == ^episode_id),
            else: query

        Repo.all(query)
      end

    by_ref = Map.new(records, &{&1.ref, &1})

    if map_size(by_ref) == length(unique),
      do: {:ok, Enum.map(unique, &Map.fetch!(by_ref, &1))},
      else: {:error, :state_record_not_found}
  end

  defp episode_id(turn_id) do
    case Repo.one(from(turn in Turn, where: turn.id == ^turn_id, select: turn.episode_id)) do
      nil -> {:error, :state_record_unauthorized}
      episode_id -> {:ok, episode_id}
    end
  end

  defp lock_episode(episode_id) do
    case Repo.one(from(episode in Episode, where: episode.id == ^episode_id, lock: "FOR UPDATE")) do
      nil -> {:error, :state_record_unauthorized}
      episode -> {:ok, episode}
    end
  end

  defp lock_turn(turn_id, episode_id) do
    case Repo.one(
           from(turn in Turn,
             where: turn.id == ^turn_id and turn.episode_id == ^episode_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :state_record_unauthorized}
      turn -> {:ok, turn}
    end
  end

  defp authorize(
         %Episode{
           destination_transport: transport,
           execution_mode: execution_mode,
           owner_kind: :turn,
           owner_ref: owner_ref,
           state: :working
         },
         %Turn{
           cancellation_intent: nil,
           status: :pending,
           turn_ref: owner_ref
         },
         kind
       ) do
    cond do
      execution_mode != :live and kind not in @shadow_record_kinds ->
        {:error, :state_record_shadow_forbidden}

      kind in @confirmation_offer_kinds and transport not in ["slack", "control_plane", "github"] ->
        {:error, :state_record_confirmation_unsupported}

      kind == "slack_post_offer" and transport not in ["slack", "control_plane"] ->
        {:error, :state_record_confirmation_unsupported}

      true ->
        :ok
    end
  end

  defp authorize(_episode, _turn, _kind), do: {:error, :state_record_unauthorized}

  defp create_or_reconcile(
         episode,
         turn,
         operation_id,
         kind,
         ref,
         prepared,
         parallel_goal_limit
       ) do
    fingerprint =
      CanonicalJSON.digest(%{
        "continuation" => prepared.continuation,
        "payload" => prepared.payload
      })

    case Repo.one(
           from(record in Record,
             where: record.turn_id == ^turn.id and record.operation_id == ^operation_id
           )
         ) do
      nil ->
        with :ok <- validate_temporal(kind, prepared.continuation),
             :ok <-
               validate_relationships(
                 episode.id,
                 kind,
                 prepared.payload,
                 parallel_goal_limit
               ),
             :ok <- record_capacity(turn.id),
             :ok <- supersede_prior_record(episode.id, turn.id, kind, prepared.payload) do
          %{
            continuation: prepared.continuation,
            episode_id: episode.id,
            id: Ecto.UUID.generate(),
            kind: kind,
            operation_id: operation_id,
            payload: prepared.payload,
            payload_fingerprint: fingerprint,
            ref: ref,
            status: :open,
            subject_ref: prepared.subject_ref,
            turn_id: turn.id
          }
          |> RecordChangeset.insert()
          |> Repo.insert()
          |> persistence_result()
        end

      %Record{kind: ^kind, payload_fingerprint: ^fingerprint} = record ->
        {:ok, record}

      %Record{} ->
        {:error, :state_record_operation_conflict}
    end
  end

  defp record_ref(turn_id, operation_id, kind) do
    digest =
      :crypto.hash(:sha256, turn_id <> <<0>> <> operation_id <> <<0>> <> kind)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "record:#{kind}:#{digest}"
  end

  defp record_capacity(turn_id) do
    count = Repo.aggregate(from(record in Record, where: record.turn_id == ^turn_id), :count)

    if count < @maximum_records_per_turn,
      do: :ok,
      else: {:error, {:invalid_state_record, :record_limit}}
  end

  defp validate_temporal("event_wait", %{"deadline_at" => nil}), do: :ok

  defp validate_temporal(
         "event_wait",
         %{"deadline_at" => deadline_at, "kind" => "wait", "wait_kind" => "event"}
       ) do
    with {:ok, deadline, 0} <- DateTime.from_iso8601(deadline_at),
         {:ok, %{rows: [[%DateTime{} = now]]}} <- Repo.query("SELECT clock_timestamp()"),
         :gt <- DateTime.compare(deadline, now) do
      :ok
    else
      _elapsed_or_invalid -> {:error, :deadline_elapsed}
    end
  end

  defp validate_temporal(_kind, _continuation), do: :ok

  defp supersede_prior_record(
         episode_id,
         turn_id,
         "task_offer",
         %{"instruction_ref" => instruction_ref, "repository" => repository}
       )
       when is_binary(instruction_ref) and byte_size(instruction_ref) > 0 and
              is_binary(repository) and byte_size(repository) > 0 do
    ids =
      Repo.all(
        from(record in Record,
          where:
            record.episode_id == ^episode_id and record.turn_id != ^turn_id and
              record.kind == "task_offer" and record.status == :open,
          select: {record.id, record.payload}
        )
      )
      |> Enum.flat_map(fn
        {id, %{"instruction_ref" => ^instruction_ref, "repository" => ^repository}} -> [id]
        _other -> []
      end)

    if ids != [] do
      from(record in Record,
        where: record.id in ^ids,
        update: [set: [status: :superseded, updated_at: fragment("clock_timestamp()")]]
      )
      |> Repo.update_all([])
    end

    :ok
  end

  defp supersede_prior_record(_episode_id, _turn_id, _kind, _payload), do: :ok

  defp validate_relationships(episode_id, "evidence", payload, _parallel_goal_limit),
    do: evidence_refs_exist(episode_id, Map.get(payload, "supersedes", []), :supersedes)

  defp validate_relationships(episode_id, "finding", payload, _parallel_goal_limit) do
    refs =
      Map.get(payload, "cause_evidence", []) ++
        (payload
         |> Map.get("alternatives", [])
         |> Enum.flat_map(fn alternative ->
           case alternative["discriminated_by"] do
             nil -> []
             ref -> [ref]
           end
         end))

    evidence_refs_exist(episode_id, refs, :cause_evidence)
  end

  defp validate_relationships(episode_id, "goal", payload, _parallel_goal_limit) do
    goal_id = payload["id"]
    parent_goal_id = payload["parent_goal_id"]
    prerequisites = Map.get(payload, "prerequisite_goal_ids", [])

    cond do
      goal_id in prerequisites ->
        {:error, {:invalid_state_record, :prerequisite_goal_ids}}

      goal_id == parent_goal_id ->
        {:error, {:invalid_state_record, :parent_goal_id}}

      goal_exists?(episode_id, goal_id) ->
        {:error, :state_record_subject_conflict}

      true ->
        goals = goals(episode_id)

        with :ok <- optional_goal_exists(episode_id, parent_goal_id, :parent_goal_id),
             :ok <- goals_exist(episode_id, prerequisites, :prerequisite_goal_ids),
             :ok <- parent_stage(payload, goals) do
          successor_attempt(payload, goals)
        end
    end
  end

  defp validate_relationships(episode_id, "goal_state", payload, parallel_goal_limit) do
    goal_id = payload["goal_id"]
    requested_state = payload["state"]
    goals = goals(episode_id)

    case Enum.find(goals, &(&1["id"] == goal_id)) do
      nil ->
        {:error, {:invalid_state_record, :goal_id}}

      goal ->
        with :ok <- goal_transition(goal["state"], requested_state),
             :ok <- prerequisites_satisfied(goal, goals, requested_state),
             :ok <- children_terminal(goal_id, goals, requested_state),
             :ok <-
               evidence_refs_exist(
                 episode_id,
                 Map.get(payload, "evidence_refs", []),
                 :evidence_refs
               ) do
          working_capacity(goal_id, goals, requested_state, parallel_goal_limit)
        end
    end
  end

  defp validate_relationships(
         episode_id,
         "alert_assessment",
         payload,
         _parallel_goal_limit
       ) do
    cause_refs = Map.get(payload, "evidence_refs", [])
    scope = payload["scope"] || %{}
    scope_refs = Map.get(scope, "evidence_refs", [])
    refs = Enum.uniq(cause_refs ++ scope_refs)

    with {:ok, evidence} <- evidence_records(episode_id, refs, :evidence_refs),
         :ok <- cause_claims(cause_refs, payload, evidence) do
      checked_targets(scope, evidence)
    end
  end

  defp validate_relationships(_episode_id, _kind, _payload, _parallel_goal_limit), do: :ok

  defp evidence_refs_exist(episode_id, refs, field) do
    case evidence_records(episode_id, Enum.uniq(refs), field) do
      {:ok, _records} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp evidence_records(_episode_id, [], _field), do: {:ok, []}

  defp evidence_records(episode_id, refs, field) do
    records =
      Repo.all(
        from(record in Record,
          where:
            record.episode_id == ^episode_id and record.kind == "evidence" and
              record.status in [:open, :confirmed] and record.ref in ^refs
        )
      )

    if length(records) == length(refs),
      do: {:ok, records},
      else: {:error, {:invalid_state_record, field}}
  end

  defp cause_claims([], _payload, _evidence), do: :ok

  defp cause_claims(refs, payload, evidence) do
    claims = Map.get(payload, "cause_claim_ids", [])
    by_ref = Map.new(evidence, &{&1.ref, &1})

    if Enum.all?(refs, fn ref ->
         get_in(by_ref, [ref, Access.key(:payload), "claim_id"]) in claims
       end),
       do: :ok,
       else: {:error, {:invalid_state_record, :cause_claim_ids}}
  end

  defp checked_targets(%{"checked_targets" => checked, "evidence_refs" => refs}, evidence) do
    selected = MapSet.new(refs)

    observed =
      evidence
      |> Enum.filter(&MapSet.member?(selected, &1.ref))
      |> Enum.map(& &1.payload["target"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    if Enum.all?(checked, &MapSet.member?(observed, &1)),
      do: :ok,
      else: {:error, {:invalid_state_record, :checked_targets}}
  end

  defp checked_targets(_scope, _evidence), do: :ok

  defp goal_exists?(episode_id, goal_id) do
    Repo.exists?(
      from(record in Record,
        where:
          record.episode_id == ^episode_id and record.kind == "goal" and
            record.subject_ref == ^goal_id and record.status in [:open, :confirmed]
      )
    )
  end

  defp optional_goal_exists(_episode_id, nil, _field), do: :ok

  defp optional_goal_exists(episode_id, goal_id, field) do
    if goal_exists?(episode_id, goal_id),
      do: :ok,
      else: {:error, {:invalid_state_record, field}}
  end

  defp goals_exist(_episode_id, [], _field), do: :ok

  defp goals_exist(episode_id, goal_ids, field) do
    count =
      Repo.aggregate(
        from(record in Record,
          where:
            record.episode_id == ^episode_id and record.kind == "goal" and
              record.subject_ref in ^goal_ids and record.status in [:open, :confirmed]
        ),
        :count
      )

    if count == length(goal_ids), do: :ok, else: {:error, {:invalid_state_record, field}}
  end

  # A subtask belongs to the stage its parent heading belongs to. Splitting a
  # tree across stages would count the same work twice on the task card.
  defp parent_stage(%{"parent_goal_id" => parent_id, "stage" => stage}, goals)
       when is_binary(parent_id) do
    case Enum.find(goals, &(&1["id"] == parent_id)) do
      %{"stage" => parent_stage} when parent_stage in [nil, stage] -> :ok
      _mismatch -> {:error, {:invalid_state_record, :stage}}
    end
  end

  defp parent_stage(_payload, _goals), do: :ok

  # A repeated check after changed work is a new attempt linked to the old one.
  # The terminal predecessor keeps its own result and is never reopened.
  defp successor_attempt(%{"successor_of" => predecessor_id, "stage" => stage}, goals)
       when is_binary(predecessor_id) do
    superseded? = Enum.any?(goals, &(&1["successor_of"] == predecessor_id))

    case Enum.find(goals, &(&1["id"] == predecessor_id)) do
      nil ->
        {:error, {:invalid_state_record, :successor_of}}

      _predecessor when superseded? ->
        {:error, {:invalid_state_record, :successor_of}}

      %{"state" => state} when state not in @terminal_goal_states ->
        {:error, {:invalid_state_record, :successor_of}}

      %{"stage" => predecessor_stage} when predecessor_stage != stage ->
        {:error, {:invalid_state_record, :stage}}

      _predecessor ->
        :ok
    end
  end

  defp successor_attempt(_payload, _goals), do: :ok

  defp goal_transition(current, requested) when current == requested, do: :ok

  defp goal_transition(current, _requested) when current in @terminal_goal_states,
    do: {:error, {:invalid_state_record, :goal_state}}

  defp goal_transition(current, requested)
       when current in ~w(ready working waiting blocked) and
              requested in ~w(ready working waiting completed blocked excluded cancelled),
       do: :ok

  defp goal_transition(_current, _requested),
    do: {:error, {:invalid_state_record, :goal_state}}

  defp prerequisites_satisfied(_goal, _goals, state)
       when state not in ["working", "completed"],
       do: :ok

  defp prerequisites_satisfied(goal, goals, _state) do
    states = Map.new(goals, &{&1["id"], &1["state"]})

    if Enum.all?(Map.get(goal, "prerequisite_goal_ids", []), fn prerequisite_id ->
         Map.get(states, prerequisite_id) in @satisfied_prerequisite_states
       end),
       do: :ok,
       else: {:error, {:invalid_state_record, :prerequisite_goal_ids}}
  end

  defp children_terminal(_goal_id, _goals, state) when state != "completed", do: :ok

  defp children_terminal(goal_id, goals, "completed") do
    open_child? =
      Enum.any?(goals, fn goal ->
        goal["parent_goal_id"] == goal_id and goal["required"] and
          goal["state"] not in @terminal_goal_states
      end)

    if open_child?,
      do: {:error, {:invalid_state_record, :child_goal_ids}},
      else: :ok
  end

  defp working_capacity(_goal_id, _goals, state, _parallel_goal_limit)
       when state != "working",
       do: :ok

  defp working_capacity(goal_id, goals, "working", parallel_goal_limit) do
    already_working? = Enum.any?(goals, &(&1["id"] == goal_id and &1["state"] == "working"))
    parents = MapSet.new(goals, & &1["parent_goal_id"]) |> MapSet.delete(nil)

    # A parent heading is visual containment over its children, not another
    # independently running goal; it must not consume worker concurrency.
    working =
      Enum.count(
        goals,
        &(&1["state"] == "working" and not MapSet.member?(parents, &1["id"]))
      )

    if already_working? or MapSet.member?(parents, goal_id) or working < parallel_goal_limit,
      do: :ok,
      else: {:error, {:invalid_state_record, :parallel_goal_limit}}
  end

  defp current_required_goals(records) do
    records
    |> goals_from_records()
    |> Enum.flat_map(fn goal ->
      if goal["required"] and goal["state"] not in @terminal_goal_states do
        [Map.take(goal, ~w(id requested_outcome state))]
      else
        []
      end
    end)
  end

  @doc false
  def goals_from_records(records) do
    states =
      records
      |> Enum.filter(&(&1.kind == "goal_state"))
      |> Map.new(&{&1.subject_ref, &1})

    successors =
      records
      |> Enum.filter(&(&1.kind == "goal"))
      |> Enum.flat_map(fn %Record{subject_ref: id, payload: goal} ->
        case goal["successor_of"] do
          nil -> []
          predecessor -> [{predecessor, id}]
        end
      end)
      |> Map.new()

    records
    |> Enum.filter(&(&1.kind == "goal"))
    |> Enum.map(fn %Record{subject_ref: id, payload: goal} = record ->
      state = Map.get(states, id)

      goal
      |> Map.merge(%{
        "changed_at" => (state || record).inserted_at,
        "detail" => state && state.payload["detail"],
        "evidence_refs" => (state && state.payload["evidence_refs"]) || [],
        "id" => id,
        # Records written before typed membership existed carry no stage. They
        # stay explicitly unassigned instead of being backfilled into a guess.
        "stage" => goal["stage"],
        "state" => (state && state.payload["state"]) || "ready",
        "successor_id" => Map.get(successors, id),
        "successor_of" => goal["successor_of"]
      })
    end)
  end

  defp goal_records(episode_id) do
    Repo.all(
      from(record in Record,
        where:
          record.episode_id == ^episode_id and record.kind in ["goal", "goal_state"] and
            record.status in [:open, :confirmed],
        order_by: [asc: record.sequence]
      )
    )
  end

  defp turn_id("state:" <> id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :state_record_unauthorized}
    end
  end

  defp turn_id(_token), do: {:error, :state_record_unauthorized}

  defp operation_id(value) do
    if is_binary(value) and Regex.match?(@operation_id, value),
      do: :ok,
      else: {:error, {:invalid_state_record, :operation_id}}
  end

  defp known_kind(kind) do
    if kind in RecordPayload.kinds(),
      do: :ok,
      else: {:error, {:invalid_state_record, :kind}}
  end

  defp create_options(options) when is_list(options) do
    if Keyword.keyword?(options) and
         Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- [:parallel_goal_limit] == [] do
      create_options(Map.new(options))
    else
      {:error, {:invalid_state_record, :options}}
    end
  end

  defp create_options(%{} = options) do
    limit = Map.get(options, :parallel_goal_limit, @maximum_working_goals)

    if Map.keys(options) -- [:parallel_goal_limit] == [] and is_integer(limit) and limit in 1..3,
      do: {:ok, limit},
      else: {:error, {:invalid_state_record, :parallel_goal_limit}}
  end

  defp create_options(_options), do: {:error, {:invalid_state_record, :options}}

  defp persistence_result({:ok, record}), do: {:ok, record}

  defp persistence_result({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, {:state_record_persistence_failed, changeset.errors}}

  defp transaction_result({:ok, record}), do: {:ok, record}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
