defmodule Ryker.Emisar.ApprovalDispatcherTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ryker.Emisar.{ApprovalDispatcher, RunState}
  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Inspectors
  alias Ryker.Records
  alias Ryker.Settings
  alias Ryker.Work.Custody

  @policy_digest String.duplicate("b", 64)
  @connection_ref "production"
  @environment_ref "production"

  setup do
    configure_emisar!()
    :ok
  end

  defmodule API do
    @behaviour Ryker.Emisar.API

    @impl true
    def wait_for_run({test_pid, result}, run_id, wait_seconds) do
      send(test_pid, {:wait_for_run, run_id, wait_seconds})
      result
    end
  end

  defmodule RacingAPI do
    @behaviour Ryker.Emisar.API

    @impl true
    def wait_for_run({test_pid, result, before_return}, run_id, wait_seconds) do
      send(test_pid, {:wait_for_run, run_id, wait_seconds})
      before_return.()
      result
    end
  end

  defmodule Presenter do
    def publish(_approval, _state, {test_pid, result}) do
      send(test_pid, :approval_presented)
      result
    end

    def permanent?(:invalid_destination), do: true
    def permanent?(_reason), do: false
  end

  test "polls the exact immutable run and resumes its episode on a terminal result" do
    episode = waiting_approval!("terminal")

    assert ApprovalDispatcher.run_once(options({:ok, state("terminal", "success")})) ==
             {:ok, {:resumed, "apr-terminal", "success"}}

    assert_receive {:wait_for_run, "run-terminal", 0}
    assert_receive :approval_presented
    assert resumed = Inspectors.episode(episode.key)
    assert resumed.state == :working
    assert Inspectors.emisar_approval(@connection_ref, "apr-terminal").status == :resumed
  end

  # Each pending approval was read every three seconds with no wait, and its
  # row written three times a read, about 86,000 updates a day while a person
  # took their time (2026-10-04 review). Once its card shows the run, Ryker
  # waits on Emisar for the run to change; a new approval is read at once, so
  # its card appears without a wait.
  test "an approval already shown waits on Emisar for a change instead of asking again at once" do
    waiting_approval!("long-poll")
    pending = state("long-poll", "pending_approval")

    assert ApprovalDispatcher.run_once(options({:ok, pending})) ==
             {:ok, {:monitoring, "apr-long-poll", "pending_approval"}}

    assert_receive {:wait_for_run, "run-long-poll", 0}

    Repo.update_all(
      from(approval in Ryker.Emisar.Approval, where: approval.request_id == "apr-long-poll"),
      set: [next_attempt_at: nil]
    )

    assert ApprovalDispatcher.run_once(options({:ok, pending})) ==
             {:ok, {:monitoring, "apr-long-poll", "pending_approval"}}

    assert_receive {:wait_for_run, "run-long-poll", 20}
  end

  test "backs off transient reads and blocks a crossed immutable identity" do
    waiting_approval!("transient")

    assert ApprovalDispatcher.run_once(options({:error, {:transport, :offline}})) ==
             {:ok, {:deferred, "apr-transient", {:transport, :offline}}}

    deferred = Inspectors.emisar_approval(@connection_ref, "apr-transient")
    assert deferred.failure_count == 1
    assert deferred.status == :monitoring
    assert %DateTime{} = deferred.next_attempt_at

    waiting_approval!("crossed")
    wrong = %{state("crossed", "success") | run_id: "run-other"}

    assert ApprovalDispatcher.run_once(options({:ok, wrong}, "approval-worker-crossed")) ==
             {:ok, {:blocked, "apr-crossed", :emisar_approval_identity_mismatch}}

    assert Inspectors.emisar_approval(@connection_ref, "apr-crossed").status == :blocked
    assert waiting = Inspectors.episode("approval-dispatcher:crossed")
    assert waiting.state == :waiting_for_event
  end

  test "a monitor that lost its exact lease cannot publish an approval card" do
    waiting_approval!("stale-presenter")

    before_return = fn ->
      Repo.update_all(
        from(approval in Ryker.Emisar.Approval,
          where: approval.request_id == "apr-stale-presenter"
        ),
        set: [
          lease_expires_at: ~U[2000-01-01 00:00:00.000000Z],
          lease_owner: "replacement-worker",
          lease_ref: "replacement-lease"
        ]
      )
    end

    settings =
      options({:ok, state("stale-presenter", "running")}, "stale-presenter-worker")
      |> Keyword.put(:api, RacingAPI)
      |> Keyword.put(
        :client,
        {self(), {:ok, state("stale-presenter", "running")}, before_return}
      )

    assert {:error, {:emisar_approval_custody_failed, _, _}} =
             ApprovalDispatcher.run_once(settings)

    refute_received :approval_presented
  end

  test "rejects malformed dispatcher configuration before claiming custody" do
    assert ApprovalDispatcher.run_once(%{}) ==
             {:error, {:invalid_emisar_approval_dispatcher, :options}}
  end

  test "presentation failures defer transiently and block only deterministic adapter faults" do
    waiting_approval!("presentation-transient")

    transient =
      options({:ok, state("presentation-transient", "running")}, "presenter-transient")
      |> Keyword.put(:presentation, {self(), {:error, :socket_closed}})

    assert ApprovalDispatcher.run_once(transient) ==
             {:ok,
              {:deferred, "apr-presentation-transient",
               {:emisar_approval_presentation_unavailable, :socket_closed}}}

    waiting_approval!("presentation-permanent")

    permanent =
      options({:ok, state("presentation-permanent", "running")}, "presenter-permanent")
      |> Keyword.put(:presentation, {self(), {:error, :invalid_destination}})

    assert ApprovalDispatcher.run_once(permanent) ==
             {:ok,
              {:blocked, "apr-presentation-permanent",
               {:emisar_approval_presentation_permanent, :invalid_destination}}}
  end

  test "keeps nonterminal runs monitored and contains malformed adapter envelopes" do
    waiting_approval!("monitoring")

    assert ApprovalDispatcher.run_once(options({:ok, state("monitoring", "running")})) ==
             {:ok, {:monitoring, "apr-monitoring", "running"}}

    waiting_approval!("invalid-api")

    assert ApprovalDispatcher.run_once(options(:invalid, "approval-worker-invalid-api")) ==
             {:ok,
              {:blocked, "apr-invalid-api", {:emisar_protocol_error, {:api_result, :invalid}}}}

    waiting_approval!("invalid-presentation")

    invalid_presentation =
      options({:ok, state("invalid-presentation", "running")}, "invalid-presentation")
      |> Keyword.put(:presentation, {self(), :invalid})

    assert ApprovalDispatcher.run_once(invalid_presentation) ==
             {:ok,
              {:blocked, "apr-invalid-presentation",
               {:emisar_protocol_error, {:presentation_result, :invalid}}}}

    waiting_approval!("not-found")

    assert ApprovalDispatcher.run_once(
             options(
               {:error, {:emisar_http_error, 404, "missing"}},
               "approval-worker-not-found"
             )
           ) == {:ok, {:blocked, "apr-not-found", {:emisar_http_error, 404, "missing"}}}

    # A request that timed out at Emisar (408) or arrived too early (425) asks to be sent again;
    # treating every 4xx but 429 as final blocked the watch on one slow answer (2026-10-04 review).
    for status <- [408, 425] do
      waiting_approval!("timed-out-#{status}")
      approval_ref = "apr-timed-out-#{status}"

      assert {:ok, {:deferred, ^approval_ref, {:emisar_http_error, ^status, _detail}}} =
               ApprovalDispatcher.run_once(
                 options(
                   {:error, {:emisar_http_error, status, "try again"}},
                   "approval-worker-timed-out-#{status}"
                 )
               )
    end
  end

  test "configuration accepts exactly one bounded keyword document" do
    assert ApprovalDispatcher.run_once(:invalid) ==
             {:error, {:invalid_emisar_approval_dispatcher, :fields}}

    assert ApprovalDispatcher.run_once(worker_ref: "one", worker_ref: "two") ==
             {:error, {:invalid_emisar_approval_dispatcher, :fields}}

    invalid = Keyword.put(options({:error, :not_used}), :lease_seconds, 0)

    assert ApprovalDispatcher.run_once(invalid) ==
             {:error, {:invalid_emisar_approval_dispatcher, :options}}
  end

  defp options(result, worker_ref \\ "approval-worker") do
    [
      api: API,
      client: {self(), result},
      connection_ref: @connection_ref,
      lease_seconds: 60,
      poll_seconds: 5,
      presentation: {self(), :ok},
      presenter: Presenter,
      retry_base_seconds: 2,
      retry_max_seconds: 60,
      wait_seconds: 20,
      worker_ref: worker_ref
    ]
  end

  defp waiting_approval!(suffix) do
    occurred_at = ~U[2026-08-29 12:00:00.000000Z]

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: Ecto.UUID.generate(),
                 episode_key: "approval-dispatcher:#{suffix}",
                 native_input_id: "source:#{suffix}",
                 occurred_at: occurred_at,
                 payload: %{"text" => "Run one governed action."},
                 turn_ref: "turn:#{suffix}"
               })
             )

    assert {:ok, _session} =
             WorkSessions.pin_episode(transition.episode.id, "test-policy", @policy_digest,
               environment_ref: @environment_ref
             )

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
                 "approval_url" => "https://emisar.example/app/acme/approvals/apr-#{suffix}",
                 "account_ref" => "account-acme",
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

    assert {:ok, waiting} =
             Episodes.apply(%Command.StartWait{
               deadline_at: ~U[2099-08-29 12:00:00.000000Z],
               episode_key: claim.episode.key,
               expected_turn_ref: claim.turn.turn_ref,
               kind: :event,
               occurred_at: DateTime.add(occurred_at, 1, :second),
               wait_ref: record.ref
             })

    waiting.episode
  end

  defp state(suffix, status) do
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
      Settings.put_environment(
        %{
          ref: @environment_ref,
          display_name: "Production",
          emisar_connection_ref: @connection_ref
        },
        snapshot.installation.revision,
        "control-plane:local"
      )
  end
end
