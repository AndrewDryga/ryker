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
  alias Ryker.{PollingWorker, Repo, Settings}
  alias Ryker.Settings.{Environment, Repository, Work}

  @actor "control-plane:local"
  @worker_env "RYKER_BUNDLED_COOP_WORKER_ID"
  @root_env "RYKER_BUNDLED_COOP_ROOT"
  @default_worker "ryker-compose"
  @default_workspace "ryker-compose"
  @installation_policies %{
    admission: "ryker-admission",
    conversational: "ryker-chat",
    incident: "ryker-incident",
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
  # An environment with several repositories needs policies of its own, one
  # set per repository: work there may change any of them, and Coop mounts
  # the other repositories read-only only for a policy that declares them.
  @environment_policies %{
    conversational: "conversation",
    contributor: "contributor",
    deep: "deep",
    standard: "standard"
  }
  # Conversation, standard and deep work share one read-only authority, which
  # is what a Work profile requires of them; a deeper model is not permission
  # to write. Only confirmed engineering work writes, through the contributor.
  @writable_purposes [:contributor]
  # Which saved list of models each policy purpose runs on.
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

  # Where the worker leaves Coop's reason when it could not load Ryker's
  # newest policies (deploy/compose/coop/load-policies.sh caps it at 4 KiB).
  @problem_file "policy-problem"
  @problem_bytes 4_096
  @unsigned ~r/policy "([^"]+)": target(?:\[(\d+)\])? credential "([^"]+)" is not authenticated/

  @doc "The Work setting that holds the models for a policy purpose."
  def model_field(purpose), do: Map.get(@models, purpose)

  @doc """
  Why the bundled worker still runs the policies it loaded before Ryker's
  newest ones, in words for Settings › Models, or nil when it runs the newest.

  Coop refuses a whole policy file over one entry; the worker then keeps what
  it last loaded and leaves Coop's reason in the directory it shares with
  Ryker. An account the worker has not signed in reads as the saved account
  and the command that signs it in. Anything else is Coop's own sentence,
  from where it names the policy.
  """
  @spec policy_problem(Settings.snapshot() | nil) :: String.t() | nil
  def policy_problem(snapshot \\ nil) do
    case policy_problem_text() do
      nil -> nil
      text -> problem_reason(text, snapshot || saved_settings())
    end
  end

  @doc false
  # The worker's own words, bounded, or nil without them.
  def policy_problem_text do
    with shared when is_binary(shared) <- System.get_env("RYKER_BUNDLED_COOP_SHARED"),
         {:ok, file} <- File.open(Path.join(shared, @problem_file), [:read, :binary]) do
      try do
        case IO.binread(file, @problem_bytes) do
          text when is_binary(text) -> text
          _empty_or_unreadable -> ""
        end
      after
        File.close(file)
      end
    else
      _absent -> nil
    end
  end

  defp saved_settings do
    case Settings.fetch() do
      {:ok, snapshot} -> snapshot
      {:error, _reason} -> nil
    end
  end

  # The worker's cap can cut a character in two, and a terminal colour code
  # is not words; neither reaches the page.
  defp problem_reason(text, snapshot) do
    text = text |> String.replace_invalid() |> String.replace(~r/\e\[[0-9;]*[A-Za-z]/, "")

    case Regex.run(@unsigned, text) do
      [_match, policy, index, name] -> unsigned_reason(snapshot, policy, index, name)
      nil -> coop_reason(text)
    end
  end

  defp unsigned_reason(snapshot, policy, index, name) do
    case unsigned_account(snapshot, policy, index, name) do
      nil ->
        "the worker has not signed in an account named #{name}. Sign it in with " <>
          "scripts/compose.sh model-login, or choose another account."

      account ->
        "the #{account} account is not signed in on the worker. Sign it in with " <>
          "scripts/compose.sh model-login #{account}, or choose another account."
    end
  end

  # The saved account Coop means: the model at that place in that policy's
  # list, or else the first saved model on an account of that name.
  defp unsigned_account(nil, _policy, _index, _name), do: nil

  defp unsigned_account(snapshot, policy, index, name) do
    named? = &(is_binary(&1) and String.ends_with?(&1, "@" <> name))
    position = if index == "", do: 0, else: String.to_integer(index)
    listed = Map.get(snapshot.work, model_field(policy_purpose(policy))) || []
    exact = listed |> Enum.at(position) |> Work.account()

    if named?.(exact),
      do: exact,
      else:
        Work.model_fields()
        |> Enum.flat_map(&(Map.get(snapshot.work, &1) || []))
        |> Enum.map(&Work.account/1)
        |> Enum.find(named?)
  end

  defp policy_purpose(name) do
    Enum.find_value(@installation_policies, fn {purpose, policy} ->
      if policy == name, do: purpose
    end) ||
      Enum.find_value(Map.merge(@repository_policies, @environment_policies), fn {purpose, suffix} ->
        if String.starts_with?(name, ["ryker-repo-", "ryker-env-"]) and
             String.ends_with?(name, "-" <> suffix),
           do: purpose
      end)
  end

  # Coop's sentence from where it names the refused policy; else the line of
  # substance after its headline, without the file's path in front.
  defp coop_reason(text) do
    lines = text |> String.split("\n") |> Enum.map(&String.trim/1)

    line =
      case Regex.run(~r/policy "[^\n]*/, text) do
        [policy] ->
          policy

        nil ->
          lines
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["✗", "Help:"])))
          |> List.first()
      end

    case line && line |> String.replace(~r{^/\S+\s+}, "") |> String.trim() do
      blank when blank in [nil, ""] -> "the worker could not load them."
      reason -> reason |> String.slice(0, 400) |> sentence()
    end
  end

  defp sentence(text) do
    if String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> "."
  end

  @doc "Whether this installation runs the Compose distribution's bundled worker."
  def distribution?, do: not is_nil(configured_root())

  @doc "Whether a Coop policy name is one this distribution writes."
  def policy?(name) when is_binary(name),
    do:
      name in Map.values(@installation_policies) or
        String.starts_with?(name, ["ryker-repo-", "ryker-env-"])

  def policy?(_name), do: false

  @doc false
  def prepare_distribution! do
    {:ok, _snapshot} = Settings.initialize(@actor)
    ensure_distribution!()
  end

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

  @doc """
  Rewrites the policy file from the saved settings. The worker reconnects when
  the file changes and its next poll re-pins the new digests, so a model saved
  in Settings applies without a restart.
  """
  def sync_policies do
    case {configured_root(), Settings.fetch()} do
      {root, {:ok, _snapshot}} when is_binary(root) ->
        write_policy_file!(root, ensure_seed_repository!(root))

      # Outside the distribution, or before installation creates the settings.
      _nothing_to_write ->
        :ok
    end
  end

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

    worker_ready?(worker) and
      snapshot.work.workspace_ref == configured_workspace_ref() and
      Enum.all?(Map.keys(@installation_policies), fn purpose ->
        Enum.any?(snapshot.policy_bindings, fn binding ->
          binding.purpose == purpose and binding.scope_kind == :installation and
            binding.scope_ref == ""
        end)
      end)
  rescue
    _error -> false
  end

  defp worker_ready?(%Worker{} = worker) do
    cutoff = DateTime.add(DateTime.utc_now(), -60, :second)
    capacity = worker.capacity || %{}

    worker.state == :eligible and match?(%DateTime{}, worker.last_seen_at) and
      DateTime.compare(worker.last_seen_at, cutoff) != :lt and capacity["state"] == "eligible" and
      Enum.all?(~w(session turn workspace), fn kind ->
        is_integer(capacity["#{kind}_slots_free"]) and capacity["#{kind}_slots_free"] > 0
      end) and
      Enum.any?(worker.capabilities, &(&1["name"] == "responder-state"))
  end

  defp worker_ready?(_worker), do: false

  defp configuration_current?(worker_id) do
    worker = Repo.get(Worker, worker_id)
    snapshot = Settings.fetch!()

    match?(%Worker{}, worker) and snapshot.work.workspace_ref == worker.workspace_ref and
      expected_bindings(snapshot)
      |> Enum.all?(fn {purpose, scope_kind, scope_ref, repository_ref, policy_name} ->
        digest = Map.get(worker.policy_digests, policy_name)

        is_binary(digest) and
          Enum.any?(snapshot.policy_bindings, fn binding ->
            binding.purpose == purpose and binding.scope_kind == scope_kind and
              binding.scope_ref == scope_ref and binding.repository_ref == repository_ref and
              binding.policy_name == policy_name and binding.policy_digest == digest
          end)
      end)
  rescue
    _error -> false
  end

  # Every binding this distribution pins: purpose, scope, the repository an
  # environment binding is for (empty for every other scope) and the policy.
  defp expected_bindings(snapshot) do
    installation =
      Enum.map(@installation_policies, fn {purpose, policy_name} ->
        {purpose, :installation, "", "", policy_name}
      end)

    repositories =
      Enum.flat_map(snapshot.repositories, fn repository ->
        Enum.map(@repository_policies, fn {purpose, suffix} ->
          {purpose, :repository, repository.ref, "",
           repository_policy_name(repository.ref, suffix)}
        end)
      end)

    environments =
      snapshot.environments
      |> Enum.filter(&own_policies?/1)
      |> Enum.flat_map(fn environment ->
        for repository_ref <- Environment.repository_refs(environment),
            {purpose, suffix} <- @environment_policies do
          {purpose, :environment, environment.ref, repository_ref,
           environment_policy_name(environment.ref, repository_ref, suffix)}
        end
      end)

    installation ++ repositories ++ environments
  end

  # A one-repository environment runs on its repository's policies.
  defp own_policies?(environment), do: length(Environment.repository_refs(environment)) > 1

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

      if worker = Process.whereis(Ryker.GitHub.OnboardingWorker),
        do: PollingWorker.poll_now(worker)
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

  # A settings save and a repository materialization can both rewrite the file.
  # Each reads the settings inside the lock, so the last writer always writes
  # the newest saved model and repositories.
  defp write_policy_file!(root, seed) do
    :global.trans({__MODULE__, :policy_file}, fn -> write_policy_file_locked!(root, seed) end)
  end

  defp write_policy_file_locked!(root, seed) do
    snapshot = Settings.fetch!()

    repositories =
      Enum.filter(snapshot.repositories, fn repository ->
        File.dir?(Path.join([root, "repositories", repository.ref, ".git"]))
      end)

    materialized = MapSet.new(repositories, & &1.ref)

    # An environment's policies wait until every repository in it exists here.
    environments =
      Enum.filter(snapshot.environments, fn environment ->
        own_policies?(environment) and
          Enum.all?(Environment.repository_refs(environment), &MapSet.member?(materialized, &1))
      end)

    policies =
      installation_policy_documents(seed) ++
        Enum.flat_map(repositories, &repository_policy_documents(root, &1)) ++
        Enum.flat_map(environments, &environment_policy_documents(root, &1))

    body =
      "version: 1\npolicies:\n" <>
        Enum.map_join(
          policies,
          "",
          &policy_yaml(&1, Map.fetch!(snapshot.work, @models[&1.purpose]))
        )

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
    :ok
  end

  defp git_revision!(checkout) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: checkout, stderr_to_stdout: true) do
      {revision, 0} -> String.trim(revision)
      {_output, _status} -> raise "could not read the materialized repository revision"
    end
  end

  defp installation_policy_documents(seed) do
    Enum.map(@installation_policies, fn {purpose, name} ->
      %{name: name, purpose: purpose, repository: seed, read_only: true}
    end)
  end

  defp repository_policy_documents(root, repository) do
    path = Path.join([root, "repositories", repository.ref])

    Enum.map(@repository_policies, fn {purpose, suffix} ->
      %{
        name: repository_policy_name(repository.ref, suffix),
        purpose: purpose,
        read_only: purpose not in @writable_purposes,
        repository: path
      }
    end)
  end

  # Work in an environment may change any of its repositories, so each one
  # gets its own policies: that repository as the working copy and every other
  # one mounted read-only under its ref, the name the Work executor checks
  # each session's companions against.
  defp environment_policy_documents(root, environment) do
    refs = Environment.repository_refs(environment)

    for repository_ref <- refs, {purpose, suffix} <- @environment_policies do
      %{
        companions:
          refs
          |> List.delete(repository_ref)
          |> Enum.map(&%{name: &1, repository: Path.join([root, "repositories", &1])}),
        name: environment_policy_name(environment.ref, repository_ref, suffix),
        purpose: purpose,
        read_only: purpose not in @writable_purposes,
        repository: Path.join([root, "repositories", repository_ref])
      }
    end
  end

  defp policy_yaml(policy, models) do
    read_only = if policy.read_only, do: "\n    repository_read_only: true", else: ""

    "  #{policy.name}:\n" <>
      "    repository: #{yaml_string(policy.repository)}\n" <>
      companions_yaml(Map.get(policy, :companions, [])) <>
      "    target: #{target_yaml(models)}#{read_only}\n" <>
      isolation_yaml(policy.purpose) <>
      "    max_turns: 100\n" <>
      "    max_queued_turns: 20\n" <>
      "    max_queued_bytes: 1048576\n" <>
      "    max_patch_bytes: 1048576\n" <>
      "    turn_timeout: 1h\n"
  end

  # Coop reads `target:` as one model or as a list it moves down in order when
  # a model hits a usage limit or its account's sign-in fails. One model stays
  # the plain string it always was: Coop reads it exactly as a one-model list,
  # with the same policy digest, and an unchanged file keeps its bytes, so the
  # worker, which reloads when the file's checksum changes, sees nothing new.
  defp target_yaml([model]), do: yaml_string(model)
  defp target_yaml(models), do: "[" <> Enum.map_join(models, ", ", &yaml_string/1) <> "]"

  defp companions_yaml([]), do: ""

  defp companions_yaml(companions) do
    "    companions:\n" <>
      Enum.map_join(companions, "", fn companion ->
        "      - name: #{yaml_string(companion.name)}\n" <>
          "        repository: #{yaml_string(companion.repository)}\n"
      end)
  end

  # Coop grants a session the project environment and project MCP servers
  # unless its policy withholds them, and background learning refuses such a
  # session before sending it a single retained message.
  defp isolation_yaml(:learning), do: "    project_env: false\n    project_mcp: false\n"
  defp isolation_yaml(_purpose), do: ""

  defp yaml_string(value), do: Jason.encode!(value)

  defp ensure_enrollment_file!(root) do
    shared = shared_root!()
    marker = Path.join(shared, "enrolled")
    token_path = Path.join(shared, "enrollment-token")
    File.mkdir_p!(shared)
    File.chmod!(shared, 0o700)

    unless File.exists?(marker) or File.exists?(token_path) do
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
      ensure_binding(worker, purpose, :installation, "", "", policy_name)
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
          "",
          repository_policy_name(repository.ref, suffix)
        )
      end)
    end)

    snapshot = Settings.fetch!()

    snapshot.environments
    |> Enum.filter(&own_policies?/1)
    |> Enum.each(fn environment ->
      for repository_ref <- Environment.repository_refs(environment),
          {purpose, suffix} <- @environment_policies do
        ensure_binding(
          worker,
          purpose,
          :environment,
          environment.ref,
          repository_ref,
          environment_policy_name(environment.ref, repository_ref, suffix)
        )
      end
    end)
  end

  defp ensure_binding(worker, purpose, scope_kind, scope_ref, repository_ref, policy_name) do
    case Map.fetch(worker.policy_digests, policy_name) do
      {:ok, digest} ->
        snapshot = Settings.fetch!()

        current =
          Enum.find(snapshot.policy_bindings, fn binding ->
            binding.purpose == purpose and binding.scope_kind == scope_kind and
              binding.scope_ref == scope_ref and binding.repository_ref == repository_ref
          end)

        attributes = %{
          authority_digest: Map.get(worker.policy_authority_digests, policy_name),
          policy_digest: digest,
          policy_name: policy_name,
          purpose: purpose,
          repository_ref: repository_ref,
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

  defp environment_policy_name(ref, repository_ref, suffix),
    do: "ryker-env-#{ref}-#{repository_ref}-#{suffix}"

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
end
