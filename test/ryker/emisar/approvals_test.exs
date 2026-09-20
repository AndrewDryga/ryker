defmodule Ryker.Emisar.ApprovalsTest do
  use Ryker.DataCase, async: true

  alias Ryker.ControlPlane.Projection
  alias Ryker.Emisar.{Approval, Approvals, Connections, Operator, RunState}
  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Settings
  alias Ryker.State.{Record, Records}
  alias Ryker.Work.Custody

  @policy_digest String.duplicate("a", 64)
  @connection_ref "production"

  setup do
    configure_emisar!()
    :ok
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

  defp approval_wait!(suffix) do
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
             Custody.pin_episode(transition.episode.id, "test-policy", @policy_digest)

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

    assert {:ok, waiting} =
             Episodes.apply(%Command.StartWait{
               deadline_at: ~U[2099-08-29 12:00:00.000000Z],
               episode_key: claim.episode.key,
               expected_turn_ref: claim.turn.turn_ref,
               kind: :event,
               occurred_at: DateTime.add(now, 1, :second),
               wait_ref: record.ref
             })

    assert waiting.episode.state == :waiting_for_event
    %{claim: claim, record: record}
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

    assert {:ok, %{connection_ref: @connection_ref}} =
             Connections.resolve(Settings.fetch!(), nil, nil)
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
