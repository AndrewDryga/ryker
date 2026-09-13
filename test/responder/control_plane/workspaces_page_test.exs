defmodule Responder.ControlPlane.WorkspacesPageTest do
  @moduledoc """
  The Workspaces page inside the shared Configuration shell: help, a quiet
  count, the working copies as one comparison table with their confirmed
  cleanup actions, then worker storage and the cleanup preview beneath.
  """
  use ExUnit.Case, async: true

  alias Responder.ControlPlane.{HTML, Router}

  @blocked %{
    action: :rearm,
    kind: "coop_session",
    episode_ref: "episode:one",
    request_title: "Fix the build",
    repository: "responder",
    ref: "workspace:blocked",
    state: :complete,
    status: :blocked,
    summary: "coop_error",
    updated_at: ~U[2026-08-28 12:00:00Z]
  }
  @unmerged %{
    @blocked
    | action: :discard_unmerged,
      ref: "workspace:unmerged",
      status: :retained,
      summary: "unpublished_unmerged"
  }
  @automatic %{
    @blocked
    | action: nil,
      ref: "workspace:dirty",
      status: :retained,
      summary: "dirty"
  }

  @storage %{
    budget: %{
      disposable_bytes_limit: 10_737_418_240,
      reclaim_target_seconds: 3_600,
      storage_high_watermark_bytes: 64_424_509_440,
      storage_low_watermark_bytes: 48_318_382_080,
      storage_reserve_bytes: 5_368_709_120
    },
    preview: [
      %{
        eligible_age_seconds: 42,
        kind: :work,
        reason: "grace expired; ask Coop for a discard plan",
        ref: "workspace:blocked",
        repository: "responder",
        status: :grace,
        target: "coop-session-1"
      }
    ],
    workers: [
      %{
        allocation: "refused",
        bytes: %{
          "capacity_bytes" => 536_870_912_000,
          "disposable_bytes" => 9_663_676_416,
          "free_bytes" => 4_294_967_296,
          "protected_bytes" => 21_474_836_480,
          "reserve_bytes" => 5_368_709_120,
          "unattributed_bytes" => nil
        },
        id: "worker-a",
        last_seen_at: ~U[2026-08-28 12:00:00Z],
        measured_at: "2026-08-28T12:00:00Z",
        measurement: :fresh,
        reclaimed_bytes: 1_073_741_824,
        refusal_reason: "reserve_exhausted",
        state: :busy
      }
    ]
  }

  test "the workspaces page is help, one quiet count, the working copies, then storage and the cleanup preview" do
    # Before 2026-09-13 the body was two bordered panels each opening with its
    # own h2 ("Repository working copies", "Workspace storage") under the
    # shell's "Workspaces", with the safety explanation as a paragraph inside
    # the first panel and the storage caveats inside the second.
    document = render([@blocked, @unmerged, @automatic], @storage)

    assert outline(document, "div.workspaces-page > *") == [
             "details.page-help",
             "p.result-count",
             "table.data-table",
             "section.workspace-storage",
             "section.cleanup-preview"
           ]

    assert LazyHTML.query(document, "p.result-count") |> LazyHTML.text() == "3 working copies"

    assert Enum.empty?(
             LazyHTML.query(document, "h1, .page-description, .table-wrap, form.filter-toolbar")
           )

    assert LazyHTML.query(document, "h2") |> LazyHTML.text() ==
             "Worker storageNext cleanup targets"

    refute LazyHTML.text(document) =~ "Repository working copies"

    help = LazyHTML.query(document, "details.page-help#workspaces-help:not([open])")

    assert LazyHTML.query(help, "summary") |> LazyHTML.text() ==
             "How working copies are kept and cleaned up"

    assert LazyHTML.text(help) =~ "not Slack workspaces"
    assert LazyHTML.text(help) =~ "discarding unmerged commits always requires confirmation"
    assert LazyHTML.text(help) =~ "A worker that reported nothing is unknown, not empty"

    storage = LazyHTML.query(document, "section.workspace-storage")
    assert LazyHTML.text(storage) =~ "10.00 GiB of inactive disposable forks per worker"
    assert LazyHTML.text(storage) =~ "3600 seconds"

    assert LazyHTML.query(storage, "table.data-table thead th") |> LazyHTML.text() ==
             "WorkerMeasurementDisposableProtectedUnattributedReclaimedNew forks"

    preview = LazyHTML.query(document, "section.cleanup-preview")
    assert LazyHTML.text(preview) =~ "Nothing here is deleted by looking at it"

    assert LazyHTML.query(preview, "table.data-table thead th") |> LazyHTML.text() ==
             "Working copyKindWhat cleanup will doEligible for"

    assert LazyHTML.query(preview, "td[data-label='Eligible for']") |> LazyHTML.text() == "42 s"
  end

  test "cleanup actions stay confirmed GET buttons with their exact target and never a direct POST" do
    # Moving the action into a comparison table is not permission to drop the
    # two-step confirmation: the button opens the confirmation page, and only
    # its CSRF-protected POST performs the discard or the resume.
    document = render([@blocked, @unmerged, @automatic], @storage)
    assert Enum.empty?(LazyHTML.query(document, "form[method=post]"))
    assert Enum.empty?(LazyHTML.query(document, "a[href^='/actions/']"))

    resume =
      LazyHTML.query(
        document,
        "td[data-label='Action'] form.action-control[method=get][action='/actions/retention/workspace%3Ablocked/rearm'] button[type=submit]"
      )

    assert LazyHTML.text(resume) == "Resume cleanup"
    assert LazyHTML.attribute(resume, "class") == ["ui-button primary"]

    discard =
      LazyHTML.query(
        document,
        "form.action-control[method=get][action='/actions/retention/workspace%3Aunmerged/discard'] button[type=submit]"
      )

    assert LazyHTML.text(discard) == "Discard unmerged"
    assert LazyHTML.attribute(discard, "class") == ["ui-button danger"]

    actions = LazyHTML.query(document, "td[data-label='Action']") |> LazyHTML.text()
    assert actions =~ "Managed automatically"
  end

  test "a working copy row reads its lifecycle as a word, keeps the request link and its exact reference" do
    document = render([@blocked, @unmerged, @automatic], @storage)
    rows = LazyHTML.query(document, "div.workspaces-page > table.data-table tbody tr")

    assert LazyHTML.query(rows, "td[data-label='Lifecycle'] .ui-status") |> LazyHTML.text() ==
             "Cleanup needs attentionChanges preservedChanges preserved"

    first =
      LazyHTML.query(document, "div.workspaces-page > table.data-table tbody tr:first-child")

    assert LazyHTML.query(first, "td[data-label='Lifecycle'] .ui-status")
           |> LazyHTML.attribute("class") == ["ui-status status-attention"]

    identity = LazyHTML.query(first, "td.row-identity")
    assert LazyHTML.query(identity, "strong") |> LazyHTML.text() == "responder"

    assert LazyHTML.query(identity, "a.workspace-request-title[href='/timeline/episode%3Aone']")
           |> LazyHTML.text() == "Fix the build"

    assert LazyHTML.query(identity, "code") |> LazyHTML.text() == "workspace:blocked"

    assert LazyHTML.query(first, "td[data-label='What happens next']") |> LazyHTML.text() =~
             "could not finish this step"

    assert LazyHTML.query(first, "td[data-label='Request']") |> LazyHTML.text() == "Completed"

    assert LazyHTML.query(first, "td[data-label='Updated'] time") |> LazyHTML.text() ==
             "28 Aug, 12:00 UTC"

    unmerged =
      LazyHTML.query(
        document,
        "div.workspaces-page > table.data-table tbody tr:nth-child(2) td[data-label='What happens next']"
      )

    assert LazyHTML.text(unmerged) =~ "Unmerged commits are being kept safe"
  end

  test "an empty working-copy list still reports storage and the cleanup preview honestly" do
    document = render([], %{@storage | preview: [], workers: []})
    assert LazyHTML.query(document, "p.empty-state") |> LazyHTML.text() =~ "No working copies"
    assert Enum.empty?(LazyHTML.query(document, "p.result-count, div.workspaces-page > table"))

    assert LazyHTML.text(LazyHTML.query(document, "section.workspace-storage")) =~
             "No fleet worker has reported storage"

    assert LazyHTML.text(LazyHTML.query(document, "section.cleanup-preview")) =~
             "Nothing is eligible for cleanup"

    refute LazyHTML.text(document) =~ "durable records"
  end

  test "storage keeps unknown and stale measurements distinct from zero and names a refusal" do
    # Responder never estimates a byte no worker measured: a missing report is
    # unknown, not 0.00 GiB, and a stale heartbeat is a stale measurement.
    unknown = %{
      hd(@storage.workers)
      | measurement: :unknown,
        bytes: %{},
        reclaimed_bytes: nil,
        allocation: nil
    }

    stale = %{hd(@storage.workers) | id: "worker-b", measurement: :stale, allocation: "open"}
    document = render([], %{@storage | workers: [unknown, stale]})
    rows = LazyHTML.query(document, "section.workspace-storage tbody tr")

    assert LazyHTML.query(rows, "td[data-label='Measurement']") |> LazyHTML.text() ==
             "no measurement reportedstale (worker heartbeat is stale)"

    assert LazyHTML.query(rows, "td[data-label='Disposable']") |> LazyHTML.text() ==
             "unknown9.00 GiB"

    assert LazyHTML.query(rows, "td[data-label='New forks']") |> LazyHTML.text() ==
             "unknownaccepted"

    refused = render([], @storage)

    assert LazyHTML.query(refused, "td[data-label='New forks']") |> LazyHTML.text() ==
             "refused: reserve_exhausted"
  end

  test "the route renders the shell's title and description around one body" do
    page =
      Router.snapshot("/workspaces", "", %{
        projection: %{
          workspaces: fn _params -> [@blocked] end,
          workspace_storage: fn -> @storage end
        }
      })

    assert page.title == "Workspaces"
    assert page.description =~ "not Slack workspaces"
    document = LazyHTML.from_fragment(page.body)
    assert Enum.count(LazyHTML.query(document, "div.workspaces-page")) == 1
    assert Enum.count(LazyHTML.query(document, "form.action-control")) == 1
  end

  defp render(rows, storage) do
    rows |> HTML.workspaces(storage) |> IO.iodata_to_binary() |> LazyHTML.from_fragment()
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
