defmodule Ryker.Learning.BatchesTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.Defaults
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Learning, as: Fixtures
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning
  alias Ryker.Learning.{Batch, Batches, InputMembership}
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Learning.LearningRun
  alias Ryker.Learning.Observations
  alias Ryker.Repo
  alias Ryker.Work.{Custody, DeliveryReceipt, Result, Submission, Turn}

  @settings %{
    policy: "recorded-read-only-policy",
    policy_digest: String.duplicate("a", 64),
    quiet_seconds: 0,
    maximum_delay_seconds: 60,
    lease_seconds: 300,
    batch_size: 16
  }

  # Memory › Learning lists what waits to be learned and what each pass did.
  # Until 2026-09-26 it heard of a new batch from a trigger's NOTIFY and a
  # five-second poll; the context now announces a batch it assembles, and a
  # lease renewal, which no page shows, stays quiet.
  test "a batch assembled for learning reaches the learning page, and a renewal does not" do
    inputs!()
    :ok = Learning.subscribe_learning()

    assert {:ok, claim} = Batches.claim("worker-announced", @settings)
    batch_id = claim.batch.id
    assert_received {:learning_updated, ^batch_id}

    assert {:ok, _renewed} = Batches.renew(claim, 300)
    refute_received {:learning_updated, ^batch_id}
  end

  test "one input revision belongs to one batch even after a worker lease expires" do
    entries = inputs!()
    assert {:ok, first} = Batches.claim("worker-a", @settings)
    assert Enum.map(first.inputs, & &1.id) == Enum.map(entries, & &1.id)
    assert {:ok, :idle} = Batches.claim("worker-b", @settings)
    Repo.update_all(Batch, set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1)])
    assert {:ok, recovered} = Batches.claim("worker-b", @settings)
    assert recovered.batch.id == first.batch.id
    refute recovered.lease_ref == first.lease_ref
    assert Repo.aggregate(InputMembership, :count) == 2
    assert {:error, :learning_lease_lost} = Batches.renew(first, 300)
    assert {:ok, _} = Batches.renew(recovered, 300)
  end

  test "execution modes never share a batch and future arrivals cannot mutate an active batch" do
    [first, second] = inputs!()

    assert {1, _} =
             Repo.update_all(
               from(e in Entry, where: e.id == ^second.id),
               set: [execution_mode: :live]
             )

    assert {:ok, a} = Batches.claim("worker-a", @settings)
    assert [input] = a.inputs
    assert input.id == first.id
    assert {:ok, b} = Batches.claim("worker-b", @settings)
    assert Enum.map(b.inputs, & &1.id) == [second.id]
    refute a.batch.id == b.batch.id
    assert {:ok, :idle} = Batches.claim("worker-c", @settings)
  end

  test "three started executions exhaust a batch across new judgments and pruned receipts" do
    # Contract failures previously bought fresh generations indefinitely. Count
    # the host start before submit, not the number of retained failure bodies.
    _entries = inputs!()

    for attempt <- 1..3 do
      assert {:ok, claim} = Batches.claim("worker", @settings)
      assert {:ok, run} = Learning.prepare(Enum.map(claim.inputs, & &1.id), @settings)
      assert {:ok, started} = Batches.begin_execution(claim, run.id)
      assert started.started_at != nil
      assert {:ok, ^started} = Batches.begin_execution(claim, run.id)
      assert Repo.get!(Batch, claim.batch.id).start_count == attempt

      body =
        "testdata/learning/retained-output-contract-failure.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("public_responses")
        |> hd()
        |> Map.fetch!("text")

      assert {:error, :invalid_learning_result} =
               Fixtures.accept(run.id, body, %{})

      assert {:ok, _} =
               Learning.record_stop(
                 run.id,
                 %{
                   "id" => "host-contract-turn:#{run.id}",
                   "session_id" => "host-contract-session:#{run.id}",
                   "state" => "cancelled"
                 },
                 claim
               )

      assert {:ok, _} = Batches.release(claim, :invalid_learning_result, 0)
    end

    Repo.update_all(LearningRun, set: [result: nil, prompt: nil, pruned_at: DateTime.utc_now()])
    assert {:ok, :idle} = Batches.claim("worker", @settings)

    assert [%{status: :deferred, start_count: 3, error_code: "learning_retry_exhausted"}] =
             Repo.all(Batch)

    assert Repo.aggregate(InputMembership, :count) == 2
  end

  @tag :recovery
  test "shrinking a never-started preparation retires its manifest without spending a start" do
    [invalid, survivor] = inputs!()
    assert {:ok, claim} = Batches.claim("unstarted-stale-preparation", @settings)
    assert {:ok, original} = Batches.prepare(claim)
    Repo.update!(Ecto.Changeset.change(invalid, operational_pruned_at: DateTime.utc_now()))

    assert {:ok, replacement} = Batches.prepare(claim)
    assert replacement.id != original.id
    assert replacement.batch_id == original.batch_id
    assert Enum.map(replacement.inputs, & &1["source_input_id"]) == [survivor.id]
    retired = Repo.get!(LearningRun, original.id)
    assert retired.status == :stale
    assert retired.inputs == original.inputs
    assert retired.prompt == original.prompt
    assert is_nil(retired.started_at)
    assert Repo.get!(Batch, claim.batch.id).start_count == 0
    assert {:ok, _} = Batches.begin_execution(claim, replacement.id)
    assert Repo.get!(Batch, claim.batch.id).start_count == 1
  end

  @tag :recovery
  test "retiring an invalid sibling cannot reset the original batch's exhausted start budget" do
    # Structural one-start ceiling over captured input: changing the manifest
    # must not turn a spent lifetime grant into a new free batch or generation.
    [invalid, survivor] = inputs!()
    assert {:ok, claim} = Batches.claim("one-start", @settings)
    Repo.update!(Ecto.Changeset.change(claim.batch, start_limit: 1))
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)

    body =
      "testdata/learning/retained-output-contract-failure.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("public_responses")
      |> hd()
      |> Map.fetch!("text")

    assert {:error, :invalid_learning_result} = Fixtures.accept(run.id, body, %{})

    assert {:ok, _} =
             Learning.record_stop(
               run.id,
               %{
                 "id" => "host-contract-turn:#{run.id}",
                 "session_id" => "host-contract-session:#{run.id}",
                 "state" => "cancelled"
               },
               claim
             )

    Repo.update!(Ecto.Changeset.change(invalid, operational_pruned_at: DateTime.utc_now()))
    assert {:error, :learning_retry_exhausted} = Batches.prepare(claim)
    assert Repo.get!(InputMembership, invalid.id).terminal_reason == "source_unavailable"
    assert Repo.get!(InputMembership, survivor.id).terminal_reason == nil
    assert Repo.get!(Batch, claim.batch.id).start_count == 1
    assert Repo.get!(LearningRun, run.id).inputs == run.inputs
    assert Repo.aggregate(LearningRun, :count) == 1
    assert Repo.aggregate(Batch, :count) == 1
  end

  test "quiet coalescing starts when admission finishes, not when an old input arrived" do
    entries = inputs!()
    assert {:ok, :idle} = Batches.claim("worker", %{@settings | quiet_seconds: 10})
    ids = Enum.map(entries, & &1.id)

    Repo.update_all(from(e in Entry, where: e.id in ^ids),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -61)]
    )

    # Admission can spend minutes behind a provider queue. Those messages must
    # still coalesce once decided instead of buying one learning call each.
    assert {:ok, :idle} = Batches.claim("worker", %{@settings | quiet_seconds: 10})

    Repo.update_all(from(e in Entry, where: e.id in ^ids),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -61)]
    )

    assert {:ok, %{inputs: [_, _]}} = Batches.claim("worker", %{@settings | quiet_seconds: 10})
  end

  # Until 2026-09-27 learning waited ten quiet seconds and one minute at most,
  # so in any conversation slower than that every message bought a pass of its
  # own, each paying for the whole learning prompt: 75 of that week's 78 passes
  # read a single message and 64 of 75 kept nothing. One of them learned a
  # Chat "hi, reply with one word please" alone, ten seconds after the reply.
  test "a conversation is learned in one pass once it has been quiet for minutes" do
    settings = production_timing()
    [first, second] = inputs!()

    # Two minutes after the last message, people may still be answering.
    routed!([first, second], 2 * 60)
    assert {:ok, :idle} = Batches.claim("worker", settings)

    # A conversation still going twenty minutes after it began keeps waiting.
    routed!([first], 20 * 60)
    routed!([second], 60)
    assert {:ok, :idle} = Batches.claim("worker", settings)

    routed!([first, second], 5 * 60)
    assert {:ok, claim} = Batches.claim("worker", settings)
    assert Enum.sort(Enum.map(claim.inputs, & &1.id)) == Enum.sort([first.id, second.id])
  end

  test "a conversation that never goes quiet is still learned within half an hour" do
    settings = production_timing()
    [first, second] = inputs!()
    routed!([first], 30 * 60)
    routed!([second], 60)

    assert {:ok, claim} = Batches.claim("worker", settings)
    assert Enum.sort(Enum.map(claim.inputs, & &1.id)) == Enum.sort([first.id, second.id])
  end

  test "an unavailable target defers immediately without buying another identical judgment" do
    _entries = inputs!()
    assert {:ok, claim} = Batches.claim("worker", @settings)
    assert {:ok, run} = Learning.prepare(Enum.map(claim.inputs, & &1.id), @settings)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    assert {:ok, batch} = Batches.release(claim, :knowledge_target_unavailable, 0)
    assert batch.status == :deferred
    assert batch.start_count == 1
    assert {:ok, :idle} = Batches.claim("worker", @settings)
  end

  test "a stale topic stays the named cause when it stops the last granted start" do
    # QA, 2026-09-25, batch 96368bd7: the first attempt stopped on a topic whose
    # source history was no longer valid; "Grant one more start" ran it again
    # and it stopped the same way, but that stop spent the granted start, so
    # the batch said "every start was used" and offered yet another start
    # instead of the relearn that fixes it.
    _entries = inputs!()
    assert {:ok, claim} = Batches.claim("worker", @settings)
    assert {:ok, run} = Learning.prepare(Enum.map(claim.inputs, & &1.id), @settings)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    Repo.update_all(Batch, set: [start_limit: 1])

    assert {:ok, batch} = Batches.release(claim, :knowledge_target_unavailable, 0)
    assert batch.status == :deferred
    assert batch.error_code == "knowledge_target_unavailable"
  end

  test "fresh arrivals cannot postpone the oldest decided input beyond the maximum delay" do
    # Structural queue timing over captured messages: busy channels may never
    # become quiet, but their oldest unassigned input must still get learned.
    [oldest, latest] = inputs!()
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    settings = %{@settings | quiet_seconds: 10}

    Repo.update_all(from(e in Entry, where: e.id == ^oldest.id),
      set: [inserted_at: DateTime.add(now, -30), updated_at: DateTime.add(now, -30)]
    )

    Repo.update_all(from(e in Entry, where: e.id == ^latest.id),
      set: [inserted_at: now, updated_at: now]
    )

    assert {:ok, :idle} = Batches.claim("coalescing", settings)

    # Move only the oldest decision past the explicit maximum. The newest
    # decision still prevents the quiet-time condition from being true.
    Repo.update_all(from(e in Entry, where: e.id == ^oldest.id),
      set: [inserted_at: DateTime.add(now, -61), updated_at: DateTime.add(now, -61)]
    )

    assert {:ok, claim} = Batches.claim("maximum-delay", settings)
    assert Enum.map(claim.inputs, & &1.id) == [oldest.id, latest.id]
    assert claim.batch.start_count == 0
    assert Repo.aggregate(InputMembership, :count) == 2
  end

  # Andrew, 2026-09-27, on the Timeline of "@Ryker check health of our infra":
  # "learning in this episode started even before work was done?" Routing
  # decided Work at 10:16:06; learning read that one message at 10:16:18,
  # found nothing worth keeping and was finished, while the Work, handed to
  # new runs after a worker outage, asked him a question at 12:08:48. A batch
  # fell due by the clock alone, so a request was learned from as soon as it
  # was routed, before its Work had said anything.
  test "a conversation's messages are not learned while the Work they started is running" do
    # Both captured alerts started a request. They were routed two hours ago,
    # far past the quiet time and the maximum delay.
    [firing, resolved] = inputs!()
    Enum.each([firing, resolved], &start_work!/1)
    routed!([firing, resolved], 7_200)

    # The Work is about to start.
    assert {:ok, :idle} = Batches.claim("learning", @settings)

    # The Work pool runs the firing alert's turn.
    work = run_work!(firing)
    assert {:ok, :idle} = Batches.claim("learning", @settings)

    # Its answer, a question, is accepted and waits to be sent.
    accepted = ask_question!(work)
    assert accepted.turn.status == :delivery_pending
    assert {:ok, :idle} = Batches.claim("learning", @settings)

    # Sent: the request waits for the person, and its message is learned from.
    deliver!(accepted)
    rested!(firing, 1)
    assert {:ok, claim} = Batches.claim("learning", @settings)
    assert Enum.map(claim.inputs, & &1.id) == [firing.id]

    # The resolved alert's Work has still not run.
    assert {:ok, _finished} = Batches.finish(claim, :no_change)
    assert {:ok, :idle} = Batches.claim("learning", @settings)
    refute Repo.exists?(from(m in InputMembership, where: m.input_id == ^resolved.id))
  end

  # Learning is meant to run a little after Ryker's answer. Counted from the
  # message, the quiet time had run out long before a two-hour Work rested.
  test "the quiet time counts from when the Work comes to rest" do
    [firing, resolved] = inputs!()
    Enum.each([firing, resolved], &start_work!/1)
    routed!([firing, resolved], 7_200)
    settings = %{@settings | quiet_seconds: 10}

    firing |> run_work!() |> ask_question!() |> deliver!()
    assert {:ok, :idle} = Batches.claim("learning", settings)

    # An idle worker sleeps until then. The time is the database's own
    # aggregate, which comes back without a zone.
    rested_at = Repo.get!(Episode, firing.episode_id).updated_at
    due_at = Batches.next_due_at(DateTime.utc_now(), settings)
    assert DateTime.diff(due_at, rested_at, :microsecond) == 10_000_000

    rested!(firing, 11)
    assert {:ok, claim} = Batches.claim("learning", settings)
    assert Enum.map(claim.inputs, & &1.id) == [firing.id]
  end

  # The maximum delay keeps a conversation that never goes quiet from waiting
  # forever. Work Andrew watched was handed to new runs at 11:34, 11:47 and
  # 12:06 after a worker outage, two hours past that delay, and learning still
  # has to wait for it.
  test "the maximum delay does not force learning during Work" do
    [firing, resolved] = inputs!()
    Enum.each([firing, resolved], &start_work!/1)
    routed!([firing, resolved], 7_200)

    # No worker took the run, and it waits to be tried again.
    work = run_work!(firing)

    assert {:ok, %{status: :pending}} =
             Custody.defer(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               600,
               "worker_unavailable",
               "No worker took the run."
             )

    # Neither the maximum delay nor a full batch forces it, and nothing falls
    # due by the clock: the Work coming to rest is what makes it learnable.
    for settings <- [%{@settings | quiet_seconds: 10}, %{@settings | batch_size: 1}] do
      assert {:ok, :idle} = Batches.claim("learning", settings)
      assert Batches.next_due_at(DateTime.utc_now(), settings) == nil
    end

    assert Repo.aggregate(Batch, :count) == 0
  end

  # Only the Work a message started holds it back. Chatter routing answered
  # itself must not wait for somebody else's request, however long it runs.
  test "messages that started no Work are learned as before, beside running Work" do
    [firing, resolved] = inputs!()
    start_work!(firing)
    routed!([firing], 7_200)
    # Routing answered the resolved alert itself, with a reaction.
    answered_by_routing!(resolved)
    routed_at = routed!([resolved], 5)
    settings = %{@settings | quiet_seconds: 10}

    # Its quiet time counts from routing, as it always has.
    assert {:ok, :idle} = Batches.claim("learning", settings)
    due_at = Batches.next_due_at(DateTime.utc_now(), settings)
    assert DateTime.diff(due_at, routed_at, :microsecond) == 10_000_000

    routed!([resolved], 11)
    assert {:ok, claim} = Batches.claim("learning", settings)
    assert Enum.map(claim.inputs, & &1.id) == [resolved.id]
  end

  # A blocked request waits for a person, for days when the Slack channel it
  # answers in was archived under it. Its episode still reads as working, but
  # nothing runs until someone acts, so waiting for it would never end.
  test "Work blocked waiting for a person is at rest, so its messages are learned" do
    [firing, resolved] = inputs!()
    Enum.each([firing, resolved], &start_work!/1)
    routed!([firing, resolved], 7_200)
    episode = Repo.get!(Episode, firing.episode_id)

    assert {:ok, %{turn: %{status: :blocked}}} =
             Custody.pause_destination(episode.id, episode.key, "slack-channel-archived")

    rested!(firing, 1)
    assert {:ok, claim} = Batches.claim("learning", @settings)
    assert Enum.map(claim.inputs, & &1.id) == [firing.id]
  end

  test "a paused conversation cannot hide another conversation's ready inputs" do
    # Structural destination and arrival expansion of captured bodies. The old
    # paused scope sorts first, so exclusion must happen before LIMIT 1.
    [entry | _] = inputs!()
    assert {:ok, paused} = Batches.claim("paused-conversation", @settings)

    assert {:ok, %{status: :deferred}} =
             Batches.finish(paused, :deferred, "knowledge_match_ambiguous")

    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    blocked = clone_input!(entry, entry.destination_conversation_ref, DateTime.add(now, -120))

    healthy =
      clone_input!(entry, "#{entry.destination_conversation_ref}-healthy", DateTime.add(now, -60))

    assert {:ok, claim} = Batches.claim("healthy-conversation", @settings)
    assert Enum.map(claim.inputs, & &1.id) == [healthy.id]
    assert claim.batch.conversation_ref == healthy.destination_conversation_ref
    refute claim.batch.id == paused.batch.id
    refute Repo.exists?(from(m in InputMembership, where: m.input_id == ^blocked.id))
    assert Repo.get!(Batch, paused.batch.id).status == :deferred
    assert {:ok, :idle} = Batches.claim("no-duplicate-work", @settings)
  end

  test "expired replay inputs cannot occupy a current learning batch" do
    [expired, current] = inputs!()
    previous = Application.get_env(:ryker, :retention)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ryker, :retention, previous),
        else: Application.delete_env(:ryker, :retention)
    end)

    Application.put_env(:ryker, :retention, %{conversation_memory_seconds: 3600})

    Repo.update_all(
      from(o in ConversationObservation, where: o.source_input_id == ^expired.id),
      set: [updated_at: ~U[2000-01-01 00:00:00.000000Z]]
    )

    assert {:ok, claim} = Batches.claim("current-first", @settings)
    assert Enum.map(claim.inputs, & &1.id) == [current.id]
    assert {:ok, _} = Batches.finish(claim, :no_change)

    assert {:ok, %{inputs: [], batch: %{start_count: 0}}} =
             Batches.claim("expired-receipt", @settings)
  end

  test "a new judgment cannot start while an earlier remote turn might still be running" do
    _entries = inputs!()
    assert {:ok, claim} = Batches.claim("worker", @settings)
    ids = Enum.map(claim.inputs, & &1.id)
    assert {:ok, run} = Learning.prepare(ids, @settings)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    assert {:error, :invalid_learning_result} = Fixtures.accept(run.id, "{}", %{})
    assert {:ok, next} = Learning.prepare(ids, @settings)
    assert {:error, :learning_remote_outstanding} = Batches.begin_execution(claim, next.id)
    assert Repo.get!(Batch, claim.batch.id).start_count == 1

    assert {:error, :learning_remote_not_stopped} =
             Learning.record_stop(
               run.id,
               %{
                 "id" => "host-contract-turn:#{run.id}",
                 "session_id" => "host-contract-session:#{run.id}",
                 "state" => "running"
               },
               claim
             )

    assert {:ok, _} =
             Learning.record_stop(
               run.id,
               %{
                 "id" => "host-contract-turn:#{run.id}",
                 "session_id" => "host-contract-session:#{run.id}",
                 "state" => "cancelled"
               },
               claim
             )

    assert {:ok, _} = Batches.begin_execution(claim, next.id)
    assert Repo.get!(Batch, claim.batch.id).start_count == 2
  end

  defp clone_input!(entry, conversation_ref, received_at) do
    id = Ecto.UUID.generate()

    attrs =
      entry |> Map.from_struct() |> Map.take(Entry.__schema__(:fields))

    next =
      Repo.insert!(
        struct!(
          Entry,
          Map.merge(attrs, %{
            id: id,
            dedupe_key: "host-queue:#{id}",
            event_ref: "host-queue:#{id}",
            decision_ref: "host-queue-decision:#{id}",
            native_input_id: id,
            source_item_ref: id,
            destination_conversation_ref: conversation_ref,
            inserted_at: received_at,
            updated_at: received_at
          })
        )
      )

    assert {:ok, :ok} =
             Repo.transaction(fn -> Observations.receive_in_transaction(next) end)

    next
  end

  defp inputs! do
    entries = Fixtures.inputs!()
    Fixtures.normalize_queue_timestamps!(entries)
  end

  # The waits the running product learns with.
  defp production_timing do
    Map.merge(
      @settings,
      Map.take(Defaults.fetch!(:learning), [:quiet_seconds, :maximum_delay_seconds])
    )
  end

  # When routing decided the messages, on the database clock learning reads.
  defp routed!(entries, seconds_ago) do
    at = DateTime.add(database_now(), -seconds_ago)
    ids = Enum.map(entries, & &1.id)

    assert {length(ids), nil} ==
             Repo.update_all(from(e in Entry, where: e.id in ^ids),
               set: [inserted_at: at, updated_at: at]
             )

    at
  end

  # When the message's Work came to rest, moved onto the database clock: a
  # rest this host stamped a moment ago can read as a moment in its future.
  defp rested!(entry, seconds_ago) do
    at = DateTime.add(database_now(), -seconds_ago)
    Repo.update_all(from(e in Episode, where: e.id == ^entry.episode_id), set: [updated_at: at])

    Repo.update_all(from(t in Turn, where: t.episode_id == ^entry.episode_id),
      set: [updated_at: at]
    )

    at
  end

  defp database_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp answered_by_routing!(entry) do
    assert {1, nil} ==
             Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
               set: [decision_action: :react, episode_id: nil]
             )
  end

  # Admission pins the Work a message starts; the Work pool claims only a
  # pinned request.
  defp start_work!(entry) do
    assert {:ok, _session} =
             Custody.pin_episode(entry.episode_id, "work-read-only", String.duplicate("a", 64))
  end

  defp run_work!(entry) do
    assert {:ok, %{episode: %{id: episode_id}} = work} =
             Custody.claim_next("work:#{entry.id}", 120, :work)

    assert episode_id == entry.episode_id
    work
  end

  # The Work settles its request by asking a person, as it settled Andrew's:
  # the answer is accepted as a reply that then waits for input.
  defp ask_question!(%{episode: episode, lease_ref: lease, turn: turn} = work) do
    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => episode.id, "turn_ref" => turn.turn_ref},
               "Continue from the frozen episode state.",
               %{
                 "additionalProperties" => false,
                 "properties" => %{"message" => %{"type" => "string"}},
                 "required" => ["message"],
                 "type" => "object"
               },
               "work-final-live-v3"
             )

    assert {:ok, _frozen} =
             Custody.freeze_submission(episode.id, turn.turn_ref, lease, submission)

    assert {:ok, session} =
             Custody.bind_session(
               episode.id,
               turn.turn_ref,
               lease,
               work.session.generation,
               work.session.create_generation,
               "coop-session:#{episode.id}"
             )

    assert {:ok, _bound} =
             Custody.bind_turn(
               episode.id,
               turn.turn_ref,
               lease,
               session.generation,
               turn.submit_generation,
               "coop-turn:#{episode.id}"
             )

    question = "Which cluster should I check first?"
    candidate = Jason.encode!(%{"delivery" => "reply", "message" => question})
    sha = digest(candidate)

    assert {:ok, _staged} =
             Custody.stage_candidate(
               episode.id,
               turn.turn_ref,
               lease,
               nil,
               nil,
               candidate,
               sha,
               1
             )

    wait = %{
      "deadline_at" => nil,
      "kind" => "wait",
      "wait_kind" => "input",
      "wait_ref" => "question:#{turn.id}"
    }

    assert {:ok, result} = Result.new(:reply, %{"message" => question}, nil, wait)

    assert {:ok, _prepared} =
             Custody.prepare_validation(episode.id, turn.turn_ref, lease, sha, 1, :accept, result)

    assert {:ok, accepted} =
             Custody.accept_result(
               episode.id,
               episode.key,
               turn.turn_ref,
               lease,
               sha,
               1,
               "validation:#{episode.id}"
             )

    accepted
  end

  # The question reaches Slack, and the request waits for the person.
  defp deliver!(%{episode: episode, turn: turn}) do
    assert {:ok, claim} = Custody.claim_next("delivery:#{episode.id}", 60, :delivery)
    target = turn.delivery_target

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               turn.delivery_ref,
               target["transport"],
               target["conversation_ref"],
               target["thread_ref"],
               "1788629000.000100"
             )

    assert {:ok, %{episode: %{state: :waiting_for_input}} = delivered} =
             Custody.confirm_delivery(
               episode.id,
               episode.key,
               turn.turn_ref,
               claim.lease_ref,
               receipt
             )

    delivered
  end
end
