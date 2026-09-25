defmodule Ryker.Emisar.ApprovalsTest do
  use Ryker.DataCase, async: true

  alias Ryker.ControlPlane.{FailureExplanation, Pages, Projection}
  alias Ryker.{Credentials, IntegrationSetup}
  alias Ryker.Emisar.{Approval, ApprovalDispatcher, Approvals, Connections, Operator, RunState}
  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Settings
  alias Ryker.State.{Record, Records}
  alias Ryker.Work.Custody

  @actor "control-plane:local"
  @policy_digest String.duplicate("a", 64)
  @connection_ref "production"
  @environment_ref "production"

  setup do
    configure_emisar!()
    :ok
  end

  defmodule UnusedAPI do
    @behaviour Ryker.Emisar.API

    @impl true
    def wait_for_run(_client, _run_id), do: {:error, :not_expected}
  end

  defmodule UnusedPresenter do
    def publish(_approval, _state, _presentation), do: {:error, :not_expected}
    def permanent?(_reason), do: false
  end

  # Verifies the replacement token against the account already connected.
  defmodule SameAccountRequester do
    def request(_client, :post, "/mcp", _body, _headers) do
      {:ok,
       %{
         body: %{
           "jsonrpc" => "2.0",
           "result" => %{"account" => %{"id" => "account-acme", "name" => "Acme production"}}
         },
         headers: [],
         status: 200
       }}
    end
  end

  test "registers the immutable approval atomically and claims it only after delivery starts the wait" do
    %{claim: claim, record: record} = approval_wait!("claim")
    record_id = record.id

    assert %Approval{
             action_id: "nomad.alloc_restart",
             record_id: ^record_id,
             remote_status: "pending_approval",
             request_id: "apr-claim",
             status: :monitoring
           } = Approvals.get_by_request_id(@connection_ref, "apr-claim")

    assert {:ok, %{approval: approval, lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert approval.episode_id == claim.episode.id
    assert approval.lease_owner == "approval-worker"

    assert {:ok, %{approval: observed, status: :monitoring}} =
             Approvals.observe(
               @connection_ref,
               "apr-claim",
               lease_ref,
               run_state("claim", "running"),
               5
             )

    assert observed.remote_status == "running"
    assert observed.failure_count == 0
    assert observed.lease_ref == nil
    assert %DateTime{} = observed.next_attempt_at
  end

  test "a terminal exact run resumes the same episode once without repeating the action" do
    %{claim: claim, record: record} = approval_wait!("terminal")

    assert Records.user_resumable_wait?(record.ref) == false

    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert {:ok,
            %{
              approval: %Approval{status: :resumed, remote_status: "success"},
              episode: resumed,
              record: %Record{status: :answered},
              status: :resumed
            }} =
             Approvals.observe(
               @connection_ref,
               "apr-terminal",
               lease_ref,
               run_state("terminal", "success"),
               5
             )

    assert resumed.id == claim.episode.id
    assert resumed.state == :working
    assert resumed.owner_kind == :turn
    assert resumed.owner_ref =~ "turn:emisar-approval:"

    assert {:ok, nil} = Approvals.claim_next(@connection_ref, "second-worker", 60)

    events = Episodes.list_events(claim.episode.key)

    assert Enum.map(events, & &1.kind) == [
             :input_admitted,
             :event_wait_started,
             :input_admitted,
             :wait_resumed
           ]

    terminal = Enum.find(events, &(&1.kind == :input_admitted and &1.sequence == 3))
    content = get_in(terminal.payload, ["payload", "content"])

    assert content["approval_request_id"] == "apr-terminal"
    assert content["required_next_operation"] == "wait_for_run"
    assert content["run_id"] == "run-terminal"
    assert content["status"] == "success"
    assert content["verification"] =~ "Never call run_action"
  end

  test "identity mismatches block no episode transition and transient failures retain durable custody" do
    %{claim: claim} = approval_wait!("failure")

    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    wrong = %{run_state("failure", "success") | action_id: "different.action"}

    assert Approvals.observe(@connection_ref, "apr-failure", lease_ref, wrong, 5) ==
             {:error, :emisar_approval_identity_mismatch}

    assert {:ok, deferred} =
             Approvals.defer(
               @connection_ref,
               "apr-failure",
               lease_ref,
               7,
               {:transport, :unavailable}
             )

    assert deferred.failure_count == 1
    assert deferred.last_error =~ "transport"
    assert deferred.lease_ref == nil
    assert %DateTime{} = deferred.next_attempt_at

    assert {:ok, waiting} = Episodes.fetch_by_key(claim.episode.key)
    assert waiting.state == :waiting_for_event

    assert Enum.map(Episodes.list_events(claim.episode.key), & &1.kind) == [
             :input_admitted,
             :event_wait_started
           ]
  end

  test "a blocked monitor is inspectable and can be rearmed without approving or repeating work" do
    %{claim: claim} = approval_wait!("operator")

    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert {:ok, %Approval{status: :blocked}} =
             Approvals.block(
               @connection_ref,
               "apr-operator",
               lease_ref,
               {:emisar_http_error, 403, "forbidden"}
             )

    assert {:ok, [blocked]} = Operator.list_blocked()
    assert blocked.request_id == "apr-operator"
    assert blocked.run_id == "run-operator"
    assert blocked.last_error =~ "forbidden"

    assert {:ok, fetched} = Operator.fetch("production/apr-operator")
    assert fetched == blocked

    assert {:ok, %{action: :rearm, ref: "production/apr-operator", status: :blocked}} =
             Projection.emisar("production/apr-operator")

    assert {:ok, failures} = Projection.failures(%{})

    assert %{kind: "emisar", ref: "production/apr-operator"} =
             Enum.find(failures, &(&1.kind == "emisar"))

    assert {:ok, rearmed} = Operator.rearm("production/apr-operator")
    assert rearmed.status == :monitoring
    assert rearmed.failure_count == 0
    assert rearmed.last_error == nil

    assert {:ok, %{approval: claimed_again}} =
             Approvals.claim_next(@connection_ref, "approval-worker-after-fix", 60)

    assert claimed_again.request_id == "apr-operator"
    assert {:ok, waiting} = Episodes.fetch_by_key(claim.episode.key)
    assert waiting.state == :waiting_for_event

    assert Operator.rearm("production/apr-operator") == {:error, :emisar_approval_not_blocked}
    assert Operator.fetch("production/missing") == {:error, :emisar_approval_not_found}
    assert Operator.list_blocked(0) == {:error, {:invalid_emisar_approval_operator, :limit}}
  end

  # A stopped watch whose task was then closed could only stay blocked: "Watch
  # the approval again" was refused every time because nothing waited for it,
  # and the row sat on Failures for good under a button that could never work.
  test "an approval watch nothing waits for any more closes by itself, keeps its history and leaves Failures" do
    %{claim: claim} = approval_wait!("closed-task")

    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert {:ok, %Approval{status: :blocked}} =
             Approvals.block(
               @connection_ref,
               "apr-closed-task",
               lease_ref,
               {:emisar_http_error, 403, "forbidden"}
             )

    assert %{kind: "emisar"} = failure("production/apr-closed-task")
    close_task!(claim.episode.key)

    # Nothing can continue from it, so it is not offered as a failure at all.
    assert failure("production/apr-closed-task") == nil
    assert Projection.emisar("production/apr-closed-task") == :not_found
    refute failures_page() =~ "apr-closed-task"

    # The monitor closes it on its next idle pass, with the reason, and keeps it.
    assert {:ok, {:closed, ["apr-closed-task"]}} = ApprovalDispatcher.run_once(dispatcher())

    closed = Approvals.get_by_request_id(@connection_ref, "apr-closed-task")
    assert closed.status == :closed
    assert closed.closed_reason == "wait_ended"
    assert %DateTime{} = closed.closed_at
    assert closed.last_error =~ "403"
    assert {:ok, %{status: :closed}} = Operator.fetch("production/apr-closed-task")
    assert Operator.rearm("production/apr-closed-task") == {:error, :emisar_approval_not_blocked}
    assert {:ok, :idle} = ApprovalDispatcher.run_once(dispatcher())
  end

  test "a watch whose wait has not started yet is never closed as if nothing waited for it" do
    # The approval is registered with its turn, before the delivered result
    # starts the wait; only a closed task or an answered wait ends it.
    unstarted = registered_approval!("unstarted")

    assert {:ok, :idle} = ApprovalDispatcher.run_once(dispatcher("closer-unstarted"))
    assert Approvals.get_by_request_id(@connection_ref, unstarted).status == :monitoring
  end

  # Turning approval monitoring off, or losing the account's token, stopped
  # every approval a task was waiting for, and nothing said so anywhere: the
  # watch was not blocked, so Failures listed nothing while tasks waited for
  # good.
  test "an approval a task waits for is a failure while its account is not watched, until it is again" do
    approval_wait!("unwatched")
    assert failure("production/apr-unwatched") == nil

    assert {:ok, _snapshot} = IntegrationSetup.disable_emisar_monitoring(@connection_ref)

    row = failure("production/apr-unwatched")
    assert %{kind: "emisar", stall: :monitoring_off, action: nil, status: :monitoring} = row
    assert {:ok, %{stall: :monitoring_off}} = Projection.emisar("production/apr-unwatched")

    explanation = FailureExplanation.explain(row)
    assert explanation.outlook == :fix_first
    assert explanation.button == %{label: "Open Emisar settings", href: "/integrations/emisar"}
    assert explanation.summary =~ "monitoring is off"
    refute Enum.any?(explanation.options, &is_binary(&1[:path]))
    assert failures_page() =~ "/failures/emisar/production%2Fapr-unwatched"

    assert {:ok, _snapshot} = IntegrationSetup.enable_emisar_monitoring(@connection_ref)
    assert failure("production/apr-unwatched") == nil

    assert {:ok, %{approval: %{request_id: "apr-unwatched"}}} =
             Approvals.claim_next(@connection_ref, "approval-worker-watched-again", 60)
  end

  test "an approval a task waits for is a failure while its account has no token, until one is saved" do
    approval_wait!("tokenless")
    assert {:ok, :ok} = Credentials.delete(:emisar, @connection_ref, @actor)

    row = failure("production/apr-tokenless")
    assert %{stall: :token_unavailable, action: nil} = row

    explanation = FailureExplanation.explain(row)
    assert explanation.outlook == :fix_first
    assert explanation.button.href == "/integrations/emisar"
    assert explanation.summary =~ "no usable Emisar token"

    assert {:ok, %{status: :rotated}} =
             IntegrationSetup.rotate_emisar(
               @connection_ref,
               "replacement-emisar-token-long-enough",
               requester: SameAccountRequester
             )

    assert failure("production/apr-tokenless") == nil
  end

  test "a token Ryker cannot read stops watching, and replacing it clears the failure" do
    approval_wait!("unreadable")

    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert {:ok, _deferred} =
             Approvals.defer(
               @connection_ref,
               "apr-unreadable",
               lease_ref,
               300,
               {:delivery_credentials_unavailable, :credential_decryption_failed}
             )

    assert %{stall: :token_unavailable} = failure("production/apr-unreadable")

    assert {:ok, %{status: :rotated}} =
             IntegrationSetup.rotate_emisar(
               @connection_ref,
               "replacement-emisar-token-long-enough",
               requester: SameAccountRequester
             )

    assert failure("production/apr-unreadable") == nil

    # The next check goes out now rather than after the backoff it had reached.
    assert {:ok, %{approval: %{request_id: "apr-unreadable"}}} =
             Approvals.claim_next(@connection_ref, "approval-worker-after-token", 60)
  end

  # Emisar refusing the token blocks the watch, and the page said to replace
  # the token, then press "Watch the approval again" on every approval.
  test "an approval stopped by a refused token is watched again once the token is replaced" do
    approval_wait!("refused")

    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert {:ok, %Approval{status: :blocked}} =
             Approvals.block(
               @connection_ref,
               "apr-refused",
               lease_ref,
               {:emisar_http_error, 401, "unauthorized"}
             )

    row = failure("production/apr-refused")
    assert row.summary == "emisar_http_401"
    assert FailureExplanation.explain(row).button.href == "/integrations/emisar"

    assert {:ok, %{status: :rotated}} =
             IntegrationSetup.rotate_emisar(
               @connection_ref,
               "replacement-emisar-token-long-enough",
               requester: SameAccountRequester
             )

    assert failure("production/apr-refused") == nil
    assert Approvals.get_by_request_id(@connection_ref, "apr-refused").status == :monitoring

    assert {:ok, %{approval: %{request_id: "apr-refused"}}} =
             Approvals.claim_next(@connection_ref, "approval-worker-after-rotation", 60)
  end

  defp approval_wait!(suffix) do
    %{claim: claim, record: record} = registered!(suffix)

    assert {:ok, waiting} =
             Episodes.apply(%Command.StartWait{
               deadline_at: ~U[2099-08-29 12:00:00.000000Z],
               episode_key: claim.episode.key,
               expected_turn_ref: claim.turn.turn_ref,
               kind: :event,
               occurred_at: ~U[2026-08-29 12:00:01.000000Z],
               wait_ref: record.ref
             })

    assert waiting.episode.state == :waiting_for_event
    %{claim: claim, record: record}
  end

  # The approval as its turn records it, before the delivered result starts
  # the episode's wait for it.
  defp registered_approval!(suffix) do
    registered!(suffix)
    "apr-#{suffix}"
  end

  defp registered!(suffix) do
    now = ~U[2026-08-29 12:00:00.000000Z]

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "emisar-approval:#{suffix}",
        native_input_id: "source:#{suffix}",
        occurred_at: now,
        payload: %{"text" => "Perform the governed action."},
        turn_ref: "turn:#{suffix}"
      })

    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(
               transition.episode.id,
               "test-policy",
               @policy_digest,
               nil,
               nil,
               nil,
               nil,
               @environment_ref
             )

    Episode
    |> Repo.get!(transition.episode.id)
    |> Ecto.Changeset.change(updated_at: ~U[2000-01-01 00:00:00.000000Z])
    |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("work:#{suffix}", 60)
    assert claim.episode.id == transition.episode.id

    assert Map.take(claim.session, [
             :emisar_connection_ref,
             :emisar_account_ref,
             :emisar_rpc_url
           ]) == %{
             emisar_connection_ref: @connection_ref,
             emisar_account_ref: "account-acme",
             emisar_rpc_url: "https://emisar.example/mcp"
           }

    assert {:ok, record} =
             Records.create(
               Records.token(claim.turn),
               "op-#{suffix}",
               "emisar_approval",
               approval_payload(suffix)
             )

    %{claim: claim, record: record}
  end

  defp close_task!(episode_key) do
    assert {:ok, waiting} = Episodes.fetch_by_key(episode_key)

    assert {:ok, _cancelled} =
             Episodes.apply(%Command.CancelEpisode{
               cancel_ref: "cancel:#{episode_key}",
               episode_key: episode_key,
               expected_owner: %{kind: waiting.owner_kind, ref: waiting.owner_ref},
               occurred_at: ~U[2026-08-29 12:05:00.000000Z],
               reason: "Closed by slack:user:U1 from the exact Slack work card."
             })
  end

  defp failure(ref) do
    assert {:ok, failures} = Projection.failures(%{})
    Enum.find(failures, &(&1.kind == "emisar" and &1.ref == ref))
  end

  defp failures_page do
    page = Pages.page(["failures"], %{}, %{projection: Projection.callbacks()})
    assert page.status == 200
    page.body
  end

  defp dispatcher(worker_ref \\ "approval-closer") do
    [
      api: UnusedAPI,
      client: :unused,
      connection_ref: @connection_ref,
      lease_seconds: 60,
      poll_seconds: 5,
      presentation: :unused,
      presenter: UnusedPresenter,
      retry_base_seconds: 2,
      retry_max_seconds: 60,
      worker_ref: worker_ref
    ]
  end

  defp approval_payload(suffix) do
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
  end

  defp configure_emisar! do
    {:ok, snapshot} = Settings.initialize("control-plane:local")

    {:ok, _credential} =
      Credentials.put(:emisar, @connection_ref, "emisar-token-long-enough", @actor)

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

    assert {:ok, %{connection_ref: @connection_ref}} =
             Connections.resolve(Settings.fetch!(), @environment_ref)
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
end
