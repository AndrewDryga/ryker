defmodule Ryker.Evals.KnowledgeJudgeTest do
  use ExUnit.Case, async: true
  alias Ryker.Evals.KnowledgeJudge
  alias Ryker.RepositoryKnowledge.Document

  @cases KnowledgeJudge.cases()
  if length(@cases) < 5, do: raise("the recorded repository-knowledge cases are missing")

  # The knowledge prompt had no recorded answer under test. On 2026-09-28,
  # hours after the lane proposed these five RYKER.md files, its citation
  # rules were made stricter (a command counts only where it stands on its
  # own, and ends at a Windows line end, a dash or emphasis), and nothing
  # showed whether the host still accepted the answers it had just proposed.
  # Each case is an answer the lane accepted, with the tree and the files it
  # checked it against: the host must keep what it kept and write the same
  # document, byte for byte.
  for directory <- @cases do
    @directory directory

    test "the recorded #{Path.basename(directory)} answer renders the RYKER.md the lane proposed" do
      recorded = KnowledgeJudge.load!(@directory)
      run = recorded.run

      # The tree is the one the lane read: as many entries, and the same top
      # level and key files in the prompt the model was given.
      assert map_size(recorded.tree) == run["manifest"]["tree_entries"]
      assert context(KnowledgeJudge.prompt(recorded)) == context(run["prompt"])

      assert {:ok, replayed} = KnowledgeJudge.replay(recorded)

      # Every file the lane read to check a command is recorded, or recorded
      # as one it could not read.
      assert Document.cited_sources(replayed.answer, recorded.tree) --
               (Map.keys(recorded.sources) ++ recorded.unreadable) == []

      assert replayed.dropped == run["dropped_count"]
      assert replayed.document == run["document"]

      verdict = KnowledgeJudge.judge(recorded, run["result"])
      assert verdict.passed, inspect(verdict.findings, pretty: true)
      assert verdict.document == run["document"]
    end
  end

  # coop's answer cites its README for three commands that are written
  # there, but the README is 135,820 bytes and Ryker reads at most 128,000
  # of a file: the lane dropped them, and the RYKER.md it proposed lost
  # `coop build && coop doctor` and `coop claude`. The judge reports them as
  # commands it cannot check, never as invented ones.
  test "a command whose file is too large to read is dropped, not held against the answer" do
    recorded = load!("coop")
    verdict = KnowledgeJudge.judge(recorded, recorded.run["result"])

    assert verdict.passed
    assert recorded.unreadable == ["README.md"]
    assert verdict.dropped == 3

    assert verdict.unverifiable_commands == [
             %{
               command: "make provider-live-e2e COOP_LIVE_TARGETS='codex,gemini@work'",
               source_file: "README.md"
             },
             %{command: "coop build && coop doctor", source_file: "README.md"},
             %{command: "coop claude", source_file: "README.md"}
           ]

    refute verdict.document =~ "coop claude"
  end

  # The judge's cases below edit a recorded answer by hand; they test the
  # judge, not the model.

  # Andrew, 2026-09-27: "everything is hash-pinned for some reason, even
  # paths to folders". The host keeps a description with a pinned link, so
  # only the judge catches it.
  test "a link into a commit anywhere in the document fails the judge" do
    recorded = load!("ryker")
    pinned = "https://github.com/AndrewDryga/ryker/blob/#{recorded.run["commit"]}/Makefile"

    result =
      edit(recorded, fn answer ->
        update_in(answer, ["components", Access.at(0), "what_it_does"], &"#{&1} See #{pinned}.")
      end)

    verdict = KnowledgeJudge.judge(recorded, result)

    refute verdict.passed
    assert verdict.dropped == 0
    assert verdict.document =~ pinned

    assert verdict.findings.pinned == [
             pinned <> ".",
             "the commit, outside the provenance line"
           ]
  end

  test "an invented path and a command its file never says fail the judge, and the host drops both" do
    recorded = load!("ryker")

    result =
      edit(recorded, fn answer ->
        answer
        |> Map.update!("components", &(&1 ++ [%{"path" => "src/", "what_it_does" => "Code."}]))
        |> Map.update!(
          "build_test_run",
          &(&1 ++
              [%{"command" => "make release", "what_it_does" => "x", "source_file" => "Makefile"}])
        )
      end)

    verdict = KnowledgeJudge.judge(recorded, result)

    refute verdict.passed
    assert verdict.findings.missing_paths == ["src/"]

    assert verdict.findings.uncited_commands == [
             %{command: "make release", source_file: "Makefile"}
           ]

    assert verdict.dropped == 2
    refute verdict.document =~ "`make release`"
    refute verdict.document =~ "[src/]"
  end

  test "a summary that says nothing about building a repository with build files fails the judge" do
    recorded = load!("ryker")
    result = edit(recorded, &Map.merge(&1, %{"purpose" => "Ryker.", "build_test_run" => []}))
    verdict = KnowledgeJudge.judge(recorded, result)

    refute verdict.passed

    assert verdict.findings.not_useful == [
             "The purpose says too little.",
             "It says nothing about building or testing a repository that has build files."
           ]

    # A repository with nothing to build owes no command.
    test = load!("test")
    assert Jason.decode!(test.run["result"])["build_test_run"] == []
    assert KnowledgeJudge.judge(test, test.run["result"]).passed
  end

  test "an answer outside the contract fails the judge with the host's reason" do
    recorded = load!("test")

    assert %{passed: false, error: :invalid_repository_knowledge} =
             KnowledgeJudge.judge(recorded, "{}")
  end

  test "a case whose answer was edited by hand is refused" do
    copy = Path.join(System.tmp_dir!(), "ryker-knowledge-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(copy) end)
    File.cp_r!(hd(@cases), copy)
    path = Path.join(copy, "run.json")
    run = path |> File.read!() |> Jason.decode!()
    File.write!(path, Jason.encode!(%{run | "result" => run["result"] <> " "}))

    assert_raise ArgumentError, ~r/no longer holds the recorded answer/, fn ->
      KnowledgeJudge.load!(copy)
    end
  end

  defp load!(name),
    do: @cases |> Enum.find(&(Path.basename(&1) == name)) |> KnowledgeJudge.load!()

  defp edit(recorded, change),
    do: recorded.run["result"] |> Jason.decode!() |> change.() |> Jason.encode!()

  defp context(prompt), do: Jason.decode!(prompt)["context"]
end
