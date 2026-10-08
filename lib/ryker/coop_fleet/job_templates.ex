defmodule Ryker.CoopFleet.JobTemplates do
  @moduledoc "Controller-owned execution settings, independent of worker advertisements."
  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.JobCheck
  alias Ryker.Settings

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

  # How long Coop keeps an agent running between turns. Only routing sessions
  # are prepared ahead of any message (`Ryker.Admission.ReadyPool`); every other
  # job starts its agent on its first turn and stops it after each, so none
  # holds one of the worker's runtime slots while it idles. A session kept
  # ready is handed out for five minutes less than this
  # (`Ryker.Admission.ReadySessions`), so the agent a message claims is still
  # running when its turn arrives. Coop allows at most an hour.
  @routing_warm_idle_timeout_ms 35 * 60 * 1_000

  # A routing turn that never finished held its conversation for up to the
  # hour every job shared, since a waiting routing turn gives its attempt
  # back (2026-10-04 review). Over 14 days to 2026-10-05 routing attempts took
  # 15 s at the median and 66 s at most.
  @routing_turn_timeout_ms 5 * 60 * 1_000
  @turn_timeout_ms 60 * 60 * 1_000

  defp model_field(purpose), do: Map.get(@models, purpose)

  @spec warm_idle_timeout_ms(atom()) :: non_neg_integer()
  def warm_idle_timeout_ms(:admission), do: @routing_warm_idle_timeout_ms
  def warm_idle_timeout_ms(_purpose), do: 0

  defp turn_timeout_ms(:admission), do: @routing_turn_timeout_ms
  defp turn_timeout_ms(_purpose), do: @turn_timeout_ms

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

    # Work in an environment may change any of its read and write
    # repositories, so each one is a working copy with every other repository
    # mounted read-only beside it. A repository the environment only reads
    # (Andrew, 2026-09-27: "can we here limit read or read/write access per
    # repo?") is never a working copy: it is only ever such a companion.
    environment =
      for environment <- snapshot.environments,
          refs = Settings.Environment.repository_refs(environment),
          length(refs) > 1 and Enum.all?(refs, &MapSet.member?(available, &1)),
          primary <- Settings.Environment.writable_refs(environment),
          purpose <- @environment do
        template(snapshot.work, purpose, :environment, environment.ref, primary, [
          primary | List.delete(refs, primary)
        ])
      end

    installation ++ repository ++ environment
  end

  # Per-container caps every job carries: Coop's job-setup:2 refuses a job
  # without finite ones. Docker refuses a CPU cap above the host's cores, and
  # tenant's worker VM has six; 4096 processes is Coop's own default cap.
  @resources %{"cpu_millis" => 4_000, "memory_bytes" => 8 * 1_073_741_824, "pids" => 4_096}

  @spec resources() :: map()
  def resources, do: @resources

  # A job names its whole setup (Coop job-setup:2). Work gets no environment
  # of its own; a working copy's check is the repository's gate, which
  # `Ryker.CoopFleet.JobAuthority` resolves at the job's base commit.
  def execution(work, purpose, repository?) do
    %{
      "targets" => Map.fetch!(work, model_field(purpose)),
      "mode" => "normal",
      "environment" => %{},
      "check" => JobCheck.none(),
      "resources" => @resources,
      "repository_read_only" => not repository? or purpose != :contributor,
      "egress" => %{"mode" => "open", "rules" => [], "export_destinations" => false},
      "limits" => %{
        "max_turns" => 100,
        "max_queued_turns" => 20,
        "max_queued_bytes" => 1_048_576,
        "turn_timeout_ms" => turn_timeout_ms(purpose),
        "warm_idle_timeout_ms" => warm_idle_timeout_ms(purpose),
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
        |> Map.put("credentials", Enum.map(execution["targets"], &Settings.Work.account/1))
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
