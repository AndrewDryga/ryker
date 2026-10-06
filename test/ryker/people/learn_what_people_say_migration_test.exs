defmodule Ryker.People.LearnWhatPeopleSayMigrationTest do
  @moduledoc """
  Andrew, 2026-09-30: Ryker should learn about people "passively ... without
  approvals (like when you mentioned when it's your birthday or what is your
  favorite tv show etc)". The migration gives what people say about
  themselves a place: one fact per person and kind, kept or forgotten, and a
  forgotten one keeps no words. Rolling back refuses while anything is kept.
  """
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @previous_version 20_260_929_020_000
  @version 20_260_930_010_000
  @at ~N[2026-09-30 09:00:00.000000]

  test "one fact per person and kind is kept, a forgotten one keeps no words, and rolling back refuses while one exists" do
    in_scratch_schema("learn_what_people_say", fn repo, prefix ->
      migrate!(repo, prefix, @previous_version)
      assert @version in migrate!(repo, prefix, @version)

      birthday = fact!(repo, prefix, "birthday", "kept", "Birthday is 12 March.", nil)

      assert_raise Postgrex.Error, ~r/person_facts_person_ref_key_index/, fn ->
        fact!(repo, prefix, "birthday", "kept", "Birthday is 13 March.", nil)
      end

      assert_raise Postgrex.Error, ~r/person_facts_valid/, fn ->
        fact!(repo, prefix, "time-zone", "forgotten", "Works on Kyiv time.", @at)
      end

      assert_raise Postgrex.Error, ~r/person_facts_valid/, fn ->
        fact!(repo, prefix, "Time Zone", "kept", "Works on Kyiv time.", nil)
      end

      assert_raise Postgrex.Error, ~r/person_facts_valid/, fn ->
        fact!(repo, prefix, "motto", "kept", String.duplicate("a", 281), nil)
      end

      forgotten = fact!(repo, prefix, "pets", "forgotten", nil, @at)

      assert_raise Postgrex.Error, ~r/what people said about themselves is kept/, fn ->
        rollback!(repo, prefix)
      end

      for id <- [birthday, forgotten] do
        SQL.query!(repo, "DELETE FROM #{prefix}.person_facts WHERE id = $1", [
          Ecto.UUID.dump!(id)
        ])
      end

      assert rollback!(repo, prefix) == [@version]
    end)
  end

  defp fact!(repo, prefix, key, status, fact, forgotten_at) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.person_facts
        (id, person_ref, key, fact, status, source_input_id, source_message_ref,
         conversation_ref, private, said_at, forgotten_at)
      VALUES ($1, 'slack:user:UALICE', $2, $3, $4, $5, 'slack-message:1', 'slack:T1:C1',
              false, $6, $7)
      """,
      [
        Ecto.UUID.dump!(id),
        key,
        fact,
        status,
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        @at,
        forgotten_at
      ]
    )

    id
  end
end
