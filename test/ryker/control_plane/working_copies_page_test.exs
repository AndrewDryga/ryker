defmodule Ryker.ControlPlane.WorkingCopiesPageTest do
  @moduledoc """
  The Working copies page: one storage line per worker, the repository
  checkouts tasks work in as Kit rows with their confirmed cleanup actions,
  what is ready for cleanup now, and removed copies behind one closed
  disclosure.
  """
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.{Pages, WorkingCopiesPage}

  @now ~U[2026-08-28 14:00:00Z]

  @blocked %{
    action: :rearm,
    discard_after: nil,
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
      },
      %{
        eligible_age_seconds: 42,
        kind: :learning,
        reason: "Close the worker session again",
        ref: "ryker-learning:one",
        repository: "Background learning",
        status: :close_pending,
        target: "coop-session-2"
      }
    ],
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

  test "the page is storage, the copies, what is ready for cleanup, then removed copies" do
    # Before 2026-09-24 the page opened with a help disclosure explaining that
    # these are "not Slack workspaces", then three tables. The new name makes
    # the disclaimer unnecessary; the lists are rows.
    document = render([@blocked, @unmerged, @removed])

    assert outline(document, "div.working-copies-page > *") == [
             "section.working-copies-storage",
             "div.entity-list",
             "section.working-copies-section",
             "details.working-copies-history"
           ]

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
        "[id='copy-workspace:blocked'] .entity-actions form.action-control[method=get][action='/actions/retention/workspace%3Ablocked/rearm'] button[type=submit]"
      )

    assert LazyHTML.text(resume) == "Resume cleanup"
    assert LazyHTML.attribute(resume, "class") == ["ui-button secondary"]

    discard =
      LazyHTML.query(
        document,
        "form.action-control[method=get][action='/actions/retention/workspace%3Aunmerged/discard'] button[type=submit]"
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

    request = LazyHTML.query(blocked, "p.entity-text a[href='/timeline/episode%3Aone']")
    assert LazyHTML.text(request) == "Fix the build"

    assert meta(blocked) ==
             "the worker could not finish this step; check the saved error before resuming · updated 2 h ago"

    assert meta(unmerged) =~ "has commits that were never merged, kept until you discard them"
    assert meta(dirty) =~ "has uncommitted changes, kept until they are safe to remove"
    assert meta(kept) =~ "removed after tomorrow 09:00"
    assert meta(active) =~ "cleanup starts when the task ends"

    # The working copy's id is for support, so it waits in the closed Details.
    refute blocked |> LazyHTML.query("p") |> LazyHTML.text() =~ "workspace:blocked"

    assert LazyHTML.query(blocked, "details:not([open]) code") |> LazyHTML.text() ==
             "workspace:blocked"
  end

  test "two requests in one repository stay distinguishable before cleanup" do
    rows =
      for title <- ["Investigate portal errors", "Update runner version"] do
        %{@removed | episode_ref: title, ref: title, request_title: title}
      end

    html = rows |> render() |> LazyHTML.to_html()
    assert html =~ ">Investigate portal errors</a>"
    assert html =~ ">Update runner version</a>"
  end

  test "a copy never presents its repository name as the reason it is kept" do
    # The projection falls back to the repository ref when no cleanup reason
    # is recorded; that fallback is not a reason and is never shown as one.
    document = render([%{@kept | status: :retained}])
    assert meta(LazyHTML.query(document, "article.entity-row")) =~ "kept until cleanup is safe"
  end

  test "background learning sessions are never listed as working copies" do
    # They share the cleanup custody but hold no repository checkout; until
    # 2026-09-24 they sat here under "Background learning". The Learning page
    # lists them now.
    learning = %{
      @blocked
      | action: nil,
        episode_ref: nil,
        execution_kind: :learning,
        ref: "ryker-learning:one",
        repository: "Background learning",
        status: :active
    }

    document = render([learning, @blocked])
    assert Enum.count(LazyHTML.query(document, "article.entity-row[id^=copy-]")) == 1
    refute LazyHTML.text(document) =~ "Background learning"

    ready = render([]) |> LazyHTML.query("#ready-for-cleanup article.entity-row")
    assert Enum.count(ready) == 1
    assert LazyHTML.text(ready) =~ "acme/checkout-api"
    assert LazyHTML.text(ready) =~ "The follow-up window ended; close the worker session"
    assert LazyHTML.text(ready) =~ "ready for 7 minutes"
    refute LazyHTML.text(ready) =~ "Background learning"
  end

  test "removed copies stay out of the current list and wait in a closed history" do
    document = render([@blocked, @removed])

    assert Enum.count(
             LazyHTML.query(document, "div.working-copies-page > .entity-list > article")
           ) == 1

    history = LazyHTML.query(document, "details#removed-copies:not([open])")

    assert LazyHTML.query(history, "details#removed-copies > summary") |> LazyHTML.text() ==
             "Removed copies (1)"

    assert LazyHTML.query(history, ".state-word") |> LazyHTML.text() == "Removed"
  end

  test "storage says plainly what each worker measured, and never invents a byte" do
    # A missing report is unknown, not 0 GiB, and a stale heartbeat is a
    # stale measurement.
    storage = render([]) |> LazyHTML.query("section.working-copies-storage")

    assert storage |> LazyHTML.query("#storage-worker-a") |> LazyHTML.text() |> squeeze() ==
             "worker-a 20 GiB kept, 9 GiB disposable of 10 GiB · measured 2 min ago · 1 GiB freed so far · not taking new copies (reserve exhausted)"

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
    assert stale_line =~ "unknown kept, 0 GiB disposable of 10 GiB"
    assert stale_line =~ "this report is out of date"
    refute stale_line =~ "not taking new copies"

    none = render([], %{@storage | workers: [], preview: [], budget: %{}})

    assert LazyHTML.query(none, "section.working-copies-storage") |> LazyHTML.text() =~
             "No worker has reported storage yet"

    assert LazyHTML.query(none, ".entity-empty-title") |> LazyHTML.text() =~
             "No working copies right now."

    assert LazyHTML.text(none) =~ "Nothing is ready for cleanup right now."
  end

  test "the route renders the working copies under their own name" do
    page =
      Pages.page(["working-copies"], %{}, %{
        projection: %{
          workspaces: fn _params -> [@blocked] end,
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

  defp render(rows, storage \\ @storage) do
    %{rows: rows, storage: storage, now: @now}
    |> WorkingCopiesPage.html()
    |> LazyHTML.from_fragment()
  end

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

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
