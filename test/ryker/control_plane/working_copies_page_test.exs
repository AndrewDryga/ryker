defmodule Ryker.ControlPlane.WorkingCopiesPageTest do
  @moduledoc """
  The Working copies page: one storage line per worker, the repository
  checkouts tasks work in as Kit rows with their confirmed cleanup actions,
  what is ready for cleanup now, and removed copies behind one closed
  disclosure.
  """
  use ExUnit.Case, async: true

  import Ryker.TestHelpers, only: [outline: 2]

  alias Ryker.ControlPlane.{PageHelp, Pages, WorkingCopiesPage}

  @now ~U[2026-08-28 14:00:00Z]
  # The request a copy was checked out for, by the id its page is addressed by.
  @request "0193a5d2-7c1e-7b8a-9f00-00000000e01e"

  @blocked %{
    action: :rearm,
    discard_after: nil,
    episode_id: @request,
    episode_ref: "episode:one",
    execution_kind: :work,
    kind: "coop_session",
    ref: "workspace:blocked",
    repository: "acme/checkout-api",
    request_title: "Fix the build",
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
  @dirty %{@blocked | action: nil, ref: "workspace:dirty", status: :retained, summary: "dirty"}
  @kept %{
    @blocked
    | action: nil,
      discard_after: ~U[2026-08-29 09:00:00Z],
      ref: "workspace:kept",
      status: :grace,
      summary: "acme/checkout-api"
  }
  @removed %{@blocked | action: nil, ref: "workspace:removed", status: :discarded}

  @storage %{
    budget: %{disposable_bytes_limit: 10_737_418_240, reclaim_target_seconds: 3_600},
    preview: [
      %{
        eligible_age_seconds: 420,
        kind: :work,
        reason: "The follow-up window ended; close the worker session",
        ref: "workspace:kept",
        repository: "acme/checkout-api",
        status: :grace,
        target: "coop-session-1"
      }
    ],
    preview_total: 1,
    workers: [
      %{
        allocation: "refused",
        bytes: %{
          "disposable_bytes" => 9_663_676_416,
          "protected_bytes" => 21_474_836_480,
          "unattributed_bytes" => nil
        },
        id: "worker-a",
        last_seen_at: ~U[2026-08-28 13:59:00Z],
        measured_at: "2026-08-28T13:58:00Z",
        measurement: :fresh,
        reclaimed_bytes: 1_073_741_824,
        refusal_reason: "reserve_exhausted",
        state: :busy
      }
    ]
  }

  # Andrew, 2026-09-28: "design the bottom half properly". The page reads as
  # every list page does: its counts, the storage line, Current or Removed,
  # and what is ready for cleanup above the current copies when there is any;
  # no closed history under the list.
  test "the page is its counts, storage, the view switch, what is ready, then the copies" do
    # Before 2026-09-24 the page opened with a help disclosure explaining that
    # these are "not Slack workspaces", then three tables. The new name makes
    # the disclaimer unnecessary; the lists are rows.
    document = render([@blocked, @unmerged, @removed])

    assert outline(document, "div.working-copies-page > *") == [
             "p.kit-counts",
             "section.working-copies-storage",
             "div.kit-toolbar",
             "section.working-copies-section",
             "div.entity-list"
           ]

    assert document
           |> LazyHTML.query(".kit-counts .kit-count")
           |> Enum.map(&squeeze(LazyHTML.text(&1))) ==
             ["2 copies in use", "1 ready for cleanup", "1 removed"]

    assert LazyHTML.query(document, "nav.segmented a") |> LazyHTML.attribute("href") == [
             "/working-copies",
             "/working-copies?view=removed"
           ]

    assert Enum.empty?(LazyHTML.query(document, "details"))

    assert Enum.empty?(LazyHTML.query(document, "table, .page-help, .result-count"))
    refute LazyHTML.text(document) =~ "Slack workspaces"

    assert LazyHTML.query(document, "#ready-for-cleanup h2") |> LazyHTML.text() ==
             "Ready for cleanup"
  end

  test "cleanup actions stay confirmed GET buttons with their exact target and never a direct POST" do
    # A row is not permission to drop the two-step confirmation: the button
    # opens the confirmation page, and only its CSRF-protected POST performs
    # the discard or the resume.
    document = render([@blocked, @unmerged, @dirty])
    assert Enum.empty?(LazyHTML.query(document, "form[method=post]"))
    assert Enum.empty?(LazyHTML.query(document, "a[href^='/actions/']"))

    resume =
      LazyHTML.query(
        document,
        "[id='copy-workspace:blocked'] .entity-actions form.action-control[method=get][action='/actions/retention/workspace:blocked/rearm'] button[type=submit]"
      )

    assert LazyHTML.text(resume) == "Resume cleanup"
    assert LazyHTML.attribute(resume, "class") == ["ui-button secondary"]

    discard =
      LazyHTML.query(
        document,
        "form.action-control[method=get][action='/actions/retention/workspace:unmerged/discard'] button[type=submit]"
      )

    assert LazyHTML.text(discard) == "Discard unmerged"
    assert LazyHTML.attribute(discard, "class") == ["ui-button danger"]

    assert Enum.empty?(LazyHTML.query(document, "[id='copy-workspace:dirty'] .entity-actions"))
  end

  test "a copy names its repository, links its request and says what cleanup does next" do
    rows =
      [@blocked, @unmerged, @dirty, @kept, %{@blocked | status: :active, action: nil}]
      |> render()
      |> LazyHTML.query("div.working-copies-page > .entity-list > article.entity-row")

    assert Enum.map(rows, fn row ->
             state = LazyHTML.query(row, ".state-word")
             {LazyHTML.text(state), LazyHTML.attribute(state, "data-tone")}
           end) == [
             {"Cleanup needs attention", ["warn"]},
             {"Changes kept", ["warn"]},
             {"Changes kept", ["warn"]},
             {"Kept for follow-up", ["off"]},
             {"In use", ["busy"]}
           ]

    [blocked, unmerged, dirty, kept, active] = Enum.to_list(rows)
    assert LazyHTML.query(blocked, "h3.entity-name") |> LazyHTML.text() =~ "acme/checkout-api"

    request = LazyHTML.query(blocked, "p.entity-text a[href='/timeline/#{@request}']")
    assert LazyHTML.text(request) == "Fix the build"

    assert meta(blocked) ==
             "the worker could not finish this step; check the saved error before resuming · updated 2 h ago"

    assert meta(unmerged) =~ "has commits that were never merged, kept until you discard them"
    assert meta(dirty) =~ "has uncommitted changes, kept until they are safe to remove"
    assert meta(kept) =~ "removed after tomorrow 09:00"
    assert meta(active) =~ "cleanup starts when the task ends"

    # The working copy's id is support plumbing; the row never shows it.
    refute LazyHTML.text(blocked) =~ "workspace:blocked"
  end

  test "two requests in one repository stay distinguishable before cleanup" do
    rows =
      for title <- ["Investigate portal errors", "Update runner version"] do
        %{@removed | episode_id: Ecto.UUID.generate(), ref: title, request_title: title}
      end

    html = rows |> render(@storage, "removed") |> LazyHTML.to_html()
    assert html =~ ">Investigate portal errors</a>"
    assert html =~ ">Update runner version</a>"
  end

  test "a copy never presents its repository name as the reason it is kept" do
    # The projection falls back to the repository ref when no cleanup reason
    # is recorded; that fallback is not a reason and is never shown as one.
    document = render([%{@kept | status: :retained}])
    assert meta(LazyHTML.query(document, "article.entity-row")) =~ "kept until cleanup is safe"
  end

  test "a copy ready for cleanup names its repository, what cleanup does and how long it waited" do
    ready = render([]) |> LazyHTML.query("#ready-for-cleanup article.entity-row")
    assert Enum.count(ready) == 1
    assert LazyHTML.text(ready) =~ "acme/checkout-api"
    assert LazyHTML.text(ready) =~ "The follow-up window ended; close the worker session"
    assert LazyHTML.text(ready) =~ "ready for 7 minutes"
  end

  # The list stopped at the next 25 and the count above it said 25, however many were due
  # (2026-10-04 review).
  test "a cut list of copies ready for cleanup says how many are due" do
    document = render([], %{@storage | preview_total: 40})

    assert document |> LazyHTML.query("#ready-for-cleanup .section-head p") |> LazyHTML.text() =~
             "the next 1 of 40"

    assert document |> LazyHTML.query(".kit-count") |> Enum.map(&squeeze(LazyHTML.text(&1))) ==
             ["0 copies in use", "40 ready for cleanup", "0 removed"]
  end

  test "removed copies stay out of the current list and have a view of their own" do
    document = render([@blocked, @removed])

    assert Enum.count(
             LazyHTML.query(document, "div.working-copies-page > .entity-list > article")
           ) == 1

    refute LazyHTML.text(document) =~ "Removed copies"

    removed = render([@blocked, @removed], @storage, "removed")
    rows = LazyHTML.query(removed, "div.working-copies-page > .entity-list > article")
    assert Enum.count(rows) == 1
    assert LazyHTML.query(rows, ".state-word") |> LazyHTML.text() == "Removed"

    assert LazyHTML.query(removed, "nav.segmented a[aria-current=page]") |> LazyHTML.text() ==
             "Removed"

    assert render([@blocked], @storage, "removed")
           |> LazyHTML.query(".kit-empty-title")
           |> LazyHTML.text() ==
             "No removed copies yet"
  end

  # QA re-test, 2026-09-26: "0.54 GiB in use" still sat beside "No working
  # copies right now" with nothing saying what used the space.
  test "space in use with no working copies says what holds it" do
    empty = render([]) |> LazyHTML.query("section.working-copies-storage") |> LazyHTML.text()
    assert squeeze(empty) =~ "No working copy holds this space"

    with_copy = render([@blocked]) |> LazyHTML.query("section.working-copies-storage")
    refute LazyHTML.text(with_copy) =~ "No working copy holds this space"
  end

  test "storage says plainly what each worker measured, and never invents a byte" do
    # A missing report is unknown, not 0 GiB, and a stale heartbeat is a
    # stale measurement. QA, 2026-09-25: "0.16 GiB kept" sat beside "No
    # working copies right now"; the worker's figure also counts its shared
    # checkouts and its own data, so it is what the worker uses, not copies
    # kept.
    storage = render([]) |> LazyHTML.query("section.working-copies-storage")

    assert storage |> LazyHTML.query("#storage-worker-a") |> LazyHTML.text() |> squeeze() ==
             "worker-a 20 GiB in use, 9 GiB can be freed of 10 GiB allowed · measured 2 min ago · 1 GiB freed so far · not taking new copies (reserve exhausted)"

    assert LazyHTML.text(storage) =~ "Ryker cleans up copies that are ready within 1 hour."

    worker = hd(@storage.workers)
    unknown = %{worker | measurement: :unknown, bytes: %{}, measured_at: nil, allocation: nil}

    stale = %{
      worker
      | id: "worker-b",
        measurement: :stale,
        allocation: "open",
        bytes: %{"protected_bytes" => nil, "disposable_bytes" => 0}
    }

    document = render([], %{@storage | workers: [unknown, stale]})

    assert document |> LazyHTML.query("#storage-worker-a") |> LazyHTML.text() |> squeeze() ==
             "worker-a has not reported storage yet."

    stale_line = document |> LazyHTML.query("#storage-worker-b") |> LazyHTML.text() |> squeeze()
    assert stale_line =~ "unknown in use, 0 GiB can be freed of 10 GiB allowed"
    assert stale_line =~ "this report is out of date"
    refute stale_line =~ "not taking new copies"

    none = render([], %{@storage | workers: [], preview: [], budget: %{}})

    assert LazyHTML.query(none, "section.working-copies-storage") |> LazyHTML.text() =~
             "No worker has reported storage yet"

    assert LazyHTML.query(none, ".kit-empty-title") |> LazyHTML.text() =~
             "No working copies right now"

    # Nothing ready for cleanup is no section at all, not an empty box.
    assert Enum.empty?(LazyHTML.query(none, "#ready-for-cleanup"))
  end

  test "the help names a worker's storage in the words its storage line uses" do
    # QA, 2026-09-25: storage read "0.16 GiB kept" beside "No working copies
    # right now". The line was reworded to what the worker measures ("in use",
    # "can be freed", "allowed"), but the page's help still said "what is
    # kept, what can be removed", sending the reader back to the old word.
    storage =
      PageHelp.for_path("/working-copies").sections
      |> Enum.find(&(&1.heading == "Storage"))
      |> Map.fetch!(:paragraphs)
      |> Enum.join(" ")

    line = render([]) |> LazyHTML.query("#storage-worker-a") |> LazyHTML.text() |> squeeze()

    for words <- ["in use", "can be freed", "allowed"], do: assert(line =~ words)

    # The help speaks of the limit, and in the line's own word for it.
    assert storage =~ "allowed"
    refute storage =~ "kept"
  end

  test "the route renders the working copies under their own name" do
    page =
      Pages.page(["working-copies"], %{}, %{
        projection: %{
          working_copies: fn _params ->
            %{
              current: [@blocked],
              removed: %{key: "page", items: [], total: 0, page: 1, pages: 1}
            }
          end,
          workspace_storage: fn -> @storage end
        }
      })

    assert page.title == "Working copies"

    assert page.description ==
             "Copies of repositories Ryker checks out while it works, and how it cleans them up."

    document = LazyHTML.from_fragment(page.body)
    assert Enum.count(LazyHTML.query(document, "div.working-copies-page")) == 1
    assert Enum.count(LazyHTML.query(document, "form.action-control")) == 1
    refute page.body =~ "not Slack workspaces"
  end

  defp meta(row), do: row |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze()

  # The page's copies as `WorkspaceProjection.copies/1` reads them: the ones in use, and one
  # page of the removed ones.
  defp render(rows, storage \\ @storage, view \\ "current") do
    {removed, current} = Enum.split_with(rows, &(&1.status == :discarded))
    page = %{key: "page", items: removed, total: length(removed), page: 1, pages: 1}

    %{copies: %{current: current, removed: page}, storage: storage, now: @now, view: view}
    |> WorkingCopiesPage.html()
    |> LazyHTML.from_fragment()
  end

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
