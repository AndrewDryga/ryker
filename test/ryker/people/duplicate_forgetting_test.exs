defmodule Ryker.People.DuplicateForgettingTest do
  use Ryker.DataCase, async: true
  alias Ryker.Fixtures.People, as: PeopleFixtures
  alias Ryker.People

  # A model chooses fact keys. The same retained sentence can already occupy
  # two kinds before Forget; erasing one row left the quoted words usable.
  for separate_source <- [false, true] do
    test "forgetting a sentence erases its existing copies from #{if separate_source, do: "different", else: "the same"} sources" do
      context = PeopleFixtures.retained_context!()
      other = PeopleFixtures.retained_context!()
      [birthday | _] = context.items
      [other_birthday | _] = other.items
      original = Enum.find(context.entries, &(&1.id == birthday["source_input_id"]))

      source =
        if unquote(separate_source),
          do: PeopleFixtures.later_entry!(context, original, -60),
          else: original

      duplicate =
        birthday |> Map.put("key", "birth-date") |> Map.put("source_input_id", source.id)

      learn!(context.entries, context.items)
      learn!([source], [duplicate])
      learn!(other.entries, [other_birthday])
      saved = Enum.find(People.facts(context.person), &(&1.key == "birthday"))
      result = People.forget_fact(saved.id)

      refute birthday["fact"] in People.about(context.person, context.conversation)
      assert length(People.facts(context.person)) == 3
      assert People.about(other.person, other.conversation) == [other_birthday["fact"]]
      assert result == {:ok, 2}

      later = PeopleFixtures.later_entry!(context, original, 60)
      repeated = Map.put(birthday, "source_input_id", later.id)
      learn!([later], [repeated])
      replay = Map.put(duplicate, "key", "archived-birthday")
      learn!([source], [replay])
      assert length(People.facts(context.person)) == 4
      known = People.about(context.person, context.conversation)
      assert Enum.count(known, &(&1 == birthday["fact"])) == 1
    end
  end

  test "withdrawing one source preserves identical words learned from another source" do
    context = PeopleFixtures.retained_context!()
    [birthday | _] = context.items
    original = Enum.find(context.entries, &(&1.id == birthday["source_input_id"]))
    other_source = PeopleFixtures.later_entry!(context, original, -60)

    duplicate =
      birthday |> Map.put("key", "birth-date") |> Map.put("source_input_id", other_source.id)

    learn!([original, other_source], [birthday, duplicate])

    assert Repo.transaction(fn ->
             People.forget_message_in_transaction(original.native_input_id)
           end) == {:ok, :ok}

    assert [%{key: "birth-date", source_input_id: id}] = People.facts(context.person)
    assert id == other_source.id
    assert People.about(context.person, context.conversation) == [birthday["fact"]]
  end

  defp learn!(entries, items) do
    assert Repo.transaction(fn -> People.learn_in_transaction(items, entries) end) == {:ok, :ok}
  end
end
