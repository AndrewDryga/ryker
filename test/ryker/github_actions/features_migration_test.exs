defmodule Ryker.GitHubActions.FeaturesMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @digest String.duplicate("a", 64)
  @commit String.duplicate("b", 40)

  test "publication targets preserve existing sessions and bound new target documents" do
    in_scratch_schema("publication_targets", fn repo, prefix ->
      migrate!(repo, prefix, 20_261_117_210_000)

      id =
        row!(repo, prefix, "episode_work_sessions", %{
          "execution_kind" => "work",
          "policy" => "fixture",
          "policy_digest" => @digest,
          "external_ref" => "existing-session",
          "ready_state" => "ready",
          "coop_session_id" => "worker"
        })

      assert migrate!(repo, prefix, 20_261_117_230_000) == [20_261_117_230_000]

      assert %{rows: [[nil, "worker"]]} =
               SQL.query!(
                 repo,
                 "SELECT publication_target, coop_session_id FROM #{prefix}.episode_work_sessions WHERE id = $1",
                 [id]
               )

      SQL.query!(
        repo,
        "UPDATE #{prefix}.episode_work_sessions SET publication_target = '{}' WHERE id = $1",
        [id]
      )

      for invalid <- ["[]", Jason.encode!(%{"body" => String.duplicate("x", 65_536)})] do
        assert_raise Postgrex.Error, ~r/episode_work_session_publication_target_valid/, fn ->
          SQL.query!(
            repo,
            "UPDATE #{prefix}.episode_work_sessions SET publication_target = $1 WHERE id = $2",
            [invalid, id]
          )
        end
      end
    end)
  end

  test "issue workflows keep existing repositories opted out and enforce plan ownership" do
    in_scratch_schema("issue_workflows", fn repo, prefix ->
      migrate!(repo, prefix, 20_261_117_230_000)
      repository!(repo, prefix, "existing")
      assert migrate!(repo, prefix, 20_261_118_000_000) == [20_261_118_000_000]

      assert %{rows: [[false]]} =
               SQL.query!(repo, "SELECT github_issue_actions FROM #{prefix}.repository_settings")

      first = workflow!(repo, prefix, "first")
      second = workflow!(repo, prefix, "second")

      plan =
        row!(
          repo,
          prefix,
          "github_issue_plans",
          %{
            "workflow_id" => first,
            "revision" => 1,
            "source_key" => "first",
            "body" => "Read then build",
            "source_commit" => @commit,
            "issue_snapshot" => "{}",
            "author_ref" => "github:user:1"
          },
          :inserted
        )

      SQL.query!(
        repo,
        "UPDATE #{prefix}.github_issue_workflows SET current_plan_id = $1 WHERE id = $2",
        [plan, first]
      )

      assert_raise Postgrex.Error, ~r/github_issue_workflow_plan_owned/, fn ->
        SQL.query!(
          repo,
          "UPDATE #{prefix}.github_issue_workflows SET current_plan_id = $1 WHERE id = $2",
          [plan, second]
        )
      end

      assert_raise Postgrex.Error, ~r/github_issue_request_valid/, fn ->
        request!(repo, prefix, first, "implement_plan", 1)
      end

      assert_raise Postgrex.Error, ~r/github_issue_request_plan_owned/, fn ->
        request!(repo, prefix, second, "implement_plan", 1, plan)
      end

      request!(repo, prefix, first, "implement_plan", 1, plan)
    end)
  end

  test "CI policy preserves own-PR repair for old repositories and opts new repositories out" do
    in_scratch_schema("ci_policy", fn repo, prefix ->
      migrate!(repo, prefix, 20_261_118_000_000)
      repository!(repo, prefix, "existing")
      assert migrate!(repo, prefix, 20_261_118_010_000) == [20_261_118_010_000]
      repository!(repo, prefix, "new")

      assert %{rows: [["existing", "own"], ["new", "off"]]} =
               SQL.query!(
                 repo,
                 "SELECT ref, github_ci_repair FROM #{prefix}.repository_settings ORDER BY ref"
               )

      assert_raise Postgrex.Error, ~r/repository_ci_repair_valid/, fn ->
        SQL.query!(repo, "UPDATE #{prefix}.repository_settings SET github_ci_repair = 'anything'")
      end
    end)
  end

  test "CI custody bounds rounds and cannot adopt another PR's repair round" do
    in_scratch_schema("ci_custody", fn repo, prefix ->
      migrate!(repo, prefix, 20_261_118_010_000)
      assert migrate!(repo, prefix, 20_261_118_020_000) == [20_261_118_020_000]
      first = identity_row!(repo, prefix, "github_ci_repairs", "first")
      second = identity_row!(repo, prefix, "github_ci_repairs", "second")

      round =
        row!(
          repo,
          prefix,
          "github_ci_repair_rounds",
          %{
            "repair_id" => first,
            "generation" => 1,
            "ordinal" => 1,
            "entry_id" => uuid(),
            "head" => @commit,
            "snapshot" => "{}"
          },
          :inserted
        )

      assert_raise Postgrex.Error, ~r/github_ci_repair_round_owned/, fn ->
        SQL.query!(
          repo,
          "UPDATE #{prefix}.github_ci_repairs SET current_round_id = $1 WHERE id = $2",
          [round, second]
        )
      end

      SQL.query!(
        repo,
        "UPDATE #{prefix}.github_ci_repairs SET current_round_id = $1 WHERE id = $2",
        [round, first]
      )

      assert_raise Postgrex.Error, ~r/github_ci_repair_valid/, fn ->
        SQL.query!(repo, "UPDATE #{prefix}.github_ci_repairs SET rounds = 3 WHERE id = $1", [
          first
        ])
      end

      assert_raise Postgrex.Error, ~r/github_ci_repair_round_valid/, fn ->
        SQL.query!(
          repo,
          "UPDATE #{prefix}.github_ci_repair_rounds SET outcome = '{}' WHERE id = $1",
          [round]
        )
      end
    end)
  end

  test "browser reports attach to existing turns and follow their retention deletion" do
    in_scratch_schema("browser_reports", fn repo, prefix ->
      migrate!(repo, prefix, 20_261_118_020_000)

      episode =
        row!(repo, prefix, "episode_kernel_episodes", %{
          "key" => "old-task",
          "state" => "complete",
          "destination_transport" => "control_plane",
          "destination_conversation_ref" => "fixture"
        })

      session =
        row!(repo, prefix, "episode_work_sessions", %{
          "episode_id" => episode,
          "execution_kind" => "work",
          "policy" => "fixture",
          "policy_digest" => @digest,
          "external_ref" => "old-task-session"
        })

      turn =
        row!(repo, prefix, "episode_work_turns", %{
          "episode_id" => episode,
          "session_id" => session,
          "turn_ref" => "old-turn"
        })

      assert migrate!(repo, prefix, 20_261_118_030_000) == [20_261_118_030_000]

      report =
        row!(
          repo,
          prefix,
          "browser_test_reports",
          %{"turn_id" => turn, "fingerprint" => @digest, "source" => "{}", "document" => "{}"},
          :inserted
        )

      for invalid <- ["[]", Jason.encode!(%{"body" => String.duplicate("x", 32_768)})] do
        assert_raise Postgrex.Error, ~r/browser_test_report_valid/, fn ->
          SQL.query!(
            repo,
            "UPDATE #{prefix}.browser_test_reports SET document = $1 WHERE id = $2",
            [invalid, report]
          )
        end
      end

      SQL.query!(repo, "DELETE FROM #{prefix}.episode_work_turns WHERE id = $1", [turn])

      assert %{rows: [[0]]} =
               SQL.query!(repo, "SELECT count(*) FROM #{prefix}.browser_test_reports")
    end)
  end

  test "triage migration preserves writer requests and reserves actor zero for read-only triage" do
    in_scratch_schema("triage_policy", fn repo, prefix ->
      migrate!(repo, prefix, 20_261_118_030_000)
      repository!(repo, prefix, "existing")
      workflow = workflow!(repo, prefix, "triage")
      old = request!(repo, prefix, workflow, "build_issue", 7)
      assert migrate!(repo, prefix, 20_261_118_040_000) == [20_261_118_040_000]

      assert %{rows: [[false, false]]} =
               SQL.query!(
                 repo,
                 "SELECT github_issue_triage, github_triage_labels FROM #{prefix}.repository_settings"
               )

      assert %{rows: [[7, "build_issue"]]} =
               SQL.query!(
                 repo,
                 "SELECT actor_id, kind FROM #{prefix}.github_issue_requests WHERE id = $1",
                 [old]
               )

      request!(repo, prefix, workflow, "triage_issue", 0)

      for kind <- ~w(make_plan build_issue implement_plan) do
        assert_raise Postgrex.Error, ~r/github_issue_request_valid/, fn ->
          request!(repo, prefix, workflow, kind, 0)
        end
      end

      assert_raise Postgrex.Error, ~r/github_issue_request_valid/, fn ->
        request!(repo, prefix, workflow, "triage_issue", 0, uuid())
      end
    end)
  end

  test "issue index bounds backfill and deletes only its own indexed reports" do
    in_scratch_schema("issue_index", fn repo, prefix ->
      migrate!(repo, prefix, 20_261_118_040_000)
      assert migrate!(repo, prefix, 20_261_118_050_000) == [20_261_118_050_000]

      attrs = %{
        "identity" => @digest,
        "binding_ref" => "fixture",
        "repository_ref" => "fixture",
        "repository_id" => 1,
        "installation_id" => 1
      }

      index = row!(repo, prefix, "github_issue_indexes", attrs)

      other =
        row!(repo, prefix, "github_issue_indexes", %{
          attrs
          | "identity" => String.duplicate("b", 64)
        })

      for owner <- [index, other],
          do: row!(repo, prefix, "github_indexed_issues", %{"index_id" => owner, "number" => 1})

      assert_raise Postgrex.Error, ~r/github_issue_index_valid/, fn ->
        SQL.query!(repo, "UPDATE #{prefix}.github_issue_indexes SET page = 7 WHERE id = $1", [
          index
        ])
      end

      SQL.query!(repo, "DELETE FROM #{prefix}.github_issue_indexes WHERE id = $1", [index])

      assert %{rows: [[^other]]} =
               SQL.query!(repo, "SELECT index_id FROM #{prefix}.github_indexed_issues")
    end)
  end

  test "inspected issue receipts preserve existing requests and cascade with their owner" do
    in_scratch_schema("triage_reads", fn repo, prefix ->
      migrate!(repo, prefix, 20_261_118_050_000)
      workflow = workflow!(repo, prefix, "reads")
      request = request!(repo, prefix, workflow, "triage_issue", 0)
      assert migrate!(repo, prefix, 20_261_118_060_000) == [20_261_118_060_000]

      attrs = %{
        "request_id" => request,
        "number" => 2,
        "fingerprint" => @digest,
        "document" => "{}"
      }

      read = row!(repo, prefix, "github_issue_triage_reads", attrs, :inserted)

      assert_raise Postgrex.Error,
                   ~r/github_issue_triage_reads_request_id_fingerprint_index/,
                   fn ->
                     row!(repo, prefix, "github_issue_triage_reads", attrs, :inserted)
                   end

      for invalid <- ["[]", Jason.encode!(%{"body" => String.duplicate("x", 131_072)})] do
        assert_raise Postgrex.Error, ~r/github_issue_triage_read_valid/, fn ->
          SQL.query!(
            repo,
            "UPDATE #{prefix}.github_issue_triage_reads SET document = $1 WHERE id = $2",
            [invalid, read]
          )
        end
      end

      SQL.query!(repo, "DELETE FROM #{prefix}.github_issue_requests WHERE id = $1", [request])

      assert %{rows: [[0]]} =
               SQL.query!(repo, "SELECT count(*) FROM #{prefix}.github_issue_triage_reads")
    end)
  end

  defp repository!(repo, prefix, ref) do
    SQL.query!(
      repo,
      "INSERT INTO #{prefix}.repository_settings (ref, inserted_at, updated_at) VALUES ($1, now(), now())",
      [ref]
    )
  end

  defp workflow!(repo, prefix, name),
    do: identity_row!(repo, prefix, "github_issue_workflows", name, %{"issue_snapshot" => "{}"})

  defp identity_row!(repo, prefix, table, name, extra \\ %{}) do
    row!(
      repo,
      prefix,
      table,
      Map.merge(
        %{
          "identity" => :crypto.hash(:sha256, name) |> Base.encode16(case: :lower),
          "binding_ref" => name,
          "repository_ref" => name,
          "repository_id" => 1,
          "installation_id" => 1,
          "number" => 1
        },
        extra
      )
    )
  end

  defp request!(repo, prefix, workflow, kind, actor, plan \\ nil) do
    row!(
      repo,
      prefix,
      "github_issue_requests",
      %{
        "workflow_id" => workflow,
        "plan_id" => plan,
        "kind" => kind,
        "request_key" => :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
        "base_revision" => 0,
        "source_snapshot" => "{}",
        "actor_id" => actor,
        "entry_id" => uuid()
      },
      :inserted
    )
  end

  # Raw inserts deliberately use the columns available at each previous migration.
  defp row!(repo, prefix, table, attrs, timestamps \\ :both) do
    id = uuid()
    pairs = Map.put(attrs, "id", id) |> Enum.sort()
    columns = Enum.map_join(pairs, ",", &elem(&1, 0))
    params = Enum.map(pairs, &elem(&1, 1))
    placeholders = Enum.map_join(1..length(params), ",", &"$#{&1}")
    stamps = if timestamps == :both, do: ",inserted_at,updated_at", else: ",inserted_at"
    values = if timestamps == :both, do: ",now(),now()", else: ",now()"

    SQL.query!(
      repo,
      "INSERT INTO #{prefix}.#{table} (#{columns}#{stamps}) VALUES (#{placeholders}#{values})",
      params
    )

    id
  end

  defp uuid, do: Ecto.UUID.dump!(Ecto.UUID.generate())
end
