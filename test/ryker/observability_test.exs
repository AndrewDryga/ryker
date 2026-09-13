defmodule Ryker.ObservabilityTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Bootstrap
  alias Ryker.CoopFleet.{Client, ControlPlane, Worker}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.FleetSession
  alias Ryker.Observability
  alias Ryker.Observability.Progress
  alias Ryker.Repo
  alias Ryker.Runtime.Owner
  alias Ryker.Settings
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.State.Learning
  alias Ryker.Work.Custody
  alias Ryker.Work.Session

  @now ~U[2026-08-29 12:00:00.000000Z]

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

    previous = Application.get_env(:ryker, :work, :missing)
    Application.put_env(:ryker, :work, %{enabled: true})

    on_exit(fn ->
      if previous == :missing,
        do: Application.delete_env(:ryker, :work),
        else: Application.put_env(:ryker, :work, previous)
    end)

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

  test "fleet execution requires fresh compatible worker capacity" do
    authority_digest = String.duplicate("d", 64)
    policy_digest = String.duplicate("b", 64)
    workspace_ref = "workspace-observability"
    previous_work = Application.get_env(:ryker, :work, :missing)
    previous_profiles = Application.get_env(:ryker, :fleet_profiles, :missing)

    assert {:ok, client} =
             Client.new(
               capability_names: ["responder-state"],
               workspace_ref: workspace_ref
             )

    Application.put_env(:ryker, :work, %{api: Client, client: client})

    Application.put_env(:ryker, :fleet_profiles, %{
      {"read_only", nil} => %{
        authority_digest: authority_digest,
        policy: "work-read-only",
        policy_digest: policy_digest,
        repository_ref: nil
      }
    })

    on_exit(fn ->
      restore_env(:work, previous_work)
      restore_env(:fleet_profiles, previous_profiles)
    end)

    assert {:error, unavailable} =
             Observability.ready(
               check_progress: false,
               check_runtimes: false,
               stall_after_seconds: 86_400
             )

    assert unavailable.fleet_issues ==
             [
               :missing_policy_capacity,
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
               fleet_poll(
                 "worker-observability",
                 workspace_ref,
                 policy_digest,
                 authority_digest
               )
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
    assert readiness.fleet.available_policy_profiles == 1
    assert readiness.fleet.required_policy_profiles == 1
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

  test "a saved revision that could not be applied is not a ready service" do
    # Readiness that only looks at what assembled would call a failed apply
    # healthy, which is exactly how an operator ends up debugging the wrong
    # code: the settings say one thing and the process is running another.
    {:ok, saved} = Settings.initialize("control-plane:local")
    assert {:ok, _ready} = Observability.ready(check_progress: false)

    :ok = Settings.record_application(saved.installation.revision, {:error, :assembly_failed})

    assert {:error, readiness} = Observability.ready(check_progress: false)
    assert readiness.settings.failure == "assembly_failed"
    assert readiness.settings.revision == saved.installation.revision
    assert readiness.settings.applied_revision == 0

    :ok = Settings.record_application(saved.installation.revision, :ok)
    assert {:ok, applied} = Observability.ready(check_progress: false)
    assert applied.settings.applied_revision == saved.installation.revision
  end

  test "an integration this installation turned on but never started is named" do
    {:ok, saved} = Settings.initialize("control-plane:local")

    {:ok, _} =
      Settings.save_learning(%{enabled: true}, saved.installation.revision, "control-plane:local")

    assert {:error, readiness} = Observability.ready(check_progress: false)
    assert readiness.settings.unconfigured == [:learning]
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
      :state_tools,
      :webhooks,
      :work
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:ryker, &1, :missing)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :missing} -> Application.delete_env(:ryker, key)
        {key, value} -> Application.put_env(:ryker, key, value)
      end)
    end)

    Enum.each(keys, &Application.put_env(:ryker, &1, %{enabled: true}))
    Application.put_env(:ryker, :schedules, false)

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
               :state_tools,
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
      :state_tools,
      :webhooks,
      :work
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:ryker, &1, :missing)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :missing} -> Application.delete_env(:ryker, key)
        {key, value} -> Application.put_env(:ryker, key, value)
      end)
    end)

    Enum.each(keys, &Application.put_env(:ryker, &1, false))
    Application.put_env(:ryker, :admission, %{enabled: true})

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
              learning publication retention schedules slack state_tools webhooks work)a

    previous = Enum.map(keys, &{&1, Application.get_env(:ryker, &1, :missing)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :missing} -> Application.delete_env(:ryker, key)
        {key, value} -> Application.put_env(:ryker, key, value)
      end)
    end)

    Enum.each(keys, &Application.put_env(:ryker, &1, false))
    Application.put_env(:ryker, :control_plane, %{enabled: true})

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

  test "a product child under the runtime owner's supervisor is alive, not missing" do
    # Durable settings moved every product child under the runtime owner's
    # dynamic supervisor. Readiness still looked only under the application
    # supervisor, so a healthy installation reported its listeners missing and
    # /readyz stayed 503 with nothing wrong — seen on the first cutover boot.
    keys = ~w(admission coop_worker_gateway control_plane delivery emisar event_waits github
              learning publication retention schedules slack state_tools webhooks work)a

    previous = Enum.map(keys, &{&1, Application.get_env(:ryker, &1, :missing)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :missing} -> Application.delete_env(:ryker, key)
        {key, value} -> Application.put_env(:ryker, key, value)
      end)
    end)

    Enum.each(keys, &Application.put_env(:ryker, &1, false))
    Application.put_env(:ryker, :state_tools, %{enabled: true})

    supervisor = Process.whereis(Ryker.Runtime.Supervisor)

    {:ok, child} =
      DynamicSupervisor.start_child(supervisor, %{
        id: Ryker.StateTools.Server,
        modules: [Ryker.StateTools.Server],
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
    now = database_now!()

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
             Ryker.Retention.Custody.claim_next("observability-retention", 60, 900)

    assert claimed in [session.id, learning.id]
  end

  # Production went silent for every Slack message on 2026-09-13: Coop refused
  # every workspace because the volume crossed its watermark, while the worker
  # still advertised free session slots — so readiness said "ready" and nothing
  # alerted. A fleet that cannot allocate a workspace cannot start any work.
  test "a fleet whose every worker refuses storage is not ready" do
    previous_work = Application.get_env(:ryker, :work, :missing)
    previous_profiles = Application.get_env(:ryker, :fleet_profiles, :missing)

    assert {:ok, client} =
             Client.new(capability_names: ["responder-state"], workspace_ref: "workspace-refused")

    Application.put_env(:ryker, :work, %{api: Client, client: client})

    Application.put_env(:ryker, :fleet_profiles, %{
      {"read_only", nil} => %{
        authority_digest: String.duplicate("d", 64),
        policy: "work-read-only",
        policy_digest: String.duplicate("b", 64),
        repository_ref: nil
      }
    })

    on_exit(fn ->
      restore_env(:work, previous_work)
      restore_env(:fleet_profiles, previous_profiles)
    end)

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
               fleet_poll(
                 "worker-silent",
                 "workspace-storage",
                 String.duplicate("b", 64),
                 String.duplicate("d", 64)
               )
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
    |> fleet_poll(workspace_ref, String.duplicate("b", 64), String.duplicate("d", 64))
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
      remote_stopped_at: database_now!(),
      stop_receipt: %{"kind" => "stopped", "session_id" => session.coop_session_id}
    )
    |> Repo.update!()

    session
  end

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
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

  defp fleet_poll(worker_id, workspace_ref, policy_digest, authority_digest) do
    %{
      "acknowledged_command_ids" => [],
      "command_results" => [],
      "event_batches" => [],
      "poll_ref" => "poll:#{worker_id}:observability",
      "version" => 1,
      "worker" => %{
        "build_version" => "coop-observability",
        "capabilities" => [%{"name" => "responder-state", "version" => "1"}],
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
        "policy_authority_digests" => %{"work-read-only" => authority_digest},
        "policy_digests" => %{"work-read-only" => policy_digest},
        "protocol_version" => "1",
        "repositories" => [],
        "sandbox_digest" => String.duplicate("a", 64),
        "state" => "eligible",
        "workspace_ref" => workspace_ref
      }
    }
  end

  defp restore_env(key, :missing), do: Application.delete_env(:ryker, key)
  defp restore_env(key, value), do: Application.put_env(:ryker, key, value)

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
      state_tools: %{ip: {127, 0, 0, 1}, port: 0},
      worker_gateway: nil,
      github_listener: %{ip: {127, 0, 0, 1}, port: 0},
      webhook_listener: %{ip: {127, 0, 0, 1}, port: 0},
      storage_root: System.tmp_dir!(),
      github_api_url: "https://api.github.com",
      github_app_id: nil,
      emisar_rpc_url: "https://emisar.dev/api/mcp/rpc",
      log_level: :warning,
      webhook_secret_names: []
    }
  end
end
