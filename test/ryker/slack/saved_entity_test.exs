defmodule Ryker.Slack.SavedEntityTest do
  use ExUnit.Case, async: true
  alias Ryker.Behaviors.Behavior
  alias Ryker.Schedules.Schedule
  alias Ryker.Slack.Renderer.SavedEntityCard
  alias Ryker.Slack.SavedEntity

  # The offer said which events a rule takes in words, and the rule it saved
  # showed the same filter as raw JSON (2026-10-04 review).
  test "a saved rule says which events it takes in the words its offer used" do
    rule = %Behavior{
      confirmed_at: ~U[2026-09-25 21:31:00.000000Z],
      confirmed_by_actor_ref: "slack:user:U123",
      expires_at: nil,
      identity_key: "pull-request-reviews",
      kind: :standing_assignment,
      payload: %{
        "context_channel" => "slack:T123:C456",
        "delivery_channel" => "slack:T123:C456",
        "filter" => %{"action" => "submitted", "state" => ["approved", "changes_requested"]},
        "source_kind" => "github",
        "task" => "Summarize each submitted review.",
        "title" => "Pull request reviews"
      },
      ref: "behavior:pull-request-reviews",
      revision: 1,
      scope_kind: :conversation,
      scope_ref: "slack:T123:C456",
      status: :active
    }

    facts = SavedEntity.document(rule, :saved)["facts"]

    assert [
             "Event filter",
             "Only when action is submitted and state is approved or changes_requested"
           ] in facts
  end

  # A fact saved from a DM read "Kind: entity relationship", then "Scope: This
  # conversation" and "Visibility: This conversation" (Slack as Andrew,
  # 2026-10-09). The card says what was saved and, once, whom it is for.
  test "a saved fact names its kind in words and says once whom it applies to" do
    entry = %Ryker.Memories.MemoryEntry{
      confirmed_at: ~U[2026-10-09 21:39:00.000000Z],
      confirmed_by_actor_ref: "slack:user:U123",
      expires_at: ~U[2027-01-07 21:39:00.000000Z],
      kind: :entity_relationship,
      payload: %{"value" => "https://status.example.test"},
      ref: "memory:status-page",
      scope_kind: :conversation,
      scope_ref: "slack:T123:D456",
      source_conversation_ref: "slack:T123:D456",
      source_transport: "slack",
      status: :active,
      subject: "our public status page",
      visibility: :conversation
    }

    facts = SavedEntity.document(entry, :saved)["facts"]
    labels = Enum.map(facts, &hd/1)

    assert ["Kind", "Fact"] in facts
    assert ["Applies to", "This conversation"] in facts
    refute "Scope" in labels
    refute "Visibility" in labels

    shared = %{entry | scope_kind: :workspace, visibility: :conversation}
    shared_facts = SavedEntity.document(shared, :saved)["facts"]
    assert ["Applies to", "Whole workspace"] in shared_facts
    assert ["Who sees it", "This conversation"] in shared_facts
  end

  # QA, 2026-09-25: the saved schedule in Slack said "Every monday at 09:00:00
  # · Etc/UTC" in words of its own, and had none for a weekday schedule. It
  # reads the recurrence through the one wording every surface shares.
  test "a saved schedule says how often it runs in the words every surface uses" do
    schedule = %Schedule{
      authority: :read_only,
      confirmed_at: ~U[2026-09-25 21:31:00.000000Z],
      confirmed_by_actor_ref: "slack:user:U123",
      destination_conversation_ref: "slack:T123:C456",
      expires_at: nil,
      next_occurrence_at: ~U[2026-09-28 09:00:00.000000Z],
      recurrence: %{"kind" => "weekdays", "time" => "09:00:00"},
      ref: "schedule:weekday-status",
      repository: nil,
      revision: 1,
      status: :active,
      task: "Post a one-line status of open incidents here.",
      timezone: "Etc/UTC",
      title: "Weekday open incident status"
    }

    assert ["When", "Every weekday at 09:00 UTC"] in SavedEntity.document(schedule, :saved)[
             "facts"
           ]

    weekly = %{
      schedule
      | recurrence: %{"kind" => "weekly", "time" => "09:00:00", "weekday" => "monday"}
    }

    assert ["When", "Every Monday at 09:00 UTC"] in SavedEntity.document(weekly, :saved)["facts"]
  end

  # A schedule or rule may hold 12,000 bytes of task, but its card shows at most 2,000
  # characters. A longer one made the card invalid: the repaint after someone confirmed it
  # failed, and "View schedules" stopped at it (2026-10-04 review).
  test "a schedule longer than its card still makes a valid card, its task cut to fit" do
    task = String.duplicate("Post a one-line status of open incidents here. ", 200)

    schedule = %Schedule{
      authority: :read_only,
      confirmed_at: ~U[2026-09-25 21:31:00.000000Z],
      confirmed_by_actor_ref: "slack:user:U123",
      destination_conversation_ref: "slack:T123:C456",
      expires_at: nil,
      next_occurrence_at: ~U[2026-09-28 09:00:00.000000Z],
      recurrence: %{"kind" => "weekdays", "time" => "09:00:00"},
      ref: "schedule:long-task",
      repository: nil,
      revision: 1,
      status: :active,
      task: task,
      timezone: "Etc/UTC",
      title: "Weekday open incident status"
    }

    document = SavedEntity.document(schedule, :saved)
    assert String.ends_with?(document["instructions"], "…")
    assert SavedEntityCard.validate(document) == :ok
  end
end
