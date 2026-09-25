defmodule Ryker.Learning.SessionCustodyTest do
  @moduledoc """
  Background learning on the local Compose install never once ran. The bundled
  worker created every learning session with the project environment and
  project MCP servers, the learner refused each one before binding it, and each
  attempt then waited for stop proof it could never get. Seven batches were
  re-checked every hour for up to four days (2026-09-21 to 09-24), 25 messages
  waited behind them, and the Learning page said the model "may still be
  running" about attempts that never sent it anything.

  These tests replay the rows and worker answers harvested from that install.
  """
  use Ryker.DataCase, async: false
  import Ecto.Query

  alias Ryker.Delivery.{PlatformAction, Reaction}
  alias Ryker.Fixtures.Learning, as: Fixtures
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.{Batch, Batches, Dispatcher, FleetSession}
  alias Ryker.State.{KnowledgeRevision, Learning, LearningRun}
  alias Ryker.TestSupport.FakeCoopAPI
  alias Ryker.Work.{Session, Turn}

  defmodule API do
    @moduledoc false
    # The recorded attempt's operation and session answer exactly as the worker
    # answered them; every other session is the ordinary fake. Placement is the
    # fleet's: a worker takes only a session whose policy digest it advertises.
    alias Ryker.Repo
    alias Ryker.TestSupport.FakeCoopAPI, as: Fake
    alias Ryker.Work.Session

    def operation_by_key(client, key) do
      case Fake.state(client)[:recorded] do
        %{create_key: ^key, operation: operation} -> {:ok, operation}
        _other -> Fake.operation_by_key(client, key)
      end
    end

    def get_session(client, id) do
      case Fake.state(client) do
        %{recorded: %{remote_id: ^id, answer: answer}} -> answer
        %{lost: %{remote_id: ^id, answer: answer}} -> answer
        _other -> Fake.get_session(client, id)
      end
    end

    def create_session(client, key, policy, ref, source) do
      session = Repo.get_by!(Session, external_ref: ref)

      if session.policy_digest == Fake.state(client)[:advertised_digest],
        do: Fake.create_session(client, key, policy, ref, source),
        else: {:error, {:coop_worker_capacity_unavailable, session.id}}
    end

    # The fleet's own question, asked without taking a slot.
    def accepts_session?(client, session),
      do: session.policy_digest == Fake.state(client)[:advertised_digest]

    defdelegate fence_create_session(client, key, policy, ref, source), to: Fake
    defdelegate cancel_turn(client, session_id, turn_id, key, revision), to: Fake

    def get_turn(client, session_id, turn_id) do
      case Fake.state(client) do
        %{lost: %{remote_id: ^session_id, answer: answer}} -> answer
        _other -> Fake.get_turn(client, session_id, turn_id)
      end
    end

    def submit_frozen_turn(client, session_id, key, revision, submission, nil, []) do
      Fake.submit_turn(
        client,
        session_id,
        key,
        revision,
        submission["prompt"],
        submission["output_schema"]
      )
    end

    def validate_frozen_candidate(client, session_id, turn_id, key, _attempt, sha256, :accept),
      do: Fake.validate_candidate(client, session_id, turn_id, key, sha256, :accept)
  end

  @fixture "testdata/learning/worker-session-never-confirmed.json"
  # The fake worker's own session digest; a corrected policy is a new digest.
  @current_digest String.duplicate("a", 64)

  @settings %{
    policy: "ryker-learning",
    policy_digest: @current_digest,
    worker_ref: "learning-session-custody",
    quiet_seconds: 0,
    maximum_delay_seconds: 60,
    lease_seconds: 300,
    batch_size: 16,
    step_delay_seconds: 0,
    execution_timeout_seconds: 600,
    api: API
  }

  test "an attempt whose worker session can never be reached again stops without a person" do
    # Five of the seven sessions lost their placement before Ryker bound them,
    # and the fleet never places an unbound session again. Each hourly check
    # asked for the same session and deferred the batch for another hour, 94
    # times for the oldest, while its conversation's new messages waited.
    stuck = recorded_stuck_attempt!("placement_replaced")
    unreachable = {:error, {:coop_session_replacement_required, stuck.session.id, 1}}
    fake = recorded_worker!(stuck, unreachable)
    settings = Map.put(@settings, :client, fake)
    replies = reply_rows()

    assert {:ok, %Batch{id: id, status: :queued}} = Dispatcher.run_once(settings)
    assert id == stuck.batch_id
    closed = Repo.get!(LearningRun, stuck.run.id)

    assert closed.remote_stopped_at,
           "the attempt still waits for a worker session no worker can reach"

    assert closed.stop_receipt == %{
             "kind" => "never_submitted",
             "reason" => "coop_session_replacement_required",
             "session" => "unaddressable",
             "session_id" => nil
           }

    assert is_nil(closed.submit_revision)
    assert Repo.get!(Batch, id).error_code == "learning_session_unconfirmed"

    # The batch learns again, with a fresh session under the policy the worker
    # offers now, on the starts it had left.
    assert %Batch{status: :applied, start_count: 2, policy_digest: @current_digest} =
             drive_to_applied!(settings, 5)

    assert [^closed, fresh] = runs(id)
    assert fresh.status == :applied and fresh.policy_digest == @current_digest
    assert FakeCoopAPI.state(fake).submit_count == 1
    assert Repo.aggregate(KnowledgeRevision, :count) == 1
    # Learning maintains knowledge; it never answers anyone.
    assert reply_rows() == replies
  end

  test "a session the worker made with project access is bound and closed before it hears a message" do
    # The other two sessions still answered, and still carried the project
    # environment and project MCP servers. Ryker refused them before binding,
    # so it could neither use them nor let cleanup close them on the worker.
    stuck = recorded_stuck_attempt!("placement_active")

    remote =
      Map.put(
        stuck.recorded["remote_session"],
        "external_ref",
        FleetSession.external_ref(stuck.run)
      )

    fake = recorded_worker!(stuck, {:ok, remote})
    settings = Map.put(@settings, :client, fake)

    assert {:ok, %Batch{status: :queued}} = Dispatcher.run_once(settings)
    closed = Repo.get!(LearningRun, stuck.run.id)

    assert closed.stop_receipt == %{"kind" => "never_submitted", "session_id" => remote["id"]},
           "the refused session was never closed"

    # Bound to its run, so cleanup can close and discard it on the worker.
    assert Repo.get!(Session, stuck.session.id).coop_session_id == remote["id"]

    assert %Batch{status: :applied, start_count: 2, policy_digest: @current_digest} =
             drive_to_applied!(settings, 5)

    assert FakeCoopAPI.state(fake).submit_count == 1
    refute FakeCoopAPI.state(fake).submitted_prompt =~ remote["id"]
  end

  test "a learning policy whose sessions are not isolated holds learning until the policy changes" do
    # One policy digest fixes one session authority, so every further attempt
    # would spend a start and leave the worker a session Ryker cannot use.
    # Learning holds instead, and resumes by itself once the policy changes.
    entries = inputs!()
    recorded = fixture()["cases"]["placement_active"]["remote_session"]

    {:ok, fake} =
      FakeCoopAPI.start_link([result(entries)],
        project_env: recorded["project_env"],
        project_mcp: recorded["project_mcp"]
      )

    Agent.update(fake, &Map.put(&1, :advertised_digest, @current_digest))
    settings = Map.put(@settings, :client, fake)
    replies = reply_rows()

    assert {:ok, %Batch{id: id, start_count: 1, error_code: "learning_session_not_isolated"}} =
             Dispatcher.run_once(settings)

    assert [refused] = Repo.all(LearningRun)
    assert refused.stop_receipt == %{"kind" => "never_submitted", "session_id" => "remote_test"}
    assert FakeCoopAPI.state(fake).submit_count == 0
    refute Map.has_key?(FakeCoopAPI.state(fake), :submitted_prompt)

    # Held, not retried: no second start and no second session under it.
    make_due!()
    assert {:ok, %Batch{id: ^id, status: :queued, start_count: 1}} = Dispatcher.run_once(settings)
    make_due!()
    assert {:ok, _held} = Dispatcher.run_once(settings)
    assert length(FakeCoopAPI.state(fake).create_keys) == 1
    assert Repo.aggregate(LearningRun, :count) == 1

    # A corrected policy is a new digest the worker advertises.
    corrected = String.duplicate("c", 64)

    Agent.update(fake, fn state ->
      state
      |> Map.put(:advertised_digest, corrected)
      |> update_in([:session], fn session ->
        Map.merge(session, %{
          "id" => "remote_isolated",
          "policy_digest" => corrected,
          "project_env" => false,
          "project_mcp" => false
        })
      end)
    end)

    settings = %{settings | policy_digest: corrected}

    assert %Batch{id: ^id, status: :applied, start_count: 2, policy_digest: ^corrected} =
             drive_to_applied!(settings, 5)

    assert FakeCoopAPI.state(fake).submit_count == 1
    assert reply_rows() == replies
  end

  test "a batch queued under a policy the worker no longer offers learns under the current one" do
    # Saving a new learning model rewrites the policy, and a worker places only
    # sessions of the digests it advertises. A batch queued before the change
    # prepared every attempt under its old digest, and each one spent a start
    # on a session no worker would ever place.
    entries = inputs!()
    old = %{@settings | policy_digest: String.duplicate("b", 64)}
    assert {:ok, claim} = Batches.claim("queued-before-the-change", old)
    assert {:ok, unstarted} = Batches.prepare(claim)
    assert {:ok, _} = Batches.yield(claim, 0)

    {:ok, fake} = FakeCoopAPI.start_link([result(entries)])
    Agent.update(fake, &Map.put(&1, :advertised_digest, @current_digest))
    settings = Map.put(@settings, :client, fake)

    assert %Batch{status: :applied, start_count: 1, policy_digest: @current_digest} =
             drive_to_applied!(settings, 5)

    # The attempt prepared under the old policy never started, and never will.
    assert %{status: :stale, error_code: "learning_policy_changed", started_at: nil} =
             Repo.get!(LearningRun, unstarted.id)

    assert [run] = Repo.all(from(r in LearningRun, where: not is_nil(r.started_at)))
    assert run.policy_digest == @current_digest
    assert length(FakeCoopAPI.state(fake).create_keys) == 1
  end

  test "an attempt whose worker never confirms its turn stopped closes after Coop's longest turn" do
    # A turn that reached the model may still be running while its worker is
    # out of reach, so its conversation waits for the worker's answer. When
    # that answer never comes (the worker was replaced, or runs another policy
    # version now), the conversation waited forever: Ryker asked again every
    # hour and learned nothing new there. No Coop turn outlives 24 hours, so
    # after that nothing more can arrive from it.
    entries = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([result(entries), result(entries)])
    Agent.update(fake, &Map.put(&1, :advertised_digest, @current_digest))
    settings = Map.put(@settings, :client, fake)
    replies = reply_rows()

    # The turn reaches the model, then its worker session drops out of reach.
    assert {:ok, %Batch{id: id, status: :queued, start_count: 1}} = Dispatcher.run_once(settings)
    assert [%LearningRun{coop_turn_id: turn_id} = submitted] = Repo.all(LearningRun)
    assert is_binary(turn_id) and is_integer(submitted.submit_revision)
    assert [session] = Repo.all(Session)

    Agent.update(
      fake,
      &Map.put(&1, :lost, %{
        remote_id: session.coop_session_id,
        answer: {:error, {:coop_session_replacement_required, session.id, 1}}
      })
    )

    assert %Batch{status: :deferred, error_code: "learning_remote_unresolved"} =
             drive_to_terminal!(settings, 13)

    # Within a day the turn may still be running, so the conversation waits.
    age!(submitted, 23 * 3_600)
    make_due!()
    assert {:ok, %Batch{id: ^id, status: :deferred}} = Dispatcher.run_once(settings)
    assert is_nil(Repo.get!(LearningRun, submitted.id).remote_stopped_at)

    # Past Coop's longest turn, counted from the end of Ryker's own window to
    # send one, nothing more can arrive: the attempt closes and learning goes on.
    age!(submitted, 24 * 3_600 + settings.execution_timeout_seconds + 60)
    make_due!()

    assert {:ok, %Batch{id: ^id, status: :queued, error_code: "learning_attempt_expired"}} =
             Dispatcher.run_once(settings)

    assert Repo.get!(LearningRun, submitted.id).stop_receipt == %{
             "closed_after_seconds" => 24 * 3_600 + settings.execution_timeout_seconds,
             "kind" => "attempt_expired",
             "session_id" => session.coop_session_id,
             "turn_id" => turn_id
           }

    Agent.update(fake, &put_in(&1, [:session, "id"], "remote_fresh"))

    assert %Batch{id: ^id, status: :applied, start_count: 2} = drive_to_applied!(settings, 5)
    assert FakeCoopAPI.state(fake).submit_count == 2
    assert Repo.aggregate(KnowledgeRevision, :count) == 1
    assert reply_rows() == replies
  end

  test "a worker outage holds learning without spending a start" do
    # A worker that is down, busy, or offers another version of the policy
    # refuses the session before anything is sent. Each attempt still spent a
    # start, then reconciled for nine minutes to prove nothing was created;
    # after three the conversation needed a person to grant another start,
    # though no model had been asked anything.
    entries = inputs!()
    {:ok, fake} = FakeCoopAPI.start_link([result(entries)])
    settings = Map.put(@settings, :client, fake)

    for _ <- 1..4 do
      make_due!()
      assert {:ok, %Batch{status: :queued, start_count: 0}} = Dispatcher.run_once(settings)
    end

    assert Repo.all(from(r in LearningRun, where: not is_nil(r.started_at))) == []
    assert FakeCoopAPI.state(fake).create_keys == []

    # The worker is back: learning resumes by itself, on its first start.
    Agent.update(fake, &Map.put(&1, :advertised_digest, @current_digest))
    assert %Batch{status: :applied, start_count: 1} = drive_to_applied!(settings, 5)
    assert FakeCoopAPI.state(fake).submit_count == 1
  end

  # The stuck rows as the install held them: one started attempt, never
  # submitted, ended unresolved after its reconciliations, its session unbound
  # and its batch deferred for the hourly re-check.
  defp recorded_stuck_attempt!(name) do
    recorded = fixture()["cases"][name]
    entries = inputs!()

    pinned = %{
      @settings
      | policy: recorded["run"]["policy"],
        policy_digest: recorded["run"]["policy_digest"]
    }

    assert {:ok, claim} = Batches.claim("recorded-learning-worker", pinned)
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, run} = Batches.begin_execution(claim, run.id)
    assert {:ok, session} = FleetSession.ensure(run)

    run =
      run
      |> Ecto.Changeset.change(
        status: String.to_existing_atom(recorded["run"]["status"]),
        error_code: recorded["run"]["error_code"],
        reconcile_attempt_count: recorded["run"]["reconcile_attempt_count"]
      )
      |> Repo.update!()

    assert {:ok, deferred} = Batches.release(claim, :learning_remote_unresolved, 0)

    assert Map.take(deferred, [:status, :start_count, :start_limit, :error_code]) == %{
             status: String.to_existing_atom(recorded["batch"]["status"]),
             start_count: recorded["batch"]["start_count"],
             start_limit: recorded["batch"]["start_limit"],
             error_code: recorded["batch"]["error_code"]
           }

    assert is_nil(session.coop_session_id) and is_nil(run.submit_revision)
    make_due!()

    %{recorded: recorded, entries: entries, run: run, session: session, batch_id: claim.batch.id}
  end

  defp recorded_worker!(stuck, answer) do
    {:ok, fake} = FakeCoopAPI.start_link([result(stuck.entries)])

    Agent.update(fake, fn state ->
      Map.merge(state, %{
        advertised_digest: @current_digest,
        recorded: %{
          answer: answer,
          create_key: Learning.operation_key(stuck.run, :create),
          operation: stuck.recorded["create_operation"],
          remote_id: stuck.recorded["create_operation"]["resource_id"]
        }
      })
    end)

    fake
  end

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()

  defp runs(batch_id),
    do: Repo.all(from(r in LearningRun, where: r.batch_id == ^batch_id, order_by: r.inserted_at))

  defp reply_rows,
    do: Enum.map([Turn, PlatformAction, Reaction], &Repo.aggregate(&1, :count))

  defp make_due! do
    Repo.update_all(Batch, set: [next_attempt_at: ~U[2000-01-01 00:00:00.000000Z]])
  end

  defp drive_to_applied!(settings, left) when left > 0 do
    make_due!()
    assert {:ok, %Batch{} = batch} = Dispatcher.run_once(settings)
    assert batch.status in [:queued, :running, :applied]
    if batch.status == :applied, do: batch, else: drive_to_applied!(settings, left - 1)
  end

  defp drive_to_applied!(_, _), do: flunk("the batch did not learn again")

  defp drive_to_terminal!(settings, left) when left > 0 do
    make_due!()
    assert {:ok, %Batch{} = batch} = Dispatcher.run_once(settings)

    if batch.status in [:queued, :running],
      do: drive_to_terminal!(settings, left - 1),
      else: batch
  end

  defp drive_to_terminal!(_, _), do: flunk("the attempt did not reach its reconciliation budget")

  # Move an attempt's start back by the database clock, which decides expiry.
  defp age!(run, seconds) do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

    Repo.update_all(from(r in LearningRun, where: r.id == ^run.id),
      set: [started_at: DateTime.add(now, -seconds)]
    )
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
    # Host-contract result over the harvested HAProxy inputs; these tests are
    # about session custody, not about what a model would learn.
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
