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

  test "a saved exact-run matcher describes the next update without inventing approval" do
    view = Presentation.project(wait(), @episode, [])
    assert view.title == "Run run-k9CpPp3nWjQrkCMG"
    assert view.condition == "Next matching Slack update"
    assert view.target_url == hd(@matcher["attachments"])["title_link"]
    # The reference stays on screen while the name is unresolved, so two
    # channels never read identically; "Slack" is dropped because
    # "Slack channel" already says it.
    assert view.context_label == "Slack channel C0BLU1GACKC · emisar"
    assert view.episode_title == @episode.title
    refute view.condition =~ "approval"
    refute view.condition =~ "terminal"
  end

  test "source removal withholds old matcher names and links without deleting the wait" do
    for episode <- [nil, %{@episode | source_available: false, title: "Message deleted"}] do
      view = Presentation.project(wait(), episode, [])
      assert view.title == "Matching Slack update"
      assert view.target_url == nil
      assert view.context_label == "Source context unavailable"
      assert view.ref == wait().ref
    end
  end

  test "an exact notification stage stays visible as a condition rather than any next update" do
    # The retained Terraform notification has a second Run Planning attachment;
    # including that title in a matcher restricts which notification can resume it.
    message = "testdata/slack/hcp-terraform-planning.json" |> File.read!() |> Jason.decode!()
    matcher = %{"attachments" => Enum.map(message["attachments"], &Map.take(&1, ["title"]))}
    view = Presentation.project(wait(%{matcher: matcher}), @episode, [])
    assert view.title == "Run run-k9CpPp3nWjQrkCMG"
    assert view.condition == "Matching Slack update · attachment title: Run Planning"
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
    assert view.title == "portal [redacted]"
    assert view.condition == "Matching Emisar update · status: healthy"

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

  test "GitHub state matching remains distinct from an unrestricted next update" do
    item =
      wait(%{
        source_kind: "github",
        matcher: %{"pull_request" => %{"number" => 42, "state" => "closed"}, "action" => "closed"}
      })

    view =
      Presentation.project(
        item,
        %{@episode | source: "GitHub", repository: "owner/repository"},
        []
      )

    assert view.title == "Pull request #42"
    assert view.condition =~ "pull request state: closed"
    assert view.condition =~ "action: closed"
    assert view.context_label == "GitHub · owner/repository"

    view =
      Presentation.project(
        wait(%{
          source_kind: "webhook",
          matcher: %{"deployment" => "portal", "state" => "healthy"}
        }),
        @episode,
        []
      )

    assert view.title == "portal"
    assert view.condition == "Matching external update · state: healthy"
  end

  test "event-only waits have neither a predicted arrival nor an invented deadline" do
    assert Presentation.timing(wait(), @now) == [
             {"Next update", "When a matching update arrives", nil},
             {"Deadline", "No deadline", nil}
           ]
  end

  test "an elapsed fallback remains a due check until the runtime actually resumes it" do
    past = DateTime.add(@now, -180)
    later = DateTime.add(@now, 300)
    item = wait(%{poll_after: past, deadline_at: later})
    assert Presentation.status(item) == {"Waiting", "active"}

    assert Presentation.timing(item, @now) == [
             {"Next check", "overdue by 3 minutes", past},
             {"Deadline", "in 5 minutes", later}
           ]
  end

  test "a deadline-only event wait never promises a polling check" do
    # EventSubscriptions stores the deadline as poll_after when no fallback was
    # requested. Calling it a check promised work that actually just times out.
    deadline = DateTime.add(@now, 7_200)

    assert Presentation.timing(wait(%{poll_after: deadline, deadline_at: deadline}), @now) == [
             {"Next update", "When a matching update arrives", nil},
             {"Deadline", "in 2 hours", deadline}
           ]
  end

  test "timer and event outcomes describe recorded resolution rather than elapsed wall time" do
    for {status, resolution, label, state} <- [
          {:resolved, :timer, "Timer fired", {"Resumed", "done"}},
          {:resolved, :input, "Matching update arrived", {"Resumed", "done"}},
          {:resolved, :poll_fallback, "Resumed for a status check", {"Resumed", "done"}},
          {:timed_out, :deadline, "Deadline reached", {"Timed out", "attention"}},
          {:cancelled, :cancelled, "Wait cancelled", {"Cancelled", "quiet"}}
        ] do
      at = DateTime.add(@now, -120)
      item = wait(%{status: status, resolution_kind: resolution, last_observed_at: at})
      assert Presentation.status(item) == state
      assert Presentation.timing(item, @now) == [{label, "2 minutes ago", at}]
    end

    assert Presentation.timing(wait(%{status: :resolved}), @now) == [
             {"Wait resolved", "Time not recorded", nil}
           ]
  end

  test "one unchanged timer advances from future to due without changing its saved state" do
    item = wait(%{trigger_type: "after", poll_after: DateTime.add(@now, 60)})
    assert Presentation.project(item, @episode, []).title == "Timed follow-up"
    assert hd(Presentation.timing(item, @now)) == {"Follow-up", "in 1 minute", item.poll_after}

    assert hd(Presentation.timing(item, DateTime.add(@now, 60))) ==
             {"Follow-up", "due now", item.poll_after}

    assert item.status == :active

    assert hd(Presentation.timing(wait(%{trigger_type: "at"}), @now)) ==
             {"Follow-up", "Time not recorded", nil}
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
