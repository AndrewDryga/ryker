defmodule Ryker.State.AutomationsTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Repo
  alias Ryker.Slack.{Renderer, ReplyRecords}

  alias Ryker.State.{
    Automations,
    Behavior,
    Behaviors,
    Record,
    Records,
    Schedule,
    Schedules
  }

  alias Ryker.Work.{Custody, DeliveryReceipt, Result, Submission}

  @now ~U[2026-08-29 12:00:00.000000Z]

  test "automation edits cannot bind an existing rule to an unregistered source" do
    # The real Terraform offer was confirmed but could never match an input:
    # terraform was a vendor name, not one of the configured ingress adapters.
    source =
      delivered_record!("source-edit", "standing_assignment_offer", standing_assignment_offer())

    assert {:ok, created} = Behaviors.confirm(confirmation(source, "create-source-edit"))

    recorded = File.read!("testdata/work/terraform-automation-recovery.json") |> Jason.decode!()
    trigger = hd(recorded["automation_arguments"]["proposals"])["trigger"]

    assert Automations.prepare_change(source.episode, %{
             "action" => "update",
             "automation_id" => created.behavior.ref,
             "patch" => %{"trigger" => trigger},
             "revision" => 1
           }) == {:error, :invalid_automation_source}

    assert Repo.get!(Behavior, created.behavior.id).payload["source_kind"] == "github"
  end

  test "a delivered operator decision manages the complete time automation lifecycle" do
    source = delivered_record!("time-source", "schedule_offer", schedule_offer())
    assert {:ok, created} = Schedules.confirm(confirmation(source, "create-time"))
    schedule = created.schedule

    assert schedule.revision == 1

    assert {:ok, updated} =
             change!(source.episode, "time-update", schedule.ref, 1, "update", %{
               "prompt" => "Inspect service health and report only material changes.",
               "title" => "Daily material service health"
             })

    assert updated.status == :confirmed
    assert updated.automation["revision"] == 2
    assert updated.automation["title"] == "Daily material service health"
    assert updated.automation["prompt"] =~ "only material changes"

    change_fixture = updated.fixture
    assert {:ok, duplicate} = Automations.confirm(confirmation(change_fixture, "update-retry"))
    assert duplicate.status == :duplicate
    assert duplicate.automation["revision"] == 2

    assert {:ok, paused} = change!(source.episode, "time-pause", schedule.ref, 2, "pause", %{})
    assert paused.automation["status"] == "paused"
    assert paused.automation["revision"] == 3

    assert {:ok, resumed} =
             change!(source.episode, "time-resume", schedule.ref, 3, "resume", %{})

    assert resumed.automation["status"] == "active"
    assert resumed.automation["revision"] == 4

    assert {:ok, deleted} =
             change!(source.episode, "time-delete", schedule.ref, 4, "delete", %{})

    assert deleted.automation["status"] == "deleted"
    assert deleted.automation["revision"] == 5
    assert Repo.get!(Schedule, schedule.id).status == :deleted
    assert Repo.get_by!(Record, ref: deleted.fixture.record.ref).status == :confirmed
  end

  test "source-event automation changes retain scope and reject a crossed revision" do
    source =
      delivered_record!(
        "source-event-source",
        "standing_assignment_offer",
        standing_assignment_offer()
      )

    assert {:ok, created} = Behaviors.confirm(confirmation(source, "create-source-event"))
    behavior = created.behavior
    assert behavior.revision == 1

    assert {:ok, update_offer} =
             Automations.prepare_change(source.episode, %{
               "action" => "update",
               "automation_id" => behavior.ref,
               "patch" => %{
                 "prompt" => "Review each submitted pull request review for material risk.",
                 "trigger" => %{
                   "filter" => %{"action" => "submitted"},
                   "source_kind" => "github",
                   "type" => "source_event"
                 }
               },
               "revision" => 1
             })

    assert update_offer["before"]["context_channel"] == "slack:T123:C456"
    assert update_offer["after"]["delivery_channel"] == "slack:T123:C456"
    assert Repo.get!(Behavior, behavior.id).payload["task"] == "Review pull request reviews."

    first = delivered_record!("source-event-update", "automation_change_offer", update_offer)

    stale =
      delivered_record!(
        "source-event-stale",
        "automation_change_offer",
        update_offer
      )

    assert {:ok, updated} = Automations.confirm(confirmation(first, "update-source-event"))
    assert updated.automation["revision"] == 2
    assert updated.automation["prompt"] =~ "material risk"

    assert Automations.confirm(confirmation(stale, "stale-source-event")) ==
             {:error, {:automation_revision_conflict, 2}}

    assert Repo.get_by!(Record, ref: stale.record.ref).status == :open

    assert {:ok, paused} =
             change!(source.episode, "source-event-pause", behavior.ref, 2, "pause", %{})

    assert paused.automation["status"] == "paused"

    assert {:ok, resumed} =
             change!(source.episode, "source-event-resume", behavior.ref, 3, "resume", %{})

    assert resumed.automation["status"] == "active"

    assert {:ok, deleted} =
             change!(source.episode, "source-event-delete", behavior.ref, 4, "delete", %{})

    assert deleted.automation["status"] == "deleted"
    assert Repo.get!(Behavior, behavior.id).revision == 5
  end

  test "a live schedule lease prevents an operator change until dispatch custody is released" do
    source = delivered_record!("busy-source", "schedule_offer", schedule_offer())
    assert {:ok, created} = Schedules.confirm(confirmation(source, "create-busy"))
    schedule = created.schedule

    Repo.update_all(
      from(stored in Schedule, where: stored.id == ^schedule.id),
      set: [
        lease_expires_at: DateTime.add(@now, 60, :second),
        lease_owner: "schedule-worker:busy",
        lease_ref: "schedule-lease:busy"
      ]
    )

    assert {:ok, payload} =
             Automations.prepare_change(source.episode, %{
               "action" => "pause",
               "automation_id" => schedule.ref,
               "patch" => %{},
               "revision" => 1
             })

    change = delivered_record!("busy-pause", "automation_change_offer", payload)

    assert Automations.confirm(confirmation(change, "busy-pause")) ==
             {:error, :automation_busy}

    assert Repo.get!(Schedule, schedule.id).status == :active
    assert Repo.get_by!(Record, ref: change.record.ref).status == :open
  end

  test "time automation updates preserve the complete supported recurrence catalog" do
    source = delivered_record!("recurrence-source", "schedule_offer", schedule_offer())
    assert {:ok, created} = Schedules.confirm(confirmation(source, "create-recurrence"))

    triggers = [
      %{
        "at" => "2026-09-01T13:00:00.000000Z",
        "recurrence" => "once",
        "timezone" => "Etc/UTC",
        "type" => "time"
      },
      %{
        "every_seconds" => 3_600,
        "recurrence" => "interval",
        "starts_at" => "2026-08-29T13:00:00.000000Z",
        "timezone" => "Etc/UTC",
        "type" => "time"
      },
      %{
        "recurrence" => "weekly",
        "time" => "13:00:00",
        "timezone" => "Etc/UTC",
        "type" => "time",
        "weekday" => "friday"
      },
      %{
        "day" => 15,
        "recurrence" => "monthly",
        "time" => "13:00:00",
        "timezone" => "Etc/UTC",
        "type" => "time"
      }
    ]

    Enum.each(triggers, fn trigger ->
      assert {:ok, offer} =
               Automations.prepare_change(source.episode, %{
                 "action" => "update",
                 "automation_id" => created.schedule.ref,
                 "patch" => %{"trigger" => trigger},
                 "revision" => 1
               })

      assert offer["after"]["trigger"] == trigger
    end)

    assert Automations.prepare_change(source.episode, %{
             "action" => "update",
             "automation_id" => created.schedule.ref,
             "patch" => %{
               "trigger" => %{
                 "recurrence" => "quarterly",
                 "timezone" => "Etc/UTC",
                 "type" => "time"
               }
             },
             "revision" => 1
           }) == {:error, :invalid_arguments}
  end

  test "automation mutation boundaries reject malformed proposals and confirmations" do
    episode = %Episode{
      destination_conversation_ref: "slack:T123:C456",
      destination_transport: "slack"
    }

    assert Automations.fetch_for_episode(%{}, "schedule:missing") == :error
    assert Automations.prepare_change(%{}, %{}) == {:error, :invalid_arguments}

    assert Automations.prepare_change(episode, %{
             "action" => nil,
             "automation_id" => "schedule:missing",
             "patch" => %{},
             "revision" => 1
           }) == {:error, :invalid_arguments}

    assert Automations.prepare_change(episode, %{
             "action" => "replace",
             "automation_id" => "schedule:missing",
             "patch" => %{},
             "revision" => 1
           }) == {:error, :invalid_arguments}

    assert Automations.prepare_change(episode, %{
             "action" => "update",
             "automation_id" => "schedule:missing",
             "patch" => %{"prompt" => "Updated prompt."},
             "revision" => 1
           }) == {:error, :not_found}

    valid = %{
      actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:automation-boundary",
      occurred_at: @now,
      record_ref: "record:automation_change_offer:missing",
      target: %{
        conversation_ref: "slack:T123:C456",
        message_ref: "1787832001.000200",
        thread_ref: "1787832000.000100",
        transport: "slack"
      }
    }

    assert Automations.confirm(:invalid) ==
             {:error, {:invalid_automation_confirmation, :fields}}

    assert Automations.confirm(actor_ref: "first", actor_ref: "second") ==
             {:error, {:invalid_automation_confirmation, :fields}}

    assert Automations.confirm(Map.delete(valid, :target)) ==
             {:error, {:invalid_automation_confirmation, :fields}}

    assert Automations.confirm(%{valid | target: nil}) ==
             {:error, {:invalid_automation_confirmation, :target}}

    assert Automations.confirm(%{valid | target: Map.delete(valid.target, :message_ref)}) ==
             {:error, {:invalid_automation_confirmation, :target}}

    assert Automations.confirm(%{valid | occurred_at: "not-a-timestamp"}) ==
             {:error, {:invalid_automation_confirmation, :occurred_at}}

    assert Automations.confirm(%{valid | occurred_at: 42}) ==
             {:error, {:invalid_automation_confirmation, :occurred_at}}

    assert Automations.confirm(Map.to_list(valid)) ==
             {:error, :automation_change_offer_not_found}
  end

  # `SavedEntity`'s `:updated` event existed only as a hand-written Card Lab
  # specimen ("Schedule has been updated"), with nothing driving it from a
  # confirmed change. An unverified card state is a claim: the 2026-09-12 audit
  # found one such claim ("the parked state clears native activity") was simply
  # false, and a thread had been told "is working..." every 90 seconds ever
  # since. The card has to show the automation as it now stands, because the
  # change offer's own payload describes a proposal that has already happened.
  test "a confirmed change shows the automation as it now stands, with its new revision" do
    source = delivered_record!("updated-card", "schedule_offer", schedule_offer())
    assert {:ok, created} = Schedules.confirm(confirmation(source, "create-updated-card"))
    schedule = created.schedule

    assert {:ok, updated} =
             change!(source.episode, "update-card", schedule.ref, 1, "update", %{
               "prompt" => "Inspect service health and report only material changes.",
               "title" => "Daily material service health"
             })

    change = Repo.get_by!(Record, ref: updated.fixture.record.ref)
    assert change.status == :confirmed

    assert [%{"presentation" => %{"entity" => entity}} = document] =
             ReplyRecords.documents("slack", updated.fixture.episode.id, [change])

    assert entity["kind"] == "schedule"
    assert entity["ref"] == schedule.ref
    assert entity["notice"] == "Schedule has been updated"
    assert entity["revision"] == 2
    assert entity["status"] == "active"
    assert entity["removable"] == true
    assert entity["title"] == "Daily material service health"
    assert entity["instructions"] == "Inspect service health and report only material changes."
    assert ["When", "Daily at 13:00:00 · Etc/UTC"] in entity["facts"]

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Change saved.", "records" => [document]})

    assert [_message, detail, _facts, context, controls] = rendered["blocks"]
    assert detail["text"]["text"] =~ "*Daily material service health*"
    assert detail["text"]["text"] =~ "only material changes"
    assert hd(context["elements"])["text"] =~ "Schedule has been updated · saved by <@U123>"

    # The control the operator is offered removes the revision they are looking
    # at, not the one the change superseded.
    assert [delete] = controls["elements"]
    assert delete["action_id"] == "ryker_delete_schedule"
    assert delete["value"] == "schedule-control:#{schedule.ref}:2"

    # A deleted automation is described by its current state, not by the change
    # that last edited it, and offers nothing to press.
    assert {:ok, _deleted} =
             change!(source.episode, "delete-card", schedule.ref, 2, "delete", %{})

    assert [%{"presentation" => %{"entity" => gone}} = removed] =
             ReplyRecords.documents("slack", updated.fixture.episode.id, [change])

    assert gone["notice"] == "Schedule deleted"
    assert gone["status"] == "deleted"
    assert gone["removable"] == false

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Change saved.", "records" => [removed]})

    refute Enum.any?(rendered["blocks"], &(&1["type"] == "actions"))
  end

  defp change!(episode, suffix, automation_id, revision, action, patch) do
    assert {:ok, payload} =
             Automations.prepare_change(episode, %{
               "action" => action,
               "automation_id" => automation_id,
               "patch" => patch,
               "revision" => revision
             })

    fixture = delivered_record!(suffix, "automation_change_offer", payload)
    assert {:ok, result} = Automations.confirm(confirmation(fixture, suffix))
    {:ok, Map.put(result, :fixture, fixture)}
  end

  defp schedule_offer do
    %{
      "authority" => "read_only",
      "expires_at" => nil,
      "recurrence" => %{"kind" => "daily", "time" => "13:00:00"},
      "repository" => nil,
      "task" => "Inspect current service health.",
      "timezone" => "Etc/UTC",
      "title" => "Daily service health"
    }
  end

  defp standing_assignment_offer do
    %{
      "context_channel" => "slack:T123:C456",
      "delivery_channel" => "slack:T123:C456",
      "expires_at" => "2099-08-29T12:00:00.000000Z",
      "filter" => %{"action" => "submitted"},
      "hold" => nil,
      "repository" => "ryker",
      "source_kind" => "github",
      "task" => "Review pull request reviews.",
      "title" => "Review pull request reviews"
    }
  end

  defp delivered_record!(suffix, kind, payload) do
    episode_id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: "slack:T123:C456",
          thread_ref: "1787832000.000100",
          transport: "slack"
        },
        episode_id: episode_id,
        episode_key: "automation-offer:#{suffix}:#{episode_id}",
        native_input_id: "slack-message:automation-offer:#{suffix}:#{episode_id}",
        occurred_at: @now,
        turn_ref: "turn:automation-offer:#{suffix}:#{episode_id}"
      })

    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "ryker-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:automation-offer:#{suffix}", 60, :work)

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "automation-offer", kind, payload)

    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => episode_id},
               "Offer the requested automation change.",
               %{"type" => "object"},
               "work-final-live-v2"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:automation-offer:#{suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:automation-offer:#{suffix}"
             )

    candidate = ~s({"delivery":"reply","message":"Please review this automation change."})
    sha256 = digest(candidate)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} =
             Result.new(:reply, %{
               "decision_reason" => nil,
               "delivery" => "reply",
               "message" => "Please review this automation change.",
               "outcome" => %{
                 "artifact_refs" => [],
                 "record_refs" => [record.ref],
                 "state" => "complete"
               }
             })

    assert {:ok, _turn} =
             Custody.prepare_validation(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               episode_id,
               transition.episode.key,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:automation-offer:#{suffix}"
             )

    assert {:ok, delivery_claim} =
             Custody.claim_next("delivery:automation-offer:#{suffix}", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "slack",
               "slack:T123:C456",
               "1787832000.000100",
               "1787832001.000200"
             )

    assert {:ok, settled} =
             Custody.confirm_delivery(
               episode_id,
               transition.episode.key,
               turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    %{episode: settled.episode, receipt: receipt, record: record}
  end

  defp confirmation(fixture, suffix) do
    %{
      actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:#{suffix}",
      occurred_at: @now,
      record_ref: fixture.record.ref,
      target: %{
        conversation_ref: fixture.receipt["conversation_ref"],
        message_ref: fixture.receipt["message_ref"],
        thread_ref: fixture.receipt["thread_ref"],
        transport: fixture.receipt["transport"]
      }
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
