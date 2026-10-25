defmodule Ryker.People.FactKeyNamespaceMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.Crypto

  @previous 20_261_025_123_000
  @version 20_261_025_160_000
  @person "slack:user:key-migration"
  @at ~N[2026-10-24 09:00:00.000000]

  setup do
    document =
      "testdata/learning/retained-people-about-themselves.json"
      |> File.read!()
      |> Jason.decode!()

    result = document |> get_in(["recorded_result", "result"]) |> Jason.decode!()
    %{words: hd(result["people"])["fact"]}
  end

  # A valid kept key could occupy the old tombstone namespace and make
  # forgetting fail. Moving tombstones must preserve all their other custody.
  test "migration separates forgotten keys and preserves every other retained field",
       %{words: words} do
    in_scratch_schema("fact_key_namespace", fn repo, prefix ->
      migrate!(repo, prefix, @previous)
      digest = Crypto.sha256_hex(@person <> "\nbirthday")
      suffix = binary_part(digest, 0, 47)
      old_key = "f" <> suffix
      new_key = "~" <> suffix
      forgotten = insert_fact!(repo, old_key, nil)
      kept = insert_fact!(repo, "birthday", words)

      SQL.query!(repo, """
      INSERT INTO person_fact_withdrawals
        (id, person_ref, source_message_ref, withdrawn_at, inserted_at, updated_at)
      VALUES (uuidv7(), '#{@person}', NULL, '#{@at}', '#{@at}', '#{@at}')
      """)

      facts = facts_without_keys(repo)
      withdrawals = SQL.query!(repo, "SELECT to_jsonb(w) FROM person_fact_withdrawals w", []).rows

      assert migrate!(repo, prefix, @version) == [@version]
      assert keys(repo) == Enum.sort([[forgotten, new_key], [kept, "birthday"]])
      assert facts_without_keys(repo) == facts

      assert SQL.query!(repo, "SELECT to_jsonb(w) FROM person_fact_withdrawals w", []).rows ==
               withdrawals

      reserved_key = "~" <> String.duplicate("a", 47)

      assert_raise Postgrex.Error, ~r/person_facts_valid/, fn ->
        insert_fact!(repo, reserved_key, words)
      end

      assert_raise Postgrex.Error, ~r/person_facts_valid/, fn ->
        insert_fact!(repo, "model-kind", nil)
      end

      assert rollback!(repo, prefix) == [@version]
      assert keys(repo) == Enum.sort([[forgotten, old_key], [kept, "birthday"]])
      assert facts_without_keys(repo) == facts
    end)
  end

  test "rollback refuses a newly valid kept key that overlaps the old forgotten namespace",
       %{words: words} do
    in_scratch_schema("fact_key_overlap", fn repo, prefix ->
      migrate!(repo, prefix, @previous)
      old_key = "f" <> String.duplicate("b", 47)
      insert_fact!(repo, old_key, nil)
      assert migrate!(repo, prefix, @version) == [@version]
      insert_fact!(repo, old_key, words)
      before = SQL.query!(repo, "SELECT to_jsonb(f) FROM person_facts f ORDER BY id", []).rows

      assert_raise Postgrex.Error, ~r/personal fact keys overlap the previous namespace/, fn ->
        rollback!(repo, prefix)
      end

      assert SQL.query!(repo, "SELECT to_jsonb(f) FROM person_facts f ORDER BY id", []).rows ==
               before
    end)
  end

  defp facts_without_keys(repo) do
    SQL.query!(repo, "SELECT to_jsonb(f) - 'key' FROM person_facts f ORDER BY id", []).rows
  end

  defp keys(repo) do
    SQL.query!(repo, "SELECT id::text, key FROM person_facts ORDER BY id", []).rows
  end

  defp insert_fact!(repo, key, fact) do
    id = Ecto.UUID.generate()
    dumped_id = Ecto.UUID.dump!(id)
    status = if is_nil(fact), do: "forgotten", else: "kept"
    forgotten_at = if is_nil(fact), do: @at

    SQL.query!(
      repo,
      """
      INSERT INTO person_facts
        (id, person_ref, key, fact, status, source_input_id, source_message_ref,
         conversation_ref, private, said_at, forgotten_at)
      VALUES ($1, $2, $3, $4, $5, uuidv7(), 'message:key-migration',
              'chat:key-migration', true, $6, $7)
      """,
      [dumped_id, @person, key, fact, status, @at, forgotten_at]
    )

    id
  end
end
