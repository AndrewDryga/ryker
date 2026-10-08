defmodule Ryker.CoopFleet.JobSpec do
  @moduledoc """
  One immutable controller-authored execution grant for a Coop worker session.

  Version 2 of this document belongs to worker protocol v2 and Coop's
  `job-setup:2`. It names exact frozen GitHub repository and source identities,
  never a worker path, URL or secret, and carries the whole work and review
  setup Ryker resolved: the work environment, the check a review runs (literal
  argv and its extra environment), and per-container resource caps. A worker
  applies nothing from the repository's own settings.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.{JobCheck, JobTemplates, Protocol}
  alias Ryker.Work

  @maximum_bytes 256 * 1_024
  @root_fields ~w(version job_ref source companions targets mode repository_read_only egress limits environment check resources)
  @source_fields ~w(repository_ref github_repository github_repository_id binding submodules)
  @submodule_fields ~w(path repository_ref github_repository github_repository_id commit tree submodules)
  @commit ~r/\A[0-9a-f]{40}\z/
  @github_segment ~r/\A[A-Za-z0-9_.-]{1,100}\z/
  @egress_fields ~w(mode rules export_destinations)
  @limit_fields ~w(max_turns max_queued_turns max_queued_bytes turn_timeout_ms warm_idle_timeout_ms max_patch_bytes)

  @spec validate(term()) :: :ok | {:error, :invalid_coop_worker_job}
  def validate(%{} = job) do
    if identity_and_mode?(job) and source_and_targets?(job) and
         execution_bounds?(job) and
         CanonicalJSON.validate(job, max_bytes: @maximum_bytes) == :ok,
       do: :ok,
       else: {:error, :invalid_coop_worker_job}
  end

  def validate(_job), do: {:error, :invalid_coop_worker_job}

  @doc false
  def github_repository?(slug) when is_binary(slug) do
    case String.split(slug, "/") do
      [owner, repository] ->
        Enum.all?(
          [owner, repository],
          &(&1 not in [".", ".."] and Regex.match?(@github_segment, &1))
        )

      _invalid ->
        false
    end
  end

  def github_repository?(_slug), do: false

  @spec digest(map()) :: {:ok, String.t()} | {:error, :invalid_coop_worker_job}
  def digest(job) do
    with :ok <- validate(job) do
      {:ok, CanonicalJSON.worker_digest(job)}
    end
  end

  def rebind(nil, nil, _job_ref), do: {:ok, nil, nil}

  def rebind(%{"version" => 1} = job, expected_digest, job_ref) do
    with true <- CanonicalJSON.worker_digest(job) == expected_digest,
         {:ok, upgraded} <- upgrade(job),
         rebound = Map.put(upgraded, "job_ref", job_ref),
         {:ok, digest} <- digest(rebound) do
      {:ok, rebound, digest}
    else
      _ -> {:error, :invalid_coop_worker_job}
    end
  end

  def rebind(job, expected_digest, job_ref) do
    with {:ok, ^expected_digest} <- digest(job),
         rebound = Map.put(job, "job_ref", job_ref),
         {:ok, digest} <- digest(rebound) do
      {:ok, rebound, digest}
    else
      _ -> {:error, :invalid_coop_worker_job}
    end
  end

  @doc """
  A frozen version-1 job as version 2. Coop's workers refuse version 1 since
  `job-setup:2`, so a session carrying one moves once, with exactly the
  sources, targets, mode, egress and limits it was granted. It had no project
  environment or MCP and gets no work environment; it gets no check, which
  `Ryker.CoopFleet.JobAuthority` resolves for a working copy before its session
  is created; and it gets the caps every job carries.
  """
  @spec upgrade(map()) :: {:ok, map()} | {:error, :invalid_coop_worker_job}
  def upgrade(%{"version" => 1, "project_env" => false, "project_mcp" => false} = job) do
    upgraded =
      job
      |> Map.drop(~w(project_env project_mcp))
      |> Map.merge(%{
        "version" => 2,
        "environment" => %{},
        "check" => JobCheck.none(),
        "resources" => JobTemplates.resources()
      })

    with :ok <- validate(upgraded), do: {:ok, upgraded}
  end

  def upgrade(_job), do: {:error, :invalid_coop_worker_job}

  defp exact?(value, fields) when is_map(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp exact?(_value, _fields), do: false

  defp exact_optional?(value, required, optional) when is_map(value) do
    keys = Map.keys(value)
    Enum.all?(required, &(&1 in keys)) and Enum.all?(keys, &(&1 in required or &1 in optional))
  end

  defp exact_optional?(_value, _required, _optional), do: false

  defp identity_and_mode?(job) do
    exact?(job, @root_fields) and
      job["version"] == 2 and
      Protocol.reference?(job["job_ref"]) and
      job["mode"] in ~w(normal readonly bare) and
      is_boolean(job["repository_read_only"])
  end

  defp source_and_targets?(job) do
    targets?(job["targets"]) and
      source_mode?(job) and
      companions?(job["companions"])
  end

  defp execution_bounds?(job) do
    egress?(job["egress"]) and limits?(job["limits"]) and mode_bounds?(job) and
      environment?(job["environment"]) and check?(job["check"]) and
      resources?(job["resources"])
  end

  # Coop's rules for the setup it refuses to normalize: shell-identifier names
  # outside its own COOP_ space, and values env-file processing cannot change.
  defp environment?(values) when is_map(values) and map_size(values) <= 64 do
    Enum.all?(values, fn {key, value} ->
      is_binary(key) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/, key) and
        not String.starts_with?(key, "COOP_") and is_binary(value) and
        byte_size(value) <= 8_192 and String.valid?(value) and
        not String.contains?(value, ["\0", "\r", "\n"]) and String.trim(value) == value
    end)
  end

  defp environment?(_values), do: false

  # Literal argv, never a shell string; no argv and no environment means no check.
  defp check?(%{"argv" => argv, "environment" => environment} = check)
       when map_size(check) == 2 and is_list(argv) and length(argv) <= 64 do
    environment?(environment) and (argv != [] or environment == %{}) and argv?(argv)
  end

  defp check?(_check), do: false

  defp argv?(argv) do
    argv
    |> Enum.with_index()
    |> Enum.all?(fn {arg, index} ->
      is_binary(arg) and byte_size(arg) <= 8_192 and String.valid?(arg) and
        not String.contains?(arg, "\0") and (index > 0 or arg != "")
    end)
  end

  defp resources?(%{} = resources) do
    exact?(resources, ~w(cpu_millis memory_bytes pids)) and
      resources["cpu_millis"] in 10..128_000 and
      resources["memory_bytes"] in (6 * 1_048_576)..1_099_511_627_776 and
      resources["pids"] in 1..65_536
  end

  defp resources?(_resources), do: false

  defp source_mode?(%{"mode" => "bare", "source" => nil}), do: true
  defp source_mode?(%{"mode" => "bare"}), do: false
  defp source_mode?(%{"source" => nil}), do: true
  defp source_mode?(%{"source" => source}), do: source?(source)

  defp source?(%{} = source) do
    exact?(source, @source_fields) and
      repository_identity?(source) and
      match?({:ok, _binding}, Work.RepositorySource.parse_binding(source["binding"])) and
      source["binding"]["remote_identity"] == "origin" and
      submodules?(source["submodules"], 0)
  end

  defp source?(_source), do: false

  defp repository_identity?(source) do
    Protocol.reference?(source["repository_ref"]) and
      github_repository?(source["github_repository"]) and
      source["github_repository_id"] in 1..9_223_372_036_854_775_807
  end

  defp submodules?(modules, depth)
       when is_list(modules) and length(modules) <= 1024 and depth <= 16 do
    paths = Enum.map(modules, &if(is_map(&1), do: &1["path"], else: nil))

    Enum.uniq(paths) == paths and
      Enum.all?(modules, &submodule?(&1, depth))
  end

  defp submodules?(_modules, _depth), do: false

  defp submodule?(module, depth) do
    exact?(module, @submodule_fields) and
      submodule_path?(module["path"]) and repository_identity?(module) and
      is_binary(module["commit"]) and Regex.match?(@commit, module["commit"]) and
      is_binary(module["tree"]) and Regex.match?(@commit, module["tree"]) and
      submodules?(module["submodules"], depth + 1)
  end

  @doc false
  def submodule_path?(path) when is_binary(path) and byte_size(path) in 1..4096 do
    String.valid?(path) and not Regex.match?(~r/[\x00-\x1f\x7f\\\\]/, path) and
      Enum.all?(
        String.split(path, "/"),
        &(&1 not in ["", ".", ".."] and String.downcase(&1) != ".git")
      )
  end

  def submodule_path?(_path), do: false

  defp targets?(targets) when is_list(targets) and length(targets) in 1..4,
    do: Enum.all?(targets, &(is_binary(&1) and byte_size(&1) in 1..256))

  defp targets?(_targets), do: false

  defp companions?(companions) when is_list(companions) and length(companions) <= 32 do
    names = Enum.map(companions, &if(is_map(&1), do: &1["name"], else: nil))

    Enum.uniq(names) == names and
      Enum.all?(companions, fn companion ->
        exact?(companion, ~w(name source)) and
          Protocol.reference?(companion["name"]) and source?(companion["source"])
      end)
  end

  defp companions?(_companions), do: false

  defp egress?(%{} = egress) do
    valid_egress_shape?(egress) and valid_egress_rules?(egress)
  end

  defp egress?(_egress), do: false

  defp valid_egress_shape?(egress) do
    exact?(egress, @egress_fields) and
      egress["mode"] in ~w(open none filtered) and
      is_boolean(egress["export_destinations"]) and
      is_list(egress["rules"]) and length(egress["rules"]) <= 128
  end

  defp valid_egress_rules?(egress) do
    (egress["mode"] == "filtered" or egress["rules"] == []) and
      (egress["mode"] == "filtered" or not egress["export_destinations"]) and
      Enum.all?(egress["rules"], &rule?/1)
  end

  defp rule?(%{} = rule) do
    exact_optional?(rule, ~w(to), ~w(protocol ports types codes)) and
      destination?(rule["to"]) and
      optional_string?(rule, "protocol") and
      optional_list?(rule, "ports", &is_integer/1) and
      optional_list?(rule, "types", &is_binary/1) and
      optional_list?(rule, "codes", &is_integer/1)
  end

  defp rule?(_rule), do: false

  defp destination?(%{} = destination) do
    selectors = ~w(domain ip cidr service provider)

    exact_optional?(destination, [], selectors ++ ["features"]) and
      is_nil(destination["service"]) and
      Enum.count(selectors, &(is_binary(destination[&1]) and destination[&1] != "")) == 1 and
      Enum.all?(selectors, &(is_nil(destination[&1]) or is_binary(destination[&1]))) and
      optional_list?(destination, "features", &is_binary/1)
  end

  defp destination?(_destination), do: false

  defp optional_string?(map, key), do: not Map.has_key?(map, key) or is_binary(map[key])

  defp optional_list?(map, key, valid) do
    not Map.has_key?(map, key) or
      (is_list(map[key]) and length(map[key]) <= 128 and Enum.all?(map[key], valid))
  end

  defp limits?(%{} = limits) do
    exact?(limits, @limit_fields) and
      limits["max_turns"] in 1..10_000 and
      limits["max_queued_turns"] in 1..1_000 and
      limits["max_queued_bytes"] in 1..(64 * 1_024 * 1_024) and
      limits["turn_timeout_ms"] in 1..86_400_000 and
      limits["warm_idle_timeout_ms"] in 0..3_600_000 and
      limits["max_patch_bytes"] in 1..1_048_576
  end

  defp limits?(_limits), do: false

  defp mode_bounds?(%{"mode" => "bare"} = job) do
    job["companions"] == [] and not job["repository_read_only"] and restricted_bounds?(job)
  end

  defp mode_bounds?(%{"mode" => "readonly"} = job),
    do: job["repository_read_only"] and restricted_bounds?(job)

  defp mode_bounds?(_job), do: true

  defp restricted_bounds?(job),
    do: job["egress"]["mode"] != "filtered" and job["limits"]["warm_idle_timeout_ms"] == 0
end
