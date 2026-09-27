defmodule Ryker.CoopFleet.JobSpec do
  @moduledoc """
  One immutable controller-authored execution grant for a Coop worker session.

  Version 1 of this document belongs to worker protocol v2. It names exact
  frozen GitHub repository and source identities, never a worker path, URL,
  shell command or secret.
  """

  alias Ryker.{CanonicalJSON, CoopFleet.Protocol}
  alias Ryker.Work.RepositorySource

  @maximum_bytes 256 * 1_024
  @root_fields ~w(version job_ref source companions targets mode project_env project_mcp repository_read_only egress limits)
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

  def rebind(job, expected_digest, job_ref) do
    with {:ok, ^expected_digest} <- digest(job),
         rebound = Map.put(job, "job_ref", job_ref),
         {:ok, digest} <- digest(rebound) do
      {:ok, rebound, digest}
    else
      _ -> {:error, :invalid_coop_worker_job}
    end
  end

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
      job["version"] == 1 and
      Protocol.reference?(job["job_ref"]) and
      job["mode"] in ~w(normal readonly bare) and
      job["project_env"] == false and
      job["project_mcp"] == false and
      is_boolean(job["repository_read_only"])
  end

  defp source_and_targets?(job) do
    targets?(job["targets"]) and
      source_mode?(job) and
      companions?(job["companions"])
  end

  defp execution_bounds?(job) do
    egress?(job["egress"]) and limits?(job["limits"]) and mode_bounds?(job)
  end

  defp source_mode?(%{"mode" => "bare", "source" => nil}), do: true
  defp source_mode?(%{"mode" => "bare"}), do: false
  defp source_mode?(%{"source" => nil}), do: true
  defp source_mode?(%{"source" => source}), do: source?(source)

  defp source?(%{} = source) do
    exact?(source, @source_fields) and
      repository_identity?(source) and
      match?({:ok, _binding}, RepositorySource.parse_binding(source["binding"])) and
      source["binding"]["remote_identity"] == "origin" and
      submodules?(source["submodules"], 0)
  end

  defp source?(_source), do: false

  defp repository_identity?(source) do
    Protocol.reference?(source["repository_ref"]) and
      github_repository?(source["github_repository"]) and
      integer_between?(source["github_repository_id"], 1, 9_223_372_036_854_775_807)
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
      integer_between?(limits["max_turns"], 1, 10_000) and
      integer_between?(limits["max_queued_turns"], 1, 1_000) and
      integer_between?(limits["max_queued_bytes"], 1, 64 * 1_024 * 1_024) and
      integer_between?(limits["turn_timeout_ms"], 1, 86_400_000) and
      integer_between?(limits["warm_idle_timeout_ms"], 0, 3_600_000) and
      integer_between?(limits["max_patch_bytes"], 1, 1_048_576)
  end

  defp limits?(_limits), do: false

  defp integer_between?(value, min, max),
    do: is_integer(value) and value >= min and value <= max

  defp mode_bounds?(%{"mode" => "bare"} = job) do
    job["companions"] == [] and not job["project_env"] and not job["project_mcp"] and
      not job["repository_read_only"] and restricted_bounds?(job)
  end

  defp mode_bounds?(%{"mode" => "readonly"} = job),
    do: job["repository_read_only"] and restricted_bounds?(job)

  defp mode_bounds?(_job), do: true

  defp restricted_bounds?(job),
    do: job["egress"]["mode"] != "filtered" and job["limits"]["warm_idle_timeout_ms"] == 0
end
