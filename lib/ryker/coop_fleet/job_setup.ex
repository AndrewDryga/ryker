defmodule Ryker.CoopFleet.JobSetup do
  @moduledoc """
  Project tools, test services and the review check, resolved before a job is frozen.

  Only the Dockerfile and Compose selectors, literal box environment and gate
  come from the project's base commit. Network policy, resource limits and
  credentials stay under the controller's authority. Review-only service
  overrides still come from the disposable candidate when Coop checks it.
  Box environment is frozen as runtime defaults so a review can override it;
  this resolver never overwrites controller environment authority.
  """
  alias Ryker.CoopFleet.JobSpec
  alias Ryker.GitHub

  @project_file ".agent/project.yaml"

  @spec no_check() :: map()
  def no_check, do: %{"argv" => [], "environment" => %{}}

  @spec resolve(map(), map(), String.t(), module(), boolean()) :: {:ok, map()} | {:error, term()}
  def resolve(binding, repository, commit, reader \\ GitHub.RepositoryFiles, runtime? \\ true) do
    with {:ok, text} <- reader.read(binding, repository, @project_file, commit),
         {:ok, project} <- project(text) do
      if runtime?,
        do: runtime_setup(project, binding, repository, commit, reader),
        else: {:ok, %{"check" => check(project["gate"])}}
    end
  end

  defp runtime_setup(project, binding, repository, commit, reader) do
    with {:ok, box} <- box(project),
         {:ok, environment} <- environment(box["env"]),
         {:ok, dockerfile} <-
           runtime_file(
             box,
             "dockerfile",
             ".agent/Dockerfile",
             binding,
             repository,
             commit,
             reader
           ),
         {:ok, compose} <- compose_file(box, binding, repository, commit, reader) do
      {:ok,
       %{
         "check" => check(project["gate"]),
         "runtime" => %{
           "version" => 1,
           "dockerfile" => dockerfile,
           "compose" => compose,
           "environment" => environment
         }
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp project(:not_found), do: {:ok, %{}}

  defp project(text) when is_binary(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, %{} = project} -> {:ok, project}
      {:ok, nil} -> {:ok, %{}}
      _invalid -> refused(@project_file, :invalid_yaml)
    end
  end

  defp box(project) do
    case Map.get(project, "box", %{}) do
      %{} = box ->
        if Map.get(box, "auto_up") in [nil, true, false] and
             Map.get(box, "network") in [nil, true, false],
           do: {:ok, box},
           else: refused("box", :invalid_settings)

      nil ->
        {:ok, %{}}

      _invalid ->
        refused("box", :invalid_settings)
    end
  end

  defp compose_file(%{"auto_up" => false}, _binding, _repository, _commit, _reader), do: {:ok, ""}
  defp compose_file(%{"network" => false}, _binding, _repository, _commit, _reader), do: {:ok, ""}

  defp compose_file(box, binding, repository, commit, reader),
    do: runtime_file(box, "compose", ".agent/compose.yml", binding, repository, commit, reader)

  defp environment(nil), do: {:ok, %{}}

  defp environment(%{} = values) do
    values = Map.new(values, fn {key, value} -> {key, environment_value(value)} end)

    if JobSpec.runtime_environment?(values),
      do: {:ok, values},
      else: refused("box.env", :invalid_environment)
  end

  defp environment(_invalid), do: refused("box.env", :invalid_environment)

  defp environment_value(nil), do: ""
  defp environment_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp environment_value(value), do: value

  defp runtime_file(box, key, default, binding, repository, commit, reader) do
    path = Map.get(box, key)
    explicit = path not in [nil, ""]
    path = normalized_path(if explicit, do: path, else: default)

    if path != "" and JobSpec.runtime_path?(path) do
      case reader.read(binding, repository, path, commit) do
        {:ok, :not_found} when not explicit -> {:ok, ""}
        {:ok, :not_found} -> refused(path, :not_found)
        {:ok, text} when is_binary(text) -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    else
      refused("box." <> key, :invalid_path)
    end
  end

  defp normalized_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") do
      nil
    else
      case Enum.reduce_while(String.split(path, "/"), [], &path_segment/2) do
        nil -> nil
        segments -> segments |> Enum.reverse() |> Enum.join("/")
      end
    end
  end

  defp normalized_path(_path), do: nil

  defp path_segment(segment, segments) when segment in ["", "."], do: {:cont, segments}
  defp path_segment("..", []), do: {:halt, nil}
  defp path_segment("..", [_last | segments]), do: {:cont, segments}
  defp path_segment(segment, segments), do: {:cont, [segment | segments]}

  defp refused(path, reason), do: {:error, {:coop_worker_project_setup_refused, path, reason}}

  defp check(gate) when is_binary(gate), do: %{"argv" => split(gate), "environment" => %{}}
  defp check(_gate), do: no_check()

  @doc """
  Splits a command into argv the way a shell splits words, and the way Coop's
  `ShellSplit` does: whitespace separates, quotes group, a backslash escapes
  the next character outside single quotes. Nothing is expanded or run.
  """
  @spec split(String.t()) :: [String.t()]
  def split(command) when is_binary(command) do
    command
    |> String.codepoints()
    |> Enum.reduce({[], [], :bare, false, false}, &step/2)
    |> finish()
  end

  defp step(char, {args, current, state, started, true}),
    do: {args, [char | current], state, started, false}

  defp step("'", {args, current, :single, started, false}),
    do: {args, current, :bare, started, false}

  defp step(char, {args, current, :single, started, false}),
    do: {args, [char | current], :single, started, false}

  defp step("\\", {args, current, :double, started, false}),
    do: {args, current, :double, started, true}

  defp step("\"", {args, current, :double, started, false}),
    do: {args, current, :bare, started, false}

  defp step(char, {args, current, :double, started, false}),
    do: {args, [char | current], :double, started, false}

  defp step("\\", {args, current, :bare, _started, false}),
    do: {args, current, :bare, true, true}

  defp step("'", {args, current, :bare, _started, false}),
    do: {args, current, :single, true, false}

  defp step("\"", {args, current, :bare, _started, false}),
    do: {args, current, :double, true, false}

  defp step(char, {args, current, :bare, started, false}) when char in [" ", "\t", "\n", "\r"] do
    if started,
      do: {[word(current) | args], [], :bare, false, false},
      else: {args, current, :bare, false, false}
  end

  defp step(char, {args, current, :bare, _started, false}),
    do: {args, [char | current], :bare, true, false}

  defp finish({args, current, _state, started, escaped}) do
    {current, started} = if escaped, do: {["\\" | current], true}, else: {current, started}
    args = if started, do: [word(current) | args], else: args
    Enum.reverse(args)
  end

  defp word(reversed), do: reversed |> Enum.reverse() |> Enum.join()
end
