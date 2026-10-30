defmodule Ryker.ControlPlane.KnowledgeDocumentTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.KnowledgeDocument
  alias Ryker.RepositoryKnowledge.Document

  @commit "162c01814dcfe24dd1472ae107c437cd54de3e77"
  @source %{github_repository: "acme/checkout-api", commit: @commit}

  defp render(document, source \\ @source) do
    {title, {:safe, html}} = KnowledgeDocument.render(document, source)
    {title, html |> IO.iodata_to_binary() |> LazyHTML.from_fragment()}
  end

  # A repository's knowledge showed as raw Markdown on its page: "## Purpose",
  # "- [portal/](portal/) — …" and all (Andrew, 2026-10-04: "well
  # structured/formatted text").
  test "headings read as headings, and the title is the row's, not repeated" do
    {title, page} =
      render(
        "# RYKER.md\n\nWritten by Ryker from `162c018` on 2026-09-27.\n\n" <>
          "## Purpose\n\nIt runs checkout.\n\n## Build, test and run\n\n- `make test` — runs the tests.\n"
      )

    assert title == "RYKER.md"

    assert page |> LazyHTML.query("h4.knowledge-heading") |> Enum.map(&LazyHTML.text/1) ==
             ["Purpose", "Build, test and run"]

    refute LazyHTML.text(page) =~ "#"
    refute LazyHTML.text(page) =~ "RYKER.md"
    assert page |> LazyHTML.query("li code") |> LazyHTML.text() == "make test"
  end

  test "a link to a path in the repository opens it on GitHub at the knowledge's commit" do
    {_title, page} =
      render(
        "## Components\n\n- [portal/](portal/) — the console.\n- [README.md](README.md) — start here.\n" <>
          "- [Coop](https://github.com/AndrewDryga/coop) — the worker.\n"
      )

    assert page |> LazyHTML.query("a") |> LazyHTML.attribute("href") == [
             "https://github.com/acme/checkout-api/tree/#{@commit}/portal/",
             "https://github.com/acme/checkout-api/blob/#{@commit}/README.md",
             "https://github.com/AndrewDryga/coop"
           ]
  end

  test "code is left as written: no heading in a fence, no link in a code span" do
    {_title, page} =
      render("## Run\n\n```sh\n# a shell comment\nmake check\n```\n\nNot `[x](y)` here.\n")

    assert page |> LazyHTML.query(".knowledge-heading") |> Enum.map(&LazyHTML.text/1) == ["Run"]
    assert page |> LazyHTML.query("pre") |> LazyHTML.text() =~ "# a shell comment"
    assert page |> LazyHTML.query("p code") |> LazyHTML.text() == "[x](y)"
    assert page |> LazyHTML.query("a") |> Enum.empty?()
  end

  test "without the repository's name or commit a path link reads as its name" do
    {_title, page} = render("See [README.md](README.md).", %{github_repository: nil, commit: nil})

    assert LazyHTML.text(page) =~ "See README.md."
    assert page |> LazyHTML.query("a") |> Enum.empty?()
  end

  test "a document without a title keeps all its text" do
    assert {nil, page} = render("Plain notes.\n\n## Later\n\nMore.")
    assert LazyHTML.text(page) =~ "Plain notes."
    assert page |> LazyHTML.query(".knowledge-heading") |> LazyHTML.text() == "Later"
  end

  # Commit subjects are repository-controlled bytes. A mixed backtick run escaped the
  # literal example and made a fake sign-in link clickable in the knowledge preview.
  test "commit examples remain literal text through the final knowledge preview" do
    for subject <- [
          "fix: ``x` [Required sign-in](https://attacker.invalid)",
          "patch(api): handle `id` and [README](README.md)",
          "fix: ```x```` [Required sign-in](https://attacker.invalid)"
        ] do
      # A structural adversarial variation, not a harvested model result.
      kept = %{
        purpose: "A repository.",
        components: [],
        build_test_run: [],
        deploy_release: [],
        conventions: [%{rule: "Use a prefix.", examples: [%{"subject" => subject}]}],
        where_to_look: [],
        open_questions: []
      }

      assert {:ok, document} = Document.render(kept, @commit, ~D[2026-10-30])
      {_title, page} = render(document)
      assert page |> LazyHTML.query("li code") |> LazyHTML.text() == subject
      assert page |> LazyHTML.query("a") |> Enum.empty?()
    end
  end
end
