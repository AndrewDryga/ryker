defmodule Responder.State.SchedulesTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Episodes.Episode
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Slack.AppHomeProjection

  alias Responder.State.{
    Automations,
    Record,
    Records,
    Schedule,
    ScheduleOccurrence,
    ScheduleRecurrence,
    Schedules
  }

  alias Responder.Work.{Custody, DeliveryReceipt, Result, Session, Submission}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @policy %{digest: String.duplicate("c", 64), name: "responder-scheduled-read"}

  test "the exact delivered offer creates one durable schedule and dispatches fresh linked work" do
    fixture = delivered_offer!("confirmed")

    assert {:ok, confirmation} = Schedules.confirm(confirmation(fixture, "confirm"))
    assert confirmation.status == :confirmed
    assert confirmation.schedule.source_episode_id == fixture.episode.id
    assert confirmation.schedule.destination_transport == "slack"
    assert confirmation.schedule.destination_conversation_ref == "slack:T123:C456"
    assert confirmation.schedule.destination_thread_ref == "1787832000.000100"
    assert confirmation.schedule.authority == :read_only
    assert confirmation.schedule.status == :active

    record = Repo.get!(Record, fixture.record.id)
    assert record.status == :confirmed
    assert record.confirmed_episode_id == nil
    assert record.confirmed_by_actor_ref == "slack:user:U123"

    assert {:ok, duplicate} = Schedules.confirm(confirmation(fixture, "confirm-retry"))
    assert duplicate.status == :duplicate
    assert duplicate.schedule.id == confirmation.schedule.id
    assert Repo.aggregate(Schedule, :count, :id) == 1

    due_at = DateTime.add(database_now!(), -60, :second)
    make_due!(confirmation.schedule, due_at)

    assert {:ok, claim} = Schedules.claim_due("schedule-worker:one", 60)
    assert claim.schedule.id == confirmation.schedule.id

    assert {:ok, dispatched} =
             Schedules.dispatch(claim.schedule.ref, claim.lease_ref, &policy/1, 900)

    assert dispatched.status == :dispatched
    assert dispatched.occurrence.status == :dispatched
    assert dispatched.occurrence.scheduled_for == due_at
    assert dispatched.episode.linked_episode_id == fixture.episode.id
    assert dispatched.episode.destination_transport == "slack"
    assert dispatched.episode.destination_conversation_ref == "slack:T123:C456"
    assert dispatched.episode.destination_thread_ref == "1787832000.000100"

    assert %Session{
             policy: "responder-scheduled-read",
             policy_digest: digest,
             repository_ref: nil
           } =
             Repo.get_by!(Session, episode_id: dispatched.episode.id)

    assert digest == @policy.digest

    assert [event] = Episodes.list_events(dispatched.episode.key)
    assert event.kind == :input_admitted
    assert event.payload["payload"]["content"]["kind"] == "scheduled_task"

    assert event.payload["payload"]["content"]["schedule"]["schedule_ref"] ==
             confirmation.schedule.ref

    assert event.payload["payload"]["content"]["schedule"]["task"] ==
             "Inspect current service health."

    assert %{"recent_runs" => [run]} = Automations.detail(dispatched.schedule, 10)
    assert run["run_ref"] == dispatched.occurrence.ref
    assert run["episode_id"] == dispatched.episode.id
    assert run["episode_state"] == "working"
    assert run["outcome"] == "dispatched"

    make_due!(dispatched.schedule, DateTime.add(database_now!(), -30, :second))
    assert {:ok, overlap_claim} = Schedules.claim_due("schedule-worker:two", 60)

    assert {:ok, overlap} =
             Schedules.dispatch(
               overlap_claim.schedule.ref,
               overlap_claim.lease_ref,
               &policy/1,
               900
             )

    assert overlap.status == :overlap
    assert Repo.aggregate(ScheduleOccurrence, :count, :id) == 1

    assert Schedules.set_status(confirmation.schedule.ref, :paused, %{
             conversation_prefix: "slack:T999:",
             transport: "slack"
           }) == {:error, :schedule_scope_mismatch}

    assert Repo.get!(Schedule, confirmation.schedule.id).status == :active

    scope = %{conversation_prefix: "slack:T123:", transport: "slack"}
    assert {:ok, paused} = Schedules.set_status(confirmation.schedule.ref, :paused, scope)
    assert paused.status == :paused
    assert paused.revision == confirmation.schedule.revision + 1

    assert {:ok, unchanged} = Schedules.set_status(confirmation.schedule.ref, :paused, scope)
    assert unchanged.revision == paused.revision

    assert {:ok, resumed} = Schedules.set_status(confirmation.schedule.ref, :active, scope)
    assert resumed.status == :active
    assert resumed.revision == paused.revision + 1

    assert {:ok, deleted} = Schedules.set_status(confirmation.schedule.ref, :deleted, scope)
    assert deleted.status == :deleted
    assert deleted.revision == resumed.revision + 1

    assert Schedules.set_status(confirmation.schedule.ref, :active, scope) ==
             {:error, :schedule_terminal}
  end

  test "a stale skipped occurrence is recorded without starting work" do
    fixture = delivered_offer!("misfire", catch_up: "skip")
    assert {:ok, confirmation} = Schedules.confirm(confirmation(fixture, "misfire"))

    make_due!(confirmation.schedule, DateTime.add(database_now!(), -3_600, :second))

    assert {:ok, claim} = Schedules.claim_due("schedule-worker:misfire", 60)
    assert {:ok, missed} = Schedules.dispatch(claim.schedule.ref, claim.lease_ref, &policy/1, 60)
    assert missed.status == :missed
    assert missed.occurrence.status == :missed
    assert missed.occurrence.child_episode_id == nil
    assert missed.occurrence.missed_reason == "outside_misfire_grace"
    assert Repo.aggregate(Episode, :count, :id) == 1
  end

  test "crossed and undelivered controls cannot activate a schedule" do
    fixture = delivered_offer!("crossed")

    crossed =
      fixture
      |> confirmation("crossed")
      |> put_in([:target, :message_ref], "1787832999.999999")

    assert Schedules.confirm(crossed) == {:error, :schedule_offer_delivery_mismatch}
    assert Repo.get!(Record, fixture.record.id).status == :open
    assert Repo.aggregate(Schedule, :count, :id) == 0

    Repo.update_all(Record, set: [status: :dismissed])
    assert Schedules.confirm(confirmation(fixture, "stale")) == {:error, :schedule_offer_stale}
  end

  test "schedule leases renew, defer bounded failures, and reject invalid policy authority" do
    fixture = delivered_offer!("lease")
    assert {:ok, confirmed} = Schedules.confirm(confirmation(fixture, "lease"))
    make_due!(confirmed.schedule, DateTime.add(database_now!(), -1, :second))

    assert {:ok, claim} = Schedules.claim_due("schedule-worker:lease", 60)
    assert {:ok, renewed} = Schedules.renew(claim.schedule.ref, claim.lease_ref, 120)
    assert DateTime.compare(renewed.lease_expires_at, claim.schedule.lease_expires_at) == :gt

    assert Schedules.renew(claim.schedule.ref, "wrong-lease", 60) ==
             {:error, :schedule_lease_lost}

    assert Schedules.dispatch(claim.schedule.ref, claim.lease_ref, fn _ -> {:ok, %{}} end, 0) ==
             {:error, :schedule_policy_unavailable}

    reason = {:temporary_failure, String.duplicate("x", 8_000)}
    assert {:ok, deferred} = Schedules.defer(claim.schedule.ref, claim.lease_ref, 30, reason)
    assert deferred.failure_count == 1
    assert deferred.lease_ref == nil
    assert byte_size(deferred.last_error) <= 4_096
    assert {:ok, nil} = Schedules.claim_due("schedule-worker:too-soon", 60)
  end

  test "expired due schedules are terminalized without starving the next claim" do
    fixture = delivered_offer!("expired")
    assert {:ok, confirmed} = Schedules.confirm(confirmation(fixture, "expired"))
    now = database_now!()

    Repo.update_all(
      from(schedule in Schedule, where: schedule.id == ^confirmed.schedule.id),
      set: [
        expires_at: DateTime.add(now, -1, :second),
        next_occurrence_at: DateTime.add(now, -2, :second)
      ]
    )

    assert {:ok, nil} = Schedules.claim_due("schedule-worker:expired", 60)
    assert Repo.get!(Schedule, confirmed.schedule.id).status == :expired
  end

  test "latest catch-up dispatches only the newest due interval and keeps the next run future" do
    fixture =
      delivered_offer!("latest-catch-up",
        recurrence: %{
          "every_seconds" => 300,
          "kind" => "interval",
          "starts_at" => DateTime.to_iso8601(DateTime.add(@now, 300, :second))
        }
      )

    assert {:ok, confirmed} = Schedules.confirm(confirmation(fixture, "latest-catch-up"))
    now = database_now!()
    make_due!(confirmed.schedule, DateTime.add(now, -3_601, :second))

    assert {:ok, claim} = Schedules.claim_due("schedule-worker:latest-catch-up", 60)

    assert {:ok, dispatched} =
             Schedules.dispatch(claim.schedule.ref, claim.lease_ref, &policy/1, 60)

    assert dispatched.status == :dispatched
    assert DateTime.compare(dispatched.occurrence.scheduled_for, now) != :gt
    assert DateTime.diff(now, dispatched.occurrence.scheduled_for, :second) < 300

    assert DateTime.compare(
             dispatched.schedule.next_occurrence_at,
             dispatched.occurrence.scheduled_for
           ) == :gt
  end

  test "a one-time schedule completes after its only exact occurrence" do
    fixture =
      delivered_offer!("once",
        recurrence: %{
          "at" => DateTime.to_iso8601(DateTime.add(@now, 3_600, :second)),
          "kind" => "once"
        }
      )

    assert {:ok, confirmed} =
             Schedules.confirm(
               confirmation(fixture, "once")
               |> Map.update!(:occurred_at, &DateTime.to_iso8601/1)
             )

    make_due!(confirmed.schedule, DateTime.add(database_now!(), -1, :second))
    assert {:ok, claim} = Schedules.claim_due("schedule-worker:once", 60)

    assert {:ok, dispatched} =
             Schedules.dispatch(claim.schedule.ref, claim.lease_ref, &policy/1, 0)

    assert dispatched.schedule.status == :completed
    assert dispatched.schedule.next_occurrence_at == nil
    assert {:ok, nil} = Schedules.claim_due("schedule-worker:once-retry", 60)
  end

  test "run now is audited once and never moves the recurring cadence" do
    fixture = delivered_offer!("run-now")
    assert {:ok, confirmed} = Schedules.confirm(confirmation(fixture, "run-now"))
    original_next = confirmed.schedule.next_occurrence_at
    scope = %{conversation_prefix: "slack:T123:", transport: "slack"}

    assert Enum.any?(
             AppHomeProjection.snapshot("T123", "U123", MapSet.new(["C456"])).schedules,
             fn row ->
               row.ref == confirmed.schedule.ref and row.title == "Daily service health" and
                 row.status == :active and row.next_occurrence_at == original_next and
                 row.url ==
                   "https://slack.com/app_redirect?team=T123&channel=C456&message_ts=1787832000.000100"
             end
           )

    assert {:ok, first} =
             Schedules.run_now(
               confirmed.schedule.ref,
               "slack:user:U123",
               "interaction:run-now",
               scope,
               &policy/1
             )

    assert first.status == :recorded
    assert first.outcome["status"] == "dispatched"
    assert is_binary(first.outcome["episode_id"])
    assert is_binary(first.outcome["run_ref"])

    cadence = Repo.get!(Schedule, confirmed.schedule.id)
    assert cadence.status == :active
    assert cadence.revision == confirmed.schedule.revision + 1
    assert cadence.next_occurrence_at == original_next

    assert %ScheduleOccurrence{trigger: :manual} =
             Repo.get_by!(ScheduleOccurrence, ref: first.outcome["run_ref"])

    assert {:ok, duplicate} =
             Schedules.run_now(
               confirmed.schedule.ref,
               "slack:user:U123",
               "interaction:run-now",
               scope,
               &policy/1
             )

    assert duplicate.status == :duplicate
    assert duplicate.outcome == first.outcome
    assert Repo.aggregate(ScheduleOccurrence, :count, :id) == 1

    assert Schedules.run_now(
             confirmed.schedule.ref,
             "slack:user:U123",
             "interaction:run-now-overlap",
             scope,
             &policy/1
           ) == {:error, :schedule_occurrence_active}

    assert Schedules.run_now(
             confirmed.schedule.ref,
             "slack:user:U123",
             "interaction:run-now-crossed",
             %{conversation_prefix: "slack:T999:", transport: "slack"},
             &policy/1
           ) == {:error, :schedule_scope_mismatch}
  end

  test "an elapsed schedule cannot dispatch or survive a stale App Home control" do
    fixture = delivered_offer!("expired-home-run")
    assert {:ok, confirmed} = Schedules.confirm(confirmation(fixture, "expired-home-run"))
    expire!(confirmed.schedule)
    scope = %{conversation_prefix: "slack:T123:", transport: "slack"}
    episode_count = Repo.aggregate(Episode, :count, :id)
    occurrence_count = Repo.aggregate(ScheduleOccurrence, :count, :id)

    assert {:ok, run_receipt} =
             Schedules.run_now(
               confirmed.schedule.ref,
               "slack:user:U123",
               "interaction:expired-home-run",
               scope,
               fn _schedule -> flunk("an expired schedule must not resolve a dispatch policy") end
             )

    assert run_receipt.status == :recorded
    assert run_receipt.outcome["status"] == "expired"
    assert Repo.get!(Schedule, confirmed.schedule.id).status == :expired
    assert Repo.aggregate(Episode, :count, :id) == episode_count
    assert Repo.aggregate(ScheduleOccurrence, :count, :id) == occurrence_count

    deleted_fixture = delivered_offer!("expired-home-deleted")

    assert {:ok, deleted} =
             Schedules.confirm(confirmation(deleted_fixture, "expired-home-deleted"))

    expire!(deleted.schedule, :deleted)

    assert Schedules.run_now(
             deleted.schedule.ref,
             "slack:user:U123",
             "interaction:expired-home-deleted",
             scope,
             fn _schedule -> flunk("deleted work must not resolve a dispatch policy") end
           ) == {:error, :schedule_terminal}

    assert Repo.get!(Schedule, deleted.schedule.id).status == :deleted

    for {suffix, starting_status, requested_status} <- [
          {"pause", :active, :paused},
          {"resume", :paused, :active}
        ] do
      fixture = delivered_offer!("expired-home-#{suffix}")

      assert {:ok, control} =
               Schedules.confirm(confirmation(fixture, "expired-home-#{suffix}"))

      expire!(control.schedule, starting_status)

      assert {:ok, receipt} =
               Schedules.set_home_status(
                 control.schedule.ref,
                 requested_status,
                 control.schedule.revision,
                 "slack:user:U123",
                 "interaction:expired-home-#{suffix}",
                 scope
               )

      assert receipt.status == :recorded
      assert receipt.outcome["status"] == "expired"
      assert Repo.get!(Schedule, control.schedule.id).status == :expired
    end
  end

  test "the local operator can run a schedule through the same audited occurrence path" do
    fixture = delivered_offer!("operator-run-now")
    assert {:ok, confirmed} = Schedules.confirm(confirmation(fixture, "operator-run-now"))
    original_next = confirmed.schedule.next_occurrence_at

    assert {:ok, receipt} =
             Schedules.run_now_for_operator(
               confirmed.schedule.ref,
               "control-plane:local",
               "control-plane:run-schedule:operator-run-now:1",
               &policy/1
             )

    assert receipt.status == :recorded

    assert %ScheduleOccurrence{trigger: :manual} =
             Repo.get_by!(ScheduleOccurrence, ref: receipt.outcome["run_ref"])

    stored = Repo.get!(Schedule, confirmed.schedule.id)
    assert stored.next_occurrence_at == original_next
    assert stored.revision == confirmed.schedule.revision + 1
  end

  test "App Home lifecycle retries cannot overwrite a newer schedule decision" do
    fixture = delivered_offer!("home-lifecycle")
    assert {:ok, confirmed} = Schedules.confirm(confirmation(fixture, "home-lifecycle"))
    schedule = confirmed.schedule
    scope = %{conversation_prefix: "slack:T123:", transport: "slack"}

    assert {:ok, paused_receipt} =
             Schedules.set_home_status(
               schedule.ref,
               :paused,
               schedule.revision,
               "slack:user:U123",
               "interaction:schedule:pause",
               scope
             )

    assert paused_receipt.status == :recorded
    assert paused_receipt.outcome["status"] == "paused"
    paused = Repo.get!(Schedule, schedule.id)

    assert {:ok, resumed_receipt} =
             Schedules.set_home_status(
               schedule.ref,
               :active,
               paused.revision,
               "slack:user:U123",
               "interaction:schedule:resume",
               scope
             )

    assert resumed_receipt.status == :recorded
    assert resumed_receipt.outcome["status"] == "active"

    assert {:ok, duplicate} =
             Schedules.set_home_status(
               schedule.ref,
               :paused,
               schedule.revision,
               "slack:user:U123",
               "interaction:schedule:pause",
               scope
             )

    assert duplicate.status == :duplicate
    assert Repo.get!(Schedule, schedule.id).status == :active
  end

  test "the next recurrence at or beyond expiry terminalizes the schedule" do
    fixture = delivered_offer!("next-expired")
    assert {:ok, confirmed} = Schedules.confirm(confirmation(fixture, "next-expired"))
    now = database_now!()
    due_at = DateTime.add(now, -1, :second)

    assert {:ok, next_at} =
             ScheduleRecurrence.next_after(
               confirmed.schedule.recurrence,
               confirmed.schedule.timezone,
               due_at
             )

    Repo.update_all(
      from(schedule in Schedule, where: schedule.id == ^confirmed.schedule.id),
      set: [
        expires_at: next_at,
        next_occurrence_at: due_at
      ]
    )

    assert {:ok, claim} = Schedules.claim_due("schedule-worker:next-expired", 60)

    assert {:ok, dispatched} =
             Schedules.dispatch(claim.schedule.ref, claim.lease_ref, &policy/1, 0)

    assert dispatched.schedule.status == :expired
    assert dispatched.schedule.next_occurrence_at == nil
  end

  test "public schedule controls reject malformed authority and missing resources" do
    assert {:error, _reason} = Schedules.confirm(%{})
    assert {:error, _reason} = Schedules.confirm(actor_ref: "duplicate", actor_ref: "duplicate")
    assert {:error, _reason} = Schedules.claim_due("", 0)
    assert {:error, _reason} = Schedules.dispatch("schedule", "lease", :not_a_resolver, 0)
    assert {:error, _reason} = Schedules.dispatch("schedule", "lease", &policy/1, -1)
    assert {:error, _reason} = Schedules.renew("schedule", "lease", 0)
    assert {:error, _reason} = Schedules.defer("schedule", "lease", 0, :failed)
    assert {:error, _reason} = Schedules.set_status("schedule", :unknown)
    assert {:error, _reason} = Schedules.set_status("schedule", :active, %{})
    assert {:error, _reason} = Schedules.run_now("", "", "", %{}, :not_a_resolver)
    assert {:error, _reason} = Schedules.run_now_for_operator("", "", "", :not_a_resolver)
    assert Schedules.set_status("missing-schedule", :active) == {:error, :schedule_not_found}
    assert Schedules.list_for_destination("slack", "slack:T123:C456") == []
  end

  defp delivered_offer!(suffix, options \\ []) do
    episode_id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: "slack:T123:C456",
          thread_ref: "1787832000.000100",
          transport: "slack"
        },
        episode_id: episode_id,
        episode_key: "schedule-offer-source:#{suffix}:#{episode_id}",
        native_input_id: "slack-message:schedule-offer:#{suffix}:#{episode_id}",
        occurred_at: @now,
        turn_ref: "turn:schedule-offer:#{suffix}:#{episode_id}"
      })

    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "responder-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:schedule-offer:#{suffix}", 60, :work)

    payload = %{
      "authority" => "read_only",
      "catch_up" => Keyword.get(options, :catch_up, "latest"),
      "expires_at" => Keyword.get(options, :expires_at),
      "recurrence" =>
        Keyword.get(options, :recurrence, %{"kind" => "daily", "time" => "13:00:00"}),
      "repository" => nil,
      "task" => "Inspect current service health.",
      "timezone" => "Etc/UTC",
      "title" => "Daily service health"
    }

    assert {:ok, record} =
             Records.create(
               Records.token(claim.turn),
               "schedule-offer",
               "schedule_offer",
               payload
             )

    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => episode_id},
               "Offer the requested schedule.",
               %{"type" => "object"},
               "work-final-v1"
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
               "coop-session:schedule-offer:#{suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:schedule-offer:#{suffix}"
             )

    candidate = ~s({"delivery":"reply","message":"I can schedule that."})
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
               "message" => "I can schedule that.",
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
               "validation-receipt:schedule-offer:#{suffix}"
             )

    assert {:ok, delivery_claim} =
             Custody.claim_next("delivery:schedule-offer:#{suffix}", 60, :delivery)

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

  defp make_due!(schedule, at) do
    Repo.update_all(
      from(stored in Schedule, where: stored.id == ^schedule.id),
      set: [
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        next_occurrence_at: at
      ]
    )
  end

  defp expire!(schedule, status \\ :active) do
    Repo.update_all(
      from(stored in Schedule, where: stored.id == ^schedule.id),
      set: [expires_at: DateTime.add(database_now!(), -1, :second), status: status]
    )
  end

  defp policy(_schedule), do: {:ok, @policy}

  defp database_now! do
    {:ok, %{rows: [[now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
