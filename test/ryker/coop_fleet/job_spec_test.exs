defmodule Ryker.CoopFleet.JobSpecTest do
  use ExUnit.Case, async: true

  alias Ryker.CoopFleet.JobSpec
  alias Ryker.Work.SessionChangeset

  defp valid_job do
    %{
      "version" => 1,
      "job_ref" => "job:one",
      "source" => %{
        "repository_ref" => "repo:one",
        "github_repository" => "example/repository",
        "github_repository_id" => 17,
        "binding" => %{
          "version" => 1,
          "kind" => "default",
          "requested" => %{"kind" => "default"},
          "remote_identity" => "origin",
          "default_ref" => "refs/heads/main",
          "default_commit" => String.duplicate("a", 40),
          "selected_ref" => "refs/heads/main",
          "selected_commit" => String.duplicate("a", 40),
          "base_commit" => String.duplicate("a", 40),
          "admitted_tree" => String.duplicate("c", 40),
          "resolved_at" => "2026-09-26T12:00:00Z"
        },
        "submodules" => []
      },
      "companions" => [],
      "targets" => ["codex:gpt-6&sol@default"],
      "mode" => "readonly",
      "project_env" => false,
      "project_mcp" => false,
      "repository_read_only" => true,
      "egress" => %{"mode" => "none", "rules" => [], "export_destinations" => false},
      "limits" => %{
        "max_turns" => 100,
        "max_queued_turns" => 20,
        "max_queued_bytes" => 1_048_576,
        "turn_timeout_ms" => 3_600_000,
        "warm_idle_timeout_ms" => 0,
        "max_patch_bytes" => 1_048_576
      }
    }
  end

  test "the immutable job digest matches Coop's sorted and escaped Go JSON" do
    for {timestamp, digest} <- [
          {"2026-09-26T12:00:00Z",
           "97a91fd4ddff4be68c9965f6cec437e8fe504eaac45db818be0d9fb48782d915"},
          {"2026-09-26T12:00:00.12345Z",
           "44b38704f83bedff2bca113538c0496e0353ec46aa2d3ae9d211276bdba8ca3a"},
          {"2026-09-26T12:00:00.000001Z",
           "f67dac296a8be0706a1fdb886071747c4dec836613806d858db8ac5718f80e1c"},
          {"2026-09-26T12:00:00.123456789Z",
           "008993e50a1ce995bc4cad96e7793c33ca55355b44c2e9ce3f0e33a7229648e2"}
        ] do
      assert {:ok, ^digest} =
               JobSpec.digest(
                 put_in(valid_job(), ["source", "binding", "resolved_at"], timestamp)
               )
    end
  end

  test "rebinding a replacement changes only job identity and refuses a corrupted predecessor" do
    job = valid_job()
    assert {:ok, digest} = JobSpec.digest(job)
    assert {:ok, rebound, new_digest} = JobSpec.rebind(job, digest, "job:replacement")
    assert Map.delete(rebound, "job_ref") == Map.delete(job, "job_ref")
    assert rebound["job_ref"] == "job:replacement"
    assert {:ok, ^new_digest} = JobSpec.digest(rebound)
    refute new_digest == digest

    assert {:error, :invalid_coop_worker_job} =
             JobSpec.rebind(job, String.duplicate("f", 64), "job:replacement")
  end

  test "GitHub identities use the same segment boundaries as the worker" do
    for slug <- ["example/.github", "example/repo.git", String.duplicate("a", 100) <> "/repo"] do
      assert :ok = JobSpec.validate(put_in(valid_job(), ["source", "github_repository"], slug))
    end

    for slug <- ["example/.", "example/..", "../repo", String.duplicate("a", 101) <> "/repo"] do
      assert {:error, :invalid_coop_worker_job} =
               JobSpec.validate(put_in(valid_job(), ["source", "github_repository"], slug))
    end
  end

  test "missing, unknown, oversized and ambiguous authority is refused" do
    job = valid_job()

    invalid = [
      Map.delete(job, "project_env"),
      Map.put(job, "worker_path", "/tmp/repo"),
      put_in(job, ["source", "github_repository_id"], 0),
      put_in(job, ["source", "url"], "https://example.invalid/repo"),
      put_in(job, ["source", "binding", "selected_commit"], String.duplicate("b", 40)),
      put_in(job, ["source", "submodules"], [%{"path" => "unapproved"}]),
      put_in(job, ["limits", "max_queued_turns"], 1_001),
      put_in(job, ["egress", "rules"], [%{"to" => %{"domain" => "a.example"}}]),
      put_in(job, ["egress", "export_destinations"], true),
      put_in(job, ["egress"], %{
        "mode" => "filtered",
        "rules" => [%{"to" => %{"service" => "database"}}],
        "export_destinations" => false
      }),
      put_in(job, ["mode"], "bare")
    ]

    Enum.each(invalid, fn document ->
      assert {:error, :invalid_coop_worker_job} = JobSpec.digest(document)
    end)
  end

  test "a workspaceless job carries no source or worker-local project settings" do
    bare = %{
      valid_job()
      | "mode" => "bare",
        "source" => nil,
        "repository_read_only" => false,
        "targets" => ["codex"]
    }

    assert :ok = JobSpec.validate(bare)
    assert {:error, :invalid_coop_worker_job} = JobSpec.validate(%{bare | "project_env" => true})
  end

  test "an empty normal workspace can carry independently authorized companions" do
    source = valid_job()["source"]

    job = %{
      valid_job()
      | "mode" => "normal",
        "source" => nil,
        "companions" => [%{"name" => "library", "source" => source}]
    }

    assert :ok = JobSpec.validate(job)

    assert {:error, :invalid_coop_worker_job} =
             JobSpec.validate(%{job | "mode" => "bare", "repository_read_only" => false})
  end

  test "submodule authority binds safe paths and exact recursive identities" do
    child = %{
      "path" => "vendor/library",
      "repository_ref" => "repo:library",
      "github_repository" => "example/library",
      "github_repository_id" => 18,
      "commit" => String.duplicate("d", 40),
      "tree" => String.duplicate("e", 40),
      "submodules" => []
    }

    child = %{child | "submodules" => [%{child | "path" => "nested"}]}
    job = put_in(valid_job(), ["source", "submodules"], [child])
    assert :ok = JobSpec.validate(job)

    for path <- [
          "",
          "/absolute",
          "../escape",
          "a/../b",
          "a//b",
          ".git",
          "a/.GIT/b",
          "a\\b",
          "a\0b"
        ] do
      invalid = put_in(job, ["source", "submodules"], [%{child | "path" => path}])
      assert {:error, :invalid_coop_worker_job} = JobSpec.validate(invalid)
    end

    assert {:error, :invalid_coop_worker_job} =
             JobSpec.validate(put_in(job, ["source", "submodules"], [child, child]))
  end

  test "session custody accepts only a matching immutable job and digest" do
    job = %{
      valid_job()
      | "mode" => "bare",
        "source" => nil,
        "repository_read_only" => false,
        "targets" => ["codex"]
    }

    assert {:ok, digest} = JobSpec.digest(job)
    base = %{authority_digest: nil, workspace_task: nil}

    insert = fn options ->
      SessionChangeset.insert_with_authority(
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        1,
        "job:one",
        String.duplicate("a", 64),
        nil,
        "job:one",
        Map.merge(base, options)
      )
    end

    assert insert.(%{worker_job_document: job, worker_job_digest: digest}).valid?

    refute insert.(%{worker_job_document: job, worker_job_digest: String.duplicate("b", 64)}).valid?

    refute insert.(%{worker_job_document: job}).valid?

    wrong_ref = Map.put(job, "job_ref", "job:another-generation")
    assert {:ok, wrong_ref_digest} = JobSpec.digest(wrong_ref)
    refute insert.(%{worker_job_document: wrong_ref, worker_job_digest: wrong_ref_digest}).valid?
    # historical sessions remain readable
    assert insert.(%{}).valid?
  end
end
