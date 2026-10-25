defmodule Ryker.People.FactWithdrawalMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_025_123_000
  @previous 20_261_025_100_000

  test "retained tombstones become durable source and historical boundaries without changing facts" do
    in_scratch_schema("fact_withdrawals", fn repo, prefix ->
      migrate!(repo, prefix, @previous)

      capture =
        "testdata/learning/retained-people-about-themselves.json"
        |> File.read!()
        |> Jason.decode!()

      result = capture |> get_in(["recorded_result", "result"]) |> Jason.decode!()
      [birthday | _] = result["people"]
      words = birthday["fact"]

      SQL.query!(
        repo,
        """
        INSERT INTO person_facts
          (id, person_ref, key, fact, status, source_input_id, source_message_ref, conversation_ref, private, said_at, forgotten_at)
        VALUES
          (uuidv7(), 'slack:user:migration', 'f1', NULL, 'forgotten', uuidv7(), 'message:old', 'chat:migration', true, '2026-10-04', '2026-10-02'),
          (uuidv7(), 'slack:user:migration', 'f2', NULL, 'forgotten', uuidv7(), 'message:old', 'chat:migration', true, '2026-10-01', '2026-10-03'),
          (uuidv7(), 'slack:user:migration', 'birthday', $1, 'kept', uuidv7(), 'message:kept', 'chat:migration', true, '2026-10-01', NULL)
        """,
        [words]
      )

      assert migrate!(repo, prefix, @version) == [@version]

      assert SQL.query!(
               repo,
               "SELECT source_message_ref, withdrawn_at::text FROM person_fact_withdrawals ORDER BY source_message_ref NULLS FIRST",
               []
             ).rows ==
               [[nil, "2026-10-04 00:00:00"], ["message:old", "2026-10-03 00:00:00"]]

      assert SQL.query!(repo, "SELECT key, fact, status FROM person_facts ORDER BY key", []).rows ==
               [["birthday", words, "kept"], ["f1", nil, "forgotten"], ["f2", nil, "forgotten"]]

      assert_raise Postgrex.Error, ~r/personal fact withdrawals are retained/, fn ->
        rollback!(repo, prefix)
      end
    end)
  end

  test "an empty withdrawal table can roll back without discarding custody" do
    in_scratch_schema("empty_fact_withdrawals", fn repo, prefix ->
      migrate!(repo, prefix, @version)
      assert rollback!(repo, prefix) == [@version]
    end)
  end
end
