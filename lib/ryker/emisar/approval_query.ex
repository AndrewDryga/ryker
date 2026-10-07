defmodule Ryker.Emisar.ApprovalQuery do
  @moduledoc "Emisar approvals Ryker asked a person for, for every read of `episode_emisar_approvals`."
  import Ecto.Query
  alias Ryker.Emisar.Approval
  alias Ryker.Episodes.Episode
  alias Ryker.Records.Record

  def all, do: from(approvals in Approval, as: :episode_emisar_approvals)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [episode_emisar_approvals: a], a.id == ^id)

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [episode_emisar_approvals: a], a.id in ^ids)

  def by_record_id(queryable \\ all(), record_id),
    do: where(queryable, [episode_emisar_approvals: a], a.record_id == ^record_id)

  def by_connection(queryable \\ all(), connection_ref),
    do: where(queryable, [episode_emisar_approvals: a], a.connection_ref == ^connection_ref)

  @doc "The watch of Emisar request `request_id` on account `connection_ref`."
  def by_request(connection_ref, request_id) do
    where(
      all(),
      [episode_emisar_approvals: a],
      a.connection_ref == ^connection_ref and a.request_id == ^request_id
    )
  end

  def with_status(queryable, status),
    do: where(queryable, [episode_emisar_approvals: a], a.status == ^status)

  def with_statuses(queryable, statuses),
    do: where(queryable, [episode_emisar_approvals: a], a.status in ^statuses)

  @doc "An account's watches, each with the card that asked and its episode."
  def watches(connection_ref) do
    connection_ref
    |> by_connection()
    |> join(:inner, [episode_emisar_approvals: a], r in Record,
      on: r.id == a.record_id and r.episode_id == a.episode_id,
      as: :episode_state_records
    )
    |> join(:inner, [episode_emisar_approvals: a], e in Episode,
      on: e.id == a.episode_id,
      as: :episode_kernel_episodes
    )
  end

  @doc "An account's watches a task is waiting for right now."
  def waited_for(connection_ref) do
    connection_ref
    |> watches()
    |> where(
      [episode_state_records: r],
      r.kind == "emisar_approval" and r.status == :open
    )
    |> where(
      [episode_state_records: r, episode_kernel_episodes: e],
      e.state == :waiting_for_event and e.owner_kind == :event and e.owner_ref == r.ref
    )
  end

  @doc "Still watched, though its card was answered or its request cancelled."
  def ended(queryable) do
    queryable
    |> with_statuses([:monitoring, :blocked])
    |> where(
      [episode_state_records: r, episode_kernel_episodes: e],
      r.status != :open or e.state == :cancelled
    )
  end

  @doc "Blocked because Emisar refused the account's token."
  def refused(queryable) do
    queryable
    |> with_status(:blocked)
    |> where(
      [episode_emisar_approvals: a],
      like(a.last_error, "{:emisar_http_error, 401,%") or
        like(a.last_error, "{:emisar_http_error, 403,%")
    )
  end

  @doc "Watched, and last stopped by one of `errors`."
  def failed_with(queryable, errors) do
    queryable
    |> with_status(:monitoring)
    |> where([episode_emisar_approvals: a], a.last_error in ^errors)
  end

  def unleased_at(queryable, now) do
    where(
      queryable,
      [episode_emisar_approvals: a],
      is_nil(a.lease_ref) or a.lease_expires_at <= ^now
    )
  end

  def due_at(queryable, now) do
    where(
      queryable,
      [episode_emisar_approvals: a],
      is_nil(a.next_attempt_at) or a.next_attempt_at <= ^now
    )
  end

  @doc "The next watch of account `connection_ref` due a look at `now`, taken by one worker."
  def next_claimable(connection_ref, now) do
    eligible =
      connection_ref
      |> waited_for()
      |> with_status(:monitoring)
      |> due_at(now)
      |> unleased_at(now)
      |> select_ids()

    all()
    |> where([episode_emisar_approvals: a], a.id in subquery(eligible))
    |> order_by([episode_emisar_approvals: a],
      asc_nulls_first: a.next_attempt_at,
      asc: a.inserted_at,
      asc: a.id
    )
    |> limit(1)
    |> lock_next_free()
  end

  @doc "The next look and the next lease expiry after `since` of account `connection_ref`'s watches."
  def next_due_after(connection_ref, since) do
    connection_ref
    |> by_connection()
    |> with_status(:monitoring)
    |> select([episode_emisar_approvals: a], [
      filter(min(a.next_attempt_at), a.next_attempt_at > ^since),
      filter(min(a.lease_expires_at), a.lease_expires_at > ^since)
    ])
  end

  def oldest_updated_first(queryable),
    do: order_by(queryable, [episode_emisar_approvals: a], asc: a.updated_at, asc: a.id)

  def select_ids(queryable), do: select(queryable, [episode_emisar_approvals: a], a.id)
  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_next_free(queryable), do: lock(queryable, "FOR UPDATE SKIP LOCKED")
end
