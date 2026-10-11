defmodule Ryker.Memories.ChatFactsEverywhereMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @previous_version 20_261_010_040_000
  @version 20_261_011_090_000

  # An offered fact may be kept installation-wide once this migration runs, and only then: a
  # remembered answer stays the only global fact without an expiry. The full path, a Chat
  # fact confirmed for everywhere and recalled in another chat, is in MemoriesTest.
  test "an offered fact can be kept everywhere only after the migration" do
    in_scratch_schema("chat_facts_everywhere", fn repo, prefix ->
      assert migrate!(repo, prefix, @previous_version) |> List.last() == @previous_version
      refute offered_global_allowed?(repo, prefix)

      assert migrate!(repo, prefix, @version) == [@version]
      assert offered_global_allowed?(repo, prefix)

      assert rollback!(repo, prefix) == [@version]
      refute offered_global_allowed?(repo, prefix)
    end)
  end

  defp offered_global_allowed?(repo, prefix) do
    %{rows: [[definition]]} =
      SQL.query!(
        repo,
        """
        SELECT pg_get_constraintdef(c.oid)
        FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname = $1 AND c.conname = 'operational_memory_entry_valid'
        """,
        [prefix]
      )

    definition =~
      "(scope_kind = 'global'::text) AND (visibility = 'global'::text) AND " <>
        "(workspace_ref = 'installation'::text) AND " <>
        "(scope_ref ~ '^installation:[a-f0-9]{64}$'::text) AND " <>
        "(((expires_at IS NULL) AND (answer_provenance IS NOT NULL)) OR " <>
        "((expires_at IS NOT NULL) AND (expires_at > confirmed_at) AND (answer_provenance IS NULL)))"
  end
end
