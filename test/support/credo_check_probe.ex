defmodule Ryker.CredoCheckProbe do
  @moduledoc """
  Runs one of the house Credo checks (`credo/checks/`) against a probe source.

  Credo loads those files only when `mix credo` runs, so a check that stops
  matching is invisible to the suite until someone writes the very shape it
  exists to stop. Four of the checks ported from Emisar on 2026-10-05 never
  ran here at all: they looked for Emisar's file names (`changeset.ex`,
  `query.ex`, `live/`) while Ryker named its files `*_changeset.ex`,
  `*_query.ex` and `*_live.ex` (query and changeset modules moved to
  Emisar's `<schema>/query.ex` and `<schema>/changeset.ex` on 2026-10-07).
  A fixture test loads the sources (`load/0`),
  parses a probe at a path the check cares about, and asserts both what must
  fire and what must not.
  """
  alias Credo.SourceFile

  @checks_dir Path.expand("../../credo/checks", __DIR__)

  @doc """
  Loads every check source. Call it from `setup_all`.

  All of them rather than a list per test: `Code.require_file/1` loads each
  file once per run whoever asks first, and requiring the whole directory also
  proves every check still compiles.
  """
  @spec load() :: :ok
  def load do
    {:ok, _started} = Application.ensure_all_started(:credo)

    @checks_dir
    |> Path.join("*.ex")
    |> Path.wildcard()
    |> Enum.each(&Code.require_file/1)
  end

  @doc """
  The check module named `name`, resolved at run time: the checks are never
  compiled into the application, so a literal `Ryker.Checks.X` would warn of
  an undefined module.
  """
  @spec check(String.t()) :: module()
  def check(name), do: Module.safe_concat([:Ryker, :Checks, name])

  @doc "Every issue `check` reports for `source` parsed at `filename`, given the check's `params`."
  @spec issues(module(), String.t(), String.t(), keyword()) :: [Credo.Issue.t()]
  def issues(check, source, filename, params \\ []),
    do: source |> SourceFile.parse(filename) |> check.run(params)

  @doc "The sorted triggers `check` reports for `source` at `filename`."
  @spec triggers(module(), String.t(), String.t()) :: [String.t()]
  def triggers(check, source, filename) do
    check |> issues(source, filename) |> Enum.map(& &1.trigger) |> Enum.sort()
  end
end
