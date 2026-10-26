defmodule Ryker.Work.CompletionReviewMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_026_033_000
  @before 20_261_025_210_000

  # Replacing the owner check once dropped ready Work sessions. Exercise the
  # upgrade with an existing row and every prior owner shape, not just new inserts.
  test "completion review preserves existing owners and isolates the new owner and accounting kind" do
    in_scratch_schema("completion_review", fn repo, prefix ->
      migrate!(repo, prefix, @before)
      id = Ecto.UUID.generate()

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.episode_work_sessions
          (id, policy, policy_digest, external_ref, execution_kind, ready_state, coop_session_id, inserted_at, updated_at)
        VALUES ($1::text::uuid, 'fixture', $2, $1, 'work', 'ready', 'ready-worker', now(), now())
        """,
        [id, String.duplicate("a", 64)]
      )

      owners = [
        %{"execution_kind" => "work", "episode_id" => id},
        %{
          "execution_kind" => "work",
          "ready_state" => "ready",
          "coop_session_id" => "ready-worker"
        },
        %{"execution_kind" => "admission", "admission_input_id" => id},
        %{
          "execution_kind" => "admission",
          "ready_state" => "ready",
          "coop_session_id" => "ready-routing"
        },
        %{"execution_kind" => "learning", "learning_run_id" => id},
        %{"execution_kind" => "improvement", "improvement_run_id" => id},
        %{
          "execution_kind" => "knowledge",
          "knowledge_run_id" => id,
          "repository_ref" => "fixture",
          "repository_source" => "{}"
        }
      ]

      for owner <- owners, do: assert(owner_valid?(repo, prefix, owner))
      assert migrate!(repo, prefix, @version) == [@version]
      for owner <- owners, do: assert(owner_valid?(repo, prefix, owner))

      assert %{rows: [[^id, "ready", "ready-worker"]]} =
               SQL.query!(
                 repo,
                 "SELECT id::text, ready_state, coop_session_id FROM #{prefix}.episode_work_sessions",
                 []
               )

      review = %{"execution_kind" => "completion_review", "completion_review_id" => id}
      assert owner_valid?(repo, prefix, review)
      refute owner_valid?(repo, prefix, Map.delete(review, "completion_review_id"))

      for field <-
            ~w(episode_id admission_input_id learning_run_id improvement_run_id knowledge_run_id repository_ref repository_source repository_context workspace_task authority_digest emisar_connection_ref environment_ref ready_state) do
        refute owner_valid?(repo, prefix, Map.put(review, field, id))
      end

      for owner <- owners,
          do: refute(owner_valid?(repo, prefix, Map.put(owner, "completion_review_id", id)))

      for kind <- ~w(work admission learning improvement knowledge completion_review) do
        assert valid?(repo, prefix, "execution_usage", "execution_usage_identity_valid", %{
                 "kind" => kind,
                 "execution_mode" => "live",
                 "generation" => "1"
               })
      end

      refute valid?(repo, prefix, "execution_usage", "execution_usage_identity_valid", %{
               "kind" => "unknown",
               "execution_mode" => "live",
               "generation" => "1"
             })
    end)
  end

  defp owner_valid?(repo, prefix, row),
    do: valid?(repo, prefix, "episode_work_sessions", "episode_work_session_owner_valid", row)

  # Evaluate the actual installed check against typed rows. Owner FKs are
  # orthogonal; every old owner's full external fixture graph is unnecessary.
  defp valid?(repo, prefix, table, constraint, row) do
    %{rows: [[expression]]} =
      SQL.query!(
        repo,
        "SELECT pg_get_expr(conbin, conrelid) FROM pg_constraint WHERE conrelid = $1::text::regclass AND conname = $2",
        ["#{prefix}.#{table}", constraint]
      )

    %{rows: [[valid]]} =
      SQL.query!(
        repo,
        "SELECT (#{expression}) IS TRUE FROM jsonb_populate_record(NULL::#{prefix}.#{table}, $1::jsonb)",
        [row]
      )

    valid
  end
end
