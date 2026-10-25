defmodule Ryker.Fixtures.People do
  @moduledoc "Personal fact tests backed by the retained author-statement capture."
  import Ecto.Query
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Ingress
  alias Ryker.People
  alias Ryker.Repo

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}

  @doc "Load captured statements with one unique author and workspace, atomically."
  def retained_context! do
    {:ok, context} = Repo.transaction(&build_retained_context!/0)
    context
  end

  defp build_retained_context! do
    document =
      "testdata/learning/retained-people-about-themselves.json" |> File.read!() |> Jason.decode!()

    id = Ecto.UUID.generate()
    workspace = "T" <> String.upcase(String.replace(id, "-", ""))
    actor = "replay-author:" <> id

    sources =
      Enum.map(document["inputs"], fn raw ->
        isolated =
          raw |> LearningFixtures.isolate_retained_input(workspace) |> Map.put("actor_ref", actor)

        {raw["id"], LearningFixtures.retained_input!(isolated, @policy), raw}
      end)

    entries = Enum.map(sources, &elem(&1, 1))
    by_original = Map.new(sources, fn {original, entry, _raw} -> {original, entry.id} end)
    raw_by_id = Map.new(sources, fn {_original, entry, raw} -> {entry.id, raw} end)
    result = document |> get_in(["recorded_result", "result"]) |> Jason.decode!()

    items =
      Enum.map(
        result["people"],
        &Map.update!(&1, "source_input_id", fn id -> Map.fetch!(by_original, id) end)
      )

    first = hd(entries)

    person = People.person_ref(first)

    %{
      actor: actor,
      entries: entries,
      items: items,
      person: person,
      conversation: first.destination_conversation_ref,
      workspace: workspace,
      raw_by_id: raw_by_id
    }
  end

  @doc "Replay the captured source with new identity/time, optionally retaining its message identity."
  def later_entry!(context, original, seconds, same_message \\ nil)

  def later_entry!(context, %Ingress.Inbox.Entry{} = original, seconds, same_message) do
    occurred_at =
      Repo.now!() |> DateTime.add(seconds) |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()

    raw =
      context.raw_by_id
      |> Map.fetch!(original.id)
      |> LearningFixtures.isolate_retained_input(context.workspace)

    raw = Map.merge(raw, %{"actor_ref" => original.actor_ref, "occurred_at" => occurred_at})

    raw =
      if same_message do
        Map.merge(raw, %{"native_input_id" => same_message, "revision" => original.revision + 1})
      else
        raw
      end

    LearningFixtures.retained_input!(raw, @policy)
  end

  def later_entry!(_context, _original, _seconds, _same_message) do
    raise ArgumentError, "an actual retained entry is required"
  end

  @doc "Delete only this fixture's unique author and retained inputs after a committed test."
  def cleanup!(context) do
    Repo.delete_all(People.PersonFact.Query.by_person(context.person))
    Repo.delete_all(People.FactWithdrawal.Query.by_person(context.person))

    Ryker.ConcurrencyCase.delete_entries!(
      from(e in Ingress.Inbox.Entry,
        where: e.actor_ref == ^context.actor and e.source_ref == ^context.workspace
      )
    )
  end
end
