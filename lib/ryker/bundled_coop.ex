defmodule Ryker.BundledCoop do
  @moduledoc """
  Owns the local co:op lane shipped with the Compose distribution.

  The distribution creates the worker identity and policy files. Once that
  exact authenticated worker reports its advertisements, Ryker selects its
  workspace and pins the advertised policies without asking an operator to
  copy identities or digests through the browser.
  """

  import Ecto.Query

  alias Ryker.CoopFleet.{Enrollment, Worker}
  alias Ryker.GitHub.InstallationTokens
  alias Ryker.{Repo, Settings}
  alias Ryker.Settings.Repository

  @actor "control-plane:local"
  @worker_env "RYKER_BUNDLED_COOP_WORKER_ID"
  @root_env "RYKER_BUNDLED_COOP_ROOT"
  @default_worker "ryker-compose"
  @default_workspace "ryker-compose"
  @installation_policies %{
    admission: "ryker-admission",
    learning: "ryker-learning",
    schedule_governed: "ryker-schedule-governed",
    schedule_read_only: "ryker-schedule-read-only"
  }
  @repository_policies %{
    conversational: "conversation",
    contributor: "contributor",
    deep: "deep",
    schedule: "schedule",
    standard: "standard"
  }

  @doc false
  def ensure_distribution! do
    root = root!()
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    seed = ensure_seed_repository!(root)
    write_policy_file!(root, seed)
    ensure_enrollment_file!(root)
    :ok
  end

  @doc false
  def ensure_enrollment_file!, do: ensure_enrollment_file!(root!())

  @doc false
  def maybe_configure(worker_id) when is_binary(worker_id) do
    case System.get_env(@worker_env) do
      ^worker_id ->
        _ = Task.start(fn -> configure_when_needed(worker_id) end)
        :ok

      _not_the_bundled_distribution ->
        :ok
    end
  rescue
    _error -> :ok
  end

  defp configure_when_needed(worker_id) do
    :global.trans({__MODULE__, worker_id}, fn ->
      unless configuration_current?(worker_id), do: configure(worker_id)
    end)
  end

  @doc false
  def configure(worker_id) when is_binary(worker_id) do
    with %Worker{} = worker <- Repo.get(Worker, worker_id),
         true <- worker.workspace_ref == configured_workspace_ref() do
      ensure_work(worker.workspace_ref)
      ensure_installation_bindings(worker)
      ensure_repository_bindings(worker)
      :ok
    else
      _missing_or_wrong_worker -> :ok
    end
  end

  @doc false
  def ready? do
    worker = Repo.get(Worker, configured_worker_id())
    snapshot = Settings.fetch!()

    match?(%Worker{state: :eligible}, worker) and
      snapshot.work.workspace_ref == configured_workspace_ref() and
      Enum.all?([:admission, :learning], fn purpose ->
        Enum.any?(snapshot.policy_bindings, fn binding ->
          binding.purpose == purpose and binding.scope_kind == :installation and
            binding.scope_ref == ""
        end)
      end)
  rescue
    _error -> false
  end

  defp configuration_current?(worker_id) do
    worker = Repo.get(Worker, worker_id)
    snapshot = Settings.fetch!()

    match?(%Worker{}, worker) and snapshot.work.workspace_ref == worker.workspace_ref and
      expected_bindings(snapshot)
      |> Enum.all?(fn {purpose, scope_kind, scope_ref, policy_name} ->
        digest = Map.get(worker.policy_digests, policy_name)

        is_binary(digest) and
          Enum.any?(snapshot.policy_bindings, fn binding ->
            binding.purpose == purpose and binding.scope_kind == scope_kind and
              binding.scope_ref == scope_ref and binding.policy_name == policy_name and
              binding.policy_digest == digest
          end)
      end)
  rescue
    _error -> false
  end

  defp expected_bindings(snapshot) do
    installation =
      Enum.map(@installation_policies, fn {purpose, policy_name} ->
        {purpose, :installation, "", policy_name}
      end)

    repositories =
      Enum.flat_map(snapshot.repositories, fn repository ->
        Enum.map(@repository_policies, fn {purpose, suffix} ->
          {purpose, :repository, repository.ref, repository_policy_name(repository.ref, suffix)}
        end)
      end)

    contexts =
      Enum.flat_map(snapshot.contexts, fn context ->
        Enum.map([:conversational, :contributor, :deep, :standard], fn purpose ->
          suffix = Map.fetch!(@repository_policies, purpose)

          {purpose, :context, context.ref,
           repository_policy_name(context.primary_repository_ref, suffix)}
        end)
      end)

    installation ++ repositories ++ contexts
  end

  @doc false
  def materialize_repository(repository_ref) when is_binary(repository_ref) do
    case configured_root() do
      nil -> :ok
      root -> do_materialize_repository(root, repository_ref)
    end
  end

  @doc false
  def request_materialization(repository_ref, %DateTime{} = occurred_at)
      when is_binary(repository_ref) do
    if configured_root() do
      Repo.update_all(
        from(repository in Repository,
          where:
            repository.ref == ^repository_ref and repository.github_access == :available and
              (is_nil(repository.last_github_event_at) or
                 repository.last_github_event_at < ^occurred_at)
        ),
        set: [last_github_event_at: occurred_at]
      )

      if worker = Process.whereis(Ryker.GitHub.OnboardingWorker), do: send(worker, :drain)
    end

    :ok
  end

  defp do_materialize_repository(root, repository_ref) do
    snapshot = Settings.fetch!()
    repository = Enum.find(snapshot.repositories, &(&1.ref == repository_ref))
    binding = Enum.find(snapshot.github_bindings, &(&1.repository_ref == repository_ref))

    materialization_watermark =
      (repository && repository.last_github_event_at) || Repo.now!()

    with %{github_repository: github_repository} <- repository,
         %{name: binding_name} <- binding,
         {:ok, token} <- InstallationTokens.token(binding_name, :onboarding),
         :ok <- synchronize_repository(root, repository, github_repository, token) do
      write_policy_file!(root, ensure_seed_repository!(root))
      mark_materialized(repository_ref, materialization_watermark)
      :ok
    else
      nil -> {:error, :repository_binding_missing}
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, :repository_materialization_failed}
  end

  defp mark_materialized(repository_ref, materialized_at) do
    Repo.update_all(
      from(repository in Repository, where: repository.ref == ^repository_ref),
      set: [materialized_at: materialized_at]
    )

    :ok
  end

  defp synchronize_repository(root, repository, github_repository, token) do
    mirror = Path.join([root, "mirrors", repository.ref <> ".git"])
    checkout = Path.join([root, "repositories", repository.ref])
    remote = "https://github.com/#{github_repository}.git"
    File.mkdir_p!(Path.dirname(mirror))
    File.mkdir_p!(Path.dirname(checkout))

    with :ok <- ensure_mirror(mirror, remote, token),
         :ok <- fetch_mirror(mirror, token),
         :ok <- ensure_checkout(checkout, mirror),
         :ok <- fetch_checkout(checkout),
         do: checkout_branch(checkout, repository.base_branch)
  end

  defp ensure_mirror(mirror, remote, token) do
    if File.dir?(Path.join(mirror, "objects")),
      do: :ok,
      else: git(["clone", "--mirror", remote, mirror], nil, token)
  end

  defp fetch_mirror(mirror, token) do
    git(
      [
        "fetch",
        "--force",
        "--prune",
        "origin",
        "+refs/heads/*:refs/heads/*",
        "+refs/pull/*/head:refs/pull/*/head"
      ],
      mirror,
      token
    )
  end

  defp ensure_checkout(checkout, mirror) do
    if File.dir?(Path.join(checkout, ".git")),
      do: :ok,
      else: git(["clone", mirror, checkout], nil, nil)
  end

  defp fetch_checkout(checkout) do
    git(
      [
        "fetch",
        "--force",
        "--prune",
        "origin",
        "+refs/heads/*:refs/remotes/origin/*",
        "+refs/pull/*/head:refs/remotes/origin/pull/*"
      ],
      checkout,
      nil
    )
  end

  defp checkout_branch(checkout, branch),
    do: git(["checkout", "--force", "-B", branch, "origin/#{branch}"], checkout, nil)

  defp git(arguments, directory, token) do
    environment = [{"GIT_TERMINAL_PROMPT", "0"}] |> maybe_put_git_token(token)
    options = [env: environment, stderr_to_stdout: true]
    options = if directory, do: Keyword.put(options, :cd, directory), else: options

    case System.cmd("git", arguments, options) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :repository_materialization_failed}
    end
  end

  defp maybe_put_git_token(environment, token) when is_binary(token) do
    environment ++
      [
        {"GIT_CONFIG_COUNT", "1"},
        {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader"},
        {"GIT_CONFIG_VALUE_0", "Authorization: Bearer #{token}"}
      ]
  end

  defp maybe_put_git_token(environment, nil), do: environment

  defp ensure_seed_repository!(root) do
    seed = Path.join(root, "seed")

    unless File.dir?(Path.join(seed, ".git")) do
      File.mkdir_p!(seed)
      run_git!(seed, ["init", "--quiet"])
      run_git!(seed, ["config", "user.email", "ryker@localhost"])
      run_git!(seed, ["config", "user.name", "Ryker"])
      run_git!(seed, ["commit", "--quiet", "--allow-empty", "-m", "Initialize Ryker worker"])
    end

    seed
  end

  defp run_git!(directory, arguments) do
    case System.cmd("git", arguments, cd: directory, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise "git failed with status #{status}: #{String.slice(output, 0, 200)}"
    end
  end

  defp write_policy_file!(root, seed) do
    repositories =
      case Settings.fetch() do
        {:ok, snapshot} ->
          Enum.filter(snapshot.repositories, fn repository ->
            File.dir?(Path.join([root, "repositories", repository.ref, ".git"]))
          end)

        _uninitialized ->
          []
      end

    policies =
      installation_policy_documents(seed) ++
        Enum.flat_map(repositories, &repository_policy_documents(root, &1))

    body = "version: 1\npolicies:\n" <> Enum.map_join(policies, "", &policy_yaml/1)
    atomic_write!(Path.join(root, "session-policies.yaml"), body, 0o600)

    advertisements =
      Enum.map(repositories, fn repository ->
        checkout = Path.join([root, "repositories", repository.ref])

        %{
          "ref" => repository.ref,
          "revision" => "commit:#{git_revision!(checkout)}"
        }
      end)

    atomic_write!(Path.join(root, "repositories.json"), Jason.encode!(advertisements), 0o600)
  end

  defp git_revision!(checkout) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: checkout, stderr_to_stdout: true) do
      {revision, 0} -> String.trim(revision)
      {_output, _status} -> raise "could not read the materialized repository revision"
    end
  end

  defp installation_policy_documents(seed) do
    Enum.map(@installation_policies, fn {_purpose, name} ->
      %{name: name, repository: seed, read_only: true}
    end)
  end

  defp repository_policy_documents(root, repository) do
    path = Path.join([root, "repositories", repository.ref])

    Enum.map(@repository_policies, fn {purpose, suffix} ->
      %{
        name: repository_policy_name(repository.ref, suffix),
        read_only: purpose in [:conversational, :schedule],
        repository: path
      }
    end)
  end

  defp policy_yaml(policy) do
    read_only = if policy.read_only, do: "\n    repository_read_only: true", else: ""

    "  #{policy.name}:\n" <>
      "    repository: #{yaml_string(policy.repository)}\n" <>
      "    target: #{yaml_string(target())}#{read_only}\n" <>
      "    max_turns: 100\n" <>
      "    max_queued_turns: 20\n" <>
      "    max_queued_bytes: 1048576\n" <>
      "    max_patch_bytes: 1048576\n" <>
      "    turn_timeout: 1h\n"
  end

  defp yaml_string(value), do: Jason.encode!(value)

  defp ensure_enrollment_file!(root) do
    shared = shared_root!()
    marker = Path.join(shared, "enrolled")
    token_path = Path.join(shared, "enrollment-token")
    File.mkdir_p!(shared)
    File.chmod!(shared, 0o700)

    unless File.exists?(marker) do
      case Enrollment.issue_token(
             configured_worker_id(),
             configured_workspace_ref(),
             @actor,
             3_600
           ) do
        {:ok, issued} -> atomic_write!(token_path, issued.token, 0o600)
        {:error, :coop_worker_enrollment_not_authorized} -> :ok
        {:error, reason} -> raise "bundled co:op enrollment failed: #{inspect(reason)}"
      end
    end

    atomic_write!(Path.join(shared, "root"), root, 0o600)
    :ok
  end

  defp ensure_work(workspace_ref) do
    snapshot = Settings.fetch!()

    if snapshot.work.workspace_ref != workspace_ref do
      {:ok, _snapshot} =
        Settings.save_work(
          %{workspace_ref: workspace_ref},
          snapshot.installation.revision,
          @actor
        )
    end
  end

  defp ensure_installation_bindings(worker) do
    Enum.each(@installation_policies, fn {purpose, policy_name} ->
      ensure_binding(worker, purpose, :installation, "", policy_name)
    end)
  end

  defp ensure_repository_bindings(worker) do
    snapshot = Settings.fetch!()

    Enum.each(snapshot.repositories, fn repository ->
      Enum.each(@repository_policies, fn {purpose, suffix} ->
        ensure_binding(
          worker,
          purpose,
          :repository,
          repository.ref,
          repository_policy_name(repository.ref, suffix)
        )
      end)
    end)

    snapshot = Settings.fetch!()

    Enum.each(snapshot.contexts, fn context ->
      [:conversational, :contributor, :deep, :standard]
      |> Enum.each(fn purpose ->
        suffix = Map.fetch!(@repository_policies, purpose)

        ensure_binding(
          worker,
          purpose,
          :context,
          context.ref,
          repository_policy_name(context.primary_repository_ref, suffix)
        )
      end)
    end)
  end

  defp ensure_binding(worker, purpose, scope_kind, scope_ref, policy_name) do
    case Map.fetch(worker.policy_digests, policy_name) do
      {:ok, digest} ->
        snapshot = Settings.fetch!()

        current =
          Enum.find(snapshot.policy_bindings, fn binding ->
            binding.purpose == purpose and binding.scope_kind == scope_kind and
              binding.scope_ref == scope_ref
          end)

        attributes = %{
          authority_digest: Map.get(worker.policy_authority_digests, policy_name),
          policy_digest: digest,
          policy_name: policy_name,
          purpose: purpose,
          scope_kind: scope_kind,
          scope_ref: scope_ref,
          verified_by: :worker,
          verified_worker_ref: worker.id
        }

        attributes = if current, do: Map.put(attributes, :id, current.id), else: attributes

        {:ok, _snapshot} =
          Settings.put_policy_binding(attributes, snapshot.installation.revision, @actor)

      :error ->
        :ok
    end
  end

  defp repository_policy_name(ref, suffix), do: "ryker-repo-#{ref}-#{suffix}"

  defp atomic_write!(path, content, mode) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(temporary, content, [:binary, :exclusive])
    File.chmod!(temporary, mode)
    File.rename!(temporary, path)
  end

  defp configured_worker_id, do: System.get_env(@worker_env, @default_worker)

  defp configured_workspace_ref,
    do: System.get_env("RYKER_BUNDLED_COOP_WORKSPACE", @default_workspace)

  defp configured_root, do: System.get_env(@root_env)
  defp root!, do: configured_root() || raise("#{@root_env} is required")

  defp shared_root!,
    do:
      System.get_env("RYKER_BUNDLED_COOP_SHARED") ||
        raise("RYKER_BUNDLED_COOP_SHARED is required")

  defp target,
    do: System.get_env("RYKER_BUNDLED_COOP_TARGET", "codex:gpt-5.6-sol/medium@default")
end
