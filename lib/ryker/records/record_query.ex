defmodule Ryker.Records.RecordQuery do
  @moduledoc "Episode state records (findings, citations, offers), for every read of `episode_state_records`."
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Records.{Record, Response}
  alias Ryker.Work.Turn

  def all, do: from(records in Record, as: :episode_state_records)

  def by_id(queryable \\ all(), id), do: where(queryable, [episode_state_records: r], r.id == ^id)

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [episode_state_records: r], r.ref == ^ref)

  def finding(id),
    do: where(all(), [episode_state_records: r], r.id == ^id and r.kind == "finding")

  @doc "The update that moves the records `queryable` selects to `status`, by the database's clock."
  def transition(queryable, status) do
    from(r in queryable,
      update: [set: [status: ^status, updated_at: fragment("clock_timestamp()")]],
      select: r
    )
  end

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [episode_state_records: r], r.id in ^ids)

  def by_refs(queryable \\ all(), refs),
    do: where(queryable, [episode_state_records: r], r.ref in ^refs)

  @doc "Records made by the Work turns of session `session_id`."
  def of_session(session_id) do
    from(r in all(),
      join: t in Turn,
      on: t.id == r.turn_id,
      where: t.session_id == ^session_id
    )
  end

  def by_turn_id(queryable \\ all(), turn_id),
    do: where(queryable, [episode_state_records: r], r.turn_id == ^turn_id)

  def by_operation_id(queryable, operation_id),
    do: where(queryable, [episode_state_records: r], r.operation_id == ^operation_id)

  def excluding_operation(queryable, operation_id),
    do: where(queryable, [episode_state_records: r], r.operation_id != ^operation_id)

  def by_subject_ref(queryable, subject_ref),
    do: where(queryable, [episode_state_records: r], r.subject_ref == ^subject_ref)

  def by_subject_refs(queryable, subject_refs),
    do: where(queryable, [episode_state_records: r], r.subject_ref in ^subject_refs)

  def of_kind(queryable, kind), do: where(queryable, [episode_state_records: r], r.kind == ^kind)

  def with_payload(queryable, payload),
    do: where(queryable, [episode_state_records: r], r.payload == ^payload)

  @doc "Still in use: open or confirmed."
  def in_use(queryable),
    do: where(queryable, [episode_state_records: r], r.status in [:open, :confirmed])

  @doc "Open, or a question even once answered: a question owns its wait until admission resumes."
  def open_or_question(queryable) do
    where(
      queryable,
      [episode_state_records: r],
      r.status == :open or r.kind == "input_request"
    )
  end

  def without_wait_error(queryable),
    do: where(queryable, [episode_state_records: r], is_nil(r.wait_error))

  def in_sequence(queryable), do: order_by(queryable, [episode_state_records: r], asc: r.sequence)

  def latest_sequence_first(queryable),
    do: order_by(queryable, [episode_state_records: r], desc: r.sequence)

  @doc "The ref of the Work turn that made each record."
  def select_turn_refs(queryable),
    do: from(r in queryable, join: t in Turn, on: t.id == r.turn_id, select: t.turn_ref)

  def select_payloads(queryable), do: select(queryable, [episode_state_records: r], r.payload)

  def select_kinds_and_payloads(queryable),
    do: select(queryable, [episode_state_records: r], %{kind: r.kind, payload: r.payload})

  def select_ids_and_payloads(queryable),
    do: select(queryable, [episode_state_records: r], {r.id, r.payload})

  def limit_to(queryable, count), do: limit(queryable, ^count)

  @doc "An episode's latest `limit` findings and evidence still in use, as a later outcome recalls them."
  def outcome_records(episode_id, limit) do
    from(r in all(),
      where:
        r.episode_id == ^episode_id and
          r.kind in ["evidence", "coverage", "finding", "progress", "alert_assessment"] and
          r.status in [:open, :confirmed],
      order_by: [desc: r.sequence],
      limit: ^limit
    )
  end

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_state_records: r], r.episode_id == ^episode_id)

  def open(queryable \\ all()),
    do: where(queryable, [episode_state_records: r], r.status == :open)

  def with_wait_error(queryable, code),
    do: where(queryable, [episode_state_records: r], r.wait_error == ^code)

  @doc "An episode's open wait `wait_ref`."
  def open_wait(episode_id, wait_ref) do
    episode_id
    |> by_episode_id()
    |> open()
    |> where([episode_state_records: r], r.ref == ^wait_ref and r.kind == "event_wait")
  end

  @doc """
  A watch for a source event with no hard deadline: a question may leave it
  open beside it, and it holds no episode by itself.
  """
  def event_only_wait do
    dynamic(
      [episode_state_records: r],
      r.kind == "event_wait" and
        fragment("?::jsonb->'event_matcher'->>'type' = 'source_event'", r.payload) and
        fragment("?::jsonb->>'deadline_at' IS NULL", r.payload)
    )
  end

  def event_only_waits(queryable), do: where(queryable, ^event_only_wait())

  def oldest_first(queryable),
    do: order_by(queryable, [episode_state_records: r], asc: r.inserted_at, asc: r.id)

  def select_rows(queryable), do: select(queryable, [episode_state_records: r], r)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def of_kinds(queryable \\ all(), kinds),
    do: where(queryable, [episode_state_records: r], r.kind in ^kinds)

  @doc """
  The offer `ref` of one of `kinds` with the episode and Work turn that made
  it, all three locked, as its confirmation reads them.
  """
  def offer_with_origin(ref, kinds) do
    ref
    |> by_ref()
    |> of_kinds(kinds)
    |> with_origin()
    |> lock("FOR UPDATE")
  end

  @doc """
  The question `ref` of episode `episode_id` a person answered live, with the
  answer and the message that gave it, all three locked: a decided message
  from a user, its bodies still kept.
  """
  def answered_question(ref, episode_id) do
    from(record in all(),
      join: response in Response,
      on: response.record_id == record.id,
      join: entry in Entry,
      on: entry.id == response.inbox_entry_id,
      where:
        record.ref == ^ref and record.kind == "input_request" and record.status == :answered and
          record.episode_id == ^episode_id and entry.episode_id == ^episode_id and
          entry.status == :decided and entry.actor_kind == :user and
          entry.execution_mode == :live and is_nil(entry.operational_pruned_at),
      select: {record, response, entry},
      lock: "FOR UPDATE"
    )
  end

  @doc "Each record with the episode and the Work turn that made it."
  def with_origin(queryable) do
    queryable
    |> join(:inner, [episode_state_records: r], e in Episode,
      on: e.id == r.episode_id,
      as: :episode_kernel_episodes
    )
    |> join(:inner, [episode_state_records: r], t in Turn,
      on: t.id == r.turn_id and t.episode_id == r.episode_id,
      as: :episode_work_turns
    )
    |> select(
      [episode_state_records: r, episode_kernel_episodes: e, episode_work_turns: t],
      {r, e, t}
    )
  end
end
