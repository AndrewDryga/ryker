defmodule Ryker.People.ForgettingReplayTest do
  use Ryker.DataCase, async: true
  alias Ryker.Fixtures.People, as: PeopleFixtures
  alias Ryker.People

  # Fact keys are chosen by the model. A tombstone indexed only by that key
  # allowed the exact forgotten sentence to return under another label.
  test "a forgotten fact cannot return from its retained source under a different key" do
    context = PeopleFixtures.retained_context!()
    learn!(context.entries, context.items)
    birthday = Enum.find(People.facts(context.person), &(&1.key == "birthday"))
    assert People.forget_fact(birthday.id) == {:ok, 1}
    [item | _] = context.items
    replay = Map.put(item, "key", "birth-date")
    learn!(context.entries, [replay])

    refute item["fact"] in People.about(context.person, context.conversation)
    assert length(People.facts(context.person)) == 3
  end

  test "forgetting a person prevents older inputs from teaching new fact kinds" do
    context = PeopleFixtures.retained_context!()
    [birthday | rest] = context.items
    learn!(context.entries, [birthday])
    assert People.forget_person(context.person) == {:ok, 1}
    replay = Enum.map(rest, &Map.update!(&1, "key", fn key -> "archived-" <> key end))
    learn!(context.entries, replay)
    assert People.facts(context.person) == []
  end

  test "forgetting a person with no kept facts still rejects their older inputs" do
    context = PeopleFixtures.retained_context!()
    assert People.forget_person(context.person) == {:ok, 0}
    learn!(context.entries, context.items)
    assert People.facts(context.person) == []
  end

  for revised_source <- [false, true] do
    test "a later statement does not erase protection against #{if revised_source, do: "revised", else: "original"} withdrawn sources" do
      context = PeopleFixtures.retained_context!()
      [birthday | _] = context.items
      original = Enum.find(context.entries, &(&1.id == birthday["source_input_id"]))
      learn!([original], [birthday])
      assert People.forget_person(context.person) == {:ok, 1}
      later = PeopleFixtures.later_entry!(context, original, 60)
      repeated = Map.put(birthday, "source_input_id", later.id)
      learn!([later], [repeated])
      assert [%{key: "birthday", source_input_id: id}] = People.facts(context.person)
      assert id == later.id

      source =
        if unquote(revised_source),
          do: PeopleFixtures.later_entry!(context, original, 120, original.native_input_id),
          else: original

      replay = birthday |> Map.put("key", "birth-date") |> Map.put("source_input_id", source.id)
      learn!([source], [replay])
      assert [%{key: "birthday", source_input_id: ^id}] = People.facts(context.person)
    end
  end

  test "withdrawing a message prevents reclassification but preserves other retained sources" do
    context = PeopleFixtures.retained_context!()
    [birthday | rest] = context.items
    entry = Enum.find(context.entries, &(&1.id == birthday["source_input_id"]))
    learn!([entry], [birthday])

    assert Repo.transaction(fn ->
             People.forget_message_in_transaction(entry.native_input_id)
           end) == {:ok, :ok}

    replay = Map.put(birthday, "key", "birth-date")
    learn!(context.entries, [replay | rest])
    refute birthday["fact"] in People.about(context.person, context.conversation)
    assert length(People.facts(context.person)) == 3
  end

  # Choosing the latest key before checking its source discarded a genuine
  # fresh statement when a blocked revision happened to have a later timestamp.
  for reversed <- [false, true] do
    test "a withdrawn revision cannot displace a fresh statement in batch order #{reversed}" do
      context = PeopleFixtures.retained_context!()
      [birthday | _] = context.items
      original = Enum.find(context.entries, &(&1.id == birthday["source_input_id"]))
      learn!([original], [birthday])
      assert People.forget_person(context.person) == {:ok, 1}
      fresh = PeopleFixtures.later_entry!(context, original, 60)
      blocked = PeopleFixtures.later_entry!(context, original, 120, original.native_input_id)

      items = [
        Map.put(birthday, "source_input_id", fresh.id),
        Map.put(birthday, "source_input_id", blocked.id)
      ]

      items = if unquote(reversed), do: Enum.reverse(items), else: items
      learn!([fresh, blocked], items)
      assert [%{key: "birthday", source_input_id: id}] = People.facts(context.person)
      assert id == fresh.id
    end
  end

  test "forgetting preserves the latest known source time even when it is ahead of the database clock" do
    context = PeopleFixtures.retained_context!()
    [birthday | _] = context.items
    original = Enum.find(context.entries, &(&1.id == birthday["source_input_id"]))
    latest = PeopleFixtures.later_entry!(context, original, 120)
    learned = Map.put(birthday, "source_input_id", latest.id)
    learn!([latest], [learned])
    assert People.forget_person(context.person) == {:ok, 1}
    earlier = PeopleFixtures.later_entry!(context, original, 60)
    replay = birthday |> Map.put("source_input_id", earlier.id) |> Map.put("key", "birth-date")
    learn!([earlier], [replay])
    assert People.facts(context.person) == []
  end

  test "repeating a forget never weakens an existing boundary" do
    context = PeopleFixtures.retained_context!()
    assert People.forget_person(context.person) == {:ok, 0}
    withdrawal = Repo.fetch!(People.FactWithdrawal.Query.by_person(context.person))
    boundary = DateTime.add(Repo.now!(), 120)
    withdrawal |> Ecto.Changeset.change(withdrawn_at: boundary) |> Repo.update!()
    assert People.forget_person(context.person) == {:ok, 0}

    assert Repo.fetch!(People.FactWithdrawal.Query.by_person(context.person)).withdrawn_at ==
             boundary
  end

  test "invalid person references return a refusal without creating withdrawal metadata" do
    for person <- ["", " ", <<0>>, String.duplicate("x", 1025)] do
      assert People.forget_person(person) == {:error, {:invalid_person_forgetting, :person_ref}}
    end

    assert Repo.all(People.FactWithdrawal.Query.all()) == []
  end

  defp learn!(entries, items) do
    assert Repo.transaction(fn -> People.learn_in_transaction(items, entries) end) == {:ok, :ok}
  end
end
