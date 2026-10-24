defmodule Ryker.Emisar.ApprovalMessage.Query do
  @moduledoc "Reads of the separate review-message custody."
  use Ryker, :query
  alias Ryker.Emisar.{Approval, ApprovalMessage}
  alias Ryker.Episodes
  alias Ryker.Records

  def all, do: from(messages in ApprovalMessage, as: :emisar_approval_messages)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [emisar_approval_messages: m], m.id == ^id)

  def by_turn_id(queryable \\ all(), id),
    do: where(queryable, [emisar_approval_messages: m], m.turn_id == ^id)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def changed_for_record(record_id) do
    from(m in all(),
      join: r in Records.Record,
      on: r.turn_id == m.turn_id,
      where: r.id == ^record_id and m.status == :active
    )
  end

  def next_claimable(connection_ref, now) do
    quiet = DateTime.add(now, -600, :second)

    from(m in all(),
      where: m.connection_ref == ^connection_ref and m.status == :active,
      where: is_nil(m.lease_expires_at) or m.lease_expires_at <= ^now,
      where: is_nil(m.next_attempt_at) or m.next_attempt_at <= ^now,
      where: is_nil(m.checked_at) or m.checked_at <= ^quiet,
      order_by: [asc_nulls_first: m.checked_at, asc: m.inserted_at, asc: m.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  @doc "One existing open watch whose asking turn predates separate review-message custody."
  def missing_records(connection_ref) do
    from(a in Approval,
      join: r in Records.Record,
      on: r.id == a.record_id and r.episode_id == a.episode_id,
      join: e in Episodes.Episode,
      on: e.id == a.episode_id,
      left_join: m in ApprovalMessage,
      on: m.turn_id == r.turn_id,
      where: a.connection_ref == ^connection_ref and a.status in [:monitoring, :blocked],
      where: r.status == :open and e.state != :cancelled and is_nil(m.id),
      order_by: [asc: r.inserted_at, asc: r.id],
      select: r
    )
  end
end
