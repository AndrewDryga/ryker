defmodule Ryker.Records.Record.Query do
  @moduledoc "Episode state records (findings, citations, offers), for every read of `episode_state_records`."
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Records.{Record, Response}
  alias Ryker.Work.{Session, Turn}

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
  def by_session_id(session_id) do
    from(r in all(),
      join: t in Turn,
      on: t.id == r.turn_id,
      where: t.session_id == ^session_id
    )
  end

  def by_turn_id(queryable \\ all(), turn_id),
    do: where(queryable, [episode_state_records: r], r.turn_id == ^turn_id)

  def by_confirmed_episode_id(queryable, episode_id),
    do: where(queryable, [episode_state_records: r], r.confirmed_episode_id == ^episode_id)

  def select_episode_ids(queryable),
    do: select(queryable, [episode_state_records: r], r.episode_id)

  def by_operation_id(queryable, operation_id),
    do: where(queryable, [episode_state_records: r], r.operation_id == ^operation_id)

  def excluding_operation(queryable, operation_id),
    do: where(queryable, [episode_state_records: r], r.operation_id != ^operation_id)

  def by_subject_ref(queryable, subject_ref),
    do: where(queryable, [episode_state_records: r], r.subject_ref == ^subject_ref)

  def by_subject_refs(queryable, subject_refs),
    do: where(queryable, [episode_state_records: r], r.subject_ref in ^subject_refs)

  def by_kind(queryable, kind), do: where(queryable, [episode_state_records: r], r.kind == ^kind)

  def by_payload(queryable, payload),
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

  def ordered_by_sequence(queryable),
    do: order_by(queryable, [episode_state_records: r], asc: r.sequence)

  def ordered_by_sequence_desc(queryable),
    do: order_by(queryable, [episode_state_records: r], desc: r.sequence)

  @doc "The ref of the Work turn that made each record."
  def select_turn_refs(queryable),
    do: from(r in queryable, join: t in Turn, on: t.id == r.turn_id, select: t.turn_ref)

  def select_payloads(queryable), do: select(queryable, [episode_state_records: r], r.payload)

  @doc "Each record's title, as its payload names it."
  def select_titles(queryable),
    do: select(queryable, [episode_state_records: r], fragment("(?::jsonb)->>'title'", r.payload))

  def select_latest_insert(queryable),
    do: select(queryable, [episode_state_records: r], max(r.inserted_at))

  @doc "Records other than progress Work reported about feedback on its pull request."
  def not_feedback_progress(queryable) do
    where(
      queryable,
      [episode_state_records: r],
      fragment("COALESCE((?::jsonb)->>'phase', '') NOT LIKE 'feedback:%'", r.payload)
    )
  end

  @doc """
  Episode `episode_id`'s 16 latest open publication offers made by a settled
  turn, each with that turn's delivered answer, as `{record, delivery_document}`.
  """
  def delivered_publication_offers(episode_id) do
    from(record in all(),
      join: turn in Turn,
      on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
      where:
        record.episode_id == ^episode_id and record.kind == "publication_offer" and
          record.status == :open and turn.status == :settled,
      order_by: [desc: record.sequence],
      limit: 16,
      select: {record, turn.delivery_document}
    )
  end

  def select_kinds_and_payloads(queryable),
    do: select(queryable, [episode_state_records: r], %{kind: r.kind, payload: r.payload})

  def select_ids_and_payloads(queryable),
    do: select(queryable, [episode_state_records: r], {r.id, r.payload})

  def limit_to(queryable, count), do: limit(queryable, ^count)

  @doc "Record `ref` with the episode and the Work turn that made it, as `{record, episode, turn}`."
  def by_ref_with_origin_turn(ref) do
    from(r in all(),
      join: e in Episode,
      on: e.id == r.episode_id,
      join: t in Turn,
      on: t.id == r.turn_id and t.episode_id == r.episode_id,
      where: r.ref == ^ref,
      select: {r, e, t}
    )
  end

  @doc "The latest offer confirmed as task `episode_id`."
  def task_offer_confirming(episode_id) do
    from(r in all(),
      where: r.kind == "task_offer" and r.confirmed_episode_id == ^episode_id,
      order_by: [desc: r.confirmed_at],
      limit: 1
    )
  end

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

  def by_wait_error(queryable, code),
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

  def ordered_by_oldest(queryable),
    do: order_by(queryable, [episode_state_records: r], asc: r.inserted_at, asc: r.id)

  def select_rows(queryable), do: select(queryable, [episode_state_records: r], r)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def by_kinds(queryable \\ all(), kinds),
    do: where(queryable, [episode_state_records: r], r.kind in ^kinds)

  @doc """
  The offer `ref` of one of `kinds` with the episode and Work turn that made
  it, all three locked, as its confirmation reads them.
  """
  def offer_with_origin(ref, kinds) do
    ref
    |> by_ref()
    |> by_kinds(kinds)
    |> with_joined_origin()
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

  @doc """
  The open Emisar approval card `record_id` of `episode_id`, while the
  episode waits on it.
  """
  def awaited_approval(record_id, episode_id) do
    from(r in all(),
      join: e in Episode,
      on: e.id == r.episode_id,
      where:
        r.id == ^record_id and r.episode_id == ^episode_id and r.kind == "emisar_approval" and
          r.status == :open and e.state == :waiting_for_event and e.owner_kind == :event and
          e.owner_ref == r.ref
    )
  end

  @doc """
  The open readiness offer of `episode_id`'s turn `turn_id` that confirmed
  task `task_ref` asked for, with the task and the settled turn that offered
  the task, as `{offer, task, source_turn}`.
  """
  def task_readiness(episode_id, turn_id, task_ref) do
    from(offer in all(),
      join: task in Record,
      on: task.ref == ^task_ref and task.confirmed_episode_id == ^episode_id,
      join: source_turn in Turn,
      on: source_turn.id == task.turn_id and source_turn.episode_id == task.episode_id,
      where:
        offer.episode_id == ^episode_id and offer.turn_id == ^turn_id and
          offer.kind == "publication_offer" and offer.status == :open and
          offer.operation_id == "host:publication:ready",
      where: task.kind == "task_offer" and task.status == :confirmed,
      where: source_turn.status == :settled,
      select: {offer, task, source_turn}
    )
  end

  @doc """
  The open publication offer `record_ref` with its episode, the turn that
  made it and that turn's session, as `{record, episode, turn, session}`.
  """
  def publication_offer(record_ref) do
    from(record in all(),
      join: episode in Episode,
      on: episode.id == record.episode_id,
      join: turn in Turn,
      on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
      join: session in Session,
      on: session.id == turn.session_id and session.episode_id == record.episode_id,
      where:
        record.ref == ^record_ref and record.kind == "publication_offer" and
          record.status == :open,
      select: {record, episode, turn, session}
    )
  end

  @doc """
  Who confirmed the task episode `episode_id` runs, for `repository`: the
  first confirmed task offer naming it.
  """
  def task_grant(episode_id, repository) do
    from(task in all(),
      where:
        task.kind == "task_offer" and task.status == :confirmed and
          task.confirmed_episode_id == ^episode_id and
          fragment("(?::jsonb) ->> 'repository' = ?", task.payload, ^repository),
      order_by: [asc: task.sequence],
      limit: 1,
      select: task.confirmed_by_actor_ref
    )
  end

  @doc """
  The incident offer `record_ref` with its episode, the turn that made it and
  that turn's session, as `{record, episode, turn, session}`. Only the offer's
  row is locked: it serializes its requests and investigations, and locking
  the episode, turn and session made every write to that conversation's work
  wait for the request (2026-10-04 review).
  """
  def incident_offer(record_ref) do
    from(record in all(),
      join: episode in Episode,
      on: episode.id == record.episode_id,
      join: turn in Turn,
      on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
      join: session in Session,
      on: session.id == turn.session_id and session.episode_id == turn.episode_id,
      where:
        record.ref == ^record_ref and record.kind == "task_offer" and
          fragment("(?::jsonb ->> 'kind') = 'incident'", record.payload),
      select: {record, episode, turn, session},
      lock: fragment("FOR UPDATE OF ?", record)
    )
  end

  @doc "Each record with the episode and the Work turn that made it."
  def with_joined_origin(queryable) do
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
