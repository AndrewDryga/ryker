defmodule Responder.Retention.ThirtyDaySimulationTest do
  @moduledoc """
  Thirty accelerated days of sustained use through the real cleanup lifecycle.

  Time is injected: every age and lease comparison in retention custody reads
  PostgreSQL's clock, so the simulation shadows `clock_timestamp()` and `now()`
  with offset versions on its own connection and moves that offset forward. A
  whole month of eligibility, grace, backoff and retained-workspace recheck
  passes through `Custody`, `Dispatcher` and `Executor` unchanged while the wall
  clock barely moves. Bytes are scaled: one fork is 64 MiB against a 10 GiB
  per-worker inactive-disposable bound, so a month of forks is proved without
  allocating a month of forks.
  """

  use Responder.DataCase, async: false

  import Ecto.Query

  @moduletag :simulation

  alias Responder.CanonicalJSON
  alias Responder.CoopFleet.{Placement, Worker}
  alias Responder.Episodes.Episode
  alias Responder.FakeRetentionCoopAPI, as: FakeAPI
  alias Responder.Fixtures.Publication, as: PublicationFixture
  alias Responder.Publication.Publication
  alias Responder.Retention.{Custody, Dispatcher}
  alias Responder.Work.Session

  @days String.to_integer(System.get_env("RESPONDER_SIMULATION_DAYS", "30"))
  @bursts_per_day 4
  @burst_seconds 21_600
  @poll_seconds 60
  @grace_seconds 900
  @retained_recheck_seconds 86_400

  # Scaled byte budget: one disposable fork is 64 MiB and the documented bound
  # for inactive disposable forks is 10 GiB per worker, so the plateau this
  # proves is 160 forks, not 160 real gigabytes in a test database.
  @fork_bytes 67_108_864
  @disposable_bytes_limit 10_737_418_240
  @reclaim_target_seconds 3_600

  @backlog 300
  @clean_per_burst 25
  @dirty_per_burst 1
  @unmerged_per_burst 1
  @active_per_burst 1

  @outage_days 12..13
  @clean_dirty_day 20
  @publish_day 22
  @restart_days [5, 17, 26]

  @workers ~w(worker-a worker-b)

  @tag timeout: 900_000
  @tag ownership_timeout: 900_000
  test "thirty days of sustained use plateau under the disposable bound without losing work" do
    {:ok, api} =
      FakeAPI.start_link(
        sessions: [],
        # One in every forty mutations answers after its response is lost, so
        # interrupted closes, plans and discards are reconciled all month.
        lose_every: 40
      )

    install_clock!()
    Enum.each(@workers, &create_worker!/1)

    backlog = arrive!(api, "backlog", :clean, @backlog)
    delayed = publication_delayed!(api)

    state = %{
      api: api,
      day_rows: [],
      dirty: [],
      grace_at: %{},
      latencies: [],
      statuses: %{},
      started_at: System.monotonic_time(:second),
      time: 0,
      unmerged: [],
      running: [],
      worker_ref: "cleanup:host-1"
    }

    state = Enum.reduce(1..@days, state, &simulate_day/2)

    report(state)
    assert_plateau(state)
    assert_latency(state)
    assert_backlog_drained(backlog)
    assert_protected_work_survived(state, api)
    assert_publication_delay_released(delayed, api)
  end

  defp simulate_day(day, state) do
    state = restart_host(state, day)
    state = start_outage(state, day)
    state = clean_one_dirty_workspace(state, day)
    state = publish_delayed(state, day)

    state =
      Enum.reduce(1..@bursts_per_day, state, fn burst, state ->
        arrive!(state.api, "d#{day}b#{burst}", :clean, @clean_per_burst)
        dirty = arrive!(state.api, "d#{day}b#{burst}", :dirty, @dirty_per_burst)
        unmerged = arrive!(state.api, "d#{day}b#{burst}", :unmerged, @unmerged_per_burst)
        running = arrive!(state.api, "d#{day}b#{burst}", :running, @active_per_burst)

        state = %{
          state
          | dirty: state.dirty ++ dirty,
            running: state.running ++ running,
            unmerged: state.unmerged ++ unmerged
        }

        drain_window(state, @burst_seconds)
      end)

    state = end_outage(state, day)
    row = measure(state, day)

    IO.puts(
      "simulation day #{day}: disposable #{row.disposable_forks} protected #{row.protected_forks} " <>
        "discarded #{row.discarded} elapsed #{System.monotonic_time(:second) - state.started_at}s"
    )

    %{state | day_rows: state.day_rows ++ [row]}
  end

  # One burst window: cleanup passes while there is work, then the clock jumps
  # to the next durable due time instead of to the next wall-clock minute.
  defp drain_window(state, remaining) when remaining <= 0, do: state

  defp drain_window(state, remaining) do
    started = database_now!()
    {:ok, pass} = run_pass(state)
    state = if pass.executed > 0, do: record_pass(state, started), else: state

    if pass.attempted > 0 do
      drain_window(tick(state, @poll_seconds), remaining - @poll_seconds)
    else
      jump = min(seconds_until_due() || remaining, remaining)
      drain_window(tick(state, max(jump, @poll_seconds)), remaining - max(jump, @poll_seconds))
    end
  end

  defp run_pass(state) do
    Dispatcher.run_pass(
      api: FakeAPI,
      batch_limit: 25,
      batch_seconds: 30,
      client: state.api,
      closed_session_grace_seconds: @grace_seconds,
      lease_seconds: 300,
      max_attempts: 8,
      retained_recheck_seconds: @retained_recheck_seconds,
      retry_base_seconds: 5,
      retry_max_seconds: 300,
      worker_ref: state.worker_ref
    )
  end

  # Cleanup latency is measured from the durable moment a session became
  # eligible: its close time plus the intentional grace period.
  defp record_pass(state, started) do
    rows =
      Repo.all(
        from(session in Session,
          where:
            session.cleanup_status in [:grace, :retained] or
              (session.cleanup_status == :discarded and session.discarded_at >= ^started),
          where: session.execution_kind == :work,
          select: {session.id, session.cleanup_status, session.coop_session_id}
        )
      )

    Enum.reduce(rows, state, fn {id, status, remote_id}, state ->
      if Map.get(state.statuses, id) == status,
        do: state,
        else: transition(state, id, status, remote_id)
    end)
  end

  # Retention is a decision, not latency: a workspace kept for dirty or
  # unpublished work is measured by what it protects, not by how long it takes
  # to reclaim once that evidence changes.
  defp transition(state, id, :retained, _remote_id) do
    %{
      state
      | grace_at: Map.delete(state.grace_at, id),
        statuses: Map.put(state.statuses, id, :retained)
    }
  end

  defp transition(state, id, :grace, _remote_id) do
    %{
      state
      | grace_at: Map.put(state.grace_at, id, state.time + @grace_seconds),
        statuses: Map.put(state.statuses, id, :grace)
    }
  end

  defp transition(state, id, :discarded, remote_id) do
    latencies =
      case Map.get(state.grace_at, id) do
        nil ->
          state.latencies

        eligible_at ->
          [
            %{
              eligible_day: div(eligible_at, 86_400) + 1,
              latency: max(state.time - eligible_at, 0),
              worker: worker_of(remote_id)
            }
            | state.latencies
          ]
      end

    %{state | latencies: latencies, statuses: Map.put(state.statuses, id, :discarded)}
  end

  defp worker_of("remote:" <> rest), do: rest |> String.split(":") |> hd()
  defp worker_of(_remote_id), do: "unknown"

  defp tick(state, seconds) do
    advance!(state.time + seconds)
    %{state | time: state.time + seconds}
  end

  # The injected clock. `pg_catalog` is searched after the simulation schema, so
  # every unqualified `clock_timestamp()` and `now()` custody issues on this
  # connection answers with the offset applied. SET and DDL are transactional,
  # so the sandbox rollback removes both without touching any other test.
  defp install_clock! do
    Repo.query!("CREATE SCHEMA simulation")

    for function <- ~w(clock_timestamp now) do
      Repo.query!("""
      CREATE FUNCTION simulation.#{function}() RETURNS timestamptz LANGUAGE sql STABLE AS $$
        SELECT pg_catalog.#{function}() +
          COALESCE(current_setting('simulation.offset_seconds', true), '0')::numeric *
            interval '1 second'
      $$
      """)
    end

    Repo.query!("SET search_path TO simulation, pg_catalog, public")
  end

  defp advance!(offset_seconds) do
    Repo.query!("SELECT set_config('simulation.offset_seconds', $1, false)", [
      Integer.to_string(offset_seconds)
    ])
  end

  defp seconds_until_due do
    %{rows: [[seconds]]} =
      Repo.query!("""
      SELECT CEIL(EXTRACT(EPOCH FROM (LEAST(
        (SELECT min(discard_after) FROM episode_work_sessions
          WHERE cleanup_status = 'grace' AND discard_after > clock_timestamp()),
        (SELECT min(cleanup_next_attempt_at) FROM episode_work_sessions
          WHERE cleanup_status <> 'discarded' AND cleanup_next_attempt_at > clock_timestamp())
      ) - clock_timestamp())))::bigint + 1
      """)

    seconds
  end

  defp restart_host(state, day) do
    if day in @restart_days do
      # A restarted host owns none of the leases it wrote before the restart.
      {:ok, _released} = Custody.release_worker_leases(state.worker_ref)
      %{state | worker_ref: "cleanup:host-#{day}"}
    else
      state
    end
  end

  defp start_outage(state, day) do
    if day == @outage_days.first do
      FakeAPI.set_offline_prefix(state.api, "remote:worker-b:")
      stale_worker!("worker-b")
    end

    state
  end

  defp end_outage(state, day) do
    if day == @outage_days.last do
      FakeAPI.set_offline_prefix(state.api, nil)
      heartbeat_worker!("worker-b")
    end

    state
  end

  defp clean_one_dirty_workspace(state, day) do
    if day == @clean_dirty_day and state.dirty != [] do
      session = hd(state.dirty)
      FakeAPI.set_workspace(state.api, session.coop_session_id, workspace(%{"dirty" => false}))
      Map.put(state, :cleaned_dirty, session)
    else
      state
    end
  end

  defp publish_delayed(state, day) do
    if day == @publish_day do
      {_count, nil} =
        Repo.update_all(
          from(publication in Publication, where: publication.status != :published),
          set: [
            published_at: database_now!(),
            published_delivery_receipt: %{"delivered" => true},
            published_delivery_receipt_fingerprint: String.duplicate("c", 64),
            status: :published
          ]
        )
    end

    state
  end

  defp measure(state, day) do
    disposable = Repo.aggregate(disposable_query(), :count, :id)
    protected = Repo.aggregate(protected_query(), :count, :id)

    %{
      day: day,
      disposable_bytes: disposable * @fork_bytes,
      disposable_forks: disposable,
      discarded:
        Repo.aggregate(from(s in Session, where: s.cleanup_status == :discarded), :count, :id),
      blocked:
        Repo.aggregate(from(s in Session, where: s.cleanup_status == :blocked), :count, :id),
      maximum_latency_seconds: state.latencies |> Enum.map(& &1.latency) |> Enum.max(fn -> 0 end),
      protected_bytes: protected * @fork_bytes,
      protected_forks: protected,
      retained:
        from(s in Session,
          where: s.cleanup_status == :retained,
          group_by: s.retained_reason,
          select: {s.retained_reason, count(s.id)}
        )
        |> Repo.all()
        |> Map.new(),
      virtual_day: div(state.time, 86_400)
    }
  end

  # Inactive disposable forks: a terminal owner, nothing pinning the session,
  # cleanup not finished. Protected work is never counted against this bound.
  defp disposable_query do
    from(session in Session,
      join: episode in Episode,
      on: episode.id == session.episode_id,
      where: episode.state in [:complete, :cancelled],
      where:
        session.cleanup_status in [
          :active,
          :close_pending,
          :grace,
          :plan_pending,
          :discard_pending
        ],
      where:
        session.id not in subquery(
          from(publication in Publication,
            where: publication.status != :published,
            select: publication.session_id
          )
        )
    )
  end

  defp protected_query do
    from(session in Session,
      join: episode in Episode,
      on: episode.id == session.episode_id,
      where:
        session.cleanup_status in [:retained, :blocked] or
          episode.state not in [:complete, :cancelled] or
          session.id in subquery(
            from(publication in Publication,
              where: publication.status != :published,
              select: publication.session_id
            )
          )
    )
  end

  defp assert_plateau(state) do
    healthy = Enum.reject(state.day_rows, &(&1.day in @outage_days))
    settled = Enum.drop(healthy, 1)
    peak = settled |> Enum.map(& &1.disposable_bytes) |> Enum.max()

    assert peak <= @disposable_bytes_limit,
           "eligible disposable bytes peaked at #{peak}, above the configured " <>
             "#{@disposable_bytes_limit} bound"

    early = Enum.find(state.day_rows, &(&1.day == min(10, @days)))
    late = Enum.find(state.day_rows, &(&1.day == @days))

    assert late.disposable_bytes <= max(early.disposable_bytes, @fork_bytes * 20),
           "disposable storage grew with elapsed days: day 10 held " <>
             "#{early.disposable_bytes} and day #{@days} held #{late.disposable_bytes}"

    recovered = Enum.find(state.day_rows, &(&1.day == @outage_days.last + 1))

    if recovered do
      assert recovered.disposable_bytes <= @disposable_bytes_limit,
             "the backlog from the multi-day outage did not drain after reconnect"
    end

    assert List.last(state.day_rows).blocked == 0,
           "an outage or a lost response left cleanup permanently blocked"
  end

  # The one-hour target is a promise about healthy workers. Forks that became
  # eligible on the offline worker during its outage are reported, not asserted,
  # and must still have been reclaimed by the end of the month.
  defp assert_latency(state) do
    assert state.latencies != []
    healthy = Enum.reject(state.latencies, &outage_sample?/1)
    maximum = healthy |> Enum.map(& &1.latency) |> Enum.max()

    assert maximum <= @reclaim_target_seconds,
           "a healthy worker reclaimed an eligible fork #{maximum}s after eligibility, " <>
             "beyond the #{@reclaim_target_seconds}s target"
  end

  defp outage_sample?(%{worker: "worker-b", eligible_day: day}),
    do: day >= @outage_days.first and day <= @outage_days.last + 1

  defp outage_sample?(_sample), do: false

  defp assert_backlog_drained(backlog) do
    remaining =
      Repo.aggregate(
        from(session in Session,
          where: session.id in ^Enum.map(backlog, & &1.id),
          where: session.cleanup_status != :discarded
        ),
        :count,
        :id
      )

    assert remaining == 0, "#{remaining} pre-existing forks were never reconciled"
  end

  defp assert_protected_work_survived(state, api) do
    discarded_targets =
      api
      |> FakeAPI.calls()
      |> Enum.filter(&match?({:discard, _key, _body}, &1))
      |> MapSet.new(fn {:discard, _key, body} -> body["session_id"] end)

    cleaned = Map.get(state, :cleaned_dirty)
    protected = state.running ++ state.unmerged ++ Enum.reject(state.dirty, &(&1 == cleaned))

    Enum.each(protected, fn session ->
      stored = Repo.get!(Session, session.id)

      refute stored.cleanup_status == :discarded,
             "protected session #{stored.external_ref} was discarded"

      refute MapSet.member?(discarded_targets, session.coop_session_id),
             "a discard was issued against protected session #{session.external_ref}"

      assert stored.coop_session_id == session.coop_session_id
      assert stored.policy_digest == session.policy_digest
    end)

    assert Repo.aggregate(from(s in Session, where: s.retained_reason == "dirty"), :count, :id) >
             0

    assert Repo.aggregate(from(s in Session, where: s.cleanup_status == :retained), :count, :id) >
             0

    if cleaned do
      assert Repo.get!(Session, cleaned.id).cleanup_status == :discarded,
             "a dirty workspace that became clean was never reconsidered"
    end
  end

  defp assert_publication_delay_released(delayed, api) do
    Enum.each(delayed, fn session ->
      stored = Repo.get!(Session, session.id)

      assert stored.cleanup_status == :discarded,
             "a session held by a delayed publication was never released after it published"
    end)

    assert Enum.any?(
             FakeAPI.calls(api),
             &match?({:discard, _key, %{"session_id" => _}}, &1)
           )
  end

  defp report(state) do
    header =
      "| day | virtual day | disposable forks | disposable bytes | protected forks | " <>
        "protected bytes | discarded | blocked | retained | max latency s |"

    rows =
      Enum.map(state.day_rows, fn row ->
        "| #{row.day} | #{row.virtual_day} | #{row.disposable_forks} | " <>
          "#{row.disposable_bytes} | #{row.protected_forks} | #{row.protected_bytes} | " <>
          "#{row.discarded} | #{row.blocked} | #{inspect(row.retained)} | " <>
          "#{row.maximum_latency_seconds} |"
      end)

    document =
      """
      # Accelerated thirty-day workspace cleanup simulation

      Deterministic, no model and no credentials. Time is injected by shadowing
      PostgreSQL's `clock_timestamp()` and `now()` on the test connection with an
      offset the simulation advances; bytes are scaled at #{@fork_bytes} per fork
      against a #{@disposable_bytes_limit} inactive-disposable bound per worker.
      One cleanup pass per simulated minute whenever work is due; idle time is
      skipped to the next durable due time.

      Pre-existing backlog: #{@backlog} forks. Arrivals: #{@clean_per_burst * @bursts_per_day}
      clean completions per simulated day plus dirty, unmerged and still-running work.
      Worker outage: days #{@outage_days.first}-#{@outage_days.last}. Host restarts on
      days #{inspect(@restart_days)}. One in forty mutations loses its response.

      Reclaim latency observed on healthy workers (excluding forks that became
      eligible on the offline worker during its outage and the recovery day):
      maximum #{latency_maximum(state, false)} s, mean #{latency_mean(state, false)} s,
      samples #{latency_count(state, false)}, target #{@reclaim_target_seconds} s.
      Outage-window forks on the offline worker: maximum #{latency_maximum(state, true)} s,
      samples #{latency_count(state, true)}; all reclaimed after reconnect.

      """ <>
        Enum.join(
          [header, "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |" | rows],
          "\n"
        ) <> "\n"

    File.mkdir_p!("artifacts")
    File.write!("artifacts/2026-09-11-thirty-day-simulation.md", document)
  end

  defp latency_samples(state, outage?),
    do: state.latencies |> Enum.filter(&(outage_sample?(&1) == outage?)) |> Enum.map(& &1.latency)

  defp latency_maximum(state, outage?), do: Enum.max(latency_samples(state, outage?), fn -> 0 end)
  defp latency_count(state, outage?), do: length(latency_samples(state, outage?))

  defp latency_mean(state, outage?) do
    case latency_samples(state, outage?) do
      [] -> 0
      values -> div(Enum.sum(values), length(values))
    end
  end

  # Structural fixtures below: durable episode and session rows. The simulation
  # is about the cleanup lifecycle, so admission is not replayed for every one
  # of several thousand sessions.
  defp arrive!(api, label, kind, count) do
    now = database_now!()
    worker_ids = @workers

    rows =
      Enum.map(1..count, fn index ->
        episode_id = Ecto.UUID.generate()
        session_id = Ecto.UUID.generate()
        worker_id = Enum.at(worker_ids, rem(index, length(worker_ids)))
        remote_id = "remote:#{worker_id}:#{session_id}"

        %{
          episode: episode_row(episode_id, "#{label}:#{kind}:#{index}", kind, now),
          kind: kind,
          remote_id: remote_id,
          session: session_row(session_id, episode_id, remote_id, now),
          worker_id: worker_id
        }
      end)

    Repo.insert_all(Episode, Enum.map(rows, & &1.episode))
    Repo.insert_all(Session, Enum.map(rows, & &1.session))
    Repo.insert_all(Placement, Enum.map(rows, &placement_row(&1, now)))

    Enum.each(rows, fn row ->
      FakeAPI.add_session(
        api,
        %{
          "external_ref" => row.session.external_ref,
          "id" => row.remote_id,
          "policy" => row.session.policy,
          "policy_digest" => row.session.policy_digest,
          "revision" => 7,
          "state" => "open"
        },
        workspace_for(kind)
      )
    end)

    Enum.map(rows, &struct(Session, &1.session))
  end

  defp episode_row(id, key, kind, now) do
    terminal? = kind != :running

    %{
      active_input_refs: [],
      destination_conversation_ref: "slack:T-simulation:C-simulation",
      destination_transport: "slack",
      execution_mode: :live,
      id: id,
      inserted_at: now,
      input_revisions: %{},
      key: "simulation:#{key}:#{id}",
      next_sequence: 1,
      owner_kind: if(terminal?, do: nil, else: :turn),
      owner_ref: if(terminal?, do: nil, else: "turn:#{id}"),
      queued_input_order_keys: [],
      queued_input_refs: [],
      semantic_version: 0,
      state: if(terminal?, do: :complete, else: :working),
      updated_at: now
    }
  end

  defp session_row(id, episode_id, remote_id, now) do
    %{
      cleanup_attempt_count: 0,
      cleanup_status: :active,
      coop_session_id: remote_id,
      create_generation: 1,
      episode_id: episode_id,
      execution_kind: :work,
      external_ref: "responder-work:#{episode_id}:session:1",
      generation: 1,
      id: id,
      inserted_at: now,
      policy: "work-read-only",
      policy_digest: String.duplicate("a", 64),
      repository_ref: "responder",
      updated_at: now
    }
  end

  defp placement_row(row, now) do
    requirements = %{"workspace_ref" => "workspace-simulation"}

    %{
      episode_id: row.episode.id,
      generation: 1,
      id: Ecto.UUID.generate(),
      inserted_at: now,
      last_acked_event_sequence: 0,
      last_acked_session_event_sequence: 0,
      lease_expires_at: now,
      lease_ref: "placement-lease:#{row.remote_id}",
      requirements: requirements,
      requirements_fingerprint: CanonicalJSON.digest(requirements),
      session_id: row.session.id,
      state: :retired,
      updated_at: now,
      worker_id: row.worker_id
    }
  end

  defp workspace_for(:dirty), do: workspace(%{"dirty" => true})
  defp workspace_for(:unmerged), do: workspace(%{"unmerged" => true})
  defp workspace_for(_kind), do: workspace(%{})

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

  defp publication_delayed!(api) do
    Enum.map(1..1, fn index ->
      %{episode: episode} = PublicationFixture.published!("simulation-#{index}")

      session =
        Repo.one!(
          from(session in Session,
            where: session.episode_id == ^episode.id,
            order_by: [desc: session.generation],
            limit: 1
          )
        )

      remote_id = "remote:worker-a:#{session.id}"

      session =
        session
        |> Ecto.Changeset.change(coop_session_id: remote_id)
        |> Repo.update!()

      # Structural fixture: the publication has not landed yet, so this session
      # is pinned until its publication becomes durable.
      {_count, nil} =
        Repo.update_all(
          from(publication in Publication, where: publication.session_id == ^session.id),
          set: [
            published_delivery_receipt: nil,
            published_delivery_receipt_fingerprint: nil,
            status: :published_ready
          ]
        )

      FakeAPI.add_session(
        api,
        %{
          "external_ref" => session.external_ref,
          "id" => remote_id,
          "policy" => session.policy,
          "policy_digest" => session.policy_digest,
          "revision" => 7,
          "state" => "open"
        },
        workspace(%{})
      )

      session
    end)
  end

  defp create_worker!(worker_id) do
    Repo.insert!(%Worker{
      capabilities: [],
      capacity: %{},
      certificate_sha256: :crypto.hash(:sha256, worker_id) |> Base.encode16(case: :lower),
      id: worker_id,
      last_seen_at: DateTime.utc_now(),
      policy_digests: %{},
      repositories: [],
      state: :eligible,
      workspace_ref: "workspace-simulation"
    })
  end

  defp stale_worker!(worker_id) do
    {1, nil} =
      Repo.update_all(from(worker in Worker, where: worker.id == ^worker_id),
        set: [last_seen_at: DateTime.add(database_now!(), -86_400, :second)]
      )
  end

  defp heartbeat_worker!(worker_id) do
    {1, nil} =
      Repo.update_all(from(worker in Worker, where: worker.id == ^worker_id),
        set: [last_seen_at: database_now!()]
      )
  end

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end
end
