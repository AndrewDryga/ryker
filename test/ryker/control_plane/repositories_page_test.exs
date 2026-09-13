defmodule Ryker.ControlPlane.RepositoriesPageTest do
  @moduledoc """
  The Repositories list inside the shared Configuration shell: one toolbar, a
  quiet count and one comparison table, with access, revision receipt and
  worker evidence kept as details on demand under each row.
  """
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.{HTML, Pages}

  @repository %{
    channels: 1,
    configured: %{contributor_policy: "ryker-write"},
    freshness: %{
      fetched_at: "2026-08-28T11:59:00Z",
      recorded_at: ~U[2026-08-28 12:00:00Z],
      remote_identity: "origin",
      requested_revision: "refs/heads/main",
      resolved_revision: String.duplicate("a", 40),
      stale_base_revision: nil,
      stale_base_status: "current",
      version: 2,
      workspace_base_revision: String.duplicate("a", 40)
    },
    publications: 0,
    ref: "ryker",
    schedules: 1,
    sessions: 2,
    workers: [
      %{
        last_seen_at: ~U[2026-08-28 12:00:00Z],
        revision: "commit:abc123",
        state: :eligible,
        worker_ref: "coop-worker-one"
      }
    ]
  }

  test "the repositories page is one toolbar, one quiet count and one comparison table in that order" do
    # Before 2026-09-13 each repository was a 14px-radius card with its own h2,
    # a row of bold counts and two disclosures, under a "Where Ryker can
    # work" intro heading that repeated the shell's title. Five repositories
    # meant five headings and no way to compare them.
    document = render([@repository, %{@repository | ref: "emisar", sessions: 0}])

    assert outline(document, "div.repositories-page > *") == [
             "form.filter-toolbar",
             "p.result-count",
             "table.data-table"
           ]

    assert LazyHTML.query(document, "p.result-count") |> LazyHTML.text() == "2 repositories"

    assert Enum.empty?(
             LazyHTML.query(document, "h1, h2, .page-description, .repository-card, .table-wrap")
           )

    assert LazyHTML.query(document, "div.repositories-page > table.data-table > thead th")
           |> LazyHTML.text() ==
             "RepositoryWork sessionsChannelsSchedulesPR workflowsCode revision"

    assert Enum.count(
             LazyHTML.query(
               document,
               "div.repositories-page > table.data-table > tbody > tr:not(.row-details)"
             )
           ) ==
             2

    assert Enum.count(
             LazyHTML.query(
               document,
               "div.repositories-page > table.data-table > tbody > tr.row-details"
             )
           ) == 2
  end

  test "a repository row compares its counts and last revision, with access and worker evidence on demand" do
    document = render([@repository])

    row =
      LazyHTML.query(
        document,
        "div.repositories-page > table.data-table > tbody > tr:not(.row-details)"
      )

    identity = LazyHTML.query(row, "td.row-identity")
    assert LazyHTML.query(identity, "strong") |> LazyHTML.text() == "ryker"

    assert LazyHTML.query(identity, "a[href='/activity?repository=ryker']") |> LazyHTML.text() =~
             "View requests"

    for {label, value} <- [
          {"Work sessions", "2"},
          {"Channels", "1"},
          {"Schedules", "1"},
          {"PR workflows", "0"}
        ] do
      assert LazyHTML.query(row, "td[data-label='#{label}']") |> LazyHTML.text() == value, label
    end

    revision = LazyHTML.query(row, "td[data-label='Code revision']")
    assert LazyHTML.query(revision, "code") |> LazyHTML.text() == "aaaaaaaa"

    assert LazyHTML.query(revision, "code") |> LazyHTML.attribute("title") == [
             String.duplicate("a", 40)
           ]

    assert LazyHTML.query(revision, ".row-secondary") |> LazyHTML.text() =~ "28 Aug, 11:59 UTC"

    details = LazyHTML.query(document, "tbody tr.row-details td[colspan='6'] details:not([open])")

    assert LazyHTML.query(details, "summary") |> LazyHTML.text() ==
             "Access and code revisionWorker connections"

    text = LazyHTML.text(details)
    assert text =~ "contributor ryker-write"
    assert text =~ "not a live Git check"
    assert text =~ "refs/heads/main"
    assert text =~ "coop-worker-one"
    assert text =~ "commit:abc123"
    assert LazyHTML.query(details, "a[href='/configuration']") |> Enum.count() == 2

    # The worker table inside the details stacks on a phone like every other.
    assert LazyHTML.query(details, "table.data-table td[data-label='Worker']") |> LazyHTML.text() ==
             "coop-worker-one"
  end

  test "a repository without a revision receipt or fleet worker says so instead of inventing either" do
    document = render([%{@repository | configured: nil, freshness: nil, workers: []}])
    row = LazyHTML.query(document, "tbody tr:not(.row-details)")

    assert LazyHTML.query(row, "td[data-label='Code revision']") |> LazyHTML.text() ==
             "No revision recorded yet"

    details = LazyHTML.query(document, "tbody tr.row-details")
    assert LazyHTML.text(details) =~ "observed only"
    assert LazyHTML.text(details) =~ "No frozen freshness-v2 receipt"
    assert LazyHTML.text(details) =~ "No fleet worker is reporting this repository here"
  end

  test "an empty repositories list tells a filtered miss from an installation with none" do
    filtered = render([], %{"q" => "absent"})
    assert LazyHTML.query(filtered, "p.empty-state") |> LazyHTML.text() =~ "No repositories match"
    assert Enum.empty?(LazyHTML.query(filtered, "p.result-count, table"))

    bare = render([])

    assert LazyHTML.query(bare, "p.empty-state") |> LazyHTML.text() =~
             "No configured or observed repositories"
  end

  test "the route keeps the shell's title and description" do
    page =
      Pages.page(["repositories"], %{"q" => "resp"}, %{
        projection: %{repositories: fn _params -> [@repository] end}
      })

    assert page.title == "Repositories"
    assert page.description =~ "Connected repositories"

    assert LazyHTML.from_fragment(page.body)
           |> LazyHTML.query("form.filter-toolbar input[name=q]")
           |> LazyHTML.attribute("value") == ["resp"]
  end

  defp render(items, params \\ %{}) do
    items |> HTML.repositories(params) |> IO.iodata_to_binary() |> LazyHTML.from_fragment()
  end

  # "tag.first-class" for each matched element, in document order.
  defp outline(document, selector) do
    nodes = LazyHTML.query(document, selector)

    nodes
    |> LazyHTML.tag()
    |> Enum.zip(LazyHTML.attributes(nodes))
    |> Enum.map(fn {tag, attributes} ->
      case List.keyfind(attributes, "class", 0) do
        {"class", class} -> tag <> "." <> hd(String.split(class))
        nil -> tag
      end
    end)
  end
end
