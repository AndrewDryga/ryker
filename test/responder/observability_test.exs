defmodule Responder.ObservabilityTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.CoopFleet.{Client, ControlPlane, Worker}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Observability
  alias Responder.Observability.Progress
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.Work.Custody

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
    assert metrics =~ ~s(responder_ingress_total{status="pending"} 1)
    assert metrics =~ ~s(responder_queue_claimable{queue="work"} 0)
    assert metrics =~ ~s(responder_queue_active_leases{queue="work"} 1)
    assert metrics =~ ~s(responder_queue_claimable{queue="retention"} 0)
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
      from(turn in Responder.Work.Turn, where: turn.id == ^claim.turn.id),
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
      from(turn in Responder.Work.Turn, where: turn.id == ^claim.turn.id),
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

    previous = Application.get_env(:responder, :work, :missing)
    Application.put_env(:responder, :work, %{enabled: true})

    on_exit(fn ->
      if previous == :missing,
        do: Application.delete_env(:responder, :work),
        else: Application.put_env(:responder, :work, previous)
    end)

    assert :ok = Progress.record(:work, :cycle)
    old = DateTime.add(DateTime.utc_now(), -3_600, :second)

    assert {:ok, _result} =
             Repo.query(
               "UPDATE responder_runtime_progress SET observed_at = $1 WHERE lane = 'work'",
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
    assert metrics =~ ~s(responder_runtime_progress_age_seconds{lane="work"})
    assert metrics =~ ~s(responder_runtime_progress_cycles{lane="work"} 2)
  end

  test "fleet execution requires fresh compatible worker capacity" do
    authority_digest = String.duplicate("d", 64)
    policy_digest = String.duplicate("b", 64)
    workspace_ref = "workspace-observability"
    previous_work = Application.get_env(:responder, :work, :missing)
    previous_profiles = Application.get_env(:responder, :cutover_profiles, :missing)

    assert {:ok, client} =
             Client.new(
               capability_names: ["responder-state"],
               workspace_ref: workspace_ref
             )

    Application.put_env(:responder, :work, %{api: Client, client: client})

    Application.put_env(:responder, :cutover_profiles, %{
      {"read_only", nil} => %{
        authority_digest: authority_digest,
        policy: "work-read-only",
        policy_digest: policy_digest,
        repository_ref: nil
      }
    })

    on_exit(fn ->
      restore_env(:work, previous_work)
      restore_env(:cutover_profiles, previous_profiles)
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
    assert metrics =~ ~s(responder_coop_fleet_eligible_workers 1)
    assert metrics =~ ~s(responder_coop_fleet_slots_free{kind="turn"} 2)
    assert metrics =~ ~s(responder_coop_fleet_workers{state="eligible"} 1)
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

    previous = Map.new(keys, &{&1, Application.get_env(:responder, &1, :missing)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :missing} -> Application.delete_env(:responder, key)
        {key, value} -> Application.put_env(:responder, key, value)
      end)
    end)

    Enum.each(keys, &Application.put_env(:responder, &1, %{enabled: true}))
    Application.put_env(:responder, :schedules, false)

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

    previous = Map.new(keys, &{&1, Application.get_env(:responder, &1, :missing)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :missing} -> Application.delete_env(:responder, key)
        {key, value} -> Application.put_env(:responder, key, value)
      end)
    end)

    Enum.each(keys, &Application.put_env(:responder, &1, false))
    Application.put_env(:responder, :admission, %{enabled: true})

    assert {:ok, runtime} =
             Agent.start_link(fn -> :healthy end, name: Responder.Admission.Runtime)

    on_exit(fn -> if Process.alive?(runtime), do: Agent.stop(runtime) end)
    assert :ok = Progress.record(:admission, :cycle)

    assert {:ok, readiness} =
             Observability.ready(check_runtimes: true, stall_after_seconds: 86_400)

    assert readiness.missing_runtimes == []
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

  defp restore_env(key, :missing), do: Application.delete_env(:responder, key)
  defp restore_env(key, value), do: Application.put_env(:responder, key, value)
end
