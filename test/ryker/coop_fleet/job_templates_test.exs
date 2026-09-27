defmodule Ryker.CoopFleet.JobTemplatesTest do
  use ExUnit.Case, async: true

  alias Ryker.CoopFleet.JobTemplates
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
      refute execution["project_env"]
      refute execution["project_mcp"]
    end
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
    single = %{scope | repositories: [%EnvironmentRepository{repository_ref: "app", position: 0}]}

    refute Enum.any?(
             JobTemplates.from_settings(%{snapshot | environments: [single]}),
             &(&1.scope_kind == :environment)
           )
  end

  defp template(templates, purpose),
    do:
      Enum.find(
        templates,
        &(&1.scope_kind == :repository and &1.scope_ref == "app" and &1.purpose == purpose)
      )

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
            %EnvironmentRepository{repository_ref: "app", position: 0},
            %EnvironmentRepository{repository_ref: "library", position: 1}
          ]
        }
      ]
    }
  end
end
