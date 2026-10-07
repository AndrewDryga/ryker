defmodule Ryker.Work.ActivityRetention do
  @moduledoc "Operational evidence expires with its owner; immutable replay identity survives."
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Work.{ActivityEvent, Turn}

  def context(%{admission_input_id: id}) when is_binary(id),
    do: %{
      all: id |> Entry.Query.by_id() |> Entry.Query.select_pruned_at() |> Repo.one(),
      turns: %{}
    }

  def context(session) do
    turns = session.id |> Turn.Query.by_session_id() |> Turn.Query.select_pruning() |> Repo.all()

    all =
      session.cleanup_status == :discarded && turns != [] &&
        Enum.all?(turns, &(elem(&1, 1) != nil))

    %{all: if(all, do: DateTime.utc_now()), turns: Map.new(turns)}
  end

  def mark(event, context),
    do: Map.put(event, :operational_pruned_at, context.all || context.turns[event.coop_turn_id])

  def expire(%{operational_pruned_at: nil} = event), do: event
  def expire(event), do: Map.put(event, :payload, %{"retention" => "pruned"})

  def prune do
    1_000
    |> ActivityEvent.Query.prunable()
    |> ActivityEvent.Query.among()
    |> Repo.update_all(
      set: [payload: %{"retention" => "pruned"}, operational_pruned_at: DateTime.utc_now()]
    )
  end
end
