defmodule Ryker.RepositoryKnowledge.RefreshTest do
  use ExUnit.Case, async: true
  alias Ryker.RepositoryKnowledge.{Document, Refresh}

  @written "a" |> String.duplicate(40)
  @head "b" |> String.duplicate(40)
  @now ~U[2026-09-27 12:00:00.000000Z]

  # Andrew, 2026-09-27: "also when those are updated?" Never, until now. A
  # model reading the whole repository costs minutes of a worker, so a push
  # that touches nothing a teammate reads to learn the repository is not
  # worth one; a changed README, build file or CI workflow is.
  test "a document a model wrote is rewritten once the default branch moved and a key file changed" do
    written = written(@now |> DateTime.add(-86_400))

    assert {:write, reason} =
             Refresh.decide(written, @head, changes(["README.md", "lib/a.ex"]), @now)

    assert reason == "These files changed: README.md."

    for path <- ~w(AGENTS.md CLAUDE.md Makefile mix.exs go.mod package.json portal/mix.exs
                   runner/go.mod docs/README.md .github/workflows/ci.yml readme.md) do
      assert {:write, _reason} =
               Refresh.decide(written, @head, changes([path]), @now),
             "#{path} should count as a key file"
    end

    # Vendored code changes with every dependency bump.
    assert Refresh.decide(written, @head, changes(["deps/jason/mix.exs"]), @now) ==
             :current

    assert Refresh.decide(written, @head, changes(["assets/node_modules/x/package.json"]), @now) ==
             :current
  end

  # Review of the knowledge lane, 2026-09-28: the rules kept a list of key
  # files of their own, narrower than the one the prompt shows the model, so
  # a changed Dockerfile, Cargo.toml or CONTRIBUTING never had RYKER.md read
  # again though the model is told those describe the repository.
  test "every file the model is shown as a key file has RYKER.md read again when it changes" do
    written = written(DateTime.add(@now, -86_400))

    for path <- ~w(Dockerfile Cargo.toml pyproject.toml Gemfile GNUmakefile go.work GEMINI.md
                   CONTRIBUTING.md docs/CONTRIBUTING.rst services/api/Dockerfile) do
      assert Document.key_file?(path), "#{path} is a key file the model is shown"

      assert {:write, _reason} = Refresh.decide(written, @head, changes([path]), @now),
             "#{path} should have RYKER.md read again"
    end
  end

  test "code alone waits a week after the last write" do
    six_days = written(DateTime.add(@now, -6 * 86_400))
    seven_days = written(DateTime.add(@now, -Refresh.stale_after_seconds()))

    assert Refresh.decide(six_days, @head, changes(["lib/a.ex"]), @now) == :current

    assert {:write, "A week has passed since the last write, and code changed."} =
             Refresh.decide(seven_days, @head, changes(["lib/a.ex"]), @now)
  end

  test "an unmoved default branch is never read again, and asks GitHub nothing more" do
    written = written(DateTime.add(@now, -30 * 86_400))
    unasked = fn -> flunk("the comparison was asked for") end

    assert Refresh.decide(%{written | commit: @head}, @head, unasked, @now) == :current
  end

  test "a change GitHub cannot list is rewritten; a comparison that failed is asked again" do
    written = written(DateTime.add(@now, -86_400))

    assert {:write, _reason} =
             Refresh.decide(written, @head, fn -> {:ok, :unknown} end, @now)

    assert Refresh.decide(written, @head, fn -> {:error, :timeout} end, @now) ==
             {:error, :timeout}
  end

  # A repository Ryker has no document for, or only the outline a failed
  # try left, is written at once, and the rules ask GitHub nothing more.
  test "a repository without a model's RYKER.md is written at once" do
    unasked = fn -> flunk("the comparison was asked for") end

    assert {:write, "Ryker has no RYKER.md for this repository yet."} =
             Refresh.decide(%{commit: nil, at: nil, by: nil}, @head, unasked, @now)

    assert {:write, "RYKER.md is only an outline from the last try."} =
             Refresh.decide(%{written(@now) | by: :outline}, @head, unasked, @now)
  end

  defp written(at), do: %{commit: @written, at: at, by: :model}
  defp changes(paths), do: fn -> {:ok, paths} end
end
