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
  alias Responder.Repo
  alias Responder.State.{Record, RecordChangeset, RecordPayload}
  alias Responder.Work.Turn

  @operation_id ~r/\A[A-Za-z0-9_.:-]{1,80}\z/
  @maximum_records_per_turn 64
  @maximum_model_records 64
  @terminal_goal_states ~w(completed excluded cancelled)
  @shadow_record_kinds ~w(evidence coverage finding progress alert_assessment)
  @confirmation_offer_kinds ~w(task_offer publication_offer schedule_offer automation_change_offer memory_offer preference_offer guidance_offer standing_assignment_offer)

  @spec token(Turn.t()) :: String.t()
  def token(%Turn{id: id}) when is_binary(id), do: "state:" <> id

  @spec create(String.t(), String.t(), String.t(), map()) ::
          {:ok, Record.t()} | {:error, term()}
  def create(state_token, operation_id, kind, payload) do
    with {:ok, turn_id} <- turn_id(state_token),
         :ok <- operation_id(operation_id),
         :ok <- known_kind(kind),
         {:ok, episode_id} <- episode_id(turn_id) do
      Repo.transaction(fn -> create_locked(episode_id, turn_id, operation_id, kind, payload) end)
      |> transaction_result()
    end
  end

  defp create_locked(episode_id, turn_id, operation_id, kind, payload) do
    with {:ok, episode} <- lock_episode(episode_id),
         {:ok, turn} <- lock_turn(turn_id, episode_id),
         :ok <- authorize(episode, turn, kind),
         ref <- record_ref(turn.id, operation_id, kind),
         {:ok, prepared} <- RecordPayload.prepare(kind, payload, ref),
         {:ok, record} <-
           create_or_reconcile(episode, turn, operation_id, kind, ref, prepared),
         :ok <- Approvals.ensure_registered_in_transaction(record) do
      record
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

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

  @spec model_records(Ecto.UUID.t()) :: [map()]
  def model_records(episode_id) do
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

  @spec repository_write_goals(Ecto.UUID.t()) :: [map()]
  def repository_write_goals(episode_id) when is_binary(episode_id) do
    Repo.all(
      from(record in Record,
        where:
          record.episode_id == ^episode_id and record.kind in ["goal", "goal_state"] and
            record.status in [:open, :confirmed],
        order_by: [asc: record.sequence]
      )
    )
    |> current_goal_details()
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

      :ok
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

      kind in @confirmation_offer_kinds and transport not in ["slack", "control_plane"] ->
        {:error, :state_record_confirmation_unsupported}

      kind == "slack_post_offer" and transport not in ["slack", "control_plane"] ->
        {:error, :state_record_confirmation_unsupported}

      true ->
        :ok
    end
  end

  defp authorize(_episode, _turn, _kind), do: {:error, :state_record_unauthorized}

  defp create_or_reconcile(episode, turn, operation_id, kind, ref, prepared) do
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
             :ok <- validate_relationships(episode.id, kind, prepared.payload),
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

  defp validate_relationships(episode_id, "evidence", payload),
    do: evidence_refs_exist(episode_id, Map.get(payload, "supersedes", []), :supersedes)

  defp validate_relationships(episode_id, "finding", payload) do
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

  defp validate_relationships(episode_id, "goal", payload) do
    goal_id = payload["id"]
    prerequisites = Map.get(payload, "prerequisite_goal_ids", [])

    cond do
      goal_id in prerequisites ->
        {:error, {:invalid_state_record, :prerequisite_goal_ids}}

      goal_exists?(episode_id, goal_id) ->
        {:error, :state_record_subject_conflict}

      true ->
        goals_exist(episode_id, prerequisites, :prerequisite_goal_ids)
    end
  end

  defp validate_relationships(episode_id, "goal_state", payload) do
    if goal_exists?(episode_id, payload["goal_id"]),
      do: :ok,
      else: {:error, {:invalid_state_record, :goal_id}}
  end

  defp validate_relationships(episode_id, "alert_assessment", payload) do
    cause_refs = Map.get(payload, "evidence_refs", [])
    scope = payload["scope"] || %{}
    scope_refs = Map.get(scope, "evidence_refs", [])
    refs = Enum.uniq(cause_refs ++ scope_refs)

    with {:ok, evidence} <- evidence_records(episode_id, refs, :evidence_refs),
         :ok <- cause_claims(cause_refs, payload, evidence) do
      checked_targets(scope, evidence)
    end
  end

  defp validate_relationships(_episode_id, _kind, _payload), do: :ok

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

  defp current_required_goals(records) do
    records
    |> current_goal_details()
    |> Enum.flat_map(fn goal ->
      if goal["required"] and goal["state"] not in @terminal_goal_states do
        [Map.take(goal, ~w(id requested_outcome state))]
      else
        []
      end
    end)
  end

  defp current_goal_details(records) do
    {goals, states} =
      Enum.reduce(records, {%{}, %{}}, fn
        %Record{kind: "goal", subject_ref: id, payload: payload}, {goals, states} ->
          {Map.put(goals, id, payload), states}

        %Record{kind: "goal_state", subject_ref: id, payload: payload}, {goals, states} ->
          {goals, Map.put(states, id, payload["state"])}
      end)

    goals
    |> Enum.map(fn {id, goal} ->
      goal
      |> Map.put("id", id)
      |> Map.put("state", Map.get(states, id, "ready"))
    end)
    |> Enum.sort_by(& &1["id"])
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

  defp persistence_result({:ok, record}), do: {:ok, record}

  defp persistence_result({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, {:state_record_persistence_failed, changeset.errors}}

  defp transaction_result({:ok, record}), do: {:ok, record}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
