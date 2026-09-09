defmodule Responder.Learning.BatchesTest do
  use Responder.DataCase, async: false
  import Ecto.Query
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Learning.{Batch, Batches, InputMembership}
  alias Responder.Repo
  alias Responder.State.{ConversationObservation, Learning, LearningRun, Observations}

  @settings %{
    policy: "recorded-read-only-policy",
    policy_digest: String.duplicate("a", 64),
    quiet_seconds: 0,
    maximum_delay_seconds: 60,
    lease_seconds: 300,
    batch_size: 16
  }

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
    previous = Application.get_env(:responder, :retention)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:responder, :retention, previous),
        else: Application.delete_env(:responder, :retention)
    end)

    Application.put_env(:responder, :retention, %{conversation_memory_seconds: 3600})

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
end
