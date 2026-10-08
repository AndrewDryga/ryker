defmodule Ryker.CoopFleet.JobSpecTest do
  use ExUnit.Case, async: true
  alias Ryker.CoopFleet.{JobSpec, JobTemplates}
  alias Ryker.Work.Session

  defp valid_job do
    %{
      "version" => 2,
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
      "repository_read_only" => true,
      "egress" => %{"mode" => "none", "rules" => [], "export_destinations" => false},
      "limits" => %{
        "max_turns" => 100,
        "max_queued_turns" => 20,
        "max_queued_bytes" => 1_048_576,
        "turn_timeout_ms" => 3_600_000,
        "warm_idle_timeout_ms" => 0,
        "max_patch_bytes" => 1_048_576
      },
      "environment" => %{"CI" => "1"},
      "check" => %{
        "argv" => ["make", "test"],
        "environment" => %{"DATABASE_URL" => "postgres://test"}
      },
      "resources" => %{"cpu_millis" => 2000, "memory_bytes" => 4_294_967_296, "pids" => 512}
    }
  end

  test "the immutable job digest matches Coop's sorted and escaped Go JSON" do
    for {timestamp, digest} <- [
          {"2026-09-26T12:00:00Z",
           "e3413eaa0fde8dffc7adb163162ab06a1d6b11ccd8918235cde00735cae49400"},
          {"2026-09-26T12:00:00.12345Z",
           "97b9bcb9a49b0017e096997e6b3d2faef7f8689c1753e3e3d8d82c92e3ad5bd4"},
          {"2026-09-26T12:00:00.000001Z",
           "857d39e4484647feddef7ed81bf095c213363858bd3b152a9baa1d0ae6d1adc3"},
          {"2026-09-26T12:00:00.123456789Z",
           "476e6a487c208a38aee4fc5d10ea082efbbdc72a8e555ececf6680349ad73554"}
        ] do
      assert {:ok, ^digest} =
               JobSpec.digest(
                 put_in(valid_job(), ["source", "binding", "resolved_at"], timestamp)
               )
    end
  end

  # Coop's workers refuse version-1 jobs since job-setup:2 (Coop 33ea84fe), and a replacement
  # session copies its predecessor's frozen job. A task begun before the move continues on a
  # version-2 job with exactly the sources and rights it was granted.
  test "a version-1 predecessor is rebound as version 2 with the same grant" do
    v1 =
      valid_job()
      |> Map.drop(~w(environment check resources))
      |> Map.merge(%{"version" => 1, "project_env" => false, "project_mcp" => false})

    v1_digest = Ryker.CanonicalJSON.worker_digest(v1)

    assert {:ok, rebound, digest} = JobSpec.rebind(v1, v1_digest, "job:replacement")
    assert rebound["version"] == 2
    assert rebound["job_ref"] == "job:replacement"
    refute Map.has_key?(rebound, "project_env")
    refute Map.has_key?(rebound, "project_mcp")
    assert rebound["environment"] == %{}
    assert rebound["check"] == %{"argv" => [], "environment" => %{}}
    assert rebound["resources"] == JobTemplates.resources()

    for field <- ~w(source companions targets mode repository_read_only egress limits),
        do: assert(rebound[field] == v1[field])

    assert {:ok, ^digest} = JobSpec.digest(rebound)

    assert JobSpec.rebind(v1, String.duplicate("f", 64), "job:replacement") ==
             {:error, :invalid_coop_worker_job}

    assert JobSpec.rebind(%{v1 | "project_env" => true}, v1_digest, "job:replacement") ==
             {:error, :invalid_coop_worker_job}
  end

  test "rebinding a replacement changes only job identity and refuses a corrupted predecessor" do
    job = valid_job()
    assert {:ok, digest} = JobSpec.digest(job)
    assert {:ok, rebound, new_digest} = JobSpec.rebind(job, digest, "job:replacement")
    assert Map.delete(rebound, "job_ref") == Map.delete(job, "job_ref")
    assert rebound["job_ref"] == "job:replacement"
    assert {:ok, ^new_digest} = JobSpec.digest(rebound)
    refute new_digest == digest

    assert JobSpec.rebind(job, String.duplicate("f", 64), "job:replacement") ==
             {:error, :invalid_coop_worker_job}
  end

  test "GitHub identities use the same segment boundaries as the worker" do
    for slug <- ["example/.github", "example/repo.git", String.duplicate("a", 100) <> "/repo"] do
      assert JobSpec.validate(put_in(valid_job(), ["source", "github_repository"], slug)) == :ok
    end

    for slug <- ["example/.", "example/..", "../repo", String.duplicate("a", 101) <> "/repo"] do
      assert JobSpec.validate(put_in(valid_job(), ["source", "github_repository"], slug)) ==
               {:error, :invalid_coop_worker_job}
    end
  end

  test "missing, unknown, oversized and ambiguous authority is refused" do
    job = valid_job()

    invalid = [
      Map.put(job, "version", 1),
      Map.delete(job, "check"),
      Map.put(job, "project_env", false),
      put_in(job, ["environment"], %{"COOP_TOKEN" => "1"}),
      put_in(job, ["environment"], %{"CI" => "1\nEVIL=1"}),
      put_in(job, ["environment"], %{"1CI" => "1"}),
      put_in(job, ["check"], %{"argv" => [], "environment" => %{"CI" => "1"}}),
      put_in(job, ["check", "argv"], [""]),
      put_in(job, ["resources", "cpu_millis"], 5),
      put_in(job, ["resources", "memory_bytes"], 1_024),
      put_in(job, ["resources", "pids"], 0),
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

    Enum.each(invalid, &assert(JobSpec.digest(&1) == {:error, :invalid_coop_worker_job}))
  end

  test "a workspaceless job carries no source or worker-local project settings" do
    bare = %{
      valid_job()
      | "mode" => "bare",
        "source" => nil,
        "repository_read_only" => false,
        "targets" => ["codex"]
    }

    assert JobSpec.validate(bare) == :ok

    assert JobSpec.validate(Map.put(bare, "project_env", false)) ==
             {:error, :invalid_coop_worker_job}
  end

  test "an empty normal workspace can carry independently authorized companions" do
    source = valid_job()["source"]

    job = %{
      valid_job()
      | "mode" => "normal",
        "source" => nil,
        "companions" => [%{"name" => "library", "source" => source}]
    }

    assert JobSpec.validate(job) == :ok

    assert JobSpec.validate(%{job | "mode" => "bare", "repository_read_only" => false}) ==
             {:error, :invalid_coop_worker_job}
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
    assert JobSpec.validate(job) == :ok

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
      assert JobSpec.validate(invalid) == {:error, :invalid_coop_worker_job}
    end

    assert JobSpec.validate(put_in(job, ["source", "submodules"], [child, child])) ==
             {:error, :invalid_coop_worker_job}
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
      Session.Changeset.insert(
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
