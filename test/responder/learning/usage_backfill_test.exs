defmodule Responder.Learning.UsageBackfillTest do
  # Learning turns only began writing execution_usage rows on 2026-09-11. The 60
  # learning runs that had already completed metered nothing, so /usage
  # under-reported the memory lane by roughly 911k tokens (286k fresh input, 623k
  # cached, 2.8k output) and the learning work type showed no history at all.
  # These tests hold the recovery shut: it writes the row the live path would
  # have written, once, and reports anything Coop can no longer produce instead
  # of inventing a counter for it.
  use Responder.DataCase, async: false
  import Ecto.Query
  alias Mix.Tasks.Responder.BackfillLearningUsage
  alias Responder.Accounting.Execution
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Learning.{Batch, Dispatcher, UsageBackfill}
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

  defmodule ForgottenTurnAPI do
    alias Responder.TestSupport.FakeCoopAPI, as: Fake

    defdelegate get_session(client, id), to: Fake

    def get_turn(_client, _session_id, _turn_id),
      do: {:error, {:coop_error, 404, "turn_not_found", "turn not found"}}
  end

  defmodule ForgottenSessionAPI do
    def get_session(_client, _session_id),
      do: {:error, {:coop_worker_command_timeout, "responder:fleet:read:get_session:1"}}
  end

  @settings %{
    policy: "recorded-read-only-policy",
    policy_digest: String.duplicate("a", 64),
    worker_ref: "learning-usage-backfill-test",
    quiet_seconds: 0,
    maximum_delay_seconds: 60,
    lease_seconds: 300,
    batch_size: 16,
    step_delay_seconds: 0,
    execution_timeout_seconds: 600,
    api: API
  }

  @target "codex:gpt-5.6-sol/medium@oncall"

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

  @recovered %{"input" => 4_100, "cached_input" => 900, "output" => 640, "reasoning" => 120}
  @nothing %{"input" => 0, "cached_input" => 0, "output" => 0, "reasoning" => 0}

  # Everything the live observation decided about this execution. usage_host_ms
  # and recorded_at are the host's own clock at observation and are checked
  # separately; the rest must come out identical or the backfill is a guess.
  @measured ~w(kind source_id generation episode_id session_id transport conversation_ref
    repository_ref execution_mode remote_ref status execution_target usage_recorded
    usage_input_tokens usage_cached_input_tokens usage_output_tokens usage_reasoning_tokens
    usage_cost_recorded usage_cost_usd timing_recorded remote_queued_at remote_started_at
    remote_finished_at usage_queued_ms usage_provider_ms measurement_error_code)a

  test "a dry run reports the spend it would recover and writes nothing" do
    %{settings: settings, run: run} = unmetered_history!()

    assert {:ok, report} = UsageBackfill.reconcile(settings, :dry_run)

    assert report["mode"] == "dry_run"
    assert report["unmetered_runs"] == 1
    assert report["recovered_runs"] == 1
    assert report["recovered_tokens"] == @recovered
    assert report["skipped_runs"] == []

    assert Repo.aggregate(Execution, :count) == 0
    assert Repo.get!(LearningRun, run.id).coop_turn_id == run.coop_turn_id
  end

  test "an applied backfill records the row the live path had already written" do
    %{settings: settings, run: run, live: live} = unmetered_history!()

    assert {:ok, report} = UsageBackfill.reconcile(settings, :apply)

    assert report["mode"] == "apply"
    assert report["recovered_runs"] == 1
    assert report["recovered_tokens"] == @recovered
    assert report["skipped_runs"] == []

    assert [row] = Repo.all(Execution)
    assert Map.take(row, @measured) == Map.take(live, @measured)

    # The daily /usage graph groups by date(recorded_at) and the ledger window
    # filters on it. Stamping the clock of the reconciliation would file every
    # recovered execution on the day the operator happened to run it.
    assert row.recorded_at == run.remote_stopped_at

    assert row.usage_host_ms ==
             DateTime.diff(run.remote_stopped_at, row.remote_finished_at, :millisecond)
  end

  test "a second apply recovers nothing because the ledger already holds the row" do
    %{settings: settings} = unmetered_history!()

    assert {:ok, _first} = UsageBackfill.reconcile(settings, :apply)
    assert [recovered] = Repo.all(Execution)

    assert {:ok, report} = UsageBackfill.reconcile(settings, :apply)

    assert report["unmetered_runs"] == 0
    assert report["recovered_runs"] == 0
    assert report["recovered_tokens"] == @nothing
    assert report["skipped_runs"] == []

    assert [unchanged] = Repo.all(Execution)
    assert unchanged.id == recovered.id
    assert unchanged.updated_at == recovered.updated_at
    assert unchanged.usage_input_tokens == recovered.usage_input_tokens
  end

  test "a run the live path already metered is never selected" do
    %{settings: settings} = metered_history!()

    assert {:ok, report} = UsageBackfill.reconcile(settings, :dry_run)

    assert report["unmetered_runs"] == 0
    assert report["recovered_runs"] == 0
    assert report["skipped_runs"] == []
    assert Repo.aggregate(Execution, :count) == 1
  end

  test "a run whose session or turn Coop can no longer produce is reported, never invented" do
    %{settings: settings, run: run} = unmetered_history!()

    # The reported reason is the stable tag and nothing else: the exact map below
    # is the whole operator-visible record, so a command reference or a
    # provider's own message cannot ride out in it.
    for {api, reason} <- [
          {ForgottenTurnAPI, "coop_error:404:turn_not_found"},
          {ForgottenSessionAPI, "coop_worker_command_timeout"}
        ] do
      assert {:ok, report} = UsageBackfill.reconcile(%{settings | api: api}, :apply)

      assert report["unmetered_runs"] == 1
      assert report["recovered_runs"] == 0
      assert report["recovered_tokens"] == @nothing

      assert report["skipped_runs"] == [
               %{"reason" => reason, "count" => 1, "run_ids" => [run.id]}
             ]

      assert Repo.aggregate(Execution, :count) == 0
    end
  end

  test "a turn Coop kept without usage is reported, never metered at zero" do
    # Nine of the sixty historical runs failed and their turns carry no usage at
    # all. A row of zeroes would read as a free execution on /usage; they stay
    # unmetered until Coop persists a failed turn's accumulated usage.
    %{settings: settings, fake: fake, run: run} = unmetered_history!()
    Agent.update(fake, fn state -> %{state | turn: Map.delete(state.turn, "usage")} end)

    assert {:ok, report} = UsageBackfill.reconcile(settings, :apply)

    assert report["recovered_runs"] == 0
    assert report["recovered_tokens"] == @nothing

    assert report["skipped_runs"] == [
             %{
               "reason" => "learning_turn_usage_unrecorded",
               "count" => 1,
               "run_ids" => [run.id]
             }
           ]

    assert Repo.aggregate(Execution, :count) == 0
  end

  test "the backfill command takes no target but the apply switch" do
    # A one-off that guessed at its arguments would write the ledger on the run
    # an operator meant to read.
    for arguments <- [
          ["--config", "/etc/responder/responder-elixir.yaml"],
          ["all"],
          ["--apply", "--apply"]
        ] do
      assert_raise Mix.Error, ~r/invalid_arguments/, fn ->
        BackfillLearningUsage.run(arguments)
      end
    end
  end

  defp unmetered_history! do
    history = metered_history!()
    # Exactly the state the ledger was in before migration 20260911001500: the
    # run and its Coop turn survive, the execution row was never written.
    Repo.delete_all(Execution)
    history
  end

  defp metered_history! do
    entries = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([result(entries)], turn_report: @report)
    Agent.update(fake, &put_in(&1, [:session, "target"], @target))
    settings = Map.put(@settings, :client, fake)

    assert %{status: :applied} = drive_to_applied!(settings, 5)
    assert [run] = Repo.all(LearningRun)
    assert %Session{} = Repo.get_by!(Session, execution_kind: :learning, learning_run_id: run.id)

    %{fake: fake, settings: settings, run: run, live: Repo.one!(Execution)}
  end

  defp drive_to_applied!(settings, left) when left > 0 do
    make_due!()
    assert {:ok, %Batch{} = batch} = Dispatcher.run_once(settings)
    assert batch.status in [:queued, :running, :applied]
    if batch.status == :applied, do: batch, else: drive_to_applied!(settings, left - 1)
  end

  defp drive_to_applied!(_settings, _left), do: flunk("the frozen execution did not resume")

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
    # exercises recovery of the learning lane's metering, not model judgment.
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
