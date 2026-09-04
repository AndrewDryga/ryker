defmodule Responder.State.EventWaitsTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Episodes.Episode
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.State.{EventSubscription, EventSubscriptions, EventWaits, Record, Records}
  alias Responder.Work.Custody

  test "a due durable event wait resumes once with host-owned evidence" do
    {:ok, %{rows: [[now]]}} = Repo.query("SELECT clock_timestamp()")
    occurred_at = DateTime.add(now, -10, :second)
    deadline = DateTime.add(now, 3_600, :second)
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:event-wait-source:#{episode_id}"

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "event-wait-source:#{episode_id}",
                 native_input_id: "event-wait-input:#{episode_id}",
                 occurred_at: DateTime.add(occurred_at, -1, :second),
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "responder-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:event-wait", 60, :work)

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "wait", "event_wait", %{
               "deadline_at" => DateTime.to_iso8601(deadline),
               "event_matcher" => %{"deployment" => "responder"},
               "kind" => "deployment_health",
               "verification" => "Verify the deployment is healthy."
             })

    assert {:ok, waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 deadline_at: deadline,
                 episode_key: transition.episode.key,
                 expected_turn_ref: turn_ref,
                 kind: :event,
                 occurred_at: occurred_at,
                 wait_ref: record.ref
               })
             )

    assert waiting.episode.state == :waiting_for_event

    # Advance the durable deadline without sleeping; the worker itself still
    # decides eligibility from PostgreSQL time.
    Repo.update_all(
      from(episode in Episode, where: episode.id == ^episode_id),
      set: [owner_deadline_at: DateTime.add(now, -1, :second)]
    )

    assert {:ok, resumed} = EventWaits.resume_due()
    assert resumed.episode.state == :working
    assert resumed.episode.owner_kind == :turn
    assert resumed.record.status == :answered

    events = Episodes.list_events(transition.episode.key)

    assert Enum.map(events, & &1.kind) == [
             :input_admitted,
             :event_wait_started,
             :input_admitted,
             :wait_resumed
           ]

    assert List.last(events).payload["resolution_ref"] =~ "admit_input:"

    wakeup = Enum.at(events, 2)
    assert wakeup.payload["payload"]["content"]["kind"] == "deadline_elapsed"
    assert wakeup.payload["payload"]["content"]["event_wait_ref"] == record.ref

    assert Repo.get!(Record, record.id).status == :answered
    assert EventWaits.resume_due() == {:ok, :idle}
  end

  test "a lost source event wakes from its durable cursor before the hard deadline" do
    {:ok, %{rows: [[now]]}} = Repo.query("SELECT clock_timestamp()")
    fixture = active_source_wait!("poll-fallback", now)
    transition = fixture.transition
    subscription = fixture.subscription

    assert subscription.status == :active
    assert subscription.source_kind == "github"
    assert subscription.cursor == %{"updated_at" => "2026-09-04T06:00:00Z"}
    assert subscription.poll_after == fixture.poll_after
    assert subscription.deadline_at == fixture.deadline

    assert {:ok, {:ok, %EventSubscription{id: subscription_id}}} =
             Repo.transaction(fn ->
               EventSubscriptions.ensure_in_transaction(fixture.waiting.episode)
             end)

    assert subscription_id == subscription.id

    Repo.update_all(
      from(saved in EventSubscription, where: saved.id == ^subscription.id),
      set: [poll_after: DateTime.add(now, -1, :second)]
    )

    assert {:ok, resumed} = EventWaits.resume_due()
    assert resumed.episode.state == :working
    assert resumed.record.status == :answered

    subscription = Repo.get!(EventSubscription, subscription.id)
    assert subscription.status == :resolved
    assert subscription.resolution_kind == :poll_fallback
    assert subscription.revision == 2
    assert subscription.last_observation["kind"] == "poll_fallback"

    wakeup =
      transition.episode.key
      |> Episodes.list_events()
      |> Enum.find(&(&1.kind == :input_admitted and &1.sequence > 1))

    assert wakeup.payload["payload"]["content"]["kind"] == "poll_fallback_due"
    assert wakeup.payload["payload"]["content"]["cursor"] == subscription.cursor
    assert EventWaits.resume_due() == {:ok, :idle}
  end

  test "reconciliation cancels a subscription whose durable wait record is no longer open" do
    {:ok, %{rows: [[now]]}} = Repo.query("SELECT clock_timestamp()")
    fixture = active_source_wait!("cancel-stale", now)

    Repo.update_all(
      from(record in Record, where: record.id == ^fixture.record.id),
      set: [status: :dismissed]
    )

    assert {:ok, 1} = EventSubscriptions.reconcile()

    subscription = Repo.get!(EventSubscription, fixture.subscription.id)
    assert subscription.status == :cancelled
    assert subscription.resolution_kind == :cancelled
    assert subscription.last_observation["event_wait_ref"] == fixture.record.ref
    assert subscription.revision == 2
  end

  test "reconciliation restores a legacy source wait with its hard deadline as fallback" do
    {:ok, %{rows: [[now]]}} = Repo.query("SELECT clock_timestamp()")
    fixture = active_source_wait!("restore-legacy", now)

    payload =
      Map.update!(fixture.record.payload, "event_matcher", fn matcher ->
        Map.delete(matcher, "poll_after")
      end)

    Repo.delete!(fixture.subscription)

    Repo.update_all(
      from(record in Record, where: record.id == ^fixture.record.id),
      set: [payload: payload]
    )

    assert {:ok, 1} = EventSubscriptions.reconcile()

    assert Repo.get_by!(EventSubscription, record_id: fixture.record.id).poll_after ==
             fixture.deadline

    assert EventSubscriptions.ensure_in_transaction(fixture.waiting.episode) ==
             {:error, :event_subscription_transaction_required}

    assert EventSubscriptions.resolve_wait_in_transaction(fixture.record.ref, :cancelled) ==
             {:error, :event_subscription_transaction_required}

    assert EventSubscriptions.resolve_wait_in_transaction(fixture.record.ref, :unsupported) ==
             {:error, :event_subscription_not_found}

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               EventSubscriptions.resolve_wait_in_transaction("missing-wait", :cancelled)
             end)
  end

  defp active_source_wait!(suffix, now) do
    occurred_at = DateTime.add(now, -10, :second)
    poll_after = DateTime.add(now, 600, :second)
    deadline = DateTime.add(now, 3_600, :second)
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:event-subscription-source:#{episode_id}"

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "event-subscription-#{suffix}:#{episode_id}",
                 native_input_id: "event-subscription-input-#{suffix}:#{episode_id}",
                 occurred_at: DateTime.add(occurred_at, -1, :second),
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "responder-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:event-subscription:#{suffix}", 60, :work)

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "wait-source", "event_wait", %{
               "deadline_at" => DateTime.to_iso8601(deadline),
               "event_matcher" => %{
                 "cursor" => %{"updated_at" => "2026-09-04T06:00:00Z"},
                 "match" => %{"deployment" => "responder", "state" => "healthy"},
                 "on_timeout" => "Report the verification timeout.",
                 "poll_after" => DateTime.to_iso8601(poll_after),
                 "source_kind" => "github",
                 "type" => "source_event"
               },
               "kind" => "source_event",
               "verification" => "Read the deployment state and verify it is healthy."
             })

    assert {:ok, waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 deadline_at: deadline,
                 episode_key: transition.episode.key,
                 expected_turn_ref: turn_ref,
                 kind: :event,
                 occurred_at: occurred_at,
                 wait_ref: record.ref
               })
             )

    assert {:ok, %EventSubscription{} = subscription} =
             Repo.transaction(fn ->
               case EventSubscriptions.ensure_in_transaction(waiting.episode) do
                 {:ok, value} -> value
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    %{
      deadline: deadline,
      poll_after: poll_after,
      record: record,
      subscription: subscription,
      transition: transition,
      waiting: waiting
    }
  end
end
