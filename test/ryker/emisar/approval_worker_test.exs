defmodule Ryker.Emisar.ApprovalWorkerTest do
  use Ryker.DataCase, async: false

  alias Ryker.Emisar.{ApprovalWorker, RunState}
  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Settings
  alias Ryker.State.Records
  alias Ryker.Work.Custody

  @policy_digest String.duplicate("b", 64)
  @connection_ref "production"

  setup do
    configure_emisar!()
    :ok
  end

  defmodule API do
    def wait_for_run({test_pid, result}, run_id) do
      send(test_pid, {:worker_wait_for_run, run_id})
      result
    end
  end

  defmodule Presenter do
    def publish(_approval, _state, _configuration), do: :ok
    def permanent?(_reason), do: false
  end

  test "an idle poll keeps the bounded worker alive without inventing work" do
    options = [dispatcher_options: dispatcher_options(), poll_interval_ms: 60_000]

    assert {:ok, state} = ApprovalWorker.init(options)
    assert_receive :poll
    assert {:noreply, ^state} = ApprovalWorker.handle_info(:poll, state)
  end

  test "invalid worker options fail before a polling process starts" do
    assert ApprovalWorker.init(poll_interval_ms: 0, dispatcher_options: []) ==
             {:stop, {:invalid_emisar_approval_worker, :options}}

    assert ApprovalWorker.init(poll_interval_ms: 10, dispatcher_options: %{}) ==
             {:stop, {:invalid_emisar_approval_worker, :options}}
  end

  test "named and anonymous workers both use the same bounded polling contract" do
    name = Module.concat(__MODULE__, "Named#{System.unique_integer([:positive])}")
    options = [dispatcher_options: dispatcher_options(), poll_interval_ms: 60_000]

    assert {:ok, named} = ApprovalWorker.start_link(Keyword.put(options, :name, name))
    assert Process.whereis(name) == named
    GenServer.stop(named)

    assert {:ok, anonymous} = ApprovalWorker.start_link(options)
    assert Process.info(anonymous, :registered_name) == {:registered_name, []}
    GenServer.stop(anonymous)
  end

  test "one worker poll contains every dispatcher custody outcome and keeps polling" do
    cases = [
      {"monitoring", {:ok, run_state("monitoring", "running")}},
      {"resumed", {:ok, run_state("resumed", "success")}},
      {"deferred", {:error, :offline}},
      {"blocked", {:ok, %{run_state("blocked", "success") | run_id: "run-crossed"}}}
    ]

    for {suffix, result} <- cases do
      waiting_approval!(suffix)

      assert {:ok, state} =
               ApprovalWorker.init(
                 dispatcher_options: dispatcher_options(result, "approval-worker:#{suffix}"),
                 poll_interval_ms: 60_000
               )

      assert_receive :poll
      assert {:noreply, ^state} = ApprovalWorker.handle_info(:poll, state)
      expected_run_id = "run-#{suffix}"
      assert_receive {:worker_wait_for_run, ^expected_run_id}
    end

    invalid_state = %{dispatcher_options: [], poll_interval_ms: 60_000}
    assert {:noreply, ^invalid_state} = ApprovalWorker.handle_info(:poll, invalid_state)
  end

  defp dispatcher_options(result \\ {:error, :not_used}, worker_ref \\ "approval-worker:test") do
    [
      api: API,
      client: {self(), result},
      connection_ref: @connection_ref,
      lease_seconds: 60,
      poll_seconds: 3,
      presentation: %{},
      presenter: Presenter,
      retry_base_seconds: 2,
      retry_max_seconds: 60,
      worker_ref: worker_ref
    ]
  end

  defp waiting_approval!(suffix) do
    occurred_at = ~U[2026-08-29 12:00:00.000000Z]

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: Ecto.UUID.generate(),
                 episode_key: "approval-worker:#{suffix}",
                 native_input_id: "source:#{suffix}",
                 occurred_at: occurred_at,
                 payload: %{"text" => "Run one governed action."},
                 turn_ref: "turn:#{suffix}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(transition.episode.id, "test-policy", @policy_digest)

    Episode
    |> Repo.get!(transition.episode.id)
    |> Ecto.Changeset.change(updated_at: ~U[2000-01-01 00:00:00.000000Z])
    |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("work:#{suffix}", 60)
    assert claim.episode.id == transition.episode.id

    assert {:ok, record} =
             Records.create(
               Records.token(claim.turn),
               "op-#{suffix}",
               "emisar_approval",
               %{
                 "action_id" => "nomad.alloc_restart",
                 "account_ref" => "account-acme",
                 "approval_url" => "https://emisar.example/app/acme/approvals/apr-#{suffix}",
                 "connection_ref" => @connection_ref,
                 "expires_at" => "2099-08-29T12:00:00.000000Z",
                 "operation_id" => "op-#{suffix}",
                 "pack_ref" => "nomad@1#sha256:abc",
                 "request_id" => "apr-#{suffix}",
                 "run_id" => "run-#{suffix}",
                 "runner_ref" => "production-runner",
                 "rpc_url" => "https://emisar.example/mcp",
                 "status" => "pending_approval"
               }
             )

    assert {:ok, _waiting} =
             Episodes.apply(%Command.StartWait{
               deadline_at: ~U[2099-08-29 12:00:00.000000Z],
               episode_key: claim.episode.key,
               expected_turn_ref: claim.turn.turn_ref,
               kind: :event,
               occurred_at: DateTime.add(occurred_at, 1, :second),
               wait_ref: record.ref
             })
  end

  defp run_state(suffix, status) do
    %RunState{
      action_id: "nomad.alloc_restart",
      error_message: nil,
      operation_id: "op-#{suffix}",
      pack_ref: "nomad@1#sha256:abc",
      run_id: "run-#{suffix}",
      run_url: "https://emisar.example/app/acme/runs/run-#{suffix}",
      runner_ref: "production-runner",
      status: status
    }
  end

  defp configure_emisar! do
    {:ok, snapshot} = Settings.initialize("control-plane:local")

    {:ok, snapshot} =
      Settings.put_emisar_connection(
        %{
          ref: @connection_ref,
          display_name: "Production approvals",
          rpc_url: "https://emisar.example/mcp",
          account_ref: "account-acme",
          account_label: "Acme production",
          enabled_for_new_work: true,
          monitoring_enabled: true,
          verified_at: ~U[2026-08-29 12:00:00.000000Z]
        },
        snapshot.installation.revision,
        "control-plane:local"
      )

    {:ok, _snapshot} =
      Settings.put_emisar_binding(
        %{
          scope_kind: :installation_purpose,
          scope_ref: "standard",
          purpose: :standard,
          connection_ref: @connection_ref
        },
        snapshot.installation.revision,
        "control-plane:local"
      )
  end
end
