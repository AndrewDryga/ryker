defmodule Ryker.Work.ActivityRetention do
  @moduledoc "Operational evidence expires with its owner; immutable replay identity survives."
  import Ecto.Query
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Work.{ActivityEvent, Session, Turn}

  def context(%{admission_input_id: id}) when is_binary(id),
    do: %{
      all: Repo.one(from(i in Entry, where: i.id == ^id, select: i.operational_pruned_at)),
      turns: %{}
    }

  def context(session) do
    turns =
      Repo.all(
        from(t in Turn,
          where: t.session_id == ^session.id,
          select: {t.coop_turn_id, t.operational_pruned_at}
        )
      )

    all =
      session.cleanup_status == :discarded && turns != [] &&
        Enum.all?(turns, &(elem(&1, 1) != nil))

    %{all: if(all, do: DateTime.utc_now()), turns: Map.new(turns)}
  end

  def mark(event, context),
    do: Map.put(event, :operational_pruned_at, context.all || context.turns[event.coop_turn_id])

  def expire(%{operational_pruned_at: nil} = event), do: event
  def expire(event), do: Map.put(event, :payload, %{"retention" => "pruned"})

  def visible(query) do
    expired = expired_ids()
    from(a in query, where: is_nil(a.operational_pruned_at) and a.id not in subquery(expired))
  end

  def prune do
    expired = expired_ids()

    candidates =
      from(a in ActivityEvent,
        where: is_nil(a.operational_pruned_at) and a.id in subquery(expired),
        order_by: [asc: a.inserted_at, asc: a.id],
        limit: 1_000,
        select: a.id,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    Repo.update_all(from(a in ActivityEvent, where: a.id in subquery(candidates)),
      set: [payload: %{"retention" => "pruned"}, operational_pruned_at: DateTime.utc_now()]
    )
  end

  defp expired_ids do
    unexpired_turns =
      from(t in Turn, where: is_nil(t.operational_pruned_at), select: t.session_id)

    expired_turns =
      from(t in Turn, where: not is_nil(t.operational_pruned_at), select: t.session_id)

    # Events without a turn binding retire when every turn in the discarded session has expired.
    from(a in ActivityEvent,
      left_join: i in Entry,
      on: i.id == a.admission_input_id,
      join: s in Session,
      on: s.id == a.session_id,
      left_join: t in Turn,
      on: t.session_id == a.session_id and t.coop_turn_id == a.coop_turn_id,
      where:
        not is_nil(i.operational_pruned_at) or not is_nil(t.operational_pruned_at) or
          (s.cleanup_status == :discarded and s.id in subquery(expired_turns) and
             s.id not in subquery(unexpired_turns)),
      select: a.id
    )
  end
end
