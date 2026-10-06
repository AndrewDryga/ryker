defmodule Ryker.CoopFleet.JobTemplatesTest do
  use ExUnit.Case, async: true
  alias Ryker.Admission.ReadySessions
  alias Ryker.CoopFleet.{JobSpec, JobTemplates}
  alias Ryker.Settings.{Environment, EnvironmentRepository, GitHubBinding, Repository, Work}

  test "repository-free jobs retain tools and semantic repair in an empty read-only workspace" do
    for purpose <- [
          :admission,
          :conversational,
          :incident,
          :learning,
          :schedule_governed,
          :schedule_read_only
        ] do
      execution = JobTemplates.execution(%Work{}, purpose, false)
      assert execution["mode"] == "normal"
      assert execution["repository_read_only"]
      refute Map.has_key?(execution, "project_env")
      refute Map.has_key?(execution, "project_mcp")
      assert execution["environment"] == %{}
      assert execution["check"] == %{"argv" => [], "environment" => %{}}
    end
  end

  # Coop's job-setup:2 refuses a job without finite per-container caps, and
  # Docker refuses a CPU cap above the host's cores: tenant's worker VM has six.
  test "every job carries caps the smallest worker can enforce" do
    for purpose <- [:admission, :contributor, :learning] do
      assert JobTemplates.execution(%Work{}, purpose, true)["resources"] == %{
               "cpu_millis" => 4_000,
               "memory_bytes" => 8 * 1_073_741_824,
               "pids" => 4_096
             }
    end
  end

  # Coop keeps a prepared routing agent running for the routing job's warm
  # idle timeout, and a session kept ready is handed out for at most its
  # maximum age. The agent has to outlast that by the five minutes a message
  # may take to reach its turn, or the message would start it cold again.
  # Every other job starts its agent on its first turn and stops it after
  # each, so none holds one of the worker's runtime slots while it idles.
  # Routing shared Work's hour-long turn timeout, and a waiting routing turn
  # gives its attempt back, so one that never finished held its conversation
  # for up to an hour (2026-10-04 review). Over 14 days to 2026-10-05 routing
  # attempts took 15 s at the median and 66 s at most.
  test "a routing turn is ended after five minutes, other work after an hour" do
    routing = JobTemplates.execution(%Work{}, :admission, false)
    assert routing["limits"]["turn_timeout_ms"] == 300_000

    for purpose <- [:conversational, :contributor, :deep, :incident, :learning, :standard] do
      assert JobTemplates.execution(%Work{}, purpose, false)["limits"]["turn_timeout_ms"] ==
               3_600_000
    end
  end

  test "only routing keeps a prepared agent running, and past a ready session's age" do
    for purpose <- [
          :conversational,
          :contributor,
          :deep,
          :incident,
          :learning,
          :schedule,
          :schedule_governed,
          :schedule_read_only,
          :standard
        ] do
      assert JobTemplates.execution(%Work{}, purpose, false)["limits"]["warm_idle_timeout_ms"] ==
               0
    end

    routing = JobTemplates.execution(%Work{}, :admission, false)
    warm_ms = routing["limits"]["warm_idle_timeout_ms"]
    assert warm_ms >= (ReadySessions.maximum_age_seconds() + 5 * 60) * 1_000

    job =
      Map.merge(routing, %{
        "version" => 2,
        "job_ref" => "ryker-admission-ready:#{Ecto.UUID.generate()}",
        "source" => nil,
        "companions" => []
      })

    assert {:ok, _digest} = JobSpec.digest(job)
  end

  test "controller templates require no worker or policy rows" do
    templates = JobTemplates.from_settings(snapshot())
    assert length(templates) == 24
    assert Enum.count(templates, &(&1.scope_kind == :installation)) == 6
    assert Enum.count(templates, &(&1.scope_kind == :repository)) == 10
    assert Enum.count(templates, &(&1.scope_kind == :environment)) == 8
    assert template(templates, :conversational).policy_name == "ryker-repo-app-conversation"
  end

  test "model choice changes execution but read-only classes share the same authority" do
    before = JobTemplates.from_settings(snapshot())

    assert template(before, :conversational).authority_digest ==
             template(before, :standard).authority_digest

    assert template(before, :standard).authority_digest ==
             template(before, :deep).authority_digest

    refute template(before, :standard).authority_digest ==
             template(before, :contributor).authority_digest

    snapshot = snapshot()

    changed = %{
      snapshot
      | work: %{snapshot.work | standard_models: ["codex:different-model/high@default"]}
    }

    after_change = JobTemplates.from_settings(changed)

    assert template(before, :standard).authority_digest ==
             template(after_change, :standard).authority_digest

    refute template(before, :standard).policy_digest ==
             template(after_change, :standard).policy_digest

    changed_account = %{
      snapshot
      | work: %{snapshot.work | standard_models: ["codex:different-model/high@other"]}
    }

    refute template(before, :standard).authority_digest ==
             template(JobTemplates.from_settings(changed_account), :standard).authority_digest
  end

  test "unavailable or unpinned source removes that repository and its dependent environment" do
    snapshot = snapshot()
    [app, companion] = snapshot.repositories

    for changed <- [%{app | github_access: :suspended}, %{app | source_commit: nil}] do
      templates = JobTemplates.from_settings(%{snapshot | repositories: [changed, companion]})
      assert length(templates) == 11
      refute Enum.any?(templates, &(&1.scope_kind == :environment or &1.scope_ref == "app"))
    end

    templates = JobTemplates.from_settings(%{snapshot | github_bindings: []})
    assert length(templates) == 6
  end

  test "adding or changing a companion changes environment authority" do
    snapshot = snapshot()
    templates = JobTemplates.from_settings(snapshot)

    environment =
      Enum.find(
        templates,
        &(&1.scope_kind == :environment and &1.repository_ref == "app" and &1.purpose == :standard)
      )

    refute environment.authority_digest == template(templates, :standard).authority_digest

    [scope] = snapshot.environments

    single = %{
      scope
      | repositories: [
          %EnvironmentRepository{repository_ref: "app", position: 0, access: :read_write}
        ]
    }

    refute Enum.any?(
             JobTemplates.from_settings(%{snapshot | environments: [single]}),
             &(&1.scope_kind == :environment)
           )
  end

  # Andrew, 2026-09-27: "can we here limit read or read/write access per
  # repo?" A repository an environment only reads is never a working copy
  # there, so no template opens it as one, writable or not: it is only ever
  # mounted beside the repositories work may change.
  test "a read-only repository is only mounted beside the repositories work may change" do
    snapshot = snapshot()
    [production] = snapshot.environments
    [app, library] = production.repositories
    limited = %{production | repositories: [app, %{library | access: :read_only}]}

    environment =
      %{snapshot | environments: [limited]}
      |> JobTemplates.from_settings()
      |> Enum.filter(&(&1.scope_kind == :environment))

    assert Enum.map(environment, & &1.purpose) |> Enum.sort() ==
             Enum.sort([:conversational, :contributor, :deep, :standard])

    for template <- environment do
      assert template.repository_ref == "app"
      assert template.repositories == ["app", "library"]
    end
  end

  defp template(templates, purpose) do
    Enum.find(
      templates,
      &(&1.scope_kind == :repository and &1.scope_ref == "app" and &1.purpose == purpose)
    )
  end

  defp snapshot do
    %{
      work: %Work{},
      repositories:
        Enum.map(
          ["app", "library"],
          &%Repository{
            ref: &1,
            github_repository: "example/" <> &1,
            source_commit: String.duplicate("a", 40)
          }
        ),
      github_bindings: Enum.map(["app", "library"], &%GitHubBinding{repository_ref: &1}),
      environments: [
        %Environment{
          ref: "production",
          repositories: [
            %EnvironmentRepository{repository_ref: "app", position: 0, access: :read_write},
            %EnvironmentRepository{repository_ref: "library", position: 1, access: :read_write}
          ]
        }
      ]
    }
  end
end
