defmodule Ryker.GitHub.ProcessingReactionsMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_101_193_000

  test "reaction custody is unique per binding repository App and exact comment and rejects invalid state" do
    assert migrate_down(@version) == :ok
    assert migrate_up(@version) == :ok

    assert keep() == {:ok, 1}

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :unique_violation,
                constraint: "github_processing_reaction_identity_unique"
              }
            }} = keep()

    assert keep(89) == {:ok, 1}
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} = keep(90, 0)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             keep(90, 9_002, "pull_request_review")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             keep(90, 9_002, "issue_comment", Repo.generate_id())
  end

  defp keep(actor_id \\ 88, comment_id \\ 9_001, kind \\ "issue_comment", lease_ref \\ nil) do
    Repo.transaction(fn ->
      %{num_rows: count} =
        SQL.query!(
          Repo,
          """
          INSERT INTO github_processing_reactions
            (id, binding, repository_id, actor_id, comment_kind, comment_id, lease_ref, inserted_at, updated_at)
          VALUES ($1::text::uuid, 'github-main', 99, $2, $3, $4, $5::text::uuid, now(), now())
          """,
          [Repo.generate_id(), actor_id, kind, comment_id, lease_ref]
        )

      count
    end)
  rescue
    error in Postgrex.Error -> {:error, error}
  end
end
