defmodule Ryker.ControlPlane.SubscriptionPresentationTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.SubscriptionPresentation, as: Presentation

  @now ~U[2026-09-10 09:00:00Z]
  @episode %{
    source_available: true,
    title: "Review the portal deployment",
    href: "/timeline/run-monitor",
    source: "Slack",
    conversation: "slack:T0BHXKZJVDX:C0BLU1GACKC",
    repository: "emisar"
  }

  # Harvested from responder_emisar.episode_event_subscriptions on 2026-09-10:
  # event-subscription:b57dc95c-3cc4-4b25-a9ab-3f44bafc6a2f. The bot_id is
  # immaterial to display and omitted; the title and link are the saved matcher.
  @matcher %{
    "attachments" => [
      %{
        "title" => "Run run-k9CpPp3nWjQrkCMG",
        "title_link" => "https://app.terraform.io/app/Dryga/emisar/runs/run-k9CpPp3nWjQrkCMG"
      }
    ]
  }

  test "a saved exact-run matcher says what it waits for without inventing approval" do
    view = Presentation.project(wait(), @episode, [])
    assert view.title == "An update on Run run-k9CpPp3nWjQrkCMG"
    assert view.condition == nil
    assert view.target_url == hd(@matcher["attachments"])["title_link"]
    # The reference stays on screen while the name is unresolved, so two
    # channels never read identically.
    assert view.place == "Slack channel C0BLU1GACKC"
    assert view.repository == "emisar"
    assert view.episode_title == @episode.title
    assert view.episode_href == @episode.href
    refute view.title =~ "approv"
    refute view.title =~ "terminal"
  end

  test "source removal withholds old matcher names and links without deleting the follow-up" do
    for episode <- [nil, %{@episode | source_available: false, title: "Message deleted"}] do
      view = Presentation.project(wait(), episode, [])
      assert view.title == "A matching Slack update"
      assert view.target_url == nil
      assert view.place == nil
      assert view.repository == nil
      assert view.ref == wait().ref
    end

    assert Presentation.project(wait(), nil, []).episode_title == nil
  end

  test "an exact notification stage stays visible as a matching condition" do
    # The retained Terraform notification has a second Run Planning attachment;
    # including that title in a matcher restricts which notification resumes it.
    message = "testdata/slack/hcp-terraform-planning.json" |> File.read!() |> Jason.decode!()
    matcher = %{"attachments" => Enum.map(message["attachments"], &Map.take(&1, ["title"]))}
    view = Presentation.project(wait(%{matcher: matcher}), @episode, [])
    assert view.title == "An update on Run run-k9CpPp3nWjQrkCMG"
    assert view.condition == "attachment title: Run Planning"
  end

  test "only safe bounded matcher labels and HTTPS resource links become presentation fields" do
    item =
      wait(%{
        matcher: %{
          "deployment" => "portal configured-secret-value",
          "status" => "healthy",
          "authorization" => "never-display-this",
          "body" => "private provider body"
        },
        source_kind: "emisar"
      })

    view = Presentation.project(item, @episode, ["configured-secret-value"])
    assert view.title == "portal [redacted] is healthy"
    assert view.condition == "status: healthy"

    # Only allowlisted matcher fields become words; the projection then drops
    # the raw matcher itself.
    for field <- [:title, :condition, :place, :repository, :target_url] do
      refute to_string(Map.get(view, field)) =~ "never-display-this", inspect(field)
      refute to_string(Map.get(view, field)) =~ "private provider body", inspect(field)
    end

    for url <- [
          "javascript:alert(1)",
          "https://user:password@example.test/run",
          "https://example.test/run?token=secret",
          "https://example.test/credential-value"
        ] do
      matcher = %{"attachments" => [%{"title" => "Run", "title_link" => url}]}
      view = Presentation.project(wait(%{matcher: matcher}), @episode, ["credential-value"])
      assert view.target_url == nil
    end

    assert String.length(
             Presentation.project(
               wait(%{matcher: %{"run_id" => String.duplicate("x", 1000)}}),
               @episode,
               []
             ).title
           ) < 300
  end

  test "a pull request says whether it waits for a merge, a close or any update" do
    for {pull_request, action, title} <- [
          {%{"number" => 42, "merged" => true}, "closed", "Pull request #42 is merged"},
          {%{"number" => 42, "state" => "closed"}, "closed", "Pull request #42 is closed"},
          {%{"number" => 42}, "synchronize", "An update on pull request #42"}
        ] do
      item =
        wait(%{
          source_kind: "github",
          matcher: %{"pull_request" => pull_request, "action" => action}
        })

      view =
        Presentation.project(
          item,
          %{@episode | source: "GitHub", repository: "owner/repository"},
          []
        )

      assert view.title == title
      assert view.condition =~ "action: #{action}"
      # A GitHub request lives in its repository; there is no channel to name.
      assert view.place == nil
      assert view.repository == "owner/repository"
    end

    view =
      Presentation.project(
        wait(%{
          source_kind: "webhook",
          matcher: %{"deployment" => "portal", "state" => "healthy"}
        }),
        @episode,
        []
      )

    assert view.title == "portal is healthy"

    assert Presentation.project(wait(%{source_kind: "github", matcher: %{}}), @episode, []).title ==
             "A matching GitHub update"
  end

  test "a follow-up from a direct conversation says so instead of naming a channel" do
    episode = %{@episode | source: "Direct conversation", conversation: "control-plane:lab:one"}
    assert Presentation.project(wait(), episode, []).place == :direct
  end

  test "a timer is a timer, not a watched source" do
    view = Presentation.project(wait(%{trigger_type: "after", matcher: %{}}), @episode, [])
    assert view.title == "Timer"
    assert view.condition == nil
    assert view.source_label == "Timer"
  end

  test "states are words with the Kit's tones" do
    assert Presentation.status(wait()) == {:busy, "Waiting"}
    assert Presentation.status(wait(%{status: :resolved})) == {:off, "Resumed"}
    assert Presentation.status(wait(%{status: :timed_out})) == {:warn, "Deadline passed"}
    assert Presentation.status(wait(%{status: :cancelled})) == {:off, "Cancelled"}
  end

  test "an event follow-up has neither a predicted arrival nor an invented deadline" do
    assert Presentation.timing(wait(), @now) == [
             {"when a matching update arrives", nil},
             {"no deadline", nil}
           ]
  end

  test "an elapsed fallback remains a due check until the runtime actually resumes it" do
    past = DateTime.add(@now, -180)
    later = DateTime.add(@now, 300)
    item = wait(%{poll_after: past, deadline_at: later})
    assert Presentation.status(item) == {:busy, "Waiting"}

    assert Presentation.timing(item, @now) == [
             {"when a matching update arrives", nil},
             {"next check overdue by 3 minutes", past},
             {"stops waiting in 5 minutes", later}
           ]
  end

  test "a deadline-only event follow-up never promises a check" do
    # EventSubscriptions stores the deadline as poll_after when no fallback was
    # requested. Calling it a check promised work that actually just ends it.
    deadline = DateTime.add(@now, 7_200)

    assert Presentation.timing(wait(%{poll_after: deadline, deadline_at: deadline}), @now) == [
             {"when a matching update arrives", nil},
             {"stops waiting in 2 hours", deadline}
           ]
  end

  test "a distant deadline is a date, and a passed one stops waiting now" do
    distant = ~U[2026-09-26 12:00:00Z]
    next_year = ~U[2027-01-05 12:00:00Z]

    assert List.last(Presentation.timing(wait(%{deadline_at: distant}), @now)) ==
             {"stops waiting 26 Sep", distant}

    assert List.last(Presentation.timing(wait(%{deadline_at: next_year}), @now)) ==
             {"stops waiting 5 Jan 2027", next_year}

    passed = DateTime.add(@now, -60)

    assert List.last(Presentation.timing(wait(%{deadline_at: passed}), @now)) ==
             {"stops waiting now", passed}
  end

  test "past follow-ups say what ended them and how long ago" do
    for {status, resolution, label} <- [
          {:resolved, :timer, "timer fired"},
          {:resolved, :input, "update arrived"},
          {:resolved, :poll_fallback, "checked again"},
          {:timed_out, :deadline, "gave up"},
          {:cancelled, :cancelled, "cancelled"}
        ] do
      at = DateTime.add(@now, -120)
      item = wait(%{status: status, resolution_kind: resolution, last_observed_at: at})
      assert Presentation.timing(item, @now) == [{label <> " 2 minutes ago", at}]
    end

    assert Presentation.timing(wait(%{status: :resolved}), @now) == [{"resumed", nil}]
  end

  test "one unchanged timer advances from future to due without changing its saved state" do
    item = wait(%{trigger_type: "after", poll_after: DateTime.add(@now, 60)})
    assert Presentation.timing(item, @now) == [{"in 1 minute", item.poll_after}]
    assert Presentation.timing(item, DateTime.add(@now, 60)) == [{"due now", item.poll_after}]
    assert item.status == :active

    # A timer with no recorded moment says nothing rather than inventing one.
    assert Presentation.timing(wait(%{trigger_type: "at"}), @now) == []
  end

  test "relative labels keep missing times distinct and include ordinary time boundaries" do
    assert Presentation.relative(nil, @now) == "Time not recorded"
    assert Presentation.relative(@now, @now) == "just now"
    assert Presentation.relative(DateTime.add(@now, 30), @now) == "in less than a minute"
    assert Presentation.relative(DateTime.add(@now, 3_600), @now) == "in 1 hour"
    assert Presentation.relative(DateTime.add(@now, -86_400), @now) == "1 day ago"
    assert Presentation.relative(DateTime.add(@now, -172_800), @now) == "2 days ago"
  end

  defp wait(overrides \\ %{}) do
    Map.merge(
      %{
        ref: "event-subscription:b57dc95c-3cc4-4b25-a9ab-3f44bafc6a2f",
        matcher: @matcher,
        source_kind: "slack",
        trigger_type: "source_event",
        status: :active,
        resolution_kind: nil,
        poll_after: nil,
        deadline_at: nil,
        last_observed_at: nil
      },
      overrides
    )
  end
end
