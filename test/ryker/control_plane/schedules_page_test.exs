defmodule Ryker.ControlPlane.SchedulesPageTest do
  @moduledoc """
  Automations › Schedules: the list of tasks Ryker runs at a set time and one
  schedule's own page, both in words a person uses — how often in the
  schedule's own time zone, where results go, what each run did — with raw
  references kept in one closed Details disclosure.
  """
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.{PageHelp, Pages, SchedulesPage}
  alias Ryker.Fixtures.ControlPlaneOptions

  @now ~U[2026-09-24 10:00:00Z]
  # The request the schedule was set up in.
  @source_id "0193a5d2-7c1e-7b8a-9f00-00000000500c"

  @item %{
    authority: :read_only,
    destination_conversation_ref: "slack:T123:C456",
    destination_thread_ref: nil,
    destination_transport: "slack",
    expires_at: nil,
    expires_local: nil,
    failures: 0,
    next_local: ~N[2026-09-25 09:00:00],
    next_occurrence_at: ~U[2026-09-25 07:00:00Z],
    now_local: ~N[2026-09-24 12:00:00],
    once_local: nil,
    recurrence: %{"kind" => "daily", "time" => "09:00:00"},
    ref: "schedule:one",
    repository: "acme/api",
    status: :active,
    task: "Summarize unresolved incidents.\nKeep it short.",
    timezone: "Europe/Berlin",
    title: "Morning incident summary",
    updated_at: ~U[2026-09-20 08:00:00Z]
  }

  describe "fixed defects" do
    test "a schedule's destination names the channel once, never a doubled transport prefix" do
      # The schedule page printed "slack:slack:T123:C456 / 1787832000.001000":
      # the transport glued onto a reference that already carries it, then the
      # thread's raw timestamp. People know a channel by its name.
      page = Pages.page(["schedules", "one"], %{}, fixture())

      refute page.body =~ "slack:slack:"
      refute page.body =~ "1787832000.001000"

      assert page.body
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("dl.kit-facts a[href='/channels/T123/C456']")
             |> LazyHTML.text() == "Slack channel C456"
    end

    test "a run reads as one plain state word, never the raw episode and turn states" do
      # The execution column printed "complete / settled" straight from two
      # enums, beside "Dispatched" from a third, so nobody could tell whether
      # the run had worked.
      page = Pages.page(["schedules", "one"], %{}, fixture())
      run = page.body |> LazyHTML.from_fragment() |> LazyHTML.query(".schedule-runs .entity-row")

      assert LazyHTML.query(run, ".entity-side .state-word") |> LazyHTML.text() == "Completed"
      assert words(LazyHTML.query(run, ".entity-meta")) == "Scheduled · took 25 s · 2 attempts"
      refute page.body =~ "complete / settled"
      refute page.body =~ "Dispatched"
    end

    test "a full list says it shows only the first 100 schedules" do
      # The list stopped at 100 rows without a word, so a schedule past the
      # cut looked as if it did not exist.
      options = fixture()
      [item] = options.projection.schedules.(%{})

      items =
        for index <- 1..100, do: %{item | ref: "schedule:#{index}", title: "Schedule #{index}"}

      options = put_in(options, [:projection, :schedules], fn _params -> items end)

      assert Pages.page(["schedules"], %{}, options).body =~ "Showing the first 100 schedules."
    end
  end

  describe "the list" do
    # QA re-test, 2026-09-26: "next run 28 Sep, 09:00" sat beside "Every
    # weekday at 09:00 UTC" with no zone of its own, so a reader could not
    # tell whose 09:00 it was.
    test "a row names what it asks for, how often in its own zone, where results go and the next run" do
      row = list_row(@item)

      assert LazyHTML.query(row, ".entity-name a[href='/schedules/one']")
             |> LazyHTML.text() == "Morning incident summary"

      # The whole row opens the schedule, and its state sits at the far edge.
      assert LazyHTML.attribute(row, "class") |> hd() =~ "entity-row-link"

      assert LazyHTML.query(row, ".entity-side .state-word[data-tone=on]") |> LazyHTML.text() ==
               "On"

      # The first line of the task; the rest is on the schedule's own page.
      assert LazyHTML.query(row, ".entity-text") |> LazyHTML.text() ==
               "Summarize unresolved incidents."

      assert words(LazyHTML.query(row, ".entity-meta")) ==
               "Every day at 09:00 Berlin time · in Slack channel C456 · next run tomorrow 09:00 Berlin time · repository acme/api"

      next = LazyHTML.query(row, ".entity-meta time")
      assert LazyHTML.attribute(next, "datetime") == ["2026-09-25T07:00:00Z"]
      assert LazyHTML.attribute(next, "title") == ["25 Sep 2026, 07:00 UTC"]
      refute LazyHTML.text(row) =~ "schedule:one"
    end

    test "each state is a word people use, and only a running schedule promises a next run" do
      for {status, tone, word} <- [
            {:active, "on", "On"},
            {:paused, "off", "Paused"},
            {:completed, "off", "Done"},
            {:expired, "off", "Expired"},
            {:deleted, "off", "Deleted"}
          ] do
        row = list_row(%{@item | status: status})

        state = LazyHTML.query(row, ".entity-side .state-word")

        assert LazyHTML.text(state) == word
        assert LazyHTML.attribute(state, "data-tone") == [tone]
        assert words(LazyHTML.query(row, ".entity-meta")) =~ "next run" == (status == :active)
      end
    end

    # Andrew, 2026-09-28: "same issue on many other pages". A row opens its
    # schedule from anywhere on the row and carries no buttons; Run now, Pause
    # and Resume sit opposite the schedule's title, and Delete is its page's
    # last card while the schedule can still change.
    test "a row carries no buttons; the schedule's page offers its actions" do
      for {status, controls, deletable} <- [
            {:active, ["Run now", "Pause"], true},
            {:paused, ["Run now", "Resume"], true},
            {:completed, ["Run now"], false},
            {:expired, [], false},
            {:deleted, [], false}
          ] do
        schedule = %{@item | status: status}
        row = list_row(schedule)
        assert Enum.empty?(LazyHTML.query(row, ".entity-actions, button, details"))

        header =
          case SchedulesPage.actions(schedule) do
            nil -> []
            html -> html |> LazyHTML.from_fragment() |> LazyHTML.query("button")
          end

        assert Enum.map(header, &LazyHTML.text/1) == controls

        delete =
          snapshot(%{status: status})
          |> detail()
          |> LazyHTML.query(
            "#delete-schedule form[action='/actions/schedule/one/deleted'] button.danger"
          )

        assert Enum.count(delete) == if(deletable, do: 1, else: 0)
      end
    end

    test "failed starts show as a warning on the row" do
      assert list_row(%{@item | failures: 2})
             |> LazyHTML.query(".entity-meta .schedule-warning")
             |> LazyHTML.text() == "failed to start 2 times"

      assert list_row(%{@item | failures: 1})
             |> LazyHTML.query(".entity-meta .schedule-warning")
             |> LazyHTML.text() == "failed to start once"

      assert Enum.empty?(LazyHTML.query(list_row(@item), ".schedule-warning"))
    end

    # Manual testing, 2026-09-26: a schedule the scheduler had not started
    # for a month still read "next run 28 Aug" on 26 Sep, as if it were
    # coming up; a run that did not start when due is a problem to notice.
    test "a run that did not start when due reads as overdue, not as coming up" do
      overdue = %{
        @item
        | next_local: ~N[2026-08-28 09:00:00],
          next_occurrence_at: ~U[2026-08-28 07:00:00Z],
          repository: nil
      }

      assert words(LazyHTML.query(list_row(overdue), ".entity-meta")) ==
               "Every day at 09:00 Berlin time · in Slack channel C456 · was due 28 Aug, 09:00 Berlin time"
    end

    test "a direct conversation, a thread and a stop date read as words" do
      direct = %{
        @item
        | destination_transport: "control_plane",
          destination_conversation_ref: "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
          destination_thread_ref: "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
          expires_local: ~N[2026-10-31 09:00:00],
          repository: nil
      }

      assert words(LazyHTML.query(list_row(direct), ".entity-meta")) ==
               "Every day at 09:00 Berlin time · in a direct conversation · next run tomorrow 09:00 Berlin time · stops 31 Oct"

      thread = %{@item | destination_thread_ref: "1787832000.001000", repository: nil}

      assert words(LazyHTML.query(list_row(thread), ".entity-meta")) ==
               "Every day at 09:00 Berlin time · in a thread in Slack channel C456 · next run tomorrow 09:00 Berlin time"
    end

    test "the list offers Current and Past, keeps the search across both, and says how to add one" do
      parent = self()

      options = %{
        projection: %{
          schedules: fn params ->
            send(parent, {:schedules, params})
            [%{@item | status: :completed}]
          end
        }
      }

      page =
        Pages.page(["schedules"], %{"q" => "incident", "view" => "past", "page" => "2"}, options)

      assert_received {:schedules, %{"q" => "incident", "view" => "past"} = params}
      assert map_size(params) == 2

      assert page.title == "Schedules"
      assert page.description == "Tasks Ryker runs at a set time, once or on repeat."

      document = LazyHTML.from_fragment(page.body)
      toolbar = LazyHTML.query(document, ".schedules-view > .kit-toolbar")
      search = LazyHTML.query(toolbar, "form.filter-toolbar[action='/schedules']")

      assert LazyHTML.query(search, "input[name=q]") |> LazyHTML.attribute("value") == [
               "incident"
             ]

      assert LazyHTML.query(search, "input[type=hidden][name=view]")
             |> LazyHTML.attribute("value") == ["past"]

      assert LazyHTML.query(search, "a.filter-clear") |> LazyHTML.attribute("href") == [
               "/schedules?view=past"
             ]

      segments = LazyHTML.query(toolbar, "nav.segmented a")
      assert Enum.map(segments, &LazyHTML.text/1) == ["Current", "Past"]

      assert LazyHTML.attribute(segments, "href") == [
               "/schedules?q=incident",
               "/schedules?q=incident&view=past"
             ]

      assert LazyHTML.query(toolbar, "nav.segmented a[aria-current=page]") |> LazyHTML.text() ==
               "Past"

      # How to ask for a schedule is the page's help now, not a line under
      # the list. Every Monday, not every weekday: a schedule repeats on one
      # day of the week, so the example is one Ryker can actually save.
      assert Enum.empty?(LazyHTML.query(document, ".ask-hint, .page-help, table, select, h1"))

      help = PageHelp.for_path("/schedules")
      text = Enum.map_join(help.sections, " ", &Enum.join(&1.paragraphs, " "))

      assert text =~
               ~s("Every Monday at 09:00 Berlin time, summarize unresolved incidents in this channel.")
    end

    test "an unknown view is the current list" do
      parent = self()

      options = %{
        projection: %{schedules: fn params -> send(parent, {:schedules, params}) && [] end}
      }

      Pages.page(["schedules"], %{"view" => "everything"}, options)
      assert_received {:schedules, %{"view" => "current"}}
    end

    test "an empty list says what would put a schedule there, and a search miss says it missed" do
      for {params, title, text} <- [
            {%{}, "Nothing is scheduled",
             "A schedule appears here once you ask Ryker to run something at a set time and confirm it."},
            {%{"view" => "past"}, "No past schedules",
             "Schedules move here when they finish, expire or are deleted."},
            {%{"q" => "absent"}, ~s(No schedules match "absent"),
             "Try other words, or look under Past."},
            {%{"q" => "absent", "view" => "past"}, ~s(No schedules match "absent"),
             "Try other words, or look under Current."}
          ] do
        page = Pages.page(["schedules"], params, %{projection: %{schedules: fn _ -> [] end}})
        empty = page.body |> LazyHTML.from_fragment() |> LazyHTML.query(".kit-empty")
        assert LazyHTML.query(empty, ".kit-empty-title") |> LazyHTML.text() == title
        assert LazyHTML.text(empty) =~ text
      end
    end
  end

  describe "a schedule's page" do
    test "facts, what it asks for, its runs, one closed Details disclosure, then Delete, in that order" do
      document = detail(snapshot())

      assert LazyHTML.query(document, ".kit-status-line .state-word[data-tone=on]")
             |> LazyHTML.text() == "On"

      assert facts(document) == [
               {"How often", "Every day at 09:00 Berlin time"},
               {"Where results go", "Slack channel C456 · in a thread"},
               {"Repository", "acme/api"},
               {"What it may do", "Read only"},
               {"Next run", "tomorrow 09:00 Berlin time"},
               {"Stops", "Never"},
               {"Started from", "Set up the morning summary"}
             ]

      assert LazyHTML.query(document, "dl.kit-facts a[href='/timeline/#{@source_id}']")
             |> LazyHTML.text() == "Set up the morning summary"

      assert LazyHTML.query(document, ".section-head h2") |> Enum.map(&LazyHTML.text/1) == [
               "What it asks for",
               "Runs",
               "Delete schedule"
             ]

      assert LazyHTML.query(document, "p.schedule-task") |> LazyHTML.text() ==
               "Summarize unresolved incidents.\nKeep it short."

      details = LazyHTML.query(document, "details#schedule-details:not([open])")
      assert LazyHTML.query(details, "summary") |> LazyHTML.text() |> String.trim() == "Details"

      assert details
             |> LazyHTML.query("button[data-copy-value]")
             |> LazyHTML.attribute("data-copy-value") ==
               ["schedule:one", @source_id, "stored diagnostic sha256:abc"]

      assert LazyHTML.text(details) =~ "Europe/Berlin"

      # Outside Details the page carries no reference, revision or digest.
      outside = document |> LazyHTML.query(".schedule-view > :not(details)") |> LazyHTML.text()
      refute outside =~ "schedule:one"
      refute outside =~ @source_id
      refute outside =~ "sha256"
    end

    test "each run says what happened in words, newest first, and opens its own timeline" do
      document = detail(snapshot())
      runs = LazyHTML.query(document, ".schedule-runs .entity-row")

      # The rows keep their times short; the list names their zone once.
      assert LazyHTML.text(document) =~ "Newest first. Times are Berlin time."

      assert Enum.map(runs, fn run ->
               {LazyHTML.query(run, ".entity-name time") |> LazyHTML.text(),
                LazyHTML.query(run, ".entity-side .state-word") |> LazyHTML.text(),
                words(LazyHTML.query(run, ".entity-meta"))}
             end) == [
               {"today 09:00", "Running", "Scheduled · started 3 min ago"},
               {"yesterday 09:00", "Failed",
                "Scheduled · took 2 min · 3 attempts · could not reach the worker"},
               {"22 Sep, 09:00", "Missed", "Scheduled · could not start on time"},
               {"21 Sep, 14:12", "Completed", "Run by hand · took 40 s"},
               {"20 Sep, 09:00", "Needs an answer", "Scheduled"},
               {"19 Sep, 09:00", "Failed",
                "Scheduled · The worker did not take or finish one of this task's commands in time."}
             ]

      assert runs
             |> LazyHTML.query(".entity-name a")
             |> LazyHTML.attribute("href")
             |> Enum.take(2) == ["/timeline/#{run_id(4)}", "/timeline/#{run_id(3)}"]

      # A missed run never started, so there is no timeline to open.
      assert runs |> Enum.at(2) |> LazyHTML.query(".entity-name a") |> Enum.empty?()

      assert runs
             |> Enum.at(1)
             |> LazyHTML.query(".state-word")
             |> LazyHTML.attribute("data-tone") ==
               ["bad"]
    end

    test "a paused or finished schedule says when it will run instead of a next run" do
      paused = detail(snapshot(%{status: :paused}))
      assert {"Next run", "None while it is paused"} in facts(paused)
      assert LazyHTML.query(paused, ".kit-status-line .state-word") |> LazyHTML.text() == "Paused"

      done = detail(snapshot(%{status: :completed}))
      labels = done |> facts() |> Enum.map(&elem(&1, 0))
      refute "Next run" in labels
      refute "Stops" in labels
    end

    test "failed starts and a stop date read as words at the top of the page" do
      document =
        detail(snapshot(%{failure_count: 3, expires_local: ~N[2026-10-31 09:00:00]}))

      assert LazyHTML.query(document, ".kit-status-line .schedule-warning") |> LazyHTML.text() ==
               "failed to start 3 times"

      assert {"Stops", "31 Oct, 09:00 Berlin time"} in facts(document)
    end

    test "a schedule that posts in a direct conversation links to that conversation" do
      document =
        snapshot(%{
          destination_transport: "control_plane",
          destination_conversation_ref: "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
          destination_thread_ref: "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
          repository: nil
        })
        |> detail()

      assert LazyHTML.query(
               document,
               "dl.kit-facts a[href='/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6']"
             )
             |> LazyHTML.text() == "A direct conversation"

      refute "Repository" in (document |> facts() |> Enum.map(&elem(&1, 0)))
    end

    test "a schedule with no runs says when the first one is due" do
      document = detail(%{snapshot() | occurrences: []})
      empty = LazyHTML.query(document, ".schedule-runs .kit-empty")
      assert LazyHTML.query(empty, ".kit-empty-title") |> LazyHTML.text() == "No runs yet"
      assert LazyHTML.text(empty) =~ "The first run is due tomorrow 09:00."
    end

    test "the page title is the schedule's title, and its actions sit opposite it" do
      options = %{projection: %{schedule: fn "schedule:one" -> {:ok, snapshot()} end}}
      page = Pages.page(["schedules", "one"], %{}, options)

      assert page.title == "Morning incident summary"
      assert page.description == nil
      assert page.action =~ "Run now"
      refute page.body =~ "Run now"
    end
  end

  defp snapshot(overrides \\ %{}) do
    schedule =
      Map.merge(
        %{
          authority: :read_only,
          confirmed_at: ~U[2026-09-01 08:00:00Z],
          destination_conversation_ref: "slack:T123:C456",
          destination_thread_ref: "1787832000.001000",
          destination_transport: "slack",
          expires_at: nil,
          expires_local: nil,
          failure_count: 0,
          last_error: "stored diagnostic sha256:abc",
          next_local: ~N[2026-09-25 09:00:00],
          next_occurrence_at: ~U[2026-09-25 07:00:00Z],
          now_local: ~N[2026-09-24 12:00:00],
          once_local: nil,
          recurrence: %{"kind" => "daily", "time" => "09:00:00"},
          ref: "schedule:one",
          repository: "acme/api",
          revision: 4,
          source_episode_id: @source_id,
          source_request: %{
            href: "/timeline/#{@source_id}",
            title: "Set up the morning summary"
          },
          status: :active,
          task: "Summarize unresolved incidents.\nKeep it short.",
          timezone: "Europe/Berlin",
          title: "Morning incident summary",
          updated_at: ~U[2026-09-20 08:00:00Z]
        },
        overrides
      )

    %{schedule: schedule, occurrences: runs()}
  end

  defp runs do
    [
      run(4, ~N[2026-09-24 09:00:00], %{
        episode_state: :working,
        turn_status: :pending,
        started_at: DateTime.add(@now, -180),
        work_attempt_count: 1
      }),
      run(3, ~N[2026-09-23 09:00:00], %{
        episode_state: :working,
        turn_status: :blocked,
        started_at: ~U[2026-09-23 07:00:10Z],
        finished_at: ~U[2026-09-23 07:02:10Z],
        failure_code: "coop_unavailable",
        work_attempt_count: 3
      }),
      %{
        run(2, ~N[2026-09-22 09:00:00], %{})
        | status: :missed,
          episode_id: nil,
          missed_reason: "outside_misfire_grace"
      },
      run(1, ~N[2026-09-21 14:12:00], %{
        episode_state: :complete,
        turn_status: :settled,
        trigger: :manual,
        started_at: ~U[2026-09-21 12:12:10Z],
        delivered_at: ~U[2026-09-21 12:12:50Z],
        work_attempt_count: 1
      }),
      run(0, ~N[2026-09-20 09:00:00], %{episode_state: :waiting_for_input}),
      run(9, ~N[2026-09-19 09:00:00], %{
        episode_state: :working,
        turn_status: :blocked,
        failure_code: "coop_worker_command_timeout",
        failure_cause: "The worker did not take or finish one of this task's commands in time."
      })
    ]
  end

  defp run(index, due_local, fields) do
    Map.merge(
      %{
        accepted_at: nil,
        delivered_at: nil,
        due_local: due_local,
        episode_id: run_id(index),
        episode_state: nil,
        failure_cause: nil,
        failure_code: nil,
        failure_detail: nil,
        finished_at: nil,
        missed_reason: nil,
        ref: "schedule-run:#{index}",
        scheduled_for: DateTime.from_naive!(due_local, "Etc/UTC"),
        started_at: nil,
        status: :dispatched,
        trigger: :scheduled,
        turn_status: nil,
        work_attempt_count: nil
      },
      fields
    )
  end

  defp run_id(index), do: "0193a5d2-7c1e-7b8a-9f00-00000000000#{index}"

  defp list_row(item) do
    [item]
    |> SchedulesPage.list(%{"q" => "", "view" => "current"})
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".entity-list .entity-row")
  end

  defp detail(snapshot) do
    snapshot
    |> SchedulesPage.detail(@now)
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
  end

  defp facts(document) do
    document
    |> LazyHTML.query("dl.kit-facts > div")
    |> Enum.map(fn fact ->
      {LazyHTML.query(fact, "dt") |> LazyHTML.text(), words(LazyHTML.query(fact, "dd"))}
    end)
  end

  defp fixture, do: ControlPlaneOptions.options(self())

  # Text as a reader sees it: markup whitespace collapsed to single spaces.
  defp words(node), do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")
end
