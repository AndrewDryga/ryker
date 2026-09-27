defmodule Ryker.CoopFleet.JobTemplates do
  @moduledoc "Controller-owned execution settings, independent of worker advertisements."

  alias Ryker.CanonicalJSON
  alias Ryker.Settings.{Environment, Work}

  @installation [
    :admission,
    :conversational,
    :incident,
    :learning,
    :schedule_governed,
    :schedule_read_only
  ]
  @repository [:conversational, :contributor, :deep, :schedule, :standard]
  @environment [:conversational, :contributor, :deep, :standard]
  @models %{
    admission: :routing_models,
    conversational: :conversation_models,
    standard: :standard_models,
    deep: :deep_models,
    contributor: :contributor_models,
    schedule: :schedule_models,
    schedule_governed: :schedule_models,
    schedule_read_only: :schedule_models,
    incident: :incident_models,
    learning: :learning_models
  }

  def model_field(purpose), do: Map.get(@models, purpose)

  def from_settings(snapshot) do
    repositories =
      Enum.filter(snapshot.repositories, &source_available?(&1, snapshot.github_bindings))

    available = MapSet.new(repositories, & &1.ref)

    installation =
      Enum.map(@installation, &template(snapshot.work, &1, :installation, "", "", []))

    repository =
      for repository <- repositories,
          purpose <- @repository,
          do: template(snapshot.work, purpose, :repository, repository.ref, "", [repository.ref])

    environment =
      for environment <- snapshot.environments,
          refs = Environment.repository_refs(environment),
          length(refs) > 1 and Enum.all?(refs, &MapSet.member?(available, &1)),
          primary <- refs,
          purpose <- @environment do
        template(snapshot.work, purpose, :environment, environment.ref, primary, [
          primary | List.delete(refs, primary)
        ])
      end

    installation ++ repository ++ environment
  end

  def execution(work, purpose, repository?) do
    %{
      "targets" => Map.fetch!(work, model_field(purpose)),
      "mode" => "normal",
      "project_env" => false,
      "project_mcp" => false,
      "repository_read_only" => not repository? or purpose != :contributor,
      "egress" => %{"mode" => "open", "rules" => [], "export_destinations" => false},
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

  defp template(work, purpose, scope, scope_ref, repository_ref, refs) do
    document = %{
      "version" => 1,
      "scope" => %{"kind" => Atom.to_string(scope), "ref" => scope_ref, "repositories" => refs},
      "execution" => execution(work, purpose, refs != [])
    }

    # Moving between conversation, standard and deep changes the model, not
    # the allowed work. The WorkProfile admission check compares these rights.
    authority =
      update_in(document, ["execution"], fn execution ->
        execution
        |> Map.delete("targets")
        |> Map.put("credentials", Enum.map(execution["targets"], &Work.account/1))
      end)

    %{
      purpose: purpose,
      scope_kind: scope,
      scope_ref: scope_ref,
      repository_ref: repository_ref,
      repositories: refs,
      policy_name: name(purpose, scope, scope_ref, repository_ref),
      policy_digest: CanonicalJSON.digest(document),
      authority_digest: CanonicalJSON.digest(authority)
    }
  end

  defp name(:conversational, :installation, _, _), do: "ryker-chat"
  defp name(purpose, :installation, _, _), do: "ryker-" <> suffix(purpose)
  defp name(purpose, :repository, ref, _), do: "ryker-repo-#{ref}-#{suffix(purpose)}"

  defp name(purpose, :environment, ref, repository),
    do: "ryker-env-#{ref}-#{repository}-#{suffix(purpose)}"

  defp suffix(:conversational), do: "conversation"
  defp suffix(purpose), do: purpose |> Atom.to_string() |> String.replace("_", "-")

  defp source_available?(repository, bindings) do
    repository.github_access == :available and is_binary(repository.source_commit) and
      Regex.match?(~r/\A[0-9a-f]{40}\z/, repository.source_commit) and
      Enum.any?(bindings, &(&1.repository_ref == repository.ref))
  end
end
