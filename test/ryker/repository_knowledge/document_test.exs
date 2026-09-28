defmodule Ryker.RepositoryKnowledge.DocumentTest do
  use ExUnit.Case, async: true

  alias Ryker.RepositoryKnowledge.{Document, Prompt}

  @fixtures "test/ryker/repository_knowledge/fixtures"
  @commit "783fc4801d274d5ee05feb3fbc5c70981b1bbd7a"
  @date ~D[2026-09-27]

  # Andrew, 2026-09-27: "everything is hash-pinned for some reason, even paths
  # to folders". Setup linked every path to
  # github.com/<repo>/blob/<commit>/<path>, so a merged RYKER.md pointed at an
  # old commit forever. A plain relative link resolves against whatever
  # branch the reader is on.
  test "the renderer never pins a link to a commit" do
    document = render!(answer())

    links = Regex.scan(~r/\]\(([^)]*)\)/, document, capture: :all_but_first) |> List.flatten()
    assert "portal/" in links
    assert "AGENTS.md" in links
    assert ".github/workflows/cd.yml" in links

    for link <- links do
      refute link =~ "://", "#{link} leaves the repository"
      refute link =~ @commit, "#{link} names the commit"
      refute link =~ String.slice(@commit, 0, 7), "#{link} names the commit"
      refute String.starts_with?(link, "/"), "#{link} is not relative"
    end

    assert document =~ "[portal/](portal/) — Elixir/Phoenix control plane"
    assert document =~ "[run](run) — The root contributor command"

    # The commit is named once, in the one provenance line, and never whole.
    refute document =~ @commit
    assert length(String.split(document, "783fc48")) == 2

    assert String.starts_with?(
             document,
             "# RYKER.md\n\nWritten by Ryker from `783fc48` on 2026-09-27.\n\n## Purpose\n\n"
           )

    assert Document.origin(document) == :model
  end

  # The old document said "No standard setup or test command was identified"
  # for a repository whose AGENTS.md starts its command section with
  # `./run help`, and "`mix test`" for ryker, whose mix.exs defines no alias
  # and whose Makefile has no test target.
  test "the document says how to build, test, run and ship, each with its source" do
    document = render!(answer())

    assert document =~
             "- `./run help` — Lists every contributor command. From [AGENTS.md](AGENTS.md)."

    assert document =~ "- `./run gate all` — "
    assert document =~ "From [portal/AGENTS.md](portal/AGENTS.md)."
    assert document =~ "- `mix test` — Runs the Portal umbrella's tests through its alias."

    assert document =~
             "- A push to main runs CI and publishes the portal image CI built and tested. " <>
               "From [.github/workflows/cd.yml](.github/workflows/cd.yml)."

    assert document =~ "## Conventions"

    assert document =~
             "- Change the ./run contributor command: [tools/cmd/devtool/](tools/cmd/devtool/)"

    assert document =~ "## Open questions"
    refute document =~ "No standard setup or test command"
  end

  test "invented paths and commands are dropped, and the rest is kept" do
    answer = answer()

    invented =
      answer
      |> Map.update!(:components, &(&1 ++ [%{path: "src/", what_it_does: "The source."}]))
      |> Map.update!(
        :build_test_run,
        &(&1 ++
            [
              # The file the command cites does not exist.
              %{command: "make test", what_it_does: "Tests.", source_file: "Makefile"},
              # The file exists and never says it.
              %{command: "./run lint", what_it_does: "Lints.", source_file: "AGENTS.md"},
              # Outside the repository.
              %{command: "cat /etc/passwd", what_it_does: "x", source_file: "../etc/passwd"}
            ])
      )
      |> Map.update!(:where_to_look, &(&1 ++ [%{task: "Deploy", path: "deploy/"}]))
      |> Map.update!(
        :conventions,
        &(&1 ++ [%{rule: "Be nice.", source_file: "CODE_OF_CONDUCT.md"}])
      )

    assert {:ok, kept, 6} = Document.verify(invented, tree!("emisar"), sources!("emisar"))

    assert Enum.map(kept.components, & &1.path) ==
             Enum.map(answer.components, &canonical(&1.path))

    refute Enum.any?(
             kept.build_test_run,
             &(&1.command in ["make test", "./run lint", "cat /etc/passwd"])
           )

    assert length(kept.build_test_run) == length(answer.build_test_run)

    {:ok, document} = Document.render(kept, @commit, @date)
    refute document =~ "src/"
    refute document =~ "make test"
    refute document =~ "./run lint"
    refute document =~ "deploy/"
    refute document =~ "CODE_OF_CONDUCT"
  end

  test "an answer with nothing real left is refused, whatever else it says" do
    answer = %{
      answer()
      | components: [%{path: "src/", what_it_does: "The source."}],
        build_test_run: [%{command: "make test", what_it_does: "Tests.", source_file: "Makefile"}]
    }

    assert Document.verify(answer, tree!("emisar"), sources!("emisar")) ==
             {:error, :repository_knowledge_unusable}
  end

  test "a command counts only where its source writes it or defines it" do
    ryker = sources!("ryker")

    # The old scan's "`make test`" and "`mix test`" for ryker: neither is
    # written or defined there.
    assert Document.cited?("make dev-check", "Makefile", ryker["Makefile"])
    assert Document.cited?("make eval-world-smoke", "Makefile", ryker["Makefile"])
    refute Document.cited?("make test", "Makefile", ryker["Makefile"])
    refute Document.cited?("mix test", "mix.exs", ryker["mix.exs"])
    refute Document.cited?("make dev-check && rm -rf /", "Makefile", ryker["Makefile"])
    refute Document.cited?("make -C portal dev-check", "Makefile", ryker["Makefile"])

    emisar = sources!("emisar")
    assert Document.cited?("mix test", "portal/mix.exs", emisar["portal/mix.exs"])
    assert Document.cited?("mix ecto.setup", "portal/mix.exs", emisar["portal/mix.exs"])
    refute Document.cited?("mix phx.routes", "portal/mix.exs", emisar["portal/mix.exs"])
    # A comment that shows it is the file writing it.
    assert Document.cited?("mix phx.server", "portal/mix.exs", emisar["portal/mix.exs"])

    # Written across a line break in the README, and quoted.
    assert Document.cited?("./run doctor", "README.md", emisar["README.md"])
    assert Document.cited?("`./run seed`", "README.md", emisar["README.md"])
    refute Document.cited?("./run deploy", "README.md", emisar["README.md"])

    site = sources!("andrewdryga")["package.json"]
    assert Document.cited?("npm run build", "package.json", site)
    assert Document.cited?("npm run typecheck", "package.json", site)
    refute Document.cited?("npm test", "package.json", site)
    refute Document.cited?("npm run deploy", "package.json", site)

    refute Document.cited?("./run help", "AGENTS.md", nil)
  end

  # Review of the knowledge lane, 2026-09-28: a command counted as written
  # wherever its words appeared, inside other words or as the start of
  # other ones, so `npm install` was cited by a README that says
  # `pnpm install`, and `make` by "make sure". A command counts only where
  # it stands on its own: nothing runs into its start, and it ends there.
  test "a command is cited only where it stands on its own" do
    readme = """
    # Widget

    Make sure Docker is running, and make sure its ports are free.

    Install the dependencies with `pnpm install`, then run every gate:

    ```sh
    make dev-check-all   # the whole gate
    ```

        ./run serve
    """

    refute Document.cited?("npm install", "README.md", readme)
    assert Document.cited?("pnpm install", "README.md", readme)
    refute Document.cited?("make", "README.md", readme)
    refute Document.cited?("make dev-check", "README.md", readme)
    assert Document.cited?("make dev-check-all", "README.md", readme)
    assert Document.cited?("./run serve", "README.md", readme)
    assert Document.cited?("make", "docs/BUILD.md", "Run `make` to build it.\n")

    # The same in any file: a workflow and its comments.
    workflow = """
    jobs:
      test:
        steps:
          # make sure the cache is warm
          - run: pnpm install
          - run: make test && make lint
    """

    refute Document.cited?("npm install", ".github/workflows/ci.yml", workflow)
    refute Document.cited?("make", ".github/workflows/ci.yml", workflow)
    assert Document.cited?("pnpm install", ".github/workflows/ci.yml", workflow)
    assert Document.cited?("make test", ".github/workflows/ci.yml", workflow)
    assert Document.cited?("make lint", ".github/workflows/ci.yml", workflow)
    assert Document.cited?("make test", "docs/TESTING.md", "Before a push, run make test.\n")

    # Wherever a command ends: a line in a file written on Windows, a list
    # entry's dash, or emphasis.
    assert Document.cited?("make test", "README.md", "Run:\r\n\r\n    make test\r\n")
    assert Document.cited?("make test", "README.md", "- make test - runs every test\n")
    assert Document.cited?("make test", "README.md", "Run **make test** first.\n")
    refute Document.cited?("make test", "README.md", "Run make test -- --watch.\n")
  end

  # PR 84's RYKER.md is what setup wrote for emisar and what its default
  # branch holds now: a refresh has to know it for the old summary it is.
  test "a document says who wrote it" do
    old = File.read!(Path.join([@fixtures, "emisar", "old_scan_RYKER.md"]))
    model = render!(answer())
    outline = Document.outline(tree!("emisar"), sources!("emisar")["README.md"], @commit, @date)

    assert Document.origin(old) == :old_scan
    assert Document.origin(model) == :model
    assert Document.origin(outline) == :outline
    assert Document.origin("# How to work here\n\nRun `make`.\n") == :person
    assert Document.origin(nil) == :none
  end

  # A rewrite names a new commit and date every time; a proposal that
  # changed only that would be noise.
  test "two documents that differ only in their provenance line say the same things" do
    first = render!(answer())
    {:ok, later} = Document.render(verified!(answer()), String.duplicate("b", 40), ~D[2026-10-05])

    assert first != later
    assert Document.same?(first, later)
    assert Document.same?(first, String.replace(first, "\n", "\r\n"))
    refute Document.same?(first, String.replace(later, "Lists every", "Shows every"))
    refute Document.same?(nil, first)
    refute Document.same?(first, nil)
  end

  # When no model can finish, the fallback is an outline from the file list,
  # and says so: never the old scan's invented commands, never a pinned link.
  test "the outline says what it is, links plainly and invents no command" do
    outline = Document.outline(tree!("emisar"), sources!("emisar")["README.md"], @commit, @date)

    assert outline =~
             "Written by Ryker from `783fc48` on 2026-09-27. This is only an outline from " <>
               "the file list"

    # The README's first paragraph in words, not its bold tagline.
    assert outline =~
             "emisar gives MCP-capable agents a catalog of declared infrastructure actions"

    refute outline =~ "Leave the agent working"

    assert outline =~ "- [portal/](portal/)"
    assert outline =~ "- [.github/](.github/)"
    refute outline =~ "[.claude/]"
    assert outline =~ "- [AGENTS.md](AGENTS.md)"
    assert outline =~ "- [portal/mix.exs](portal/mix.exs)"
    refute outline =~ "mix test"
    refute outline =~ "make test"
    refute outline =~ "://"
    refute outline =~ @commit
  end

  defp render!(answer) do
    {:ok, document} = Document.render(verified!(answer), @commit, @date)
    document
  end

  defp verified!(answer) do
    {:ok, kept, 0} = Document.verify(answer, tree!("emisar"), sources!("emisar"))
    kept
  end

  defp canonical(path), do: String.trim_trailing(path, "/")

  # The recorded answer, as the host parses it.
  defp answer do
    {:ok, answer} =
      Path.join([@fixtures, "emisar", "answer.json"]) |> File.read!() |> Prompt.parse()

    answer
  end

  defp tree!(name) do
    [@fixtures, name, "tree.tsv"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [type, path] = String.split(line, "\t", parts: 2)
      %{"type" => type, "path" => path}
    end)
    |> Document.tree()
  end

  # The files each repository's commands cite, as harvested at its commit.
  defp sources!(name) do
    root = Path.join([@fixtures, name, "files"])

    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    # A harvested .exs is kept as .exs.fixture, so ExUnit does not take it
    # for a test file.
    |> Map.new(
      &{&1 |> Path.relative_to(root) |> String.trim_trailing(".fixture"), File.read!(&1)}
    )
  end
end
