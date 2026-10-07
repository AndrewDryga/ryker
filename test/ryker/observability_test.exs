defmodule Ryker.ObservabilityTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  import Plug.Test
  alias Ryker.Admission
  alias Ryker.Admission.Decision
  alias Ryker.Config
  alias Ryker.ControlPlane.Router
  alias Ryker.CoopFleet.{Client, ControlPlane, Worker}
  alias Ryker.Delivery.RoutingResponseCustody
  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.ControlPlaneOptions
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning
  alias Ryker.Learning.FleetSession
  alias Ryker.Learning.LearningRun
  alias Ryker.Observability
  alias Ryker.Observability.Progress
  alias Ryker.Operator.Retention, as: RetentionOperator
  alias Ryker.Repo
  alias Ryker.Runtime.{Child, Owner}
  alias Ryker.Settings
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.Custody
  alias Ryker.Work.Session

  @now ~U[2026-08-29 12:00:00.000000Z]

  # scripts/watchdog.sh reads the reasons /readyz prints and sums the blocked
  # totals /metrics exports, deploy.sh waits on both, and Prometheus scrapes
  # every series. Splitting the 1,080-line observability module on 2026-09-26
  # must not move one byte they read, so this pins all three answers for one
  # fixed installation: every family, label, value and line in order. Ages move
  # with the clock, so each must fall between the database clock readings taken
  # around the scrape. Series built from maps come out in the VM's map order
  # (atom keys iterate by atom index, not by name), so the expectation iterates
  # maps with the same keys instead of assuming an alphabetical order.
  test "the probes answer the same bytes for the same installation" do
    assert {:ok, client} =
             Client.new(capability_names: ["controller-tools"], workspace_ref: "workspace-probes")

    Config.put_override(:work, %{api: Client, client: client})
    Config.put_override(:slack, nil)

    now = Repo.now!()
    ingress_at = DateTime.add(now, -7_200, :second)
    lease_at = DateTime.add(now, -1_800, :second)
    progress_at = DateTime.add(now, -3_600, :second)
    measured_at = DateTime.add(now, -600, :second)

    # Structural fixture: an input that has waited two hours for admission.
    assert {:ok, input} = slack_input("probe input")
    assert {:ok, %{entry: entry}} = Inbox.record(input)

    Repo.update_all(from(row in Entry, where: row.id == ^entry.id),
      set: [inserted_at: ingress_at, updated_at: ingress_at]
    )

    # Structural fixture: Work whose lease has been held for thirty minutes.
    episode_id = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "observability-probes:#{episode_id}",
                 native_input_id: "source:observability-probes:#{episode_id}",
                 occurred_at: @now,
                 turn_ref: "turn:observability-probes:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(transition.episode.id, "read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("observability-probes-worker", 3_600, :work)

    Repo.update_all(from(turn in Ryker.Work.Turn, where: turn.id == ^claim.turn.id),
      set: [updated_at: lease_at]
    )

    # Structural fixture: the Work lane last cycled an hour ago.
    assert :ok = Progress.record(:work, :cycle)

    Repo.query!("UPDATE ryker_runtime_progress SET observed_at = $1 WHERE lane = 'work'", [
      progress_at
    ])

    # One worker whose volume refuses workspaces, measured ten minutes ago.
    assert {:ok, _worker} =
             ControlPlane.authorize_worker(
               "worker-probes",
               "workspace-probes",
               String.duplicate("e", 64)
             )

    assert {:ok, _poll} =
             ControlPlane.handle_poll(
               "worker-probes",
               "worker-probes"
               |> storage_poll("workspace-probes", 9_663_676_416, "refused")
               |> put_in(["worker", "storage", "measured_at"], DateTime.to_iso8601(measured_at))
             )

    # Structural fixture: one workspace kept because it is dirty.
    retained = terminal_work_session!("probes")

    Repo.update_all(from(row in Session, where: row.id == ^retained.id),
      set: [cleanup_status: :retained, retained_reason: "dirty"]
    )

    # Slack turned on in settings but never started.
    {:ok, saved} = Settings.initialize("control-plane:local")

    {:ok, _saved} =
      Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: "T0123456789",
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789"
        },
        saved.installation.revision,
        "control-plane:local"
      )

    before = Repo.now!()
    health = probe("/healthz")
    ready = probe("/readyz")
    metrics = probe("/metrics")
    later = Repo.now!()

    assert {health.status, health.resp_body} == {200, "ok\n"}

    assert {ready.status, ready.resp_body} ==
             {503,
              "not ready: runtime not running: work; no_workspace_storage; " <>
                "lane not cycling: work; lease held too long: work; " <>
                "queue not draining: ingress; not configured: slack\n"}

    assert metrics.status == 200
    assert Plug.Conn.get_resp_header(metrics, "content-type") == ["text/plain; charset=utf-8"]

    # The inbox entry, the Work turn and the progress heartbeat are stored
    # without a zone, read back naive and aged by whole-second boundaries
    # (`Reads.age_seconds/2`), so they are bracketed by the same rule. Bracketed
    # as zoned times, a scrape that crossed a second boundary after the fixture
    # read one second older than the bracket allowed (gate, 2026-10-05). The
    # lower bound gives a second back: the database's clock runs in the Docker
    # VM, which steps it back when it resyncs, and twice a scrape after `before`
    # read the lease a second younger than `before` did (2026-10-06).
    timed = %{
      ~s(ryker_queue_oldest_age_seconds{queue="ingress"}) => DateTime.to_naive(ingress_at),
      ~s(ryker_queue_oldest_active_age_seconds{queue="work"}) => DateTime.to_naive(lease_at),
      ~s(ryker_runtime_progress_age_seconds{lane="work"}) => DateTime.to_naive(progress_at),
      "ryker_coop_fleet_storage_oldest_measurement_age_seconds" => measured_at
    }

    scraped =
      metrics.resp_body
      |> String.split("\n")
      |> Enum.map_join("\n", fn line ->
        with [series, value] <- String.split(line, " "),
             %{} = at <- Map.get(timed, series),
             true <- String.to_integer(value) in (age(before, at) - 1)..age(later, at) do
          series <> " <age>"
        else
          _exact -> line
        end
      end)

    assert scraped == Enum.join(expected_probe_metrics(), "\n") <> "\n"
  end

  # Every queue in the order readiness reads them; only these two have rows.
  defp expected_probe_metrics do
    queues =
      Enum.flat_map(
        ~w(ingress work cancellation delivery routing_delivery publication emisar_approval
           publication_followup publication_lifecycle retention schedule),
        fn queue ->
          label = ~s({queue="#{queue}"})

          {active, claimable, oldest_active, oldest} =
            case queue do
              "ingress" -> {0, 1, 0, "<age>"}
              "work" -> {1, 0, "<age>", 0}
              _empty -> {0, 0, 0, 0}
            end

          [
            "ryker_queue_active_leases#{label} #{active}",
            "ryker_queue_claimable#{label} #{claimable}",
            "ryker_queue_oldest_active_age_seconds#{label} #{oldest_active}",
            "ryker_queue_oldest_age_seconds#{label} #{oldest}"
          ]
        end
      )

    [
      "# Ryker aggregate lifecycle metrics. No message or prompt labels are exported.",
      "# An absent storage series is an unmeasured value, never a measured zero.",
      "ryker_observability_snapshot 1"
    ] ++
      in_map_order(%{
        incidents: [],
        ingress: [~s(ryker_ingress_total{status="pending"} 1)],
        publications: [],
        routing_responses: [],
        schedules: [],
        task_cards: ["ryker_task_cards_total 0"],
        work: [~s(ryker_work_total{status="pending"} 1)]
      }) ++
      queues ++
      [
        ~s(ryker_runtime_progress_age_seconds{lane="work"} <age>),
        ~s(ryker_runtime_progress_cycles{lane="work"} 1),
        "ryker_coop_fleet_required 1",
        "ryker_coop_fleet_fresh_workers 1",
        "ryker_coop_fleet_stale_workers 0",
        "ryker_coop_fleet_eligible_workers 1",
        "ryker_coop_fleet_current_placements 0",
        "ryker_coop_fleet_expired_current_placements 0",
        "ryker_coop_fleet_event_cursor_lag 0",
        "ryker_coop_fleet_oldest_queued_command_age_seconds 0",
        "ryker_coop_fleet_checkpoints 0",
        "ryker_coop_fleet_latest_checkpoint_age_seconds 0",
        ~s(ryker_coop_fleet_workers{state="eligible"} 1),
        ~s(ryker_coop_fleet_provider_workers{state="eligible"} 1)
      ] ++
      in_map_order(%{
        session: [
          ~s(ryker_coop_fleet_slots_free{kind="session"} 2),
          ~s(ryker_coop_fleet_slots_total{kind="session"} 4)
        ],
        turn: [
          ~s(ryker_coop_fleet_slots_free{kind="turn"} 2),
          ~s(ryker_coop_fleet_slots_total{kind="turn"} 4)
        ],
        workspace: [
          ~s(ryker_coop_fleet_slots_free{kind="workspace"} 2),
          ~s(ryker_coop_fleet_slots_total{kind="workspace"} 4)
        ]
      }) ++
      [
        "ryker_coop_fleet_storage_reporting_workers 1",
        "ryker_coop_fleet_storage_stale_workers 0",
        "ryker_coop_fleet_storage_unknown_workers 0",
        "ryker_coop_fleet_storage_refused_workers 1",
        "ryker_coop_fleet_storage_reclaimed_bytes 0",
        "ryker_coop_fleet_storage_oldest_measurement_age_seconds <age>",
        ~s(ryker_coop_fleet_storage_bytes{kind="capacity"} 536870912000),
        ~s(ryker_coop_fleet_storage_bytes{kind="disposable"} 9663676416),
        ~s(ryker_coop_fleet_storage_bytes{kind="free"} 107374182400),
        ~s(ryker_coop_fleet_storage_bytes{kind="protected"} 21474836480),
        ~s(ryker_coop_fleet_storage_bytes{kind="reserve"} 5368709120),
        ~s(ryker_coop_fleet_storage_bytes{kind="unattributed"} 1073741824),
        "ryker_retention_blocked 0",
        "ryker_retention_eligible 0",
        "ryker_retention_retrying 0",
        "ryker_retention_oldest_eligible_age_seconds 0",
        "ryker_retention_last_reclaimed_age_seconds 0"
      ] ++
      in_map_order(%{
        active: [~s(ryker_retention_sessions{status="active"} 1)],
        retained: [~s(ryker_retention_sessions{status="retained"} 1)]
      }) ++
      [~s(ryker_retention_retained{reason="dirty"} 1)]
  end

  defp assert_probes_unavailable do
    assert {probe("/healthz").status, probe("/healthz").resp_body} == {200, "ok\n"}

    assert {probe("/readyz").status, probe("/readyz").resp_body} ==
             {503, "not ready: readiness check failed\n"}

    assert {probe("/metrics").status, probe("/metrics").resp_body} ==
             {503, "metrics unavailable\n"}
  end

  defp in_map_order(lines_by_key), do: Enum.flat_map(lines_by_key, &elem(&1, 1))

  # Aged exactly as the scrape ages them: a naive timestamp by the whole
  # seconds NaiveDateTime.diff counts, a zoned one by elapsed time.
  defp age(now, %NaiveDateTime{} = at),
    do: max(NaiveDateTime.diff(DateTime.to_naive(now), at, :second), 0)

  defp age(now, at), do: max(DateTime.diff(now, at, :second), 0)

  # The split replaced one rescue around the whole snapshot with an answer from
  # each read. A read the database refuses after the clock was read must leave
  # the probes saying so: a crashed request answers a bare 500 that tells the
  # watchdog nothing.
  test "a read refused mid-snapshot leaves the probes answering unavailable" do
    for table <- ~w(ryker_runtime_progress coop_workers episode_work_sessions) do
      # Only this table is broken; the sandbox rollback restores it either way.
      Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_broken")

      assert {:error, {:observability_query_failed, detail}} = Observability.snapshot(900)
      assert detail =~ table
      assert_probes_unavailable()

      Repo.query!("ALTER TABLE #{table}_broken RENAME TO #{table}")
    end

    Repo.query!("ALTER TABLE coop_workers RENAME TO coop_workers_broken")
    assert {:error, {:observability_query_failed, _detail}} = Observability.fleet()
    Repo.query!("ALTER TABLE coop_workers_broken RENAME TO coop_workers")
  end

  # The heartbeat a release's lane left behind stays when a later release
  # retires or renames the lane. Every snapshot then failed: /readyz and
  # /metrics answered unavailable for good, and a deploy waiting on /readyz
  # rolled back a healthy release (2026-10-04 review).
  test "a heartbeat from a lane this release does not have is not read" do
    Repo.query!("""
    INSERT INTO ryker_runtime_progress
      (lane, outcome, cycle_count, observed_at, inserted_at, updated_at)
    VALUES ('retired_lane', 'cycle', 1, clock_timestamp(), clock_timestamp(), clock_timestamp())
    """)

    assert {:ok, snapshot} = Observability.snapshot(900)
    refute Enum.any?(snapshot.progress, &(to_string(&1.lane) == "retired_lane"))
  end

  test "health readiness and metrics expose queue facts without payloads or destinations" do
    secret = "private-payload-never-a-metric"
    assert {:ok, input} = slack_input(secret)
    assert {:ok, %{entry: entry}} = Inbox.record(input)

    episode_id = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:T-private:C-private",
                   thread_ref: "thread-private",
                   transport: "slack"
                 },
                 episode_id: episode_id,
                 episode_key: "observability:#{episode_id}",
                 native_input_id: "source:observability:#{episode_id}",
                 occurred_at: @now,
                 payload: %{"secret" => secret},
                 turn_ref: "turn:observability:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(transition.episode.id, "read-only", String.duplicate("a", 64))

    assert {:ok, _claim} = Custody.claim_next("observability-worker", 60, :work)

    assert {:ok, %{database: :ok}} = Observability.health()
    assert {:ok, _default_readiness} = Observability.ready()
    assert {:ok, _default_snapshot} = Observability.snapshot()
    assert {:ok, snapshot} = Observability.snapshot(86_400)
    assert snapshot.counts.ingress.pending == 1
    assert snapshot.counts.work.pending == 1
    assert Enum.find(snapshot.queues, &(&1.name == :ingress)).claimable == 1
    assert Enum.find(snapshot.queues, &(&1.name == :work)).claimable == 0
    assert Enum.find(snapshot.queues, &(&1.name == :work)).active_leases == 1
    assert Enum.find(snapshot.queues, &(&1.name == :emisar_approval)).claimable == 0
    assert Enum.find(snapshot.queues, &(&1.name == :publication_followup)).claimable == 0
    assert Enum.find(snapshot.queues, &(&1.name == :publication_lifecycle)).claimable == 0
    assert Enum.find(snapshot.queues, &(&1.name == :retention)).claimable == 0
    assert snapshot.stalled_queues == []

    assert {:ok, metrics} = Observability.metrics()
    assert metrics =~ ~s(ryker_ingress_total{status="pending"} 1)
    assert metrics =~ ~s(ryker_queue_claimable{queue="work"} 0)
    assert metrics =~ ~s(ryker_queue_active_leases{queue="work"} 1)
    assert metrics =~ ~s(ryker_queue_claimable{queue="retention"} 0)
    refute metrics =~ secret
    refute metrics =~ entry.id
    refute metrics =~ transition.episode.destination_conversation_ref
  end

  # Routing may send a few messages for one person's message, each after the
  # one before it is delivered (2026-09-27). The second waiting its turn is
  # not work a worker could take: counted as claimable it would age into a
  # stalled queue and fail readiness, paging someone about a thread where
  # nothing is wrong.
  @tag isolation: "REPEATABLE READ"
  test "a routing message waiting for the one before it is not claimable work" do
    assert {:ok, input} = slack_input("hi")
    assert {:ok, %{entry: entry}} = Inbox.record(input)

    assert {:ok, context} =
             Admission.context(Inbox.ref(entry),
               now: @now,
               continuation_window: 1_800,
               history_window: 2_592_000,
               candidate_limit: 8,
               lease_ref: nil
             )

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "quick_reply",
               "episode_ref" => nil,
               "messages" => ["Hi!", "What can I help with?"],
               "reactions" => nil,
               "relation" => "unrelated",
               "repository" => nil,
               "repository_source" => nil,
               "reason" => "A greeting needs a greeting back.",
               "work_class" => nil
             })

    assert {:ok, _result} = Admission.commit(context, decision, "decision:observability")

    routing = fn ->
      assert {:ok, snapshot} = Observability.snapshot(86_400)
      Enum.find(snapshot.queues, &(&1.name == :routing_delivery))
    end

    assert %{claimable: 1, active_leases: 0} = routing.()

    assert {:ok, %{response: %{position: 1}}} =
             RoutingResponseCustody.claim_next("observability-routing", 60)

    assert %{claimable: 0, active_leases: 1} = routing.()
  end

  test "readiness fails for custody whose active lease has outlived the stall bound" do
    episode_id = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:T-observability:C-active",
                   thread_ref: "thread-active",
                   transport: "slack"
                 },
                 episode_id: episode_id,
                 episode_key: "observability-active:#{episode_id}",
                 native_input_id: "source:observability-active:#{episode_id}",
                 occurred_at: @now,
                 payload: %{"text" => "bounded"},
                 turn_ref: "turn:observability-active:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(transition.episode.id, "read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("observability-active-worker", 3_600, :work)
    old = DateTime.add(DateTime.utc_now(), -3_600, :second)

    Repo.update_all(
      from(turn in Ryker.Work.Turn, where: turn.id == ^claim.turn.id),
      set: [inserted_at: old]
    )

    assert {:ok, healthy_old_work} =
             Observability.ready(
               check_progress: false,
               check_runtimes: false,
               stall_after_seconds: 30
             )

    refute :work in healthy_old_work.stalled_active_leases

    Repo.update_all(
      from(turn in Ryker.Work.Turn, where: turn.id == ^claim.turn.id),
      set: [updated_at: old]
    )

    assert {:error, readiness} =
             Observability.ready(
               check_progress: false,
               check_runtimes: false,
               stall_after_seconds: 30
             )

    assert :work in readiness.stalled_active_leases
    work = Enum.find(readiness.queues, &(&1.name == :work))
    assert work.active_leases == 1
    assert work.oldest_active_age_seconds >= 3_500
  end

  test "configured scheduler progress is durable and stale heartbeats fail readiness" do
    assert Progress.record(:unknown_lane, :cycle) ==
             {:error, {:invalid_runtime_progress, :fields}}

    Config.put_override(:work, %{enabled: true})

    assert :ok = Progress.record(:work, :cycle)
    old = DateTime.add(DateTime.utc_now(), -3_600, :second)

    assert {:ok, _result} =
             Repo.query(
               "UPDATE ryker_runtime_progress SET observed_at = $1 WHERE lane = 'work'",
               [old]
             )

    assert {:error, stale} =
             Observability.ready(
               check_progress: true,
               check_runtimes: false,
               stall_after_seconds: 30
             )

    assert stale.stale_progress_lanes == [:work]

    assert :ok = Progress.record(:work, :cycle)

    assert {:ok, fresh} =
             Observability.ready(
               check_progress: true,
               check_runtimes: false,
               stall_after_seconds: 30
             )

    assert fresh.stale_progress_lanes == []

    assert {:ok, metrics} = Observability.metrics()
    assert metrics =~ ~s(ryker_runtime_progress_age_seconds{lane="work"})
    assert metrics =~ ~s(ryker_runtime_progress_cycles{lane="work"} 2)
  end

  # An idle worker polls about every ten seconds. A heartbeat on each of
  # those polls was a quarter of everything an idle install still committed
  # on 2026-09-27, where readiness needs one in fifteen minutes.
  test "a lane polled every ten seconds writes its heartbeat once a minute" do
    assert :ok = Progress.beat(:learning)
    # The next idle poll, ten seconds on.
    Process.put({Progress, :learning}, System.monotonic_time(:millisecond) - 10_000)
    assert :ok = Progress.beat(:learning)

    assert Repo.query!("SELECT cycle_count FROM ryker_runtime_progress WHERE lane = 'learning'").rows ==
             [[1]]

    # A minute on, it beats again.
    Process.put({Progress, :learning}, System.monotonic_time(:millisecond) - 60_000)
    assert :ok = Progress.beat(:learning)

    assert Repo.query!("SELECT cycle_count FROM ryker_runtime_progress WHERE lane = 'learning'").rows ==
             [[2]]
  end

  test "fleet execution requires fresh compatible worker capacity" do
    workspace_ref = "workspace-observability"

    assert {:ok, client} =
             Client.new(
               capability_names: ["controller-tools"],
               workspace_ref: workspace_ref
             )

    Config.put_override(:work, %{api: Client, client: client})

    assert {:error, unavailable} =
             Observability.ready(
               check_progress: false,
               check_runtimes: false,
               stall_after_seconds: 86_400
             )

    assert unavailable.fleet_issues ==
             [
               :no_eligible_workers,
               :no_session_capacity,
               :no_turn_capacity,
               :no_workspace_capacity
             ]

    assert {:ok, _worker} =
             ControlPlane.authorize_worker(
               "worker-observability",
               workspace_ref,
               String.duplicate("c", 64)
             )

    assert {:ok, _poll} =
             ControlPlane.handle_poll(
               "worker-observability",
               fleet_poll("worker-observability", workspace_ref)
             )

    assert {:ok, readiness} =
             Observability.ready(
               check_progress: false,
               check_runtimes: false,
               stall_after_seconds: 86_400
             )

    assert readiness.fleet_issues == []
    assert readiness.fleet.required
    assert readiness.fleet.eligible_workers == 1
    assert readiness.fleet.capacity.turn.free == 2
    assert readiness.fleet.capacity.turn.total == 4

    assert {:ok, metrics} = Observability.metrics()
    assert metrics =~ ~s(ryker_coop_fleet_eligible_workers 1)
    assert metrics =~ ~s(ryker_coop_fleet_slots_free{kind="turn"} 2)
    assert metrics =~ ~s(ryker_coop_fleet_workers{state="eligible"} 1)
    refute metrics =~ "worker-observability"
    refute metrics =~ workspace_ref

    old = DateTime.add(DateTime.utc_now(), -120, :second)

    Repo.update_all(from(worker in Worker, where: worker.id == "worker-observability"),
      set: [last_seen_at: old]
    )

    assert {:error, stale} =
             Observability.ready(
               check_progress: false,
               check_runtimes: false,
               stall_after_seconds: 86_400
             )

    assert :no_eligible_workers in stale.fleet_issues
    assert stale.fleet.stale_workers == 1
  end

  test "readiness uses database time and identifies a due queue that has stopped moving" do
    assert {:ok, input} = slack_input("stalled input")
    assert {:ok, %{entry: entry}} = Inbox.record(input)

    old = DateTime.add(DateTime.utc_now(), -3_600, :second)

    Repo.update_all(
      from(candidate in Entry, where: candidate.id == ^entry.id),
      set: [inserted_at: old, updated_at: old]
    )

    assert {:error, readiness} =
             Observability.ready(check_runtimes: false, stall_after_seconds: 30)

    assert :ingress in readiness.stalled_queues
    ingress = Enum.find(readiness.queues, &(&1.name == :ingress))
    assert ingress.oldest_age_seconds >= 3_500

    assert {:ok, readiness} =
             Observability.ready(check_runtimes: false, stall_after_seconds: 7_200)

    assert readiness.stalled_queues == []
  end

  test "a failed readiness names fixed reasons and nothing it read" do
    # /readyz printed "not ready" alone for four and a half days of a missing
    # worker; an operator (and the watchdog) could not tell a stopped fleet
    # from an unapplied setting without attaching to the node.
    readiness = %{
      fleet_issues: [:no_eligible_workers],
      missing_runtimes: [:github],
      settings: %{failure: "settings_apply_failed", unconfigured: [:slack]},
      stale_progress_lanes: [:learning],
      stalled_active_leases: [:delivery],
      stalled_queues: [:ingress]
    }

    assert Observability.problems(readiness) == [
             "runtime not running: github",
             "no_eligible_workers",
             "lane not cycling: learning",
             "lease held too long: delivery",
             "queue not draining: ingress",
             "settings not applied: settings_apply_failed",
             "not configured: slack"
           ]

    assert Observability.problems({:database_unavailable, :error, "secret connection detail"}) ==
             ["database unavailable"]

    assert Observability.problems({:observability_query_failed, "row 42 said something"}) ==
             ["readiness check failed"]
  end

  test "a saved revision that could not be applied is not a ready service" do
    # Readiness that only looks at what assembled would call a failed apply
    # healthy, which is exactly how an operator ends up debugging the wrong
    # code: the settings say one thing and the process is running another.
    Config.put_override(:learning, %{configured: true})

    {:ok, saved} = Settings.initialize("control-plane:local")
    assert {:ok, _ready} = Observability.ready(check_progress: false, check_runtimes: false)

    :ok = Settings.record_application(saved.installation.revision, {:error, :assembly_failed})

    assert {:error, readiness} =
             Observability.ready(check_progress: false, check_runtimes: false)

    assert readiness.settings.failure == "assembly_failed"
    assert readiness.settings.revision == saved.installation.revision
    assert readiness.settings.applied_revision == 0

    :ok = Settings.record_application(saved.installation.revision, :ok)

    assert {:ok, applied} =
             Observability.ready(check_progress: false, check_runtimes: false)

    assert applied.settings.applied_revision == saved.installation.revision
  end

  test "an integration this installation turned on but never started is named" do
    Config.put_override(:slack, nil)

    {:ok, saved} = Settings.initialize("control-plane:local")

    {:ok, _saved} =
      Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: "T0123456789",
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789"
        },
        saved.installation.revision,
        "control-plane:local"
      )

    assert {:error, readiness} = Observability.ready(check_progress: false)
    assert readiness.settings.unconfigured == [:slack]
    refute readiness.settings.failure
  end

  test "invalid observability thresholds and readiness options fail closed" do
    assert Observability.snapshot(0) ==
             {:error, {:invalid_observability, :stall_after_seconds}}

    assert Observability.ready(unknown: true) ==
             {:error, {:invalid_observability, :readiness_options}}

    assert Observability.ready(check_runtimes: :sometimes) ==
             {:error, {:invalid_observability, :readiness_options}}

    assert Observability.ready(check_progress: :sometimes) ==
             {:error, {:invalid_observability, :readiness_options}}

    assert Observability.ready(:invalid) ==
             {:error, {:invalid_observability, :readiness_options}}

    assert Map.keys(Observability.callbacks()) |> Enum.sort() == [:health, :metrics, :ready]
  end

  test "configured runtimes must be alive while disabled runtimes are omitted" do
    keys = [
      :admission,
      :coop_worker_gateway,
      :control_plane,
      :delivery,
      :emisar,
      :event_waits,
      :github,
      :publication,
      :retention,
      :schedules,
      :slack,
      :webhooks,
      :work
    ]

    Enum.each(keys, &Config.put_override(&1, %{enabled: true}))
    Config.put_override(:schedules, false)

    assert {:error, readiness} =
             Observability.ready(check_runtimes: true, stall_after_seconds: 86_400)

    assert readiness.missing_runtimes ==
             [
               :admission,
               :control_plane,
               :coop_worker_gateway,
               :delivery,
               :emisar,
               :event_waits,
               :github,
               :publication,
               :retention,
               :slack,
               :webhooks,
               :work
             ]
  end

  test "a configured live runtime satisfies readiness without exporting process identity" do
    keys = [
      :admission,
      :coop_worker_gateway,
      :control_plane,
      :delivery,
      :emisar,
      :event_waits,
      :github,
      :publication,
      :retention,
      :schedules,
      :slack,
      :webhooks,
      :work
    ]

    Enum.each(keys, &Config.put_override(&1, false))
    Config.put_override(:admission, %{enabled: true})

    assert {:ok, _runtime} =
             Agent.start_link(fn -> :healthy end, name: Ryker.Admission.Runtime)

    assert :ok = Progress.record(:admission, :cycle)

    assert {:ok, readiness} =
             Observability.ready(check_runtimes: true, stall_after_seconds: 86_400)

    assert readiness.missing_runtimes == []
  end

  test "a listener the owner started counts as its setting's runtime" do
    # Durable settings start the control plane, worker gateway, state tools and
    # webhook listeners as plain web-server children, so their supervisor entry
    # names the web server and not the setting. Readiness matched on the module
    # and reported all four missing on a healthy installation, holding /readyz
    # at 503 while every lane cycled and every setting was applied.
    keys = ~w(admission coop_worker_gateway control_plane delivery emisar event_waits github
              learning publication retention schedules slack webhooks work)a

    Enum.each(keys, &Config.put_override(&1, false))
    Config.put_override(:control_plane, %{enabled: true})

    # The owner starts its children in the shared dynamic supervisor, so this
    # test cleans up both: a console left listening collides with every other
    # suite that starts the endpoint.
    before = DynamicSupervisor.which_children(Ryker.Runtime.Supervisor)

    {:ok, owner} =
      Owner.start_link(
        name: Owner,
        bootstrap: owner_bootstrap(),
        supervisor: Ryker.Runtime.Supervisor
      )

    on_exit(fn ->
      if Process.alive?(owner), do: GenServer.stop(owner)

      started =
        DynamicSupervisor.which_children(Ryker.Runtime.Supervisor) -- before

      Enum.each(started, fn {_id, pid, _type, _modules} ->
        if is_pid(pid), do: DynamicSupervisor.terminate_child(Ryker.Runtime.Supervisor, pid)
      end)
    end)

    assert Owner.running_keys() == [:control_plane]

    assert {_result, readiness} =
             Observability.ready(check_runtimes: true, stall_after_seconds: 86_400)

    assert readiness.missing_runtimes == []
  end

  # Since 2026-10-04 each runtime key runs under a supervisor of its own inside the dynamic one,
  # so a listener is one level down. Looking only at the dynamic supervisor's own children would
  # report every listener missing and hold /readyz at 503 on a healthy installation.
  test "a product child under its runtime key's supervisor is alive, not missing" do
    keys = ~w(admission coop_worker_gateway control_plane delivery emisar event_waits github
              learning publication retention schedules slack webhooks work)a

    Enum.each(keys, &Config.put_override(&1, false))
    Config.put_override(:webhooks, %{enabled: true})

    supervisor = Process.whereis(Ryker.Runtime.Supervisor)

    listener = %{
      id: Ryker.Webhooks.Server,
      start: {Agent, :start_link, [fn -> :serving end]}
    }

    {:ok, key_supervisor} =
      DynamicSupervisor.start_child(
        supervisor,
        Child.child_spec({:webhooks, [listener]})
      )

    on_exit(fn ->
      if Process.alive?(key_supervisor),
        do: DynamicSupervisor.terminate_child(supervisor, key_supervisor)
    end)

    assert {_result, readiness} =
             Observability.ready(check_runtimes: true, stall_after_seconds: 86_400)

    assert readiness.missing_runtimes == []
  end

  test "a product child under the runtime owner's supervisor is alive, not missing" do
    # Durable settings moved every product child under the runtime owner's
    # dynamic supervisor. Readiness still looked only under the application
    # supervisor, so a healthy installation reported its listeners missing and
    # /readyz stayed 503 with nothing wrong — seen on the first cutover boot.
    keys = ~w(admission coop_worker_gateway control_plane delivery emisar event_waits github
              learning publication retention schedules slack webhooks work)a

    Enum.each(keys, &Config.put_override(&1, false))
    Config.put_override(:webhooks, %{enabled: true})

    supervisor = Process.whereis(Ryker.Runtime.Supervisor)

    {:ok, child} =
      DynamicSupervisor.start_child(supervisor, %{
        id: Ryker.Webhooks.Server,
        modules: [Ryker.Webhooks.Server],
        start: {Agent, :start_link, [fn -> :serving end]}
      })

    on_exit(fn ->
      if Process.alive?(child), do: DynamicSupervisor.terminate_child(supervisor, child)
    end)

    assert {_result, readiness} =
             Observability.ready(check_runtimes: true, stall_after_seconds: 86_400)

    assert readiness.missing_runtimes == []
  end

  test "retention readiness ages cleanup from eligibility and sees every custody owner" do
    # Production /readyz returned 503 while cleanup was healthy: the queue aged
    # from session insertion, so four minutes of conversation plus the intentional
    # fifteen-minute grace read as a stall the moment the session became eligible.
    # Learning sessions were invisible to the same queue, so their backlog could
    # never be seen at all.
    session = terminal_work_session!("eligible-age")
    now = Repo.now!()

    # Structural fixture: freeze the exact durable cleanup timestamps the defect
    # confuses. The session was created two hours ago, closed sixteen minutes ago
    # and became eligible sixty seconds ago when its grace expired.
    Repo.update_all(
      from(row in Session, where: row.id == ^session.id),
      set: [
        cleanup_status: :grace,
        closed_at: DateTime.add(now, -16 * 60, :second),
        discard_after: DateTime.add(now, -60, :second),
        inserted_at: DateTime.add(now, -7_200, :second),
        updated_at: DateTime.add(now, -16 * 60, :second)
      ]
    )

    learning = stopped_learning_session!()

    assert {:ok, snapshot} = Observability.snapshot(86_400)
    retention = Enum.find(snapshot.queues, &(&1.name == :retention))

    assert retention.claimable == 2,
           "retention readiness must count both the work and learning sessions custody can claim"

    assert retention.oldest_age_seconds <= 120,
           "eligible age must be measured from grace expiry, not session creation"

    assert {:error, _readiness} =
             Observability.ready(
               check_progress: false,
               check_runtimes: false,
               stall_after_seconds: 30
             )

    # The same fixtures are exactly what retention custody claims next.
    assert {:ok, %{session: %{id: claimed}}} =
             Ryker.Retention.Custody.claim_next("observability-retention", 60)

    assert claimed in [session.id, learning.id]
  end

  test "a cleanup that just came due again is not a stalled queue" do
    # On 2026-09-18 an operator resumed three blocked learning cleanups whose
    # runs had stopped hours or days before. Readiness aged them from that
    # stop, so the resume itself read as a stall for three minutes and the
    # watchdog told the operator Ryker was not working. A retry that comes due
    # is the same: it becomes claimable when its backoff ends, not before.
    learning = stopped_learning_session!()
    now = Repo.now!()

    # Structural fixture: the run stopped two days ago and its cleanup blocked.
    Repo.update_all(
      from(run in LearningRun, where: run.id == ^learning.learning_run_id),
      set: [remote_stopped_at: DateTime.add(now, -2 * 86_400, :second)]
    )

    Repo.update_all(
      from(row in Session, where: row.id == ^learning.id),
      set: [cleanup_status: :blocked, cleanup_blocked_from: :close_pending]
    )

    assert {:ok, %{outcome: :rearmed}} =
             RetentionOperator.rearm(
               learning.external_ref,
               "slack:user:operator",
               "retention-action:#{Ecto.UUID.generate()}"
             )

    # A Work cleanup whose episode ended an hour ago, and whose failed close
    # comes due from its backoff thirty seconds ago.
    work = terminal_work_session!("retry-due")

    Repo.update_all(
      from(episode in Episode, where: episode.id == ^work.episode_id),
      set: [updated_at: DateTime.add(now, -3_600, :second)]
    )

    Repo.update_all(
      from(row in Session, where: row.id == ^work.id),
      set: [
        cleanup_status: :close_pending,
        cleanup_next_attempt_at: DateTime.add(now, -30, :second),
        updated_at: DateTime.add(now, -3_600, :second)
      ]
    )

    assert {:ok, snapshot} = Observability.snapshot(900)
    retention = Enum.find(snapshot.queues, &(&1.name == :retention))
    assert retention.claimable == 2

    assert retention.oldest_age_seconds <= 120,
           "a cleanup is due from its resume or its retry, not from when it first became eligible"

    refute :retention in snapshot.stalled_queues
  end

  # A turn, reply, approval check or schedule that waits out a backoff or a
  # poll interval falls due again when that wait ends. Readiness aged it from
  # when it was created, so an approval Ryker had checked every few seconds for
  # a quarter of an hour read as a stalled queue in the second between two
  # checks, and /readyz failed (2026-10-04 review).
  test "work whose retry just came due is not a stalled queue" do
    episode_id = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "observability-retry:#{episode_id}",
                 native_input_id: "source:observability-retry:#{episode_id}",
                 occurred_at: @now,
                 turn_ref: "turn:observability-retry:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(transition.episode.id, "read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("observability-retry-worker", 60, :work)
    now = Repo.now!()

    # Structural fixture: a turn created an hour ago whose attempt failed and
    # whose retry came due thirty seconds ago.
    Repo.update_all(from(turn in Ryker.Work.Turn, where: turn.id == ^claim.turn.id),
      set: [
        inserted_at: DateTime.add(now, -3_600, :second),
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: DateTime.add(now, -30, :second)
      ]
    )

    assert {:ok, snapshot} = Observability.snapshot(900)
    work = Enum.find(snapshot.queues, &(&1.name == :work))
    assert work.claimable == 1

    assert work.oldest_age_seconds <= 120,
           "a retry is due when its backoff ends, not when the turn was created"

    refute :work in snapshot.stalled_queues
  end

  # Production went silent for every Slack message on 2026-09-13: Coop refused
  # every workspace because the volume crossed its watermark, while the worker
  # still advertised free session slots — so readiness said "ready" and nothing
  # alerted. A fleet that cannot allocate a workspace cannot start any work.
  test "a fleet whose every worker refuses storage is not ready" do
    assert {:ok, client} =
             Client.new(
               capability_names: ["controller-tools"],
               workspace_ref: "workspace-refused"
             )

    Config.put_override(:work, %{api: Client, client: client})

    assert {:ok, _worker} =
             ControlPlane.authorize_worker(
               "worker-refused",
               "workspace-refused",
               String.duplicate("e", 64)
             )

    assert {:ok, _poll} =
             ControlPlane.handle_poll(
               "worker-refused",
               storage_poll("worker-refused", "workspace-refused", 0, "refused")
             )

    assert {:ok, snapshot} = Observability.snapshot(86_400)
    storage = snapshot.fleet.storage
    assert storage.reporting == 1
    assert storage.refused == 1

    assert {:error, readiness} =
             Observability.ready(
               check_progress: false,
               check_runtimes: false,
               stall_after_seconds: 86_400
             )

    assert :no_workspace_storage in readiness.fleet_issues
  end

  test "workspace storage is reported per measurement state and unknown is never zero" do
    # Reporting a missing measurement as zero would have said the fleet had no
    # disposable bytes at the exact moment nobody could see how many it had.
    assert {:ok, _worker} =
             ControlPlane.authorize_worker(
               "worker-storage",
               "workspace-storage",
               String.duplicate("e", 64)
             )

    assert {:ok, _unknown} =
             ControlPlane.authorize_worker(
               "worker-silent",
               "workspace-storage",
               String.duplicate("f", 64)
             )

    assert {:ok, _poll} =
             ControlPlane.handle_poll(
               "worker-storage",
               storage_poll("worker-storage", "workspace-storage", 9_663_676_416)
             )

    assert {:ok, _poll} =
             ControlPlane.handle_poll(
               "worker-silent",
               fleet_poll("worker-silent", "workspace-storage")
             )

    assert {:ok, snapshot} = Observability.snapshot(86_400)
    storage = snapshot.fleet.storage
    assert storage.reporting == 1
    assert storage.unknown == 1
    assert storage.stale == 0
    assert storage.refused == 0
    assert storage.bytes["disposable_bytes"] == 9_663_676_416
    assert storage.unattributed_bytes == 1_073_741_824
    assert storage.reclaimed_bytes == 0

    assert {:ok, metrics} = Observability.metrics()
    assert metrics =~ ~s(ryker_coop_fleet_storage_bytes{kind="disposable"} 9663676416)
    assert metrics =~ ~s(ryker_coop_fleet_storage_unknown_workers 1)
    assert metrics =~ ~s(ryker_coop_fleet_storage_reporting_workers 1)
    refute metrics =~ "worker-storage"

    assert {:ok, _poll} =
             ControlPlane.handle_poll(
               "worker-storage",
               "worker-storage"
               |> storage_poll("workspace-storage", 1_073_741_824)
               |> put_in(["worker", "storage", "unattributed_bytes"], nil)
             )

    assert {:ok, reclaimed} = Observability.snapshot(86_400)
    assert reclaimed.fleet.storage.reclaimed_bytes == 8_589_934_592
    assert reclaimed.fleet.storage.unattributed_bytes == nil

    assert {:ok, unknown_metrics} = Observability.metrics()
    refute unknown_metrics =~ ~s(ryker_coop_fleet_storage_bytes{kind="unattributed"})
    assert unknown_metrics =~ ~s(ryker_coop_fleet_storage_reclaimed_bytes 8589934592)

    Repo.update_all(from(worker in Worker, where: worker.id == "worker-storage"),
      set: [last_seen_at: DateTime.add(DateTime.utc_now(), -300, :second)]
    )

    assert {:ok, stale} = Observability.snapshot(86_400)
    assert stale.fleet.storage.stale == 1
    assert stale.fleet.storage.reporting == 0
    assert stale.fleet.storage.bytes["disposable_bytes"] == 0
  end

  test "retention reports remaining sessions by reason and the last measured reclamation" do
    session = terminal_work_session!("reasons")

    # Structural fixture: one workspace retained because it is dirty.
    Repo.update_all(
      from(row in Session, where: row.id == ^session.id),
      set: [cleanup_status: :retained, retained_reason: "dirty"]
    )

    assert {:ok, snapshot} = Observability.snapshot(86_400)
    assert snapshot.retention.retained == %{"dirty" => 1}
    assert snapshot.retention.sessions[:retained] == 1
    assert snapshot.retention.blocked == 0
    assert snapshot.retention.eligible == 0

    assert {:ok, metrics} = Observability.metrics()
    assert metrics =~ ~s(ryker_retention_retained{reason="dirty"} 1)
    assert metrics =~ ~s(ryker_retention_sessions{status="retained"} 1)
    assert metrics =~ "ryker_retention_oldest_eligible_age_seconds 0"
  end

  defp storage_poll(worker_id, workspace_ref, disposable_bytes, allocation \\ "open") do
    storage = %{
      "allocation" => allocation,
      "capacity_bytes" => 536_870_912_000,
      "disposable_bytes" => disposable_bytes,
      "free_bytes" => 107_374_182_400,
      "high_watermark_bytes" => 64_424_509_440,
      "low_watermark_bytes" => 48_318_382_080,
      "measured_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "protected_bytes" => 21_474_836_480,
      "refusal_reason" => if(allocation == "refused", do: "reserve_exhausted"),
      "reserve_bytes" => 5_368_709_120,
      "unattributed_bytes" => 1_073_741_824,
      "version" => 1
    }

    worker_id
    |> fleet_poll(workspace_ref)
    |> put_in(["worker", "storage"], storage)
    |> put_in(["poll_ref"], "poll:#{worker_id}:#{System.unique_integer([:positive])}")
  end

  defp terminal_work_session!(suffix) do
    id = Ecto.UUID.generate()
    key = "observability-retention:#{suffix}:#{id}"
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
             Custody.pin_episode(id, "work-read-only", String.duplicate("a", 64), "ryker")

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
    |> Ecto.Changeset.change(coop_session_id: "remote:#{suffix}:#{id}")
    |> Repo.update!()
  end

  defp stopped_learning_session! do
    entries = LearningFixtures.inputs!()

    assert {:ok, run} =
             Learning.prepare(Enum.map(entries, & &1.id), %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("a", 64)
             })

    assert {:ok, _session} = FleetSession.ensure(run)
    assert {:ok, session} = FleetSession.bind(run, "remote-learning:#{run.id}")

    # Structural fixture: the durable remote stop proof retention custody requires.
    run
    |> Ecto.Changeset.change(
      remote_stopped_at: Repo.now!(),
      stop_receipt: %{"kind" => "stopped", "session_id" => session.coop_session_id}
    )
    |> Repo.update!()

    session
  end

  defp slack_input(content) do
    SlackInput.new(%{
      actor: %{kind: :user, ref: "U-observability"},
      channel_ref: "C-observability",
      content: %{"text" => content},
      event_kind: :message,
      event_ref: "event:#{Ecto.UUID.generate()}",
      message_ref: "message:#{Ecto.UUID.generate()}",
      occurred_at: @now,
      revision: 1,
      thread_ref: nil,
      workspace_ref: "T-observability"
    })
  end

  defp fleet_poll(worker_id, workspace_ref) do
    %{
      "acknowledged_command_ids" => [],
      "command_results" => [],
      "event_batches" => [],
      "poll_ref" => "poll:#{worker_id}:observability",
      "version" => 2,
      "worker" => %{
        "build_version" => "coop-observability",
        "capabilities" => [%{"name" => "controller-tools", "version" => "1"}],
        "capacity" => %{
          "cooldown_until" => nil,
          "session_slots_free" => 2,
          "session_slots_total" => 4,
          "state" => "eligible",
          "turn_slots_free" => 2,
          "turn_slots_total" => 4,
          "workspace_slots_free" => 2,
          "workspace_slots_total" => 4
        },
        "clock_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "id" => worker_id,
        "protocol_version" => "2",
        "sandbox_digest" => String.duplicate("a", 64),
        "state" => "eligible",
        "workspace_ref" => workspace_ref
      }
    }
  end

  # The request exactly as a probe or scraper sends it, answered by the real
  # observability callbacks rather than the router fixture's doubles.
  defp probe(path) do
    options =
      self()
      |> ControlPlaneOptions.options()
      |> Map.put(:observability, Observability.callbacks())

    :get
    |> conn(path)
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Router.call(Router.init(options))
  end

  # A real listener needs a real port; the owner starts the console before any
  # settings exist, which is exactly the state this test drives.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp owner_bootstrap do
    %Ryker.Bootstrap{
      repo: [url: "ecto://ryker@localhost/ryker", pool_size: 2],
      control_plane: %{ip: {127, 0, 0, 1}, port: free_port()},
      worker_gateway: nil,
      github_listener: %{ip: {127, 0, 0, 1}, port: 0},
      github_public_url: "http://127.0.0.1:4319/v1/github",
      webhook_listener: %{ip: {127, 0, 0, 1}, port: 0},
      webhook_public_url: "http://127.0.0.1:4320",
      storage_root: System.tmp_dir!(),
      credential_key: :binary.copy(<<7>>, 32),
      log_level: :warning
    }
  end
end
