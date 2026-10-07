defmodule Ryker.CoopFleet.JobCheck do
  @moduledoc """
  The check a draft pull request's review runs, resolved before the job is frozen.

  Coop's `job-setup:2` runs only the check a job names: the trusted parent's
  `gate:` and a worker's `COOP_GATE` stopped applying to remote reviews. So
  Ryker reads the repository's `.agent/project.yaml` at the job's base commit
  and freezes its `gate:` as argv, split the way Coop splits it. The review
  stack's environment still comes from the candidate at review time, so the
  check's own environment stays empty. A repository without a readable gate
  gets no check, and its review is not publishable, as before.
  """
  alias Ryker.GitHub.RepositoryFiles
  require Logger

  @project_file ".agent/project.yaml"

  @spec none() :: map()
  def none, do: %{"argv" => [], "environment" => %{}}

  @spec resolve(map(), map(), String.t(), module()) :: {:ok, map()} | {:error, term()}
  def resolve(binding, repository, commit, reader \\ RepositoryFiles) do
    case reader.read(binding, repository, @project_file, commit) do
      {:ok, :not_found} -> {:ok, none()}
      {:ok, text} when is_binary(text) -> {:ok, check(gate(text, repository))}
      {:error, _reason} = error -> error
    end
  end

  defp gate(text, repository) do
    case YamlElixir.read_from_string(text) do
      {:ok, %{"gate" => gate}} when is_binary(gate) ->
        gate

      {:ok, _settings} ->
        nil

      {:error, _reason} ->
        Logger.warning(
          "#{@project_file} in #{repository.github_repository} is not valid YAML; its review runs no check"
        )

        nil
    end
  end

  defp check(nil), do: none()
  defp check(gate), do: %{"argv" => split(gate), "environment" => %{}}

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
