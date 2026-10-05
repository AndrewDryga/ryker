defmodule Ryker.Waits.EventWaitsTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.ControlPlane.SubscriptionProjection
  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.Waits.EventSubscription
  alias Ryker.Waits.EventSubscriptions
  alias Ryker.Waits.EventWaits
  alias Ryker.Work.Custody

  test "an event-only source wait survives reconciliation without any timer wakeup" do
    # The real TFC wait created repeated unchanged replies at 10:45 and 11:15 UTC.
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

    fixture =
      active_wait!(
        "event-only",
        now,
        %{
          "type" => "source_event",
          "source_kind" => "slack",
          "match" => %{
            "bot_id" => "B0BHPQTBMA7",
            "attachments" => [%{"title" => "Run run-k9CpPp3nWjQrkCMG"}]
          },
          "poll_after" => nil,
          "on_timeout" => nil
        },
        nil
      )

    assert fixture.waiting.episode.state == :waiting_for_event
    assert fixture.waiting.episode.owner_deadline_at == nil
    assert fixture.subscription.poll_after == nil
    assert fixture.subscription.deadline_at == nil
    future = DateTime.add(now, 365, :day)

    assert EventWaits.resume_at(fixture.record.id, fixture.waiting.episode.id, future) ==
             {:error, :event_wait_not_due}

    assert EventWaits.resume_due() == {:ok, :idle}

    Repo.delete!(fixture.subscription)
    assert {:ok, 1} = EventSubscriptions.reconcile()
    restored = Repo.get_by!(EventSubscription, record_id: fixture.record.id)
    assert restored.status == :active
    assert restored.poll_after == nil
    assert restored.deadline_at == nil
    assert Repo.get!(Record, fixture.record.id).wait_error == nil
    assert EventWaits.resume_due() == {:ok, :idle}
  end

  # Episode 0b0c3590 in production, 2026-09-13, asked a question while two event-only watches
  # stayed open, and the validator learned to accept that. Ensuring the episode's subscription
  # then read "the" event-only watch with Repo.one, which raises on two: the reply's delivery
  # confirmation would raise on every retry, with the person's answer queued behind it, and the
  # event-wait worker would crash on every poll (2026-10-04 review). One subscription per episode
  # stays the rule; it goes to the oldest watch.
  test "a question asked beside two event-only watches subscribes the oldest of them" do
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:two-watches:#{episode_id}"
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "two-watches:#{episode_id}",
                 native_input_id: "two-watches-input:#{episode_id}",
                 occurred_at: DateTime.add(now, -20, :second),
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "ryker-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:two-watches", 60, :work)

    watch = fn ref, title ->
      Records.create(Records.token(claim.turn), ref, "event_wait", %{
        "deadline_at" => nil,
        "event_matcher" => %{
          "type" => "source_event",
          "source_kind" => "slack",
          "match" => %{"attachments" => [%{"title" => title}]},
          "poll_after" => nil,
          "on_timeout" => nil
        },
        "kind" => "source_event",
        "verification" => "Read the run and say whether it finished."
      })
    end

    assert {:ok, first} = watch.("watch-first", "Run first")
    assert {:ok, _second} = watch.("watch-second", "Run second")

    assert {:ok, waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 episode_key: transition.episode.key,
                 expected_turn_ref: turn_ref,
                 kind: :input,
                 occurred_at: DateTime.add(now, -10, :second),
                 wait_ref: "question-beside-two-watches"
               })
             )

    assert waiting.episode.state == :waiting_for_input

    assert {:ok, %EventSubscription{record_id: record_id, status: :active}} =
             Repo.transaction(fn ->
               case EventSubscriptions.ensure_in_transaction(waiting.episode) do
                 {:ok, value} -> value
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    assert record_id == first.id
    assert {:ok, _count} = EventSubscriptions.reconcile()

    assert Repo.aggregate(
             from(s in EventSubscription, where: s.episode_id == ^episode_id),
             :count
           ) == 1
  end

  # Follow-ups lists what Ryker waits for and a request's page shows its wait.
  # Until 2026-09-26 both heard of a change from a trigger's NOTIFY and a
  # five-second poll; the context now announces each wait it starts or ends.
  test "a follow-up Ryker starts waiting on reaches the follow-ups list and its request" do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

    fixture =
      active_wait!(
        "announced",
        now,
        %{
          "type" => "source_event",
          "source_kind" => "slack",
          "match" => %{"bot_id" => "B0ANNOUNCED"},
          "poll_after" => nil,
          "on_timeout" => nil
        },
        nil
      )

    episode_id = fixture.waiting.episode.id
    Repo.delete!(fixture.subscription)
    :ok = EventSubscriptions.subscribe_follow_ups()
    :ok = Episodes.subscribe_episode(episode_id)

    assert {:ok, 1} = EventSubscriptions.reconcile()
    %{id: id} = Repo.get_by!(EventSubscription, record_id: fixture.record.id)
    assert_received {:follow_up_updated, ^id}
    assert_received {:episode_updated, ^episode_id}
  end

  test "source waits at the canonical byte limits persist without a database check failure" do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    cursor = %{"value" => String.duplicate("é", 8_186)}
    assert byte_size(Ryker.CanonicalJSON.encode!(cursor)) == 16_384
    source_kind = String.duplicate("a", 120)

    fixture =
      active_wait!("source-bounds", now, %{
        "type" => "source_event",
        "source_kind" => source_kind,
        "cursor" => cursor,
        "match" => %{"run_id" => "run-one"},
        "poll_after" => DateTime.to_iso8601(DateTime.add(now, 600, :second)),
        "on_timeout" => "Report verification gap."
      })

    assert fixture.subscription.cursor == cursor
    assert fixture.subscription.source_kind == source_kind
  end

  test "a real subscription uniqueness failure is not mislabeled as invalid scheduling data" do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    occupied = active_source_wait!("occupied", now)
    target = active_source_wait!("target", now)
    Repo.delete!(target.subscription)

    Repo.update_all(
      from(subscription in EventSubscription,
        where: subscription.id == ^occupied.subscription.id
      ),
      set: [episode_id: target.waiting.episode.id]
    )

    assert {:error, {:event_subscription_persistence_failed, errors}} =
             Repo.transaction(fn ->
               case EventSubscriptions.ensure_in_transaction(target.waiting.episode) do
                 {:error, reason} -> Repo.rollback(reason)
                 result -> result
               end
             end)

    assert Keyword.has_key?(errors, :episode_id)
    assert Repo.get!(Record, target.record.id).wait_error == nil
  end

  for type <- ~w(after at source_event) do
    test "a #{type} wait without a subscription can time out only at its saved hard deadline" do
      %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

      fixture =
        if unquote(type) == "source_event",
          do: active_source_wait!("missing", now),
          else: active_timer_wait!(unquote(type), now)

      Repo.delete!(fixture.subscription)

      assert EventWaits.resume_at(
               fixture.record.id,
               fixture.waiting.episode.id,
               DateTime.add(fixture.deadline, -1, :microsecond)
             ) == {:error, :event_wait_not_due}

      assert {:ok, %{record: %{status: :answered}}} =
               EventWaits.resume_at(
                 fixture.record.id,
                 fixture.waiting.episode.id,
                 fixture.deadline
               )

      wakeup =
        Episodes.list_events(fixture.transition.episode.key)
        |> Enum.find(&(&1.kind == :input_admitted and &1.sequence > 1))

      assert wakeup.payload["payload"]["content"]["kind"] == "deadline_elapsed"

      assert EventWaits.resume_at(fixture.record.id, fixture.waiting.episode.id, fixture.deadline) ==
               {:ok, :idle}
    end
  end

  test "a missing subscription cannot authorize a deadline changed away from its saved promise" do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    fixture = active_timer_wait!("after", now)
    Repo.delete!(fixture.subscription)

    Repo.update_all(from(episode in Episode, where: episode.id == ^fixture.waiting.episode.id),
      set: [owner_deadline_at: now]
    )

    assert EventWaits.resume_at(fixture.record.id, fixture.waiting.episode.id, now) ==
             {:ok, :idle}

    assert Repo.get!(Record, fixture.record.id).status == :open
  end

  for invalid_deadline <- ["not-a-date", nil, 42] do
    test "an invalid saved deadline #{inspect(invalid_deadline)} cannot poison selection of another due wait" do
      %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
      fixture = active_timer_wait!("after", now)
      expire_wait!(fixture, DateTime.add(now, -2, :second))
      Repo.delete!(fixture.subscription)
      payload = Map.put(fixture.record.payload, "deadline_at", unquote(invalid_deadline))

      Repo.update_all(from(record in Record, where: record.id == ^fixture.record.id),
        set: [payload: payload]
      )

      healthy = active_timer_wait!("after", now)
      expire_wait!(healthy, DateTime.add(now, -1, :second))

      assert {:ok, %{record: resumed_record}} = EventWaits.resume_due()
      assert resumed_record.id == healthy.record.id
      assert Repo.get!(Record, fixture.record.id).wait_error == "deadline"

      assert EventWaits.resume_at(fixture.record.id, fixture.waiting.episode.id, now) ==
               {:ok, :idle}

      assert EventWaits.resume_due() == {:ok, :idle}
    end
  end

  for status <- [:cancelled, :resolved, :timed_out] do
    test "an inactive #{status} subscription cannot block another expired wait" do
      %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
      fixture = active_timer_wait!("after", now)
      expire_wait!(fixture, DateTime.add(now, -2, :second))

      resolution =
        %{cancelled: :cancelled, resolved: :timer, timed_out: :deadline}[unquote(status)]

      Repo.update_all(
        from(subscription in EventSubscription,
          where: subscription.id == ^fixture.subscription.id
        ),
        set: [status: unquote(status), resolution_kind: resolution]
      )

      healthy = active_timer_wait!("after", now)
      expire_wait!(healthy, DateTime.add(now, -1, :second))

      assert {:ok, %{record: resumed_record}} = EventWaits.resume_due()
      assert resumed_record.id == healthy.record.id
      assert Repo.get!(Record, fixture.record.id).status == :open
      assert EventWaits.resume_due() == {:ok, :idle}
    end
  end

  test "a mismatched active subscription cannot monopolize the due queue" do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    fixture = active_timer_wait!("after", now)
    expire_wait!(fixture, DateTime.add(now, -2, :second))

    Repo.update_all(
      from(subscription in EventSubscription, where: subscription.id == ^fixture.subscription.id),
      set: [
        deadline_at: DateTime.add(now, -3, :second),
        poll_after: DateTime.add(now, -4, :second)
      ]
    )

    healthy = active_timer_wait!("after", now)
    expire_wait!(healthy, DateTime.add(now, -1, :second))

    assert {:ok, %{record: resumed_record}} = EventWaits.resume_due()
    assert resumed_record.id == healthy.record.id
    assert Repo.get!(Record, fixture.record.id).status == :open
  end

  # Each poll took the earliest due wait again, so one wait Ryker could not resume held up every
  # wait due after it (2026-10-04 review). It is marked, passed over, and tried again ten minutes
  # on.
  for path <- [:timer, :deadline] do
    test "a wait whose #{path} wake-up fails holds up no other wait and is tried again later" do
      %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
      failing = active_timer_wait!("after", now)
      healthy = active_timer_wait!("after", now)
      make_due!(failing, unquote(path), DateTime.add(now, -2, :second))
      make_due!(healthy, unquote(path), DateTime.add(now, -1, :second))

      # The request already holds the wake-up input, so admitting it again is refused.
      revisions = failing.waiting.episode.input_revisions
      wakeup = "state-event-wait:#{failing.record.ref}"
      set_input_revisions!(failing, Map.put(revisions, wakeup, 1))

      assert {:error, {:event_wait_resume_failed, failed_id, _reason}} = EventWaits.resume_due()
      assert failed_id == failing.record.id

      assert %Record{status: :open, wait_error: "resume_failed"} =
               Repo.get!(Record, failing.record.id)

      assert {:ok, %{record: resumed}} = EventWaits.resume_due()
      assert resumed.id == healthy.record.id
      assert EventWaits.resume_due() == {:ok, :idle}

      set_input_revisions!(failing, revisions)

      Repo.update_all(from(record in Record, where: record.id == ^failing.record.id),
        set: [updated_at: DateTime.add(now, -601, :second)]
      )

      assert {:ok, %{record: %Record{status: :answered, wait_error: nil} = retried}} =
               EventWaits.resume_due()

      assert retried.id == failing.record.id
    end
  end

  # One wait whose subscription could not be saved rolled back the whole reconciliation, and
  # every due wait waited behind it (2026-10-04 review).
  test "a wait Ryker cannot schedule holds up no other wait and is tried again later" do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    unschedulable = active_source_wait!("unschedulable", now)
    Repo.delete!(unschedulable.subscription)
    trigger = unschedulable.record.payload["event_matcher"]
    # The subscription table keeps a match only as an object.
    set_trigger!(unschedulable, Map.put(trigger, "match", ["not", "an", "object"]))

    healthy = active_timer_wait!("after", now)
    make_due!(healthy, :timer, DateTime.add(now, -1, :second))

    assert {:ok, %{record: resumed}} = EventWaits.resume_due()
    assert resumed.id == healthy.record.id

    assert %Record{status: :open, wait_error: "schedule_failed"} =
             Repo.get!(Record, unschedulable.record.id)

    assert {:ok, 0} = EventSubscriptions.reconcile()

    set_trigger!(unschedulable, trigger)

    Repo.update_all(from(record in Record, where: record.id == ^unschedulable.record.id),
      set: [updated_at: DateTime.add(now, -601, :second)]
    )

    assert {:ok, 1} = EventSubscriptions.reconcile()
    assert Repo.get!(Record, unschedulable.record.id).wait_error == nil
    assert Repo.get_by!(EventSubscription, record_id: unschedulable.record.id).status == :active
  end

  for timer_type <- ~w(after at) do
    test "a #{timer_type} timer wakes at its scheduled time, not its hard deadline" do
      # The real Airflow world armed after:10m with a 15-minute deadline,
      # but the worker ignored the timer and could only report a timeout.
      %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
      fixture = active_timer_wait!(unquote(timer_type), now)
      due_at = fixture.subscription.poll_after

      expected =
        if unquote(timer_type) == "after",
          do: DateTime.add(fixture.record.inserted_at, 600, :second),
          else: DateTime.add(now, 600, :second)

      assert due_at == expected
      assert fixture.subscription.source_kind == nil
      assert fixture.subscription.matcher == %{}

      assert [%{trigger_type: trigger_type, source_kind: nil}] =
               SubscriptionProjection.list(%{"q" => fixture.subscription.ref})

      assert trigger_type == unquote(timer_type)
      assert EventWaits.resume_due() == {:ok, :idle}

      assert EventWaits.resume_at(
               fixture.record.id,
               fixture.waiting.episode.id,
               DateTime.add(due_at, -1, :microsecond)
             ) == {:error, :event_wait_not_due}

      assert {:ok, resumed} =
               EventWaits.resume_at(fixture.record.id, fixture.waiting.episode.id, due_at)

      assert resumed.episode.state == :working
      assert resumed.record.status == :answered
      subscription = Repo.get!(EventSubscription, fixture.subscription.id)
      assert subscription.status == :resolved
      assert subscription.resolution_kind == :timer
      assert subscription.last_observation["kind"] == "timer"

      wakeup =
        fixture.transition.episode.key
        |> Episodes.list_events()
        |> Enum.find(&(&1.kind == :input_admitted and &1.sequence > 1))

      assert wakeup.payload["payload"]["content"]["kind"] == "timer_due"
      assert wakeup.payload["payload"]["source"] == %{"kind" => "system", "ref" => "ryker"}
      assert wakeup.payload["payload"]["content"]["event_wait_ref"] == fixture.record.ref

      assert EventWaits.resume_at(fixture.record.id, fixture.waiting.episode.id, due_at) ==
               {:ok, :idle}
    end
  end

  # The event-wait lane sleeps until this moment (`PollingWorker.idle_delay/2`): an
  # answer too late or missing leaves a due wait waiting out the safety-net interval.
  # The 2026-09-27 crash was in this family, a due-time aggregate that came back without
  # a zone and crashed every Work and delivery lane on each poll while a row was due.
  # Nothing ran this query against rows before.
  test "the event-wait lane sleeps until a wait's polling fallback, then its hard deadline" do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    fixture = active_source_wait!("due-source", now)
    poll_after = fixture.subscription.poll_after
    deadline = fixture.deadline
    assert DateTime.compare(poll_after, deadline) == :lt

    assert EventWaits.next_due_at(now) == poll_after
    assert EventWaits.next_due_at(poll_after) == deadline

    # A wait with no subscription still times out at its episode's deadline.
    Repo.delete!(fixture.subscription)
    assert Repo.get!(Episode, fixture.waiting.episode.id).owner_deadline_at == deadline
    assert EventWaits.next_due_at(now) == deadline
    assert EventWaits.next_due_at(deadline) == nil
  end

  test "reconciliation retains a timer's original due time after a restart" do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    fixture = active_timer_wait!("after", now)
    due_at = fixture.subscription.poll_after
    Repo.delete!(fixture.subscription)

    assert {:ok, 1} = EventSubscriptions.reconcile()
    restored = Repo.get_by!(EventSubscription, record_id: fixture.record.id)
    assert restored.poll_after == due_at
    assert {:ok, 0} = EventSubscriptions.reconcile()
    assert Repo.get_by!(EventSubscription, record_id: fixture.record.id).id == restored.id
  end

  test "the regular PostgreSQL-clock worker picks an overdue timer before its deadline" do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    fixture = active_timer_wait!("after", now)

    Repo.update_all(from(saved in EventSubscription, where: saved.id == ^fixture.subscription.id),
      set: [poll_after: DateTime.add(now, -1, :second)]
    )

    assert {:ok, resumed} = EventWaits.resume_due()
    assert resumed.record.id == fixture.record.id
    assert Repo.get!(EventSubscription, fixture.subscription.id).resolution_kind == :timer
    assert EventWaits.resume_due() == {:ok, :idle}
  end

  test "a changed subscription deadline cannot turn a timer into an early timeout" do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    fixture = active_timer_wait!("after", now)
    due_at = fixture.subscription.poll_after

    Repo.update_all(from(saved in EventSubscription, where: saved.id == ^fixture.subscription.id),
      set: [deadline_at: due_at]
    )

    assert EventWaits.resume_at(fixture.record.id, fixture.waiting.episode.id, due_at) ==
             {:ok, :idle}

    assert Repo.get!(Record, fixture.record.id).status == :open
    assert length(Episodes.list_events(fixture.transition.episode.key)) == 2
  end

  test "a timer cannot resume a different episode even when both waits are due" do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    first = active_timer_wait!("after", now)
    second = active_timer_wait!("at", now)

    assert EventWaits.resume_at(
             first.record.id,
             second.waiting.episode.id,
             first.subscription.poll_after
           ) ==
             {:ok, :idle}

    assert Repo.get!(Record, first.record.id).status == :open
    assert Repo.get!(Record, second.record.id).status == :open
    assert length(Episodes.list_events(first.transition.episode.key)) == 2
    assert length(Episodes.list_events(second.transition.episode.key)) == 2
  end

  test "a timer processed after its hard deadline reports timeout instead of completion" do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    fixture = active_timer_wait!("after", now)

    assert {:ok, resumed} =
             EventWaits.resume_at(
               fixture.record.id,
               fixture.waiting.episode.id,
               fixture.deadline
             )

    assert resumed.record.status == :answered
    subscription = Repo.get!(EventSubscription, fixture.subscription.id)
    assert subscription.status == :timed_out
    assert subscription.resolution_kind == :deadline

    wakeup =
      fixture.transition.episode.key
      |> Episodes.list_events()
      |> Enum.find(&(&1.kind == :input_admitted and &1.sequence > 1))

    assert wakeup.payload["payload"]["content"]["kind"] == "deadline_elapsed"
  end

  test "cancelling a timer prevents its scheduled continuation" do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    fixture = active_timer_wait!("after", now)

    Repo.update_all(from(record in Record, where: record.id == ^fixture.record.id),
      set: [status: :dismissed]
    )

    assert {:ok, 1} = EventSubscriptions.reconcile()

    assert EventWaits.resume_at(
             fixture.record.id,
             fixture.waiting.episode.id,
             fixture.subscription.poll_after
           ) == {:ok, :idle}

    assert Repo.get!(EventSubscription, fixture.subscription.id).status == :cancelled
    assert length(Episodes.list_events(fixture.transition.episode.key)) == 2
  end

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
             Custody.pin_episode(episode_id, "ryker-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:event-wait", 60, :work)

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "wait", "event_wait", %{
               "deadline_at" => DateTime.to_iso8601(deadline),
               "event_matcher" => %{"deployment" => "ryker"},
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

    # Advance the saved promise with its owner, preserving the deadline custody
    # invariant. A mismatched owner-only deadline is tested as a denial above.
    payload =
      Map.put(record.payload, "deadline_at", DateTime.to_iso8601(DateTime.add(now, -1, :second)))

    Repo.update_all(from(saved in Record, where: saved.id == ^record.id),
      set: [payload: payload, payload_fingerprint: Ryker.CanonicalJSON.digest(payload)]
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
    active_wait!(suffix, now, %{
      "cursor" => %{"updated_at" => "2026-09-04T06:00:00Z"},
      "match" => %{"deployment" => "ryker", "state" => "healthy"},
      "on_timeout" => "Report the verification timeout.",
      "poll_after" => now |> DateTime.add(600, :second) |> DateTime.to_iso8601(),
      "source_kind" => "github",
      "type" => "source_event"
    })
  end

  defp active_timer_wait!(type, now) do
    trigger =
      if type == "after",
        do: %{"type" => "after", "delay" => "10m"},
        else: %{
          "type" => "at",
          "at" => now |> DateTime.add(600, :second) |> DateTime.to_iso8601()
        }

    active_wait!(
      "timer-#{type}",
      now,
      Map.put(trigger, "on_timeout", "Report the verification gap.")
    )
  end

  defp active_wait!(suffix, now, trigger, deadline_override \\ :timed) do
    occurred_at = DateTime.add(now, -10, :second)
    poll_after = DateTime.add(now, 600, :second)

    deadline =
      if deadline_override == :timed,
        do:
          DateTime.add(now, if(trigger["type"] == "source_event", do: 3_600, else: 900), :second),
        else: deadline_override

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
             Custody.pin_episode(episode_id, "ryker-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:event-subscription:#{suffix}", 60, :work)

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "wait-source", "event_wait", %{
               "deadline_at" => if(deadline, do: DateTime.to_iso8601(deadline)),
               "event_matcher" => trigger,
               "kind" => trigger["type"],
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

  defp make_due!(fixture, :timer, at) do
    Repo.update_all(
      from(subscription in EventSubscription, where: subscription.id == ^fixture.subscription.id),
      set: [poll_after: at]
    )
  end

  defp make_due!(fixture, :deadline, at), do: expire_wait!(fixture, at)

  defp set_input_revisions!(fixture, revisions) do
    Repo.update_all(from(episode in Episode, where: episode.id == ^fixture.waiting.episode.id),
      set: [input_revisions: revisions]
    )
  end

  defp set_trigger!(fixture, trigger) do
    payload = Map.put(fixture.record.payload, "event_matcher", trigger)

    Repo.update_all(from(record in Record, where: record.id == ^fixture.record.id),
      set: [payload: payload, payload_fingerprint: Ryker.CanonicalJSON.digest(payload)]
    )
  end

  defp expire_wait!(fixture, deadline) do
    payload = Map.put(fixture.record.payload, "deadline_at", DateTime.to_iso8601(deadline))

    Repo.update_all(from(record in Record, where: record.id == ^fixture.record.id),
      set: [payload: payload, payload_fingerprint: Ryker.CanonicalJSON.digest(payload)]
    )

    Repo.update_all(from(episode in Episode, where: episode.id == ^fixture.waiting.episode.id),
      set: [owner_deadline_at: deadline]
    )

    Repo.update_all(
      from(subscription in EventSubscription, where: subscription.id == ^fixture.subscription.id),
      set: [deadline_at: deadline, poll_after: DateTime.add(deadline, -1, :second)]
    )
  end
end
