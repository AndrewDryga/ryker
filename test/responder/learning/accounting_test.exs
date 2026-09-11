defmodule Responder.Learning.AccountingTest do
  use Responder.DataCase, async: false
  import Ecto.Query
  alias Responder.Accounting.Execution
  alias Responder.ControlPlane.UsageProjection
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Learning.{Batch, Dispatcher}
  alias Responder.State.LearningRun
  alias Responder.TestSupport.FakeCoopAPI
  alias Responder.Work.Session

  defmodule API do
    alias Responder.TestSupport.FakeCoopAPI, as: Fake

    defdelegate operation_by_key(client, key), to: Fake
    defdelegate get_session(client, id), to: Fake
    defdelegate get_turn(client, sid, tid), to: Fake
    defdelegate create_session(client, key, policy, ref, source), to: Fake
    defdelegate fence_create_session(client, key, policy, ref, source), to: Fake
    defdelegate cancel_turn(client, sid, tid, key, revision), to: Fake

    def submit_frozen_turn(client, sid, key, revision, submission, nil, []) do
      Fake.submit_turn(
        client,
        sid,
        key,
        revision,
        submission["prompt"],
        submission["output_schema"]
      )
    end

    def fence_frozen_turn(client, sid, key, revision, submission, nil, []) do
      Fake.fence_submit_turn(
        client,
        sid,
        key,
        revision,
        submission["prompt"],
        submission["output_schema"]
      )
    end

    def validate_frozen_candidate(client, sid, tid, key, _attempt, sha, :accept),
      do: Fake.validate_candidate(client, sid, tid, key, sha, :accept)
  end

  @settings %{
    policy: "recorded-read-only-policy",
    policy_digest: String.duplicate("a", 64),
    worker_ref: "learning-accounting-test",
    quiet_seconds: 0,
    maximum_delay_seconds: 60,
    lease_seconds: 300,
    batch_size: 16,
    step_delay_seconds: 0,
    execution_timeout_seconds: 600,
    api: API
  }

  @target "codex:gpt-5.6-luna/low@oncall"

  @report %{
    "usage" => %{
      "input_tokens" => 4_100,
      "cached_input_tokens" => 900,
      "output_tokens" => 640,
      "reasoning_tokens" => 120
    },
    "queued_at" => "2026-09-11T10:00:00.000000Z",
    "started_at" => "2026-09-11T10:00:02.000000Z",
    "finished_at" => "2026-09-11T10:00:09.500000Z"
  }

  test "learning spend is metered in the same ledger as admission and work" do
    # Learning turns were never written to the execution ledger, so the memory
    # lane's model spend was invisible on /usage: every token the background
    # learner bought was missing from the only page that reports spend
    # (found 2026-09-11).
    entries = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([result(entries)], turn_report: @report)
    Agent.update(fake, &put_in(&1, [:session, "target"], @target))
    settings = Map.put(@settings, :client, fake)

    assert %{status: :applied} = drive_to_applied!(settings, 5)

    assert [run] = Repo.all(LearningRun)
    assert [batch] = Repo.all(Batch)
    session = Repo.get_by!(Session, execution_kind: :learning, learning_run_id: run.id)

    assert Repo.aggregate(Execution, :count) == 1
    row = Repo.one!(Execution)

    assert row.kind == "learning"
    assert row.source_id == run.id
    assert row.generation == to_string(run.generation)
    assert row.episode_id == nil
    assert row.session_id == session.id
    assert row.transport == batch.transport
    assert row.conversation_ref == batch.conversation_ref
    assert row.repository_ref == batch.repository_ref
    assert row.execution_mode == to_string(batch.execution_mode)
    assert row.status == "completed"
    assert row.remote_ref == run.coop_turn_id
    assert row.execution_target == @target
    assert row.usage_recorded
    assert row.usage_input_tokens == 4_100
    assert row.usage_cached_input_tokens == 900
    assert row.usage_output_tokens == 640
    assert row.usage_reasoning_tokens == 120
    assert row.timing_recorded
    assert row.usage_queued_ms == 2_000
    assert row.usage_provider_ms == 7_500
    assert is_integer(row.usage_host_ms) and row.usage_host_ms >= 0
    assert row.measurement_error_code == nil

    ledger = Responder.Accounting.Query.executions(nil, "all")
    assert Repo.aggregate(ledger, :count) == 1

    assert Repo.aggregate(
             Responder.Accounting.Query.executions(nil, to_string(batch.execution_mode)),
             :count
           ) == 1

    snapshot = UsageProjection.snapshot(ledger)
    assert [kind] = snapshot.kinds
    assert kind.work_kind == "learning"
    assert kind.tokens == 4_100 + 900 + 640
    assert kind.attempts == 1
    assert [model] = snapshot.models
    assert model.model == "gpt-5.6-luna"
    assert model.effort == "low"
    assert model.provider == "codex"
    assert snapshot.totals.usage_measured == 1
  end

  test "a learning turn that fails still keeps the spend it reported" do
    _entries = inputs!()

    {:ok, fake} =
      FakeCoopAPI.start_link([], fail_first_turn: true, turn_report: @report)

    Agent.update(fake, &put_in(&1, [:session, "target"], @target))
    settings = Map.put(@settings, :client, fake)

    assert {:ok, %{status: :queued}} = Dispatcher.run_once(settings)

    assert Repo.aggregate(Execution, :count) == 1
    row = Repo.one!(Execution)
    assert row.kind == "learning"
    assert row.status == "failed"
    assert row.usage_input_tokens == 4_100
    assert row.usage_recorded == true
    assert row.execution_target == @target

    assert [run] = Repo.all(LearningRun)
    assert run.stop_receipt["state"] == "failed"
  end

  test "repeated completed observations keep the first host span and never add tokens twice" do
    entries = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([result(entries)], turn_report: @report)
    Agent.update(fake, &put_in(&1, [:session, "target"], @target))
    settings = Map.put(@settings, :client, fake)

    assert %{status: :applied} = drive_to_applied!(settings, 5)

    assert [run] = Repo.all(LearningRun)
    assert [batch] = Repo.all(Batch)
    session = Repo.get_by!(Session, execution_kind: :learning, learning_run_id: run.id)
    row = Repo.one!(Execution)
    assert is_integer(row.usage_host_ms)

    completed_turn = FakeCoopAPI.state(fake).turn
    assert completed_turn["state"] == "completed"

    assert {:ok, _} =
             Repo.transaction(fn ->
               Responder.Accounting.observe_learning_in_transaction(
                 batch,
                 run,
                 session.id,
                 completed_turn,
                 %{"target" => @target},
                 DateTime.add(DateTime.utc_now(), 3600, :second)
               )
             end)

    assert Repo.aggregate(Execution, :count) == 1
    repeated = Repo.one!(Execution)
    assert repeated.usage_host_ms == row.usage_host_ms
    assert repeated.usage_input_tokens == row.usage_input_tokens
    assert repeated.usage_cached_input_tokens == row.usage_cached_input_tokens
    assert repeated.usage_output_tokens == row.usage_output_tokens
    assert repeated.usage_reasoning_tokens == row.usage_reasoning_tokens
  end

  defp drive_to_applied!(settings, left) when left > 0 do
    make_due!()
    assert {:ok, %Batch{} = batch} = Dispatcher.run_once(settings)
    assert batch.status in [:queued, :running, :applied]
    if batch.status == :applied, do: batch, else: drive_to_applied!(settings, left - 1)
  end

  defp drive_to_applied!(_, _), do: flunk("the frozen execution did not resume")

  defp make_due! do
    Repo.update_all(Batch, set: [next_attempt_at: ~U[2000-01-01 00:00:00.000000Z]])
  end

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
    # tests metering of the learning lane, not whether a model would judge well.
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
