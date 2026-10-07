defmodule Ryker.RepositoryKnowledge.DocumentsFitWorkMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_007_210_000

  # A repository's RYKER.md was kept up to 128,000 bytes while every Work
  # turn's briefing carried at most 48 KiB of it, cut in the middle (2026-10-04
  # review). The database now keeps no more than Work reads whole.
  test "a repository's document is kept only as large as a Work turn reads it" do
    assert :ok = migrate_down(@version)
    assert :ok = migrate_up(@version)

    SQL.query!(
      Repo,
      "INSERT INTO repository_knowledge (repository_ref, inserted_at, updated_at) " <>
        "VALUES ('fits-work', now(), now())",
      []
    )

    assert {:ok, 1} = keep(49_152)
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} = keep(49_153)
  end

  # A savepoint keeps the refused write from aborting the test's transaction.
  defp keep(bytes) do
    Repo.transaction(fn ->
      %{num_rows: count} =
        SQL.query!(
          Repo,
          """
          UPDATE repository_knowledge
          SET document = repeat('a', $1), document_sha256 = repeat('b', 64),
              document_commit = repeat('c', 40), document_by = 'model', document_at = now()
          WHERE repository_ref = 'fits-work'
          """,
          [bytes]
        )

      count
    end)
  rescue
    error in Postgrex.Error -> {:error, error}
  end
end
