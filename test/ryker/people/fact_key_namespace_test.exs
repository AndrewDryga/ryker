defmodule Ryker.People.FactKeyNamespaceTest do
  use Ryker.DataCase, async: true
  alias Ryker.Crypto
  alias Ryker.Fixtures.People, as: PeopleFixtures
  alias Ryker.People

  setup do
    %{context: PeopleFixtures.retained_context!()}
  end

  # A valid model key can equal another kind's old tombstone digest. The
  # lookup then replaced an unrelated kept fact; Forget hit the unique index
  # and rolled back without erasing the sentence the operator had selected.
  test "distinct valid kinds remain independent even when one looks like a tombstone",
       %{context: context} do
    [birthday, other | _] = context.items
    birthday_source = Enum.find(context.entries, &(&1.id == birthday["source_input_id"]))
    other_source = Enum.find(context.entries, &(&1.id == other["source_input_id"]))
    earlier = PeopleFixtures.later_entry!(context, other_source, -120)
    later = PeopleFixtures.later_entry!(context, birthday_source, -60)
    key = old_digest(context.person, birthday["key"])
    other = other |> Map.put("key", key) |> Map.put("source_input_id", earlier.id)
    birthday = Map.put(birthday, "source_input_id", later.id)

    learn!([earlier], [other])
    learn!([later], [birthday])

    assert Enum.sort(People.about(context.person, context.conversation)) ==
             Enum.sort([birthday["fact"], other["fact"]])

    keys = Enum.map(People.facts(context.person), & &1.key)

    assert Enum.sort(keys) ==
             Enum.sort([birthday["key"], key])
  end

  test "a valid neighboring key cannot prevent an operator from forgetting a fact",
       %{context: context} do
    [birthday, other | _] = context.items
    key = old_digest(context.person, birthday["key"])
    other = Map.put(other, "key", key)
    learn!(context.entries, [birthday, other])
    selected = Enum.find(People.facts(context.person), &(&1.key == birthday["key"]))

    result = People.forget_fact(selected.id)

    assert People.about(context.person, context.conversation) == [other["fact"]]
    assert result == {:ok, 1}
  end

  test "a fresh statement reuses its forgotten row without losing the replay boundary",
       %{context: context} do
    [birthday | _] = context.items
    source = Enum.find(context.entries, &(&1.id == birthday["source_input_id"]))
    learn!(context.entries, [birthday])
    [selected] = People.facts(context.person)
    assert People.forget_fact(selected.id) == {:ok, 1}
    later = PeopleFixtures.later_entry!(context, source, 60)
    repeated = Map.put(birthday, "source_input_id", later.id)
    learn!([later], [repeated])

    assert [%{id: id, source_input_id: input_id}] = People.facts(context.person)
    assert id == selected.id
    assert input_id == later.id

    replay = Map.put(birthday, "key", "archived-birthday")
    learn!(context.entries, [replay])
    assert length(People.facts(context.person)) == 1
  end

  test "reserved forgotten kinds cannot be learned from a model result",
       %{context: context} do
    [birthday, other | _] = context.items
    reserved_key = "~" <> String.duplicate("a", 47)
    other = Map.put(other, "key", reserved_key)
    learn!(context.entries, [birthday, other])

    assert People.about(context.person, context.conversation) == [birthday["fact"]]
  end

  defp old_digest(person, key) do
    digest = Crypto.sha256_hex(person <> "\n" <> key)
    "f" <> binary_part(digest, 0, 47)
  end

  defp learn!(entries, items) do
    assert Repo.transaction(fn -> People.learn_in_transaction(items, entries) end) == {:ok, :ok}
  end
end
