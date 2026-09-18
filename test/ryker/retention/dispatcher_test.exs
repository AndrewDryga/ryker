defmodule Ryker.Retention.DispatcherTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.{ControlPlane, Placement}
  alias Ryker.Episodes
  alias Ryker.FakeRetentionCoopAPI, as: FakeAPI
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Retention.{Dispatcher, Executor}
  alias Ryker.Work.{Custody, Session}

  @now ~U[2026-08-29 10:00:00.000000Z]

  test "clean terminal work closes, plans, and discards one exact Coop session" do
    session = terminal_session!("clean")
    {:ok, api} = FakeAPI.start_link(sessions: [remote_session(session)])

    assert {:ok, {:executed, %{phase: :closed}}} = run(api, "cleanup:close")
    assert Repo.get!(Session, session.id).cleanup_status == :grace

    assert {:ok, {:executed, %{phase: :planned}}} = run(api, "cleanup:plan")
    assert Repo.get!(Session, session.id).cleanup_status == :discard_pending

    assert {:ok, {:executed, %{phase: :discarded}}} = run(api, "cleanup:discard")
    stored = Repo.get!(Session, session.id)
    assert stored.cleanup_status == :discarded
    assert stored.cleanup_receipt["remote_session_id"] == session.coop_session_id
    assert {:ok, :idle} = run(api, "cleanup:idle")

    calls = FakeAPI.calls(api)
    assert Enum.count(calls, &match?({:close, _, _}, &1)) == 1
    assert Enum.count(calls, &match?({:plan, _, _}, &1)) == 1
    assert Enum.count(calls, &match?({:discard, _, _}, &1)) == 1

    assert Enum.all?(Enum.filter(calls, &match?({:plan, _, _}, &1)), fn
             {:plan, _key, body} -> body["accept_dirty"] == false
           end)
  end

  test "completed writable task sessions release their worker capacity" do
    # Two finished task sessions held both worker reservations and blocked every new Slack turn.
    session = terminal_session!("writable-task-capacity")
    offer_ref = "record:task_offer:#{Ecto.UUID.generate()}"

    session =
      session
      |> Ecto.Changeset.change(workspace_task: %{"offer_ref" => offer_ref})
      |> Repo.update!()

    remote = session |> remote_session() |> Map.put("external_ref", offer_ref)
    {:ok, api} = FakeAPI.start_link(sessions: [remote])

    assert {:ok, {:executed, %{phase: :closed}}} =
             run(api, "cleanup:writable-task-capacity")

    assert Repo.get!(Session, session.id).cleanup_status == :grace
    assert Enum.any?(FakeAPI.calls(api), &match?({:close, _, _}, &1))
  end

  test "lost mutation responses reconcile exact keys and bodies without duplicate cleanup" do
    session = terminal_session!("response-loss")

    {:ok, api} =
      FakeAPI.start_link(
        sessions: [remote_session(session)],
        fail_first: [:close, :plan, :discard]
      )

    assert {:ok, {:deferred, {:coop_unavailable, :response_lost}}} =
             run(api, "cleanup:close:first")

    make_due!(session.id)
    assert {:ok, {:executed, %{phase: :closed}}} = run(api, "cleanup:close:reconcile")

    assert {:ok, {:deferred, {:coop_unavailable, :response_lost}}} =
             run(api, "cleanup:plan:first")

    make_due!(session.id)
    assert {:ok, {:executed, %{phase: :planned}}} = run(api, "cleanup:plan:reconcile")

    assert {:ok, {:deferred, {:coop_unavailable, :response_lost}}} =
             run(api, "cleanup:discard:first")

    make_due!(session.id)

    assert {:ok, {:executed, %{phase: :discarded}}} =
             run(api, "cleanup:discard:reconcile")

    calls = FakeAPI.calls(api)
    plan_calls = Enum.filter(calls, &match?({:plan, _, _}, &1))
    assert length(plan_calls) == 2

    assert plan_calls
           |> Enum.map(fn {:plan, key, body} -> {key, body} end)
           |> Enum.uniq()
           |> length() == 1

    assert Enum.count(calls, &match?({:discard, _, _}, &1)) == 1
  end

  test "dirty and unpublished unmerged work is retained instead of destroyed" do
    for {suffix, workspace, reason} <- [
          {"dirty", %{"dirty" => true, "unmerged" => false}, "dirty"},
          {"unmerged", %{"dirty" => false, "unmerged" => true}, "unpublished_unmerged"}
        ] do
      session = terminal_session!(suffix)

      {:ok, api} =
        FakeAPI.start_link(sessions: [remote_session(session)], workspace: workspace(workspace))

      assert {:ok, {:executed, %{phase: :closed}}} = run(api, "cleanup:#{suffix}:close")
      assert {:ok, {:executed, %{phase: :retained}}} = run(api, "cleanup:#{suffix}:plan")

      retained = Repo.get!(Session, session.id)
      assert retained.cleanup_status == :retained
      assert retained.retained_reason == reason
      refute Enum.any?(FakeAPI.calls(api), &match?({:discard, _, _}, &1))
    end
  end

  test "published unmerged work is explicitly accepted and then reclaimed" do
    %{episode: episode} = PublicationFixture.published!("retention-published")

    {_count, nil} =
      Repo.update_all(
        from(record in Ryker.State.Record,
          where: record.episode_id == ^episode.id and record.status == :open
        ),
        set: [status: :dismissed]
      )

    session =
      Repo.one!(
        from(session in Session,
          where: session.episode_id == ^episode.id,
          order_by: [desc: session.generation],
          limit: 1
        )
      )

    {:ok, api} =
      FakeAPI.start_link(
        sessions: [remote_session(session)],
        workspace: workspace(%{"dirty" => false, "unmerged" => true})
      )

    assert {:ok, {:executed, %{phase: :closed}}} = run(api, "cleanup:published:close")
    assert {:ok, {:executed, %{phase: :planned}}} = run(api, "cleanup:published:plan")

    planned = Repo.get!(Session, session.id)
    assert planned.discard_plan_accept_unmerged
    assert planned.discard_plan["workspace"]["accepted_unmerged"]

    assert {:ok, {:executed, %{phase: :discarded}}} = run(api, "cleanup:published:discard")
  end

  test "crossed remote authority blocks without deleting another session" do
    session = terminal_session!("crossed")

    crossed =
      session
      |> remote_session()
      |> Map.put("policy_digest", String.duplicate("f", 64))

    {:ok, api} = FakeAPI.start_link(sessions: [crossed])

    assert {:ok, {:blocked, {:coop_protocol_error, :session_authority}}} =
             run(api, "cleanup:crossed")

    assert Repo.get!(Session, session.id).cleanup_status == :blocked

    refute Enum.any?(
             FakeAPI.calls(api),
             &match?({phase, _, _} when phase in [:close, :plan, :discard], &1)
           )
  end

  test "malformed remote cleanup state and revision fail closed" do
    invalid_state = terminal_session!("invalid-state")

    {:ok, invalid_state_api} =
      FakeAPI.start_link(
        sessions: [remote_session(invalid_state) |> Map.put("state", "starting")]
      )

    assert {:ok, {:blocked, {:coop_protocol_error, :session_state}}} =
             run(invalid_state_api, "cleanup:invalid-state")

    missing_revision = terminal_session!("missing-revision")

    {:ok, missing_revision_api} =
      FakeAPI.start_link(sessions: [remote_session(missing_revision) |> Map.delete("revision")])

    assert {:ok, {:blocked, {:coop_protocol_error, :session_revision}}} =
             run(missing_revision_api, "cleanup:missing-revision")

    malformed_resource = terminal_session!("malformed-resource")

    {:ok, malformed_resource_api} =
      FakeAPI.start_link(sessions: [%{"id" => malformed_resource.coop_session_id}])

    assert {:ok, {:blocked, {:coop_protocol_error, :session_resource}}} =
             run(malformed_resource_api, "cleanup:malformed-resource")

    refute Enum.any?(FakeAPI.calls(invalid_state_api), &match?({:close, _, _}, &1))
    refute Enum.any?(FakeAPI.calls(missing_revision_api), &match?({:close, _, _}, &1))
    refute Enum.any?(FakeAPI.calls(malformed_resource_api), &match?({:close, _, _}, &1))
  end

  test "already terminal, exhausted, and never-bound sessions reconcile without unsafe deletion" do
    discarded = terminal_session!("already-discarded")

    {:ok, discarded_api} =
      FakeAPI.start_link(sessions: [remote_session(discarded) |> Map.put("state", "discarded")])

    assert {:ok, {:executed, %{phase: :discarded}}} =
             run(discarded_api, "cleanup:already-discarded")

    assert Repo.get!(Session, discarded.id).cleanup_receipt["kind"] == "already_discarded"

    closed = terminal_session!("already-closed")

    {:ok, closed_api} =
      FakeAPI.start_link(sessions: [remote_session(closed) |> Map.put("state", "closed")])

    assert {:ok, {:executed, %{phase: :closed}}} = run(closed_api, "cleanup:already-closed")
    stop_cleanup!(closed.id)

    exhausted = terminal_session!("exhausted")

    {:ok, exhausted_api} =
      FakeAPI.start_link(sessions: [remote_session(exhausted) |> Map.put("state", "exhausted")])

    assert {:ok, {:executed, %{phase: :closed}}} = run(exhausted_api, "cleanup:exhausted")
    stop_cleanup!(exhausted.id)

    never_bound = terminal_session!("never-bound")
    never_bound |> Ecto.Changeset.change(coop_session_id: nil) |> Repo.update!()
    {:ok, unused_api} = FakeAPI.start_link(sessions: [remote_session(never_bound)])

    assert {:ok, {:executed, %{phase: :discarded}}} =
             run(unused_api, "cleanup:never-bound")

    assert FakeAPI.calls(unused_api) == []
  end

  test "typed transient failures defer while permanent failures block with bounded diagnostics" do
    # A cleanup that raced two fresh placements was permanently blocked even though the next
    # worker poll reported both slots free, leaving terminal session custody stuck.
    transient_reasons = [
      {:retention_generation_spent, :close, :revision_conflict},
      {:coop_mutation_response_unresolved, :plan, :lost_response},
      {:coop_transport_error, :closed},
      {:coop_worker_capacity_unavailable, "session-capacity"},
      # On 2026-09-18 two learning cleanups were blocked for an operator after
      # one attempt because the only worker stopped polling for ninety seconds.
      {:coop_worker_command_timeout, "3b0c6f7e-8f1e-4d53-9c1f-2f4f0d7f9a11"},
      {:coop_error, 429, "rate_limited", "later"},
      {:coop_error, 503, "unavailable", "later"}
    ]

    for {reason, index} <- Enum.with_index(transient_reasons, 1) do
      session = terminal_session!("typed-transient-#{index}")

      assert {:ok, {:deferred, ^reason}} =
               run_returning(reason, "cleanup:typed-transient:#{index}")

      stored = Repo.get!(Session, session.id)
      assert stored.cleanup_status == :close_pending
      assert %DateTime{} = stored.cleanup_next_attempt_at
    end

    session = terminal_session!("bounded-permanent")
    reason = {:unsafe_cleanup, String.duplicate("é", 3_000)}

    assert {:ok, {:blocked, ^reason}} = run_returning(reason, "cleanup:bounded-permanent")

    blocked = Repo.get!(Session, session.id)
    assert blocked.cleanup_status == :blocked
    assert byte_size(blocked.cleanup_last_error_detail) <= 4_096
    assert String.valid?(blocked.cleanup_last_error_detail)
  end

  test "one cleanup pass drains a completion burst instead of a single phase" do
    # Six sessions finished inside one minute. Advancing one phase per sixty-second
    # poll meant the last one waited eighteen polls, and readiness reported that
    # perfectly healthy backlog as a stall long before cleanup could reach it.
    sessions = for index <- 1..6, do: terminal_session!("burst-#{index}")
    {:ok, api} = FakeAPI.start_link(sessions: Enum.map(sessions, &remote_session/1))

    assert {:ok, closed} = run_pass(api, "cleanup:burst:close")
    assert closed.executed == 6
    assert closed.attempted == 6
    assert closed.stopped == :idle

    assert Enum.all?(sessions, &(Repo.get!(Session, &1.id).cleanup_status == :grace))

    assert {:ok, planned} = run_pass(api, "cleanup:burst:plan")
    assert planned.executed == 6

    assert {:ok, discarded} = run_pass(api, "cleanup:burst:discard")
    assert discarded.executed == 6

    assert Enum.all?(sessions, &(Repo.get!(Session, &1.id).cleanup_status == :discarded))
    assert {:ok, %{attempted: 0, idle: true}} = run_pass(api, "cleanup:burst:idle")
  end

  test "one pass advances a session once so no single item can spend the budget" do
    sessions = for index <- 1..4, do: terminal_session!("share-#{index}")
    {:ok, api} = FakeAPI.start_link(sessions: Enum.map(sessions, &remote_session/1))

    assert {:ok, pass} = run_pass(api, "cleanup:share", batch_limit: 2)
    assert pass.attempted == 2
    assert pass.executed == 2
    assert pass.stopped == :batch_limit

    advanced = Enum.count(sessions, &(Repo.get!(Session, &1.id).cleanup_status == :grace))
    assert advanced == 2
  end

  test "a finite worker outage never exhausts cleanup into permanently blocked" do
    # A worker offline for a weekend spent every retry attempt and then blocked
    # cleanup permanently, so an operator had to rearm each session by hand even
    # though nothing about the session was wrong.
    session = terminal_session!("outage")
    {:ok, api} = FakeAPI.start_link(sessions: [remote_session(session)], offline: true)

    for attempt <- 1..12 do
      assert {:ok, %{deferred: 1}} = run_pass(api, "cleanup:outage:#{attempt}")
      make_due!(session.id)
    end

    deferred = Repo.get!(Session, session.id)
    assert deferred.cleanup_status == :close_pending
    assert deferred.cleanup_last_error_code == "coop_transport_error"
    assert deferred.cleanup_attempt_count >= 12

    FakeAPI.set_offline(api, false)
    assert {:ok, %{executed: 1}} = run_pass(api, "cleanup:outage:recovered")
    recovered = Repo.get!(Session, session.id)
    assert recovered.cleanup_status == :grace
    assert recovered.cleanup_attempt_count == 0
  end

  test "an unreachable worker cannot spend the pass budget owed to a healthy one" do
    offline_sessions = for index <- 1..3, do: terminal_session!("offline-#{index}")
    healthy = terminal_session!("healthy")

    Enum.each(offline_sessions, &place!(&1, "worker-offline"))
    place!(healthy, "worker-healthy")

    {:ok, api} =
      FakeAPI.start_link(
        sessions: Enum.map([healthy | offline_sessions], &remote_session/1),
        offline_sessions: Enum.map(offline_sessions, & &1.coop_session_id)
      )

    assert {:ok, pass} = run_pass(api, "cleanup:fairness", batch_limit: 4)

    assert pass.deferred == 1, "only the first call to an unreachable worker is worth making"
    assert pass.executed == 1
    assert pass.attempted == 2
    assert Repo.get!(Session, healthy.id).cleanup_status == :grace

    assert Enum.all?(
             offline_sessions,
             &(Repo.get!(Session, &1.id).cleanup_status in [:active, :close_pending])
           )
  end

  test "a reconnected worker makes its own deferred cleanup due before the backoff" do
    session = terminal_session!("reconnect")
    place!(session, "worker-reconnect")

    {:ok, api} =
      FakeAPI.start_link(
        sessions: [remote_session(session)],
        offline_sessions: [session.coop_session_id]
      )

    long_backoff = [retry_base_seconds: 300, retry_max_seconds: 300]

    assert {:ok, %{deferred: 1}} = run_pass(api, "cleanup:reconnect:outage", long_backoff)
    deferred = Repo.get!(Session, session.id)
    assert %DateTime{} = deferred.cleanup_next_attempt_at
    assert {:ok, %{attempted: 0}} = run_pass(api, "cleanup:reconnect:waiting", long_backoff)

    FakeAPI.set_offline(api, false)

    {:ok, api2} = FakeAPI.start_link(sessions: [remote_session(session)])
    heartbeat!("worker-reconnect")

    assert {:ok, %{executed: 1}} = run_pass(api2, "cleanup:reconnect:resumed")
    assert Repo.get!(Session, session.id).cleanup_status == :grace
  end

  test "a dirty workspace that later becomes clean is reclaimed without a manual edit" do
    # Dirty retention had no way back: the row stayed pinned even after the user
    # committed the change, so the fork survived every sweep until someone
    # edited the database by hand.
    session = terminal_session!("dirty-recheck")

    {:ok, api} =
      FakeAPI.start_link(
        sessions: [remote_session(session)],
        workspaces: %{session.coop_session_id => workspace(%{"dirty" => true})}
      )

    assert {:ok, %{executed: 1}} = run_pass(api, "cleanup:dirty:close")
    assert {:ok, %{executed: 1}} = run_pass(api, "cleanup:dirty:plan")

    retained = Repo.get!(Session, session.id)
    assert retained.cleanup_status == :retained
    assert retained.retained_reason == "dirty"
    assert %DateTime{} = retained.cleanup_next_attempt_at
    assert {:ok, %{attempted: 0}} = run_pass(api, "cleanup:dirty:pinned")

    FakeAPI.set_workspace(api, session.coop_session_id, workspace(%{"dirty" => false}))
    make_recheck_due!(session.id)

    assert {:ok, %{executed: 1}} = run_pass(api, "cleanup:dirty:replan")
    assert Repo.get!(Session, session.id).cleanup_status == :discard_pending

    assert {:ok, %{executed: 1}} = run_pass(api, "cleanup:dirty:discard")
    assert Repo.get!(Session, session.id).cleanup_status == :discarded
  end

  test "invalid dispatcher and executor options fail before claiming custody" do
    assert {:error, {:invalid_retention_dispatcher, :options}} = Dispatcher.settings(:invalid)

    assert {:error, {:invalid_retention_dispatcher, :options}} =
             Dispatcher.settings(client: :a, client: :b)

    assert {:error, {:invalid_retention_dispatcher, :options}} =
             Dispatcher.settings(%{unknown: true})

    assert {:error, {:invalid_retention_executor, :claim}} =
             Executor.run(:invalid, [])

    assert {:error, {:invalid_retention_executor, :options}} =
             Executor.run(
               %{lease_ref: "lease", session: %Session{cleanup_status: :active}},
               :invalid
             )

    assert {:error, {:invalid_retention_executor, :status}} =
             Executor.run(
               %{lease_ref: "lease", session: %Session{cleanup_status: :active}},
               client: :unused
             )
  end

  defp run(api, worker_ref) do
    Dispatcher.run_once(
      api: FakeAPI,
      client: api,
      closed_session_grace_seconds: 0,
      lease_seconds: 60,
      max_attempts: 8,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: worker_ref
    )
  end

  defp run_pass(api, worker_ref, overrides \\ []) do
    Dispatcher.run_pass(
      Keyword.merge(
        [
          api: FakeAPI,
          batch_limit: 25,
          batch_seconds: 30,
          client: api,
          closed_session_grace_seconds: 0,
          lease_seconds: 60,
          max_attempts: 8,
          retained_recheck_seconds: 21_600,
          retry_base_seconds: 1,
          retry_max_seconds: 60,
          worker_ref: worker_ref
        ],
        overrides
      )
    )
  end

  defp place!(session, worker_id) do
    assert {:ok, _worker} =
             ControlPlane.authorize_worker(
               worker_id,
               "workspace-retention",
               :crypto.hash(:sha256, worker_id) |> Base.encode16(case: :lower)
             )

    now = DateTime.utc_now()
    requirements = %{"workspace_ref" => "workspace-retention"}

    # Structural fixture: the durable record of which worker still owns the fork.
    Repo.insert!(%Placement{
      episode_id: session.episode_id,
      generation: 1,
      id: Ecto.UUID.generate(),
      inserted_at: now,
      lease_expires_at: DateTime.add(now, 3_600, :second),
      lease_ref: "placement-lease:#{session.id}",
      requirements: requirements,
      requirements_fingerprint: CanonicalJSON.digest(requirements),
      session_id: session.id,
      state: :retired,
      updated_at: now,
      worker_id: worker_id
    })
  end

  defp run_returning(reason, worker_ref) do
    Dispatcher.run_once(
      api: FakeAPI,
      client: {:error, reason},
      closed_session_grace_seconds: 0,
      executor: __MODULE__.ReturningExecutor,
      lease_seconds: 60,
      max_attempts: 8,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: worker_ref
    )
  end

  defmodule ReturningExecutor do
    @moduledoc false

    def run(_claim, options), do: Keyword.fetch!(options, :client)
  end

  defp terminal_session!(suffix) do
    id = Ecto.UUID.generate()
    key = "retention-dispatch:#{suffix}:#{id}"
    turn_ref = "turn:#{suffix}:#{id}"

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: key,
                 native_input_id: "source:#{suffix}:#{id}",
                 occurred_at: @now,
                 turn_ref: turn_ref
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(
               id,
               "work-read-only",
               String.duplicate("a", 64),
               "ryker"
             )

    session =
      session
      |> Ecto.Changeset.change(coop_session_id: "remote:#{suffix}:#{id}")
      |> Repo.update!()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.cancel_episode(%{
                 cancel_ref: "cancel:#{suffix}:#{id}",
                 episode_key: key,
                 expected_owner: %{kind: :turn, ref: turn_ref},
                 occurred_at: DateTime.add(@now, 1, :second)
               })
             )

    session
  end

  defp remote_session(session) do
    %{
      "external_ref" => session.external_ref,
      "id" => session.coop_session_id,
      "policy" => session.policy,
      "policy_digest" => session.policy_digest,
      "revision" => 7,
      "state" => "open"
    }
  end

  defp workspace(overrides) do
    Map.merge(
      %{
        "branch" => "coop/session",
        "dirty" => false,
        "head" => String.duplicate("a", 40),
        "running" => false,
        "status_digest" => String.duplicate("b", 64),
        "unmerged" => false
      },
      overrides
    )
  end

  defp make_due!(session_id) do
    {1, nil} =
      Repo.update_all(
        from(session in Session, where: session.id == ^session_id),
        set: [
          cleanup_lease_expires_at: ~U[2000-01-01 00:00:00.000000Z],
          cleanup_next_attempt_at: ~U[2000-01-01 00:00:00.000000Z]
        ]
      )
  end

  defp heartbeat!(worker_id) do
    # Structural fixture: the durable heartbeat that proves the worker is back.
    {1, nil} =
      Repo.update_all(
        from(worker in Ryker.CoopFleet.Worker, where: worker.id == ^worker_id),
        set: [last_seen_at: DateTime.utc_now()]
      )
  end

  defp make_recheck_due!(session_id) do
    {1, nil} =
      Repo.update_all(
        from(session in Session, where: session.id == ^session_id),
        set: [cleanup_next_attempt_at: ~U[2000-01-01 00:00:00.000000Z]]
      )
  end

  defp stop_cleanup!(session_id) do
    session = Repo.get!(Session, session_id)
    session |> Ecto.Changeset.change(cleanup_status: :blocked) |> Repo.update!()
  end
end
