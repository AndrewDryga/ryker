defmodule Responder.Learning.DispatcherTest do
  use Responder.DataCase, async: false
  import Ecto.Query
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Learning.{Batch, Batches, Dispatcher, InputMembership}
  alias Responder.State.{KnowledgeRevision, Learning, LearningRun, Observations}
  alias Responder.TestSupport.FakeCoopAPI
  alias Responder.Work.Session

  defmodule API do
    alias Responder.Repo
    alias Responder.TestSupport.FakeCoopAPI, as: Fake

    def operation_by_key(client, key) do
      record_call(client, :operation_by_key)

      if Fake.state(client)[:unreachable],
        do: {:error, :unreachable},
        else: Fake.operation_by_key(client, key)
    end

    def get_session(client, id) do
      record_call(client, :get_session)
      Fake.get_session(client, id)
    end

    def get_turn(client, sid, tid) do
      record_call(client, :get_turn)
      Fake.get_turn(client, sid, tid)
    end

    def fence_create_session(client, key, policy, ref, source) do
      Agent.update(client, &Map.update(&1, :fence_keys, [key], fn keys -> keys ++ [key] end))

      lose_after(client, :create_fence, fn ->
        Fake.fence_create_session(client, key, policy, ref, source)
      end)
    end

    def cancel_turn(client, sid, tid, key, revision) do
      request = %{session_id: sid, turn_id: tid, key: key, revision: revision}

      Agent.update(
        client,
        &Map.update(&1, :cancel_requests, [request], fn calls -> calls ++ [request] end)
      )

      lose_after(client, :cancel, fn -> Fake.cancel_turn(client, sid, tid, key, revision) end)
    end

    def create_session(client, key, policy, ref, source),
      do:
        lose_after(client, :create, fn ->
          Fake.create_session(client, key, policy, ref, source)
        end)

    def submit_frozen_turn(client, sid, key, revision, submission, nil, []) do
      unless submission["contract_version"] == "conversation-learning-v2",
        do: raise("wrong contract")

      lose_after(client, :submit, fn ->
        Fake.submit_turn(
          client,
          sid,
          key,
          revision,
          submission["prompt"],
          submission["output_schema"]
        )
      end)
    end

    def fence_frozen_turn(client, sid, key, revision, submission, nil, []) do
      Agent.update(client, &Map.update(&1, :fence_keys, [key], fn keys -> keys ++ [key] end))

      lose_after(client, :submit_fence, fn ->
        Fake.fence_submit_turn(
          client,
          sid,
          key,
          revision,
          submission["prompt"],
          submission["output_schema"]
        )
      end)
    end

    def validate_frozen_candidate(client, sid, tid, key, attempt, sha, :accept) do
      unless Fake.state(client).turn["candidate"]["attempt"] == attempt,
        do: raise("wrong attempt")

      if fault?(client, :before_accept),
        do: {:error, :simulated_response_loss},
        else:
          lose_after(client, :accept, fn ->
            result = Fake.validate_candidate(client, sid, tid, key, sha, :accept)
            after_accept(client)
            result
          end)
    end

    defp after_accept(client) do
      case Fake.state(client)[:after_accept] do
        nil -> :ok
        callback -> callback.()
      end
    end

    defp lose_after(client, phase, fun) do
      record_call(client, phase)

      if fault?(client, {:before, phase}) do
        {:error, :simulated_response_loss}
      else
        result = fun.()
        pause_after(client, phase)
        if fault?(client, phase), do: {:error, :simulated_response_loss}, else: result
      end
    end

    defp record_call(client, phase),
      do:
        Agent.update(
          client,
          &Map.update(&1, :boundary_calls, [phase], fn calls -> calls ++ [phase] end)
        )

    defp pause_after(client, phase) do
      target =
        Agent.get_and_update(client, fn state ->
          case state[:pause_after] do
            {^phase, target} -> {target, Map.delete(state, :pause_after)}
            _ -> {nil, state}
          end
        end)

      if target do
        send(target, {:provider_paused, phase, self(), Repo.in_transaction?()})

        receive do
          :continue_provider -> :ok
        after
          5_000 -> raise "test never released the provider response"
        end
      end
    end

    defp fault?(client, phase),
      do:
        Agent.get_and_update(client, fn state ->
          if state[:lose_boundary] == phase,
            do: {true, Map.delete(state, :lose_boundary)},
            else: {false, state}
        end)
  end

  @settings %{
    policy: "recorded-read-only-policy",
    policy_digest: String.duplicate("a", 64),
    worker_ref: "learning-test",
    quiet_seconds: 0,
    maximum_delay_seconds: 60,
    lease_seconds: 300,
    batch_size: 16,
    step_delay_seconds: 0,
    execution_timeout_seconds: 600,
    api: API
  }

  @tag :recovery
  test "a crash after preparation resumes the same judgment with exactly one counted start" do
    # Fable found this crash window created a remote session but never counted
    # its start, so every submit failed forever and blocked the conversation.
    entries = inputs!()

    assert {:ok, _} =
             Responder.Instructions.save(
               :global,
               "Preserve source attribution.",
               0,
               "operator:test"
             )

    assert {:ok, claim} = Batches.claim("crashed-before-start", @settings)
    assert {:ok, prepared} = Batches.prepare(claim)
    assert {:ok, _} = Responder.Instructions.save(:global, "", 1, "operator:test")
    assert is_nil(prepared.started_at)
    Repo.update_all(Batch, set: [lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]])
    {:ok, fake} = FakeCoopAPI.start_link([result(entries)])
    settings = Map.put(@settings, :client, fake)
    assert {:ok, _} = Dispatcher.run_once(settings)
    assert Repo.get!(Batch, claim.batch.id).start_count == 1

    assert %{status: :applied, start_count: 1} =
             drive_to_applied!(settings, 5)

    assert [run] = Repo.all(LearningRun)
    assert run.id == prepared.id
    assert run.inputs == prepared.inputs
    assert run.prompt == prepared.prompt
    assert run.started_at != nil
    assert length(FakeCoopAPI.state(fake).create_keys) == 1
    # The intentionally local learning scratch is workspace-free from the host's
    # point of view: its session is created with no repository source, so it can
    # never be asked to resolve a branch, pull request or commit.
    assert FakeCoopAPI.state(fake).create_sources == [nil]
    assert FakeCoopAPI.state(fake).submit_count == 1
    submitted = FakeCoopAPI.state(fake).submitted_prompt
    assert submitted == prepared.prompt

    assert Jason.decode!(submitted)["custom_instructions"]["global"]["text"] ==
             "Preserve source attribution."
  end

  for unavailable <- [:pruned, :deleted] do
    @tag :recovery
    test "a #{unavailable} assigned input does not discard its valid sibling before preparation" do
      # An exclusive membership cannot be reclaimed by a later batch. Finishing
      # all members here permanently lost up to fifteen otherwise valid inputs.
      [invalid, survivor] = inputs!()
      assert {:ok, claim} = Batches.claim("assigned-before-withdrawal", @settings)

      case unquote(unavailable) do
        :pruned ->
          Repo.update!(Ecto.Changeset.change(invalid, operational_pruned_at: DateTime.utc_now()))

        :deleted ->
          withdraw!(invalid)
      end

      assert {:ok, _} = Batches.yield(claim, 0)
      {:ok, fake} = FakeCoopAPI.start_link([result([survivor])])

      assert %{id: id, status: :applied, start_count: 1} =
               drive_to_applied!(Map.put(@settings, :client, fake), 5)

      assert id == claim.batch.id
      assert Repo.get!(InputMembership, invalid.id).terminal_reason == "source_unavailable"
      assert Repo.get!(InputMembership, survivor.id).terminal_reason == "applied"
      assert [run] = Repo.all(LearningRun)
      assert Enum.map(run.inputs, & &1["source_input_id"]) == [survivor.id]
      assert Repo.aggregate(Batch, :count) == 1
    end
  end

  for phase <- [:create, :submit, :accept] do
    test "a worker replaced during #{phase} cannot make another call or accept its result" do
      # Structural failure injection over captured HAProxy source inputs. A
      # returning old worker must not acknowledge/cancel the new owner's turn,
      # write its result, or buy another execution after losing its exact lease.
      entries = inputs!()
      {:ok, fake} = FakeCoopAPI.start_link([result(entries)])
      owner = self()
      Agent.update(fake, &Map.put(&1, :pause_after, {unquote(phase), owner}))
      settings = Map.put(@settings, :client, fake)
      worker = Task.async(fn -> drive_to_pause!(settings, fake, 5) end)

      try do
        assert_receive {:provider_paused, unquote(phase), executor, false}, 5_000
        [batch] = Repo.all(Batch)
        [run] = Repo.all(LearningRun)
        [session] = Repo.all(Session)
        calls = FakeCoopAPI.state(fake).boundary_calls
        %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

        Repo.update_all(from(b in Batch, where: b.id == ^batch.id),
          set: [lease_expires_at: DateTime.add(now, -1)]
        )

        assert {:ok, replacement} = Batches.claim("replacement-worker", @settings)
        assert replacement.batch.id == batch.id
        refute replacement.lease_ref == batch.lease_ref
        send(executor, :continue_provider)

        assert {:error, :learning_lease_lost} = Task.await(worker)
        assert Repo.aggregate(KnowledgeRevision, :count) == 0
        assert Repo.get!(LearningRun, run.id) == run
        assert Repo.get!(Session, session.id) == session
        assert FakeCoopAPI.state(fake).boundary_calls == calls
        assert Repo.get!(Batch, batch.id).start_count == 1

        assert {:ok, _} = Batches.yield(replacement, 0)
        assert %{status: :applied, start_count: 1} = drive_to_applied!(settings, 5)
        assert Repo.aggregate(LearningRun, :count) == 1
        remote = FakeCoopAPI.state(fake)
        assert length(remote.create_keys) == 1
        assert remote.submit_count == 1
        assert length(remote.validations) == 1
        assert Map.get(remote, :cancel_requests, []) == []
      after
        if Process.alive?(worker.pid), do: Task.shutdown(worker, :brutal_kill)
      end
    end
  end

  test "a lost cancel response reconciles one terminal turn without another execution" do
    [entry | _] = entries = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([result(entries)])
    Agent.update(fake, &Map.put(&1, :lose_boundary, :before_accept))
    settings = Map.put(@settings, :client, fake)
    drive_until_fault!(settings, fake, 5)
    withdraw!(entry)
    Agent.update(fake, &Map.put(&1, :lose_boundary, :cancel))
    drive_until_fault!(settings, fake, 5)

    [run] = Repo.all(LearningRun)
    assert is_nil(run.remote_stopped_at)
    assert FakeCoopAPI.state(fake).turn["state"] == "cancelled"
    # Stop at reconciliation, before a valid sibling's separately budgeted
    # replacement judgment. Losing cancel's reply must not buy that start early.
    assert %{status: :queued, start_count: 1} = drive_to_stopped!(settings, 5)
    saved = Repo.get!(LearningRun, run.id)
    assert saved.stop_receipt["state"] == "cancelled"
    assert saved.remote_stopped_at != nil
    remote = FakeCoopAPI.state(fake)
    assert [cancel] = remote.cancel_requests
    assert cancel.key == Learning.operation_key(run, :cancel) <> ":r#{cancel.revision}"
    assert cancel.session_id == Repo.get_by!(Session, learning_run_id: run.id).coop_session_id
    assert cancel.turn_id == run.coop_turn_id
    assert remote.submit_count == 1
    assert length(remote.create_keys) == 1
    assert remote.validations == []
    assert Repo.aggregate(KnowledgeRevision, :count) == 0
    assert Repo.aggregate(LearningRun, :count) == 1
  end

  for phase <- [:create, :submit] do
    test "a lost #{phase} fence response proves absence without buying another judgment" do
      [entry | _] = entries = inputs!()
      {:ok, fake} = FakeCoopAPI.start_link([result(entries)])
      Agent.update(fake, &Map.put(&1, :lose_boundary, {:before, unquote(phase)}))
      settings = Map.put(@settings, :client, fake)
      drive_until_fault!(settings, fake, 5)
      [run] = Repo.all(LearningRun)
      assert is_nil(run.remote_stopped_at)
      withdraw!(entry)

      Agent.update(
        fake,
        &Map.put(
          &1,
          :lose_boundary,
          unquote(phase) |> Atom.to_string() |> Kernel.<>("_fence") |> String.to_existing_atom()
        )
      )

      drive_until_fault!(settings, fake, 5)
      assert is_nil(Repo.get!(LearningRun, run.id).remote_stopped_at)

      assert %{status: :queued, start_count: 1} = drive_to_stopped!(settings, 5)
      assert Repo.get!(LearningRun, run.id).remote_stopped_at != nil
      remote = FakeCoopAPI.state(fake)
      assert remote.fence_keys == [Learning.operation_key(run, unquote(phase))]
      assert remote.submit_count == 0
      assert length(remote.create_keys) == if(unquote(phase) == :create, do: 0, else: 1)
      assert remote.validations == []
      assert Map.get(remote, :cancel_requests, []) == []
      assert Repo.aggregate(KnowledgeRevision, :count) == 0
      assert Repo.aggregate(LearningRun, :count) == 1
    end
  end

  for boundary <- [:create, :submit, :before_accept, :accept] do
    test "lost #{boundary} response resumes one frozen judgment and applies once" do
      entries = inputs!()
      body = result(entries)
      {:ok, fake} = FakeCoopAPI.start_link([body])
      Agent.update(fake, &Map.put(&1, :lose_boundary, unquote(boundary)))
      settings = Map.put(@settings, :client, fake)
      drive_until_fault!(settings, fake, 5)
      assert Repo.aggregate(KnowledgeRevision, :count) == 0
      [run] = Repo.all(LearningRun)
      assert run.started_at != nil
      assert run.reconcile_attempt_count == 1
      assert %{status: :applied, start_count: 1} = drive_to_applied!(settings, 5)
      assert {:ok, :idle} = Dispatcher.run_once(settings)
      assert Repo.aggregate(LearningRun, :count) == 1
      assert Repo.aggregate(Session, :count) == 1
      assert Repo.aggregate(KnowledgeRevision, :count) == 1
      stored = Repo.get!(LearningRun, run.id)
      assert stored.status == :applied
      assert stored.remote_stopped_at != nil
      assert stored.stop_receipt["state"] == "completed"

      assert stored.validation_receipt["validation_candidate_sha256"] ==
               :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      refute stored.result_sha256 == stored.validation_receipt["validation_candidate_sha256"]
      remote = FakeCoopAPI.state(fake)
      assert length(remote.create_keys) == 1
      assert remote.submit_count == 1
      assert length(remote.validations) == 1
    end
  end

  for boundary <- [:async_create, :async_submit] do
    test "pending #{boundary} yields and resumes the same learning attempt" do
      # The first live learning run crashed before reaching the model: a valid
      # running CreateRemoteSession receipt became Access.get(:waiting, ...).
      # Both asynchronous boundaries must yield, not fabricate a ready resource.
      entries = inputs!()

      {:ok, fake} =
        FakeCoopAPI.start_link(
          [result(entries)],
          [{unquote(boundary), true}, {:async_operations_running, true}]
        )

      settings = Map.put(@settings, :client, fake)

      assert {:ok, %{status: :queued, start_count: 1}} = Dispatcher.run_once(settings)
      assert Repo.aggregate(KnowledgeRevision, :count) == 0
      assert [%{status: :prepared, reconcile_attempt_count: 0}] = Repo.all(LearningRun)
      assert %{status: :applied, start_count: 1} = drive_to_applied!(settings, 5)
      assert Repo.aggregate(LearningRun, :count) == 1
      assert Repo.aggregate(Session, :count) == 1
      assert Repo.aggregate(KnowledgeRevision, :count) == 1
      remote = FakeCoopAPI.state(fake)
      assert length(remote.create_keys) == 1
      assert remote.submit_count == 1
    end
  end

  test "a learning receipt records the session target when Coop omits it from the turn" do
    # Live Coop turn receipts expose usage and IDs but target belongs to the
    # session. Looking only at turn.target hid the real model from operator UI.
    entries = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([result(entries)])
    target = "codex:gpt-5.6-sol/medium@emisar"
    Agent.update(fake, &put_in(&1, [:session, "target"], target))
    assert %{status: :applied} = drive_to_applied!(Map.put(@settings, :client, fake), 5)
    [run] = Repo.all(LearningRun)
    assert run.producer["target"] == target
  end

  @tag :recovery
  test "source withdrawal stops the old judgment before learning its valid sibling in the same batch" do
    [entry, survivor] = entries = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([result(entries)])
    Agent.update(fake, &Map.put(&1, :lose_boundary, :before_accept))
    settings = Map.put(@settings, :client, fake)
    drive_until_fault!(settings, fake, 5)
    assert [%{status: :responded, result: result} = original] = Repo.all(LearningRun)
    assert is_binary(result)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Observations.receive_in_transaction(%{
                 entry
                 | id: Ecto.UUID.generate(),
                   revision: entry.revision + 1,
                   event_kind: :delete
               })
             end)

    for _ <- 1..2 do
      make_due!()
      assert {:ok, _} = Dispatcher.run_once(settings)
    end

    assert Repo.aggregate(KnowledgeRevision, :count) == 0
    assert Repo.aggregate(LearningRun, :count) == 1
    assert [%{status: :queued, start_count: 1} = batch] = Repo.all(Batch)
    assert FakeCoopAPI.state(fake).validations == []
    assert FakeCoopAPI.state(fake).turn["state"] == "cancelled"
    assert hd(Repo.all(LearningRun)).remote_stopped_at != nil

    # A new fake native identity represents the next isolated judgment only
    # after the old remote has a terminal receipt, not an invented model answer.
    {:ok, next_fake} = FakeCoopAPI.start_link([result([survivor])])
    Agent.update(next_fake, &put_in(&1, [:session, "id"], "remote_surviving_input"))

    assert %{id: id, status: :applied, start_count: 2, start_limit: 3} =
             drive_to_applied!(Map.put(@settings, :client, next_fake), 5)

    assert id == batch.id
    assert Repo.get!(LearningRun, original.id).inputs == original.inputs
    assert Repo.get!(LearningRun, original.id).prompt == original.prompt
    assert Repo.get!(InputMembership, entry.id).terminal_reason == "source_unavailable"
    assert Repo.get!(InputMembership, survivor.id).terminal_reason == "applied"
    assert Repo.aggregate(Batch, :count) == 1
    assert Repo.aggregate(KnowledgeRevision, :count) == 1
    assert Repo.aggregate(LearningRun, :count) == 2
  end

  test "an empty valid-input set is terminal without a model session" do
    ids = inputs!() |> Enum.map(& &1.id)
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

    Repo.update_all(from(e in Entry, where: e.id in ^ids),
      set: [operational_pruned_at: now, updated_at: DateTime.add(now, -1)]
    )

    assert {:ok, %{status: :superseded, error_code: "source_unavailable"}} =
             Dispatcher.run_once(Map.put(@settings, :client, nil))

    assert Repo.aggregate(LearningRun, :count) == 0
    assert Repo.aggregate(Session, :count) == 0
    assert {:ok, :idle} = Dispatcher.run_once(Map.put(@settings, :client, nil))
  end

  for {field, value} <- [project_env: true, project_mcp: true, repository_read_only: false] do
    test "learning refuses #{field}=#{value} before submitting any source text" do
      entries = inputs!()
      {:ok, fake} = FakeCoopAPI.start_link([result(entries)], [{unquote(field), unquote(value)}])
      settings = Map.put(@settings, :client, fake)
      assert {:ok, %{status: :queued}} = Dispatcher.run_once(settings)
      assert FakeCoopAPI.state(fake).submit_count == 0
      assert hd(Repo.all(LearningRun)).submit_revision == nil
    end
  end

  test "learning refuses Responder action authority before disclosing any source text" do
    # The unattended learner creates an unbound session. An unexpected state-tool
    # binding must not receive retained messages even when every project flag is safe.
    entries = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([result(entries)])

    Agent.update(fake, fn state ->
      put_in(state.session["responder_binding_digest"], String.duplicate("b", 64))
    end)

    settings = Map.put(@settings, :client, fake)
    assert {:ok, batch} = Dispatcher.run_once(settings)
    assert FakeCoopAPI.state(fake).submit_count == 0
    refute Map.has_key?(FakeCoopAPI.state(fake), :submitted_prompt)
    assert batch.status == :queued
    assert hd(Repo.all(LearningRun)).submit_revision == nil
  end

  test "a deferred judgment records no change and does not pause new evidence" do
    entries = inputs!()

    body =
      Jason.encode!(%{
        "reason" => "More evidence is needed.",
        "updates" => [
          %{
            "action" => "defer",
            "source_input_ids" => Enum.map(entries, & &1.id),
            "reason" => "Recovery is unverified."
          }
        ]
      })

    {:ok, fake} = FakeCoopAPI.start_link([body])
    settings = Map.put(@settings, :client, fake)

    assert %{status: :no_change, error_code: "learning_judgment_deferred", next_attempt_at: nil} =
             drive_to_terminal!(settings, 5)

    # A separate queued item in the same scope is not blocked by model uncertainty.
    [entry | _] = entries
    id = Ecto.UUID.generate()

    attrs =
      entry |> Map.from_struct() |> Map.take(Entry.__schema__(:fields))

    next =
      Repo.insert!(
        struct!(
          Entry,
          Map.merge(attrs, %{
            id: id,
            dedupe_key: "host-defer-next:#{id}",
            event_ref: "host-defer-next:#{id}",
            decision_ref: "host-defer-decision:#{id}",
            native_input_id: id,
            source_item_ref: id,
            inserted_at: ~U[2000-01-01 00:00:00.000000Z],
            updated_at: ~U[2000-01-01 00:00:00.000000Z]
          })
        )
      )

    assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(next) end)

    assert {:ok, %{inputs: [claimed]}} =
             Batches.claim("next-evidence", @settings)

    assert claimed.id == id
  end

  test "pruning an applied result before batch completion cannot buy a new judgment" do
    entries = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([result(entries)])
    settings = Map.put(@settings, :client, fake)
    assert %{status: :applied} = drive_to_applied!(settings, 5)
    # Recreate the crash window after run application, before the atomic batch
    # finish marks its members. These are host lifecycle mutations, not a reply.
    Repo.update_all(Batch, set: [status: :queued, completed_at: nil])
    Repo.update_all(InputMembership, set: [terminal_reason: nil])
    Repo.update_all(LearningRun, set: [result: nil, pruned_at: DateTime.utc_now()])

    assert {:ok, %{status: :applied, error_code: "learning_result_pruned"}} =
             Dispatcher.run_once(settings)

    assert FakeCoopAPI.state(fake).submit_count == 1
  end

  test "remote acceptance followed by source withdrawal still retains terminal stop proof" do
    [entry | _] = entries = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([result(entries)])

    Agent.update(
      fake,
      &Map.put(&1, :after_accept, fn ->
        {:ok, :ok} =
          Repo.transaction(fn ->
            Observations.receive_in_transaction(%{
              entry
              | id: Ecto.UUID.generate(),
                revision: entry.revision + 1,
                event_kind: :delete
            })
          end)
      end)
    )

    settings = Map.put(@settings, :client, fake)
    assert %{status: :queued, start_count: 1} = drive_to_stopped!(settings, 5)

    assert [%{remote_stopped_at: stopped, stop_receipt: %{"state" => "completed"}}] =
             Repo.all(LearningRun)

    assert stopped != nil
    assert Repo.aggregate(KnowledgeRevision, :count) == 0
    assert FakeCoopAPI.state(fake).submit_count == 1
  end

  test "unreachable remote custody stops reconciling after twelve steps without another start" do
    _entries = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([])
    Agent.update(fake, &Map.put(&1, :unreachable, true))
    settings = Map.put(@settings, :client, fake)

    assert %{status: :deferred, start_count: 1, error_code: "learning_remote_unresolved"} =
             drive_to_terminal!(settings, 12)

    assert [%{reconcile_attempt_count: 12}] = Repo.all(LearningRun)
    assert {:ok, :idle} = Dispatcher.run_once(settings)
    assert FakeCoopAPI.state(fake).submit_count == 0
  end

  test "an unresolved remote turn blocks later inputs even after the scope pause expires" do
    # Fable found that the hourly pause could expire while the prior remote
    # operation still had no stop proof, allowing duplicate work in a new batch.
    [entry | _] = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([])
    Agent.update(fake, &Map.put(&1, :unreachable, true))
    settings = Map.put(@settings, :client, fake)
    deferred = drive_to_terminal!(settings, 12)
    id = Ecto.UUID.generate()

    attrs =
      entry |> Map.from_struct() |> Map.take(Entry.__schema__(:fields))

    next =
      Repo.insert!(
        struct!(
          Entry,
          Map.merge(attrs, %{
            id: id,
            dedupe_key: "host-unresolved-next:#{id}",
            event_ref: "host-unresolved-next:#{id}",
            decision_ref: "host-unresolved-decision:#{id}",
            native_input_id: id,
            source_item_ref: id,
            inserted_at: ~U[2000-01-01 00:00:00.000000Z],
            updated_at: ~U[2000-01-01 00:00:00.000000Z]
          })
        )
      )

    assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(next) end)
    make_due!()
    assert {:ok, resumed} = Dispatcher.run_once(settings)
    assert resumed.id == deferred.id
    assert resumed.status == :deferred
    assert resumed.error_code == "learning_remote_unresolved"
    assert Repo.aggregate(Batch, :count) == 1
    assert Repo.aggregate(LearningRun, :count) == 1
    assert FakeCoopAPI.state(fake).submit_count == 0

    # Reconciliation after connectivity returns fences the original operation;
    # it is not a new billable judgment and does not discard the original inputs.
    Agent.update(fake, &Map.put(&1, :unreachable, false))
    make_due!()
    assert {:ok, _} = Dispatcher.run_once(settings)
    [run] = Repo.all(LearningRun)
    assert run.remote_stopped_at != nil
    assert FakeCoopAPI.state(fake).submit_count == 0
    assert {:ok, recovered} = Batches.claim("recovered-originals", @settings)
    assert recovered.batch.id == deferred.id
    assert length(recovered.inputs) == 2
    refute Enum.any?(recovered.inputs, &(&1.id == id))
  end

  test "configuration rotation does not replace the policy pinned to a started batch" do
    entries = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([result(entries)])
    Agent.update(fake, &Map.put(&1, :lose_boundary, :create))
    settings = Map.put(@settings, :client, fake)
    drive_until_fault!(settings, fake, 2)
    changed = %{settings | policy: "new-future-policy", policy_digest: String.duplicate("b", 64)}

    assert %{status: :applied, policy: "recorded-read-only-policy"} =
             drive_to_applied!(changed, 5)

    [run] = Repo.all(LearningRun)
    assert run.policy_digest == @settings.policy_digest
    assert FakeCoopAPI.state(fake).submit_count == 1
  end

  defp make_due! do
    Repo.update_all(Batch, set: [next_attempt_at: ~U[2000-01-01 00:00:00.000000Z]])
  end

  defp withdraw!(entry) do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Observations.receive_in_transaction(%{
                 entry
                 | id: Ecto.UUID.generate(),
                   revision: entry.revision + 1,
                   event_kind: :delete
               })
             end)
  end

  defp drive_until_fault!(settings, fake, left) when left > 0 do
    make_due!()
    assert {:ok, %{status: :queued}} = Dispatcher.run_once(settings)
    if FakeCoopAPI.state(fake)[:lose_boundary], do: drive_until_fault!(settings, fake, left - 1)
  end

  defp drive_until_fault!(_, _, _), do: flunk("the requested boundary was not exercised")

  defp drive_to_pause!(settings, fake, left) when left > 0 do
    result = Dispatcher.run_once(settings)

    if FakeCoopAPI.state(fake)[:pause_after] do
      assert {:ok, %{status: :queued}} = result
      make_due!()
      drive_to_pause!(settings, fake, left - 1)
    else
      result
    end
  end

  defp drive_to_pause!(_, _, _), do: flunk("the requested provider pause was not reached")

  defp drive_to_applied!(settings, left) when left > 0 do
    make_due!()
    assert {:ok, %Batch{} = batch} = Dispatcher.run_once(settings)
    assert batch.status in [:queued, :running, :applied]
    if batch.status == :applied, do: batch, else: drive_to_applied!(settings, left - 1)
  end

  defp drive_to_applied!(_, _), do: flunk("the frozen execution did not resume")

  defp drive_to_terminal!(settings, left) when left > 0 do
    make_due!()
    assert {:ok, batch} = Dispatcher.run_once(settings)

    if batch.status in [:queued, :running],
      do: drive_to_terminal!(settings, left - 1),
      else: batch
  end

  defp drive_to_terminal!(_, _), do: flunk("the execution did not reach its terminal budget")

  defp drive_to_stopped!(settings, left) when left > 0 do
    make_due!()
    assert {:ok, %Batch{} = batch} = Dispatcher.run_once(settings)

    if Batches.latest(batch.id).remote_stopped_at,
      do: batch,
      else: drive_to_stopped!(settings, left - 1)
  end

  defp drive_to_stopped!(_, _), do: flunk("the original remote execution has no terminal proof")

  defp inputs! do
    entries = Fixtures.inputs!()
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

    Repo.update_all(
      from(e in Entry, where: e.id in ^Enum.map(entries, & &1.id)),
      set: [inserted_at: DateTime.add(now, -1), updated_at: DateTime.add(now, -1)]
    )

    entries
  end

  defp result(entries) do
    # Constructed host-contract result over the harvested HAProxy inputs. This
    # tests restart custody, not whether a model would make the right judgment.
    Jason.encode!(%{
      "reason" => "Maintain the reported condition with uncertainty.",
      "updates" => [
        %{
          "action" => "create",
          "source_input_ids" => Enum.map(entries, & &1.id),
          "topic_key" => "website-haproxy-oom",
          "title" => "Website HAProxy memory limit",
          "summary" => "Grafana reported the OOM warning resolved; recovery remains unverified.",
          "topics" => ["website", "OOM"],
          "anchors" => [],
          "target_ref" => nil,
          "expected_version" => 0
        }
      ]
    })
  end
end
