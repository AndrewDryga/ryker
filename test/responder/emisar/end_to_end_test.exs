defmodule Responder.Emisar.EndToEndTest do
  use Responder.DataCase, async: true

  alias Responder.Delivery.Adapters
  alias Responder.Emisar.{Approval, ApprovalDispatcher, ApprovalPresenter, Approvals, RunState}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Slack.Publisher
  alias Responder.State.{Record, Records}
  alias Responder.StateTools.Tools
  alias Responder.TestSupport.FakeWorkCoopAPI
  alias Responder.Work.{Custody, DeliveryReceipt, Executor, Turn}

  @now ~U[2026-08-29 12:00:00.000000Z]
  @policy_digest String.duplicate("a", 64)

  defmodule EmisarAPI do
    def wait_for_run({test_pid, state}, run_id) do
      send(test_pid, {:wait_for_run, run_id})
      {:ok, state}
    end
  end

  defmodule SlackAPI do
    @behaviour Responder.Slack.API

    def start_link(test_pid), do: Agent.start_link(fn -> test_pid end)

    @impl true
    def update_message(agent, channel, message_ref, document, delivery_ref) do
      send(Agent.get(agent, & &1), {
        :approval_status_update,
        channel,
        message_ref,
        document,
        delivery_ref
      })

      :ok
    end

    @impl true
    def find_message(_client, _channel, _thread, _delivery_ref), do: :not_found

    @impl true
    def post_message(_client, _channel, _thread, _body, _delivery_ref),
      do: {:error, :not_used}

    @impl true
    def find_files(_client, _channel, _thread, _filenames), do: :not_found

    @impl true
    def upload_files(_client, _channel, _thread, _body, _delivery_ref, _files),
      do: {:error, :not_used}

    @impl true
    def add_reaction(_client, _channel, _message_ref, _emoji_name), do: {:error, :not_used}
  end

  test "a governed action waits for Emisar and resumes the same episode after the exact run terminates" do
    claim = claim_episode!("approval-lifecycle")

    assert {:ok, recorded} =
             Tools.call(
               "record_emisar_approval",
               approval_arguments(),
               binding: %{state_token: Records.token(claim.turn)},
               emisar_rpc_url: "https://emisar.example/mcp"
             )

    approval_ref = recorded["record_ref"]

    assert %Record{kind: "emisar_approval", ref: ^approval_ref, status: :open} =
             Repo.get_by!(Record, ref: approval_ref)

    {:ok, fake} =
      FakeWorkCoopAPI.start_link([
        approval_reply(approval_ref),
        final_reply("The governed action completed and its exact run was verified.")
      ])

    assert {:ok, first} = Executor.run(claim, executor_options(fake))
    assert first.status == :accepted
    assert first.turn.status == :delivery_pending
    assert first.turn.delivery_document["outcome"]["state"] == "waiting_for_event"
    assert first.turn.delivery_document["outcome"]["record_refs"] == [approval_ref]

    assert {:ok, delivery} = Custody.claim_next("approval-card-delivery", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               first.turn.delivery_ref,
               first.episode.destination_transport,
               first.episode.destination_conversation_ref,
               first.episode.destination_thread_ref,
               "1788019200.000100"
             )

    assert {:ok, delivered} =
             Custody.confirm_delivery(
               first.episode.id,
               first.episode.key,
               first.turn.turn_ref,
               delivery.lease_ref,
               receipt
             )

    assert delivered.episode.state == :waiting_for_event
    assert delivered.episode.owner_ref == approval_ref
    assert delivered.turn.status == :settled

    {:ok, slack} = SlackAPI.start_link(self())

    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{workspaces: %{"TEC879C5EE335" => %{api: SlackAPI, client: slack}}},
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    assert {:ok, {:resumed, "apr-e2e", "success"}} =
             ApprovalDispatcher.run_once(
               api: EmisarAPI,
               client: {self(), terminal_run_state()},
               lease_seconds: 60,
               poll_seconds: 5,
               presentation: adapters,
               presenter: Responder.Emisar.ApprovalPresenter,
               retry_base_seconds: 2,
               retry_max_seconds: 60,
               worker_ref: "emisar-approval-monitor"
             )

    assert_receive {:wait_for_run, "run-e2e"}

    assert_receive {
      :approval_status_update,
      "C456",
      "1788019200.000100",
      %{"emisar_approval_status" => %{"status" => "success"} = status},
      delivery_ref
    }

    assert status["run_id"] == "run-e2e"
    assert status["approval_url"] =~ "/approvals/apr-e2e"
    assert delivery_ref == first.turn.delivery_ref

    approval = Approvals.get_by_request_id("apr-e2e")
    assert :ok = ApprovalPresenter.publish(approval, terminal_run_state(), adapters)
    refute_receive {:approval_status_update, _, _, _, _}

    changed = %{terminal_run_state() | error_message: "governed action failed", status: "failure"}

    assert ApprovalPresenter.publish(approval, changed, adapters) ==
             {:error, :emisar_approval_record_stale}

    assert ApprovalPresenter.publish(:invalid, changed, adapters) ==
             {:error, {:invalid_emisar_approval_presentation, :arguments}}

    orphan = %Approval{
      episode_id: Ecto.UUID.generate(),
      record_id: Ecto.UUID.generate(),
      remote_status: "pending_approval"
    }

    assert ApprovalPresenter.publish(orphan, terminal_run_state(), adapters) ==
             {:error, :emisar_approval_delivery_not_settled}

    for transient <- [
          {:delivery_rate_limited, 10, :provider_backoff},
          {:delivery_uncertain, :response_lost},
          {:slack_http_error, 503, "unavailable"},
          {:github_api_error, 502, "unavailable"},
          {:emisar_approval_presentation_unavailable, :offline}
        ] do
      refute ApprovalPresenter.permanent?(transient)
    end

    assert ApprovalPresenter.permanent?(:invalid_destination)

    assert {:ok, resumed} = Episodes.fetch_by_key(first.episode.key)

    assert resumed.id == first.episode.id
    assert resumed.state == :working
    assert resumed.owner_kind == :turn

    assert %Record{status: :answered} = Repo.get_by!(Record, ref: approval_ref)

    assert {:ok, continuation_claim} =
             Custody.claim_next("approval-terminal-continuation", 60, :work)

    assert continuation_claim.episode.id == first.episode.id
    assert continuation_claim.session.id == claim.session.id
    assert continuation_claim.turn.id != claim.turn.id

    assert {:ok, final} = Executor.run(continuation_claim, executor_options(fake))
    assert final.status == :accepted
    assert final.turn.status == :delivery_pending

    [initial_submission, terminal_submission] = FakeWorkCoopAPI.state(fake).submissions
    assert initial_submission.prompt =~ approval_ref

    assert terminal_submission.prompt =~ "emisar_approval_terminal"
    assert terminal_submission.prompt =~ "required_next_operation"
    assert terminal_submission.prompt =~ "wait_for_run"
    assert terminal_submission.prompt =~ "Never call run_action"

    assert Repo.aggregate(Turn, :count, :id) == 2

    assert Enum.map(Episodes.list_events(first.episode.key), & &1.kind) == [
             :input_admitted,
             :result_accepted,
             :delivery_confirmed,
             :input_admitted,
             :wait_resumed,
             :result_accepted
           ]
  end

  defp claim_episode!(suffix) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: "slack:TEC879C5EE335:C456",
          thread_ref: "1788019100.000100",
          transport: "slack"
        },
        episode_id: id,
        episode_key: "emisar-e2e:#{suffix}:#{id}",
        native_input_id: "source:#{suffix}:#{id}",
        occurred_at: @now,
        payload: %{"text" => "Restart the exact governed allocation and verify it."},
        turn_ref: "turn:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)
    assert {:ok, _session} = Custody.pin_episode(id, "work-read-only", @policy_digest)
    assert {:ok, claim} = Custody.claim_next("emisar-e2e:#{suffix}", 60, :work)
    claim
  end

  defp approval_arguments do
    %{
      "action_id" => "nomad.alloc_restart",
      "approval_url" => "https://emisar.example/app/acme/approvals/apr-e2e",
      "expires_at" => "2099-08-29T12:00:00.000000Z",
      "operation_id" => "operation-e2e",
      "pack_ref" => "nomad@1#sha256:abc",
      "request_id" => "apr-e2e",
      "run_id" => "run-e2e",
      "runner_ref" => "production-runner",
      "status" => "pending_approval"
    }
  end

  defp approval_reply(record_ref) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "Approval is required in Emisar. Slack cannot approve this governed action.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [record_ref],
        "state" => "waiting_for_event"
      }
    })
  end

  defp final_reply(message) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    })
  end

  defp terminal_run_state do
    %RunState{
      action_id: "nomad.alloc_restart",
      error_message: nil,
      operation_id: "operation-e2e",
      pack_ref: "nomad@1#sha256:abc",
      run_id: "run-e2e",
      run_url: "https://emisar.example/app/acme/runs/run-e2e",
      runner_ref: "production-runner",
      status: "success"
    }
  end

  defp executor_options(fake) do
    [
      api: FakeWorkCoopAPI,
      client: fake,
      lease_seconds: 60,
      max_block_ms: 1_000,
      max_polls: 20,
      monotonic_ms: fn -> 0 end,
      now: fn -> @now end,
      poll_interval_ms: 0,
      sleep: fn _milliseconds -> :ok end
    ]
  end
end
