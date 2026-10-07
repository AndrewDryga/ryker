defmodule Ryker.Evals.KnowledgeJudge do
  @moduledoc """
  Repository-knowledge answers the lane accepted, replayed without a model,
  and the judge that scores an answer for one of their repositories.

  Each case in `testdata/repository_knowledge/` is one run the lane accepted
  in production, harvested read-only: its exact prompt and answer, the
  RYKER.md it wrote from them, the repository tree at the commit it read, and
  the text of each file the answer's commands cite, as the lane read it.
  `replay/1` runs the answer through the host's own check and render, as
  `Ryker.RepositoryKnowledge.Executor` does:
  `Ryker.RepositoryKnowledge.Prompt.parse/1`, then
  `Ryker.RepositoryKnowledge.Document.verify/3` against the tree and the
  cited files, then `Document.render/3`.

  `judge/2` scores any answer for a case's repository: every path it names
  exists, every command is written in the file it cites, nothing in the
  RYKER.md it renders to is pinned to a commit, and it says what the
  repository is for, what is in it, where to start and, when the repository
  has build files, how to build and test it. A command whose file's text the
  case does not hold (Ryker could not read it, or the recorded answer never
  cited it) cannot be checked: it is reported, and does not fail the answer.
  The checks are structural; whether the words are right still takes a
  person reading the document.

  The knowledge prompt has no live run here: one would stage the case's
  repository as the job's read-only checkout, as a world scenario that
  captured a repository is staged (`Ryker.Evals.WorldSource`), and nothing
  stages the knowledge cases.
  """
  alias Ryker.Crypto
  alias Ryker.RepositoryKnowledge.{Document, Prompt}

  @root "testdata/repository_knowledge"
  @guidance_names ~w(AGENTS.md CLAUDE.md GEMINI.md)
  # A purpose shorter than this says nothing a teammate can use; the outline
  # takes a README paragraph as words from the same count.
  @purpose_words 8

  @doc "The directory of each recorded case, in order."
  @spec cases() :: [String.t()]
  def cases do
    @root
    |> Path.join("*/run.json")
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)
    |> Enum.sort()
  end

  @doc """
  One recorded case. Its answer and prompt must still match the digests the
  lane recorded: a case edited by hand is no longer a harvested one.
  """
  @spec load!(String.t()) :: map()
  def load!(directory) do
    run = directory |> Path.join("run.json") |> File.read!() |> Jason.decode!()

    unless Crypto.sha256_hex(run["result"]) == run["result_sha256"] and
             Crypto.sha256_hex(run["prompt"]) == run["prompt_sha256"],
           do: raise(ArgumentError, "#{directory} no longer holds the recorded answer and prompt")

    %{
      name: Path.basename(directory),
      run: run,
      tree: tree(directory),
      sources: sources(directory),
      unreadable: Map.keys(run["unreadable_sources"])
    }
  end

  @doc """
  The prompt the lane sends for the case's repository: the top level and key
  files of its tree, under today's instructions.
  """
  @spec prompt(map()) :: String.t()
  def prompt(%{run: run, tree: tree}) do
    tree
    |> Prompt.for_tree(%{
      name: run["repository"],
      default_branch: run["default_branch"],
      commit: run["commit"],
      current_document: Jason.decode!(run["prompt"])["context"]["current_document"]
    })
    |> Prompt.render()
  end

  @doc "The recorded answer, checked and rendered on the day the lane did it."
  @spec replay(map()) :: {:ok, map()} | {:error, atom()}
  def replay(%{run: run} = recorded), do: check(recorded, run["result"], checked_on(run))

  @doc """
  The host's check and render of `result` against the case's repository: the
  answer as `Prompt.parse/1` reads it, what `Document.verify/3` keeps of it
  given the cited files the case holds, how many items it dropped, and the
  RYKER.md `Document.render/3` writes from what it kept.
  """
  @spec check(map(), String.t(), Date.t()) :: {:ok, map()} | {:error, atom()}
  def check(recorded, result, %Date{} = date) do
    with {:ok, answer} <- Prompt.parse(result),
         sources = Map.take(recorded.sources, Document.cited_sources(answer, recorded.tree)),
         {:ok, kept, dropped, document} <-
           Document.keep(answer, recorded.tree, sources, recorded.run["commit"], date) do
      {:ok, %{answer: answer, kept: kept, dropped: dropped, document: document}}
    end
  end

  @doc """
  The verdict on `result` for the case's repository. It passes when the host
  accepts it and every finding is empty: no named path missing from the tree,
  no command its file never says, nothing pinned to a commit, and nothing a
  useful summary lacks.
  """
  @spec judge(map(), String.t()) :: map()
  def judge(recorded, result) do
    case check(recorded, result, checked_on(recorded.run)) do
      {:ok, checked} ->
        {unverifiable, uncited} = commands(checked.answer, recorded)

        findings = %{
          missing_paths: missing_paths(checked.answer, recorded.tree),
          uncited_commands: uncited,
          pinned: pinned(checked.document, recorded.run["commit"]),
          not_useful: not_useful(checked.kept, recorded.tree)
        }

        %{
          passed: Enum.all?(Map.values(findings), &(&1 == [])),
          findings: findings,
          unverifiable_commands: unverifiable,
          dropped: checked.dropped,
          document: checked.document,
          semantic_review: semantic_review()
        }

      {:error, reason} ->
        %{passed: false, error: reason, semantic_review: semantic_review()}
    end
  end

  defp semantic_review,
    do: "required; structural checks do not prove the purpose and descriptions are right"

  defp missing_paths(answer, tree) do
    named =
      Enum.map(answer.components, &{&1.path, nil}) ++
        Enum.map(answer.where_to_look, &{&1.path, nil}) ++
        Enum.map(answer.deploy_release, &{&1.source_file, nil}) ++
        Enum.map(answer.conventions, &{&1.source_file, :blob}) ++
        Enum.map(answer.build_test_run, &{&1.source_file, :blob})

    for {path, only} <- named, not located?(tree, path, only), uniq: true, do: path
  end

  defp located?(tree, path, only) do
    case Document.located(tree, path) do
      {:ok, _path, kind} -> is_nil(only) or kind == only
      :error -> false
    end
  end

  # A command whose file is missing is a missing path; the rest are checked
  # against the text of the file they cite, when the case holds it.
  defp commands(answer, recorded) do
    cited =
      for item <- answer.build_test_run,
          {:ok, path, :blob} <- [Document.located(recorded.tree, item.source_file)],
          do: {%{command: item.command, source_file: path}, recorded.sources[path]}

    {unverifiable, readable} = Enum.split_with(cited, fn {_command, text} -> is_nil(text) end)

    uncited =
      for {command, text} <- readable,
          not Document.cited?(command.command, command.source_file, text),
          do: command

    {Enum.map(unverifiable, &elem(&1, 0)), uncited}
  end

  # Andrew, 2026-09-27: "everything is hash-pinned for some reason, even paths
  # to folders". The renderer links every path plainly and names the commit
  # once, in the provenance line, but it writes the model's words as they
  # are: a link into a commit in a description reaches RYKER.md all the same.
  defp pinned(document, commit) do
    short = String.slice(commit, 0, 7)

    links =
      ~r"\S*/(?:blob|tree)/[0-9a-f]{7,40}(?:[/#)]\S*)?"
      |> Regex.scan(document)
      |> List.flatten()

    outside_provenance =
      if length(String.split(document, short)) > 2 or String.contains?(document, commit),
        do: ["the commit, outside the provenance line"],
        else: []

    Enum.uniq(links) ++ outside_provenance
  end

  defp not_useful(kept, tree) do
    [
      length(String.split(kept.purpose)) < @purpose_words && "The purpose says too little.",
      kept.components == [] && "It names no part of the repository.",
      kept.where_to_look == [] && "It says nowhere to start a task.",
      (kept.build_test_run == [] and build_files?(tree)) &&
        "It says nothing about building or testing a repository that has build files."
    ]
    |> Enum.filter(&is_binary/1)
  end

  # A key file that is not a README, CONTRIBUTING or agent guidance: a build
  # file or a CI workflow.
  defp build_files?(tree) do
    Enum.any?(tree, fn {path, kind} ->
      name = Path.basename(path)

      kind == :blob and Document.key_file?(path) and name not in @guidance_names and
        not String.starts_with?(String.upcase(name), ["README", "CONTRIBUTING"])
    end)
  end

  defp checked_on(run) do
    {:ok, at, 0} = DateTime.from_iso8601(run["recorded_at"])
    DateTime.to_date(at)
  end

  defp tree(directory) do
    directory
    |> Path.join("tree.tsv")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [type, path] = String.split(line, "\t", parts: 2)
      %{"type" => type, "path" => path}
    end)
    |> Document.tree()
  end

  defp sources(directory) do
    root = Path.join(directory, "files")

    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, root), File.read!(&1)})
  end
end
