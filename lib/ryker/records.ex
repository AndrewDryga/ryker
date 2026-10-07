defmodule Ryker.Records do
  @moduledoc """
  Durable, episode-scoped state-tool records.

  A record is created for one Work turn, named by its state token (`token/1`),
  and only while that turn owns its episode and has not entered cancellation or
  delivery custody. The token is the turn's id with a prefix, not a secret, so
  it authorizes nothing by itself: it is built only from a binding the worker
  gateway already verified (`Ryker.StateTools.Binding`) or by the executor for
  the turn it holds, and it never leaves Ryker.

  A record created, answered, confirmed, superseded or dismissed is announced
  after the outermost commit (`subscribe_records/0`), on its request's topics
  too, whichever context changed it (`broadcast_record_updated/1`).
  """

  alias Ryker.CanonicalJSON
  alias Ryker.Crypto
  alias Ryker.Emisar.Approvals
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Input
  alias Ryker.Records.DerivedContext
  alias Ryker.Records.InvestigationPayload
  alias Ryker.Records.Record
  alias Ryker.Records.RecordPayload
  alias Ryker.Repo
  alias Ryker.Waits.EventSubscriptions
  alias Ryker.Waits.EventWaitTiming
  alias Ryker.Waits.SourceEventMatcher
  alias Ryker.Work.Turn

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

  @doc "The name `create/5` takes for the records of `turn`; see the moduledoc for who may build it."
  @spec token(Turn.t()) :: String.t()
  def token(%Turn{id: id}) when is_binary(id), do: "state:" <> id

  @spec create(String.t(), String.t(), String.t(), map()) ::
          {:ok, Record.t()} | {:error, term()}
  def create(state_token, operation_id, kind, payload, options \\ []) do
    create(state_token, operation_id, kind, payload, options, false)
  end

  @doc false
  @spec create_reusing_open_source_wait(String.t(), String.t(), map(), keyword() | map()) ::
          {:ok, Record.t()} | {:error, term()}
  def create_reusing_open_source_wait(state_token, operation_id, payload, options \\ []) do
    create(state_token, operation_id, "event_wait", payload, options, true)
  end

  defp create(state_token, operation_id, kind, payload, options, reuse_open_source_wait?) do
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
          parallel_goal_limit,
          reuse_open_source_wait?
        )
      end)
    end
  end

  defp create_locked(
         episode_id,
         turn_id,
         operation_id,
         kind,
         payload,
         parallel_goal_limit,
         reuse_open_source_wait?
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
             parallel_goal_limit,
             reuse_open_source_wait?
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
    episode_id
    |> Record.Query.by_episode_id()
    |> Record.Query.in_use()
    |> Record.Query.ordered_by_sequence()
    |> Repo.all()
    |> Map.new(fn record ->
      {record.ref, validation_record(record)}
    end)
  end

  defp validation_record(%Record{
         continuation: continuation,
         kind: "event_wait",
         payload: %{"event_matcher" => %{"type" => type}}
       })
       when type in ["after", "at"] do
    %{"continuation" => continuation, "kind" => "event_wait", "wait_mode" => "timer"}
  end

  defp validation_record(%Record{continuation: continuation, kind: "event_wait"}) do
    %{"continuation" => continuation, "kind" => "event_wait", "wait_mode" => "external"}
  end

  defp validation_record(%Record{continuation: continuation, kind: kind}) do
    %{"continuation" => continuation, "kind" => kind}
  end

  @doc "Read-only retained history for operator projections, not a model disclosure."
  @spec retained_records(Ecto.UUID.t()) :: [map()]
  def retained_records(episode_id) do
    episode_id
    |> Record.Query.by_episode_id()
    |> Record.Query.in_use()
    |> Record.Query.ordered_by_sequence_desc()
    |> Record.Query.limit_to(@maximum_model_records)
    |> Repo.all()
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

  @doc """
  Whether this episode already holds an unanswered question.

  `waiting_for_input` accepts exactly one open input wait, so a second open
  question leaves the turn no valid final: referencing both fails the count,
  and dropping one abandons an open wait. Creation has to agree with that.
  """
  @spec question_open?(Ecto.UUID.t(), String.t() | nil) :: boolean()
  def question_open?(episode_id, operation_id \\ nil)

  def question_open?(episode_id, operation_id) when is_binary(episode_id) do
    query =
      episode_id
      |> Record.Query.by_episode_id()
      |> Record.Query.by_kind("input_request")
      |> Record.Query.open()

    # A retry of the same call is the same question, and `Records.create`
    # already returns the record it made the first time. Only a *different*
    # operation asking again is the one that strands the turn.
    query =
      if is_binary(operation_id),
        do: Record.Query.excluding_operation(query, operation_id),
        else: query

    Repo.exists?(query)
  end

  def question_open?(_episode_id, _operation_id), do: false

  @spec open_required_goals(Ecto.UUID.t()) :: [map()]
  def open_required_goals(episode_id) when is_binary(episode_id) do
    episode_id
    |> goal_records()
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

    Map.new(@goal_stages, fn stage ->
      {stage, stage_bucket(Enum.filter(current, &(&1["stage"] == stage)))}
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

  @doc """
  Resolves the wait `wait_ref` names when an input of `event_kind` resumes
  its episode. A reply answers it. An edit starts the work again, so the
  question it made obsolete is replaced rather than answered: the card said
  "answered" after an edit, though nobody had answered it (QA re-test,
  2026-09-26).
  """
  @spec resolve_wait_in_transaction(String.t(), atom()) :: :ok | {:error, term()}
  def resolve_wait_in_transaction(wait_ref, event_kind) when is_binary(wait_ref) do
    if Repo.in_transaction?() do
      status = if event_kind == :edit, do: :superseded, else: :answered

      {_count, resolved} =
        wait_ref
        |> Record.Query.by_ref()
        |> Record.Query.by_kinds(["input_request", "event_wait"])
        |> Record.Query.open()
        |> Record.Query.transition(status)
        |> Repo.update_all([])

      Enum.each(resolved, &broadcast_record_updated/1)
      EventSubscriptions.resolve_wait_in_transaction(wait_ref, :input)
    else
      {:error, :state_record_transaction_required}
    end
  end

  def resolve_wait_in_transaction(_wait_ref, _event_kind), do: {:error, :state_record_not_found}

  @doc """
  Closes the questions an episode still holds open once its work has ended.

  A question belongs to the work that asked it: an answer resolves it through
  `resolve_wait_in_transaction/2`, and work that ends without one, such as
  work closed as no longer needed, takes its unanswered question with it.
  """
  @spec dismiss_open_questions_in_transaction(Ecto.UUID.t()) :: :ok | {:error, term()}
  def dismiss_open_questions_in_transaction(episode_id) when is_binary(episode_id) do
    if Repo.in_transaction?() do
      {_count, dismissed} =
        episode_id
        |> Record.Query.by_episode_id()
        |> Record.Query.by_kind("input_request")
        |> Record.Query.open()
        |> Record.Query.transition(:dismissed)
        |> Repo.update_all([])

      Enum.each(dismissed, &broadcast_record_updated/1)
    else
      {:error, :state_record_transaction_required}
    end
  end

  @doc false
  @spec user_resumable_wait?(String.t()) :: boolean()
  def user_resumable_wait?(wait_ref) when is_binary(wait_ref) do
    not (wait_ref
         |> Record.Query.by_ref()
         |> Record.Query.by_kind("emisar_approval")
         |> Record.Query.open()
         |> Repo.exists?())
  end

  def user_resumable_wait?(_wait_ref), do: false

  @doc false
  @spec user_resumable_wait?(String.t(), Input.t()) :: boolean()
  def user_resumable_wait?(wait_ref, %Input{} = input) when is_binary(wait_ref) do
    # A question owns its wait until admission resumes the episode, even after a
    # native choice already marked the record answered. Only a person may consume it.
    holder =
      wait_ref
      |> Record.Query.by_ref()
      |> Record.Query.open_or_question()
      |> Record.Query.select_kinds_and_payloads()
      |> Repo.one()

    case holder do
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

  defp event_wait_matches?(_timer_or_deadline_wait, _input), do: true

  defp source_matches?(nil, _actual), do: true
  defp source_matches?(expected, actual), do: expected == actual

  defp fetch_records(refs, episode_id) do
    unique = Enum.uniq(refs)

    records =
      if unique == [] do
        []
      else
        query = Record.Query.by_refs(unique)
        query = if episode_id, do: Record.Query.by_episode_id(query, episode_id), else: query

        Repo.all(query)
      end

    by_ref = Map.new(records, &{&1.ref, &1})

    if map_size(by_ref) == length(unique),
      do: {:ok, Enum.map(unique, &Map.fetch!(by_ref, &1))},
      else: {:error, :state_record_not_found}
  end

  defp episode_id(turn_id) do
    episode_id = turn_id |> Turn.Query.by_id() |> Turn.Query.select_episode_ids() |> Repo.one()

    case episode_id do
      nil -> {:error, :state_record_unauthorized}
      episode_id -> {:ok, episode_id}
    end
  end

  defp lock_episode(episode_id) do
    episode = episode_id |> Episode.Query.by_id() |> Episode.Query.lock_for_update() |> Repo.one()

    case episode do
      nil -> {:error, :state_record_unauthorized}
      episode -> {:ok, episode}
    end
  end

  defp lock_turn(turn_id, episode_id) do
    turn =
      turn_id
      |> Turn.Query.by_id()
      |> Turn.Query.by_episode_id(episode_id)
      |> Turn.Query.lock_for_update()
      |> Repo.one()

    case turn do
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
         parallel_goal_limit,
         reuse_open_source_wait?
       ) do
    fingerprint =
      CanonicalJSON.digest(%{
        "continuation" => prepared.continuation,
        "payload" => prepared.payload
      })

    existing =
      turn.id
      |> Record.Query.by_turn_id()
      |> Record.Query.by_operation_id(operation_id)
      |> Repo.one()

    case existing do
      nil ->
        case reusable_open_source_wait(
               episode.id,
               kind,
               prepared.payload,
               reuse_open_source_wait?
             ) do
          %Record{} = record ->
            {:ok, record}

          nil ->
            insert_new_record(
              episode,
              turn,
              operation_id,
              kind,
              ref,
              prepared,
              fingerprint,
              parallel_goal_limit
            )
        end

      %Record{kind: ^kind, payload_fingerprint: ^fingerprint} = record ->
        {:ok, record}

      %Record{} ->
        {:error, :state_record_operation_conflict}
    end
  end

  defp insert_new_record(
         episode,
         turn,
         operation_id,
         kind,
         ref,
         prepared,
         fingerprint,
         parallel_goal_limit
       ) do
    with :ok <- validate_temporal(kind, prepared.continuation),
         :ok <- validate_relationships(episode.id, kind, prepared.payload, parallel_goal_limit),
         :ok <- record_capacity(turn.id, operation_id),
         :ok <- supersede_prior_record(episode.id, kind, prepared.payload) do
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
      |> Record.Changeset.insert()
      |> Repo.insert()
      |> persistence_result()
    end
  end

  defp reusable_open_source_wait(
         episode_id,
         "event_wait",
         %{
           "deadline_at" => nil,
           "event_matcher" => %{"type" => "source_event"}
         } = payload,
         true
       ) do
    episode_id
    |> Record.Query.by_episode_id()
    |> Record.Query.by_kind("event_wait")
    |> Record.Query.open()
    |> Record.Query.without_wait_error()
    |> Record.Query.by_payload(payload)
    |> Record.Query.ordered_by_sequence()
    |> Record.Query.limit_to(1)
    |> Repo.one()
  end

  defp reusable_open_source_wait(_episode_id, _kind, _payload, _reuse?), do: nil

  defp record_ref(turn_id, operation_id, kind) do
    digest =
      Crypto.sha256_hex(turn_id <> <<0>> <> operation_id <> <<0>> <> kind)
      |> binary_part(0, 32)

    "record:#{kind}:#{digest}"
  end

  # The host makes the publication offer when the work completes, so it is
  # not one of the records the model may write in a turn: a large task that
  # had written its 64 could not complete (2026-10-04 review).
  @publication_offer "host:publication:ready"

  defp record_capacity(_turn_id, @publication_offer), do: :ok

  defp record_capacity(turn_id, _operation_id) do
    count =
      turn_id
      |> Record.Query.by_turn_id()
      |> Record.Query.excluding_operation(@publication_offer)
      |> Repo.aggregate(:count)

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
         :gt <- DateTime.compare(deadline, Repo.now!()) do
      :ok
    else
      _elapsed_or_invalid -> {:error, :deadline_elapsed}
    end
  end

  defp validate_temporal(_kind, _continuation), do: :ok

  # A new offer for the same instruction and repository replaces the open one,
  # whichever turn made it: a refinement in the turn that made the offer left
  # both open (2026-10-04 review). An identical retry never reaches here.
  defp supersede_prior_record(
         episode_id,
         "task_offer",
         %{"instruction_ref" => instruction_ref, "repository" => repository}
       )
       when is_binary(instruction_ref) and byte_size(instruction_ref) > 0 and
              is_binary(repository) and byte_size(repository) > 0 do
    ids =
      episode_id
      |> Record.Query.by_episode_id()
      |> Record.Query.by_kind("task_offer")
      |> Record.Query.open()
      |> Record.Query.select_ids_and_payloads()
      |> Repo.all()
      |> Enum.flat_map(fn
        {id, %{"instruction_ref" => ^instruction_ref, "repository" => ^repository}} -> [id]
        _other -> []
      end)

    if ids != [] do
      {_count, superseded} =
        ids
        |> Record.Query.by_ids()
        |> Record.Query.transition(:superseded)
        |> Repo.update_all([])

      Enum.each(superseded, &broadcast_record_updated/1)
    end

    :ok
  end

  defp supersede_prior_record(_episode_id, _kind, _payload), do: :ok

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
      episode_id
      |> Record.Query.by_episode_id()
      |> Record.Query.by_kind("evidence")
      |> Record.Query.in_use()
      |> Record.Query.by_refs(refs)
      |> Repo.all()

    if length(records) == length(refs),
      do: {:ok, records},
      else: {:error, {:invalid_state_record, field}}
  end

  defp cause_claims([], _payload, _evidence), do: :ok

  defp cause_claims(refs, payload, evidence) do
    claims = Map.get(payload, "cause_claim_ids", [])
    by_ref = Map.new(evidence, &{&1.ref, &1})

    if Enum.all?(refs, &(get_in(by_ref, [&1, Access.key(:payload), "claim_id"]) in claims)),
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
    episode_id
    |> Record.Query.by_episode_id()
    |> Record.Query.by_kind("goal")
    |> Record.Query.by_subject_ref(goal_id)
    |> Record.Query.in_use()
    |> Repo.exists?()
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
      episode_id
      |> Record.Query.by_episode_id()
      |> Record.Query.by_kind("goal")
      |> Record.Query.by_subject_refs(goal_ids)
      |> Record.Query.in_use()
      |> Repo.aggregate(:count)

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

    if Enum.all?(
         Map.get(goal, "prerequisite_goal_ids", []),
         &(Map.get(states, &1) in @satisfied_prerequisite_states)
       ),
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

  defp goals_from_records(records) do
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
    episode_id
    |> Record.Query.by_episode_id()
    |> Record.Query.by_kinds(["goal", "goal_state"])
    |> Record.Query.in_use()
    |> Record.Query.ordered_by_sequence()
    |> Repo.all()
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

  defp persistence_result({:ok, record}) do
    broadcast_record_updated(record)
    {:ok, record}
  end

  defp persistence_result({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, {:state_record_persistence_failed, changeset.errors}}

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to record changes: `{:record_updated, record_id}` once
  something a request recorded (a finding, a question, an offer, a wait) is
  created, answered, confirmed, superseded or dismissed, and that change has
  committed.
  """
  def subscribe_records, do: Ryker.PubSub.subscribe(records_topic())

  def unsubscribe_records, do: Ryker.PubSub.unsubscribe(records_topic())

  @doc """
  The offer or question `ref` of one of `kinds` with the episode and Work
  turn that made it, all three locked until the caller's transaction ends,
  for its confirmation or answer. Seven cards kept a copy of this.
  """
  @spec lock_offer(String.t(), [String.t()]) ::
          {:ok, Record.t(), Episode.t(), Turn.t()} | {:error, :not_found}
  def lock_offer(ref, kinds) do
    case Repo.fetch(Record.Query.offer_with_origin(ref, kinds)) do
      {:ok, {record, episode, turn}} -> {:ok, record, episode, turn}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Marks the offer `record` confirmed by a person's answer (its `occurred_at`,
  `actor_ref` and `confirmation_ref`) and announces it once the caller's
  transaction commits. Five offers kept a copy of this.
  """
  @spec confirm_offer(Record.t(), map()) :: {:ok, Record.t()} | {:error, Ecto.Changeset.t()}
  def confirm_offer(%Record{} = record, answer) do
    changeset =
      Record.Changeset.confirm_resource(record, %{
        confirmed_at: answer.occurred_at,
        confirmed_by_actor_ref: answer.actor_ref,
        confirmation_ref: answer.confirmation_ref,
        status: :confirmed
      })

    with {:ok, confirmed} <- Repo.update(changeset) do
      broadcast_record_updated(confirmed)
      {:ok, confirmed}
    end
  end

  @doc """
  Internal — announces, after the outermost commit, that `record` changed.
  Every context that writes a record calls this, so the record's request
  hears it on its own topics too.
  """
  @spec broadcast_record_updated(Record.t()) :: :ok
  def broadcast_record_updated(%Record{id: id, episode_id: episode_id}) do
    Ryker.Episodes.broadcast_episode_updated(episode_id)
    Repo.after_commit(fn -> Ryker.PubSub.broadcast(records_topic(), {:record_updated, id}) end)
  end

  defp records_topic, do: "records"
end
