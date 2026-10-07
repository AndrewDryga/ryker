defmodule Ryker.ControlPlane.Activity.Query do
  @moduledoc """
  The Activity list's rows (`Ryker.ControlPlane.Activity`): every request, as
  its episode or, before it became one, as the message waiting for routing,
  with the bucket its view lists it under, and the filters and search the
  list applies to them.
  """
  import Ecto.Query
  require Ryker.ControlPlane.CurrentInput.Query
  alias Ryker.ControlPlane.CurrentInput
  alias Ryker.Episodes.{Episode, RoutingDigest}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Operator.FailureDismissal
  alias Ryker.Records.Record
  alias Ryker.Schedules.{Schedule, ScheduleOccurrence}
  alias Ryker.Work.{Session, Turn}

  @doc "Every row of the list at `now`, unordered."
  def rows(now), do: from(row in subquery(union_all(episode_rows(), ^admission_rows(now))))

  @doc "The rows of the requests `refs` names."
  def requests(now, refs),
    do: from(row in rows(now), where: row.kind == "episode" and row.ref in ^refs)

  @doc """
  Each conversation's newest row, then the newest `limit` of those: a limit
  beside DISTINCT ON kept the alphabetically first ones.
  """
  def latest_per_conversation(now, limit) do
    latest =
      from(row in rows(now),
        distinct: [row.source, row.conversation],
        order_by: [row.source, row.conversation, desc: row.updated_at]
      )

    from(row in subquery(latest), order_by: [desc: row.updated_at], limit: ^limit)
  end

  def by_mode(queryable, mode), do: from(row in queryable, where: row.mode == ^mode)
  def by_bucket(queryable, bucket), do: from(row in queryable, where: row.bucket == ^bucket)

  def by_episode_state(queryable, state),
    do: from(row in queryable, where: row.episode_state == ^state)

  @doc "Rows showing `repository`, whichever source it came from."
  def by_repository(queryable, repository),
    do: from(row in queryable, where: row.repository == ^repository)

  @doc "Rows whose `column` (`:conversation`, `:thread` or `:source`) is `value`."
  def by_column(queryable, column, value)
      when column in [:conversation, :thread, :source],
      do: from(row in queryable, where: field(row, ^column) == ^value)

  @doc """
  Rows whose text, title, ref, repository or conversation contains
  `pattern`, or that show one of `repositories` or `conversations`.
  """
  def matching(queryable, pattern, repositories, conversations) do
    from(row in queryable,
      where:
        ilike(row.text, ^pattern) or ilike(row.episode_title, ^pattern) or
          ilike(row.schedule_title, ^pattern) or ilike(row.ref, ^pattern) or
          ilike(row.repository, ^pattern) or ilike(row.conversation, ^pattern) or
          row.repository in ^repositories or row.conversation in ^conversations
    )
  end

  @doc "What message `entry_id` reads as at `now`, as its Activity row says it."
  def input_state(entry_id, now) do
    from(message in Entry,
      where: message.id == ^entry_id,
      select: CurrentInput.Query.input_state(message, ^now)
    )
  end

  @doc """
  The rows of `queryable` whose request one of `executions`, a usage ledger
  query, served: an episode's, or a routed message's that became none.
  """
  def by_executions(queryable, executions) do
    episode_ids = from(e in executions, select: e.episode_id)
    admission_ids = from(e in executions, where: e.kind == "admission", select: e.source_id)

    from(row in queryable,
      where:
        (row.kind == "episode" and row.id in subquery(episode_ids)) or
          (row.kind == "admission" and row.id in subquery(admission_ids))
    )
  end

  @doc "How many rows each bucket holds, as `{bucket, count}`."
  def bucket_counts(queryable),
    do: from(row in queryable, group_by: row.bucket, select: {row.bucket, count()})

  # The message that opened each request, as it reads now, read for that
  # request alone.
  defp first_input do
    first =
      from(entry in Entry,
        where: entry.episode_id == parent_as(:episode).id,
        order_by: [asc: entry.inserted_at, asc: entry.id],
        limit: 1
      )

    from(entry in subquery(first),
      as: :revision,
      inner_lateral_join: current in subquery(CurrentInput.Query.current()),
      on: true,
      select: %{
        content: current.content,
        event_kind: current.event_kind,
        pruned_at: current.operational_pruned_at,
        repository: entry.repository_ref,
        inserted_at: entry.inserted_at
      }
    )
  end

  defp episode_rows do
    from(episode in Episode,
      as: :episode,
      left_lateral_join: input in subquery(first_input()),
      on: true,
      left_join: checkout in subquery(checkouts()),
      on: checkout.episode_id == episode.id,
      left_join: scheduled in subquery(scheduled_runs()),
      on: scheduled.episode_id == episode.id,
      left_join: turn in Turn,
      as: :turn,
      on: ^holding_turn(),
      left_join: left in FailureDismissal,
      on:
        left.kind == "delivery" and left.ref == turn.delivery_ref and
          left.failure_summary == coalesce(turn.last_error_code, "delivery blocked"),
      left_join: digest in RoutingDigest,
      on: digest.episode_id == episode.id,
      left_join: task in subquery(confirmed_tasks()),
      on: task.episode_id == episode.id,
      select: %{
        id: episode.id,
        kind: type(^"episode", :string),
        episode_title: fragment("COALESCE(?, ?)", task.title, digest.title),
        task_kind: task.kind,
        schedule_title: scheduled.title,
        ref: episode.key,
        conversation: episode.destination_conversation_ref,
        thread: episode.destination_thread_ref,
        episode_state: fragment("?::text", episode.state),
        mode: fragment("?::text", episode.execution_mode),
        state:
          fragment(
            "CASE WHEN ? = 'blocked' THEN 'blocked' WHEN ? = 'delivery' THEN 'delivery_pending' ELSE ?::text END",
            turn.status,
            episode.owner_kind,
            episode.state
          ),
        bucket:
          fragment(
            "CASE WHEN (? = 'blocked' AND ? IS NULL) OR ? = 'waiting_for_input' THEN 'attention' WHEN ? = 'blocked' OR ? IN ('complete','cancelled') THEN 'done' ELSE 'running' END",
            turn.status,
            left.kind,
            episode.state,
            turn.status,
            episode.state
          ),
        source: episode.destination_transport,
        repository: fragment("COALESCE(?, ?)", input.repository, checkout.repository),
        source_available:
          not is_nil(input.content) and is_nil(input.pruned_at) and input.event_kind != :delete,
        text:
          CurrentInput.Query.visible_preview(input.pruned_at, input.event_kind, input.content),
        started_at: fragment("LEAST(?, ?)", episode.inserted_at, input.inserted_at),
        updated_at: episode.updated_at
      }
    )
  end

  # The turn that holds the request, or whose reply it is delivering: a reply
  # Slack refused read as running, though it waited for a person, and leaving it
  # on Failures changed nothing here (2026-10-04 review).
  defp holding_turn do
    dynamic(
      [episode: e, turn: t],
      t.episode_id == e.id and
        ((e.owner_kind == :turn and t.turn_ref == e.owner_ref) or
           (e.owner_kind == :delivery and t.delivery_ref == e.owner_ref))
    )
  end

  # A deletion is a revision of a message that already has its row, which
  # reads "Message deleted" from then on; as a row of its own it was a
  # second "Message deleted" counted as one more request (manual testing,
  # 2026-09-26). Routing settles deletions without a model, so no spend
  # loses its row.
  #
  # A stopped message a person left as it is on Failures needs nobody now.
  defp admission_rows(now) do
    from(entry in Entry,
      as: :revision,
      inner_lateral_join: current in subquery(CurrentInput.Query.current()),
      on: true,
      left_join: left in FailureDismissal,
      on:
        left.kind == "admission" and
          left.ref == fragment("'ingress-input:' || ?::text", entry.id) and
          left.failure_summary == coalesce(entry.last_error_code, "admission blocked"),
      where: is_nil(entry.episode_id),
      where: entry.event_kind != :delete,
      select: %{
        id: entry.id,
        kind: type(^"admission", :string),
        episode_title: type(^nil, :string),
        task_kind: type(^nil, :string),
        schedule_title: type(^nil, :string),
        ref: fragment("?::text", entry.id),
        conversation: entry.destination_conversation_ref,
        thread: entry.destination_thread_ref,
        episode_state: type(^nil, :string),
        mode: fragment("?::text", entry.execution_mode),
        state: CurrentInput.Query.input_state(entry, ^now),
        bucket:
          fragment(
            "CASE WHEN ? = 'blocked' AND ? IS NULL THEN 'attention' WHEN ? = 'pending' THEN 'running' ELSE 'done' END",
            entry.status,
            left.kind,
            entry.status
          ),
        source: entry.destination_transport,
        repository: entry.repository_ref,
        source_available:
          not is_nil(current.content) and is_nil(current.operational_pruned_at) and
            current.event_kind != :delete,
        text:
          CurrentInput.Query.visible_preview(
            current.operational_pruned_at,
            current.event_kind,
            current.content
          ),
        started_at: entry.inserted_at,
        updated_at: entry.updated_at
      }
    )
  end

  # The repository the latest working copy checked out, for work whose
  # message named none.
  defp checkouts do
    from(session in Session,
      where: not is_nil(session.episode_id) and not is_nil(session.repository_ref),
      distinct: session.episode_id,
      order_by: [asc: session.episode_id, desc: session.generation],
      select: %{episode_id: session.episode_id, repository: session.repository_ref}
    )
  end

  # A task starts from its confirmation, not from a message: its row reads as the task, and says
  # what kind of task it is (Andrew, 2026-10-01).
  defp confirmed_tasks do
    from(record in Record,
      where:
        record.kind == "task_offer" and record.status == :confirmed and
          not is_nil(record.confirmed_episode_id),
      select: %{
        episode_id: record.confirmed_episode_id,
        title: fragment("(?::jsonb)->>'title'", record.payload),
        kind: fragment("(?::jsonb)->>'kind'", record.payload)
      }
    )
  end

  # A scheduled run starts from its schedule, not from a message.
  defp scheduled_runs do
    from(occurrence in ScheduleOccurrence,
      join: schedule in Schedule,
      on: schedule.id == occurrence.schedule_id,
      where: not is_nil(occurrence.child_episode_id),
      distinct: occurrence.child_episode_id,
      order_by: [asc: occurrence.child_episode_id, asc: occurrence.scheduled_for],
      select: %{episode_id: occurrence.child_episode_id, title: schedule.title}
    )
  end
end
