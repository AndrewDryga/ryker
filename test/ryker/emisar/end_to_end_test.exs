defmodule Ryker.Emisar.EndToEndTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Delivery.Adapters

  alias Ryker.Emisar.{
    Approval,
    ApprovalDispatcher,
    ApprovalPresenter,
    Approvals,
    Review,
    RunState
  }

  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Slack.Publisher
  alias Ryker.State.{KnowledgeSnapshot, Record, Records}
  alias Ryker.StateTools.Tools
  alias Ryker.TestSupport.FakeWorkCoopAPI
  alias Ryker.Work.{Custody, DeliveryReceipt, Executor, Turn}

  @now ~U[2026-08-29 12:00:00.000000Z]
  @policy_digest String.duplicate("a", 64)
  @connection_ref "production"
  @environment_ref "production"

  setup do
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
          verified_at: @now
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

    :ok
  end

  defmodule EmisarAPI do
    def wait_for_run({test_pid, state}, run_id) do
      send(test_pid, {:wait_for_run, run_id})
      {:ok, state}
    end
  end

  defmodule SlackAPI do
    @behaviour Ryker.Slack.API

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

    # The fake model's approval record is constructed before Executor runs.
    # Normal execution exposes its frozen context before any tool call. Preserve
    # that ordering here; existing records cannot retroactively gain custody.
    assert :ok = KnowledgeSnapshot.expose(claim, [])

    assert {:ok, recorded} =
             Tools.call(
               "record_emisar_approval",
               approval_arguments(),
               binding: %{state_token: Records.token(claim.turn), session: claim.session}
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
               connection_ref: @connection_ref,
               lease_seconds: 60,
               poll_seconds: 5,
               presentation: adapters,
               presenter: Ryker.Emisar.ApprovalPresenter,
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

    approval = Approvals.get_by_request_id(@connection_ref, "apr-e2e")
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

    resumed
    |> Ecto.Changeset.change(updated_at: ~U[2000-01-01 00:00:00.000000Z])
    |> Repo.update!()

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

    assert Repo.aggregate(
             from(turn in Turn, where: turn.episode_id == ^first.episode.id),
             :count,
             :id
           ) ==
             2

    assert Enum.map(Episodes.list_events(first.episode.key), & &1.kind) == [
             :input_admitted,
             :result_accepted,
             :delivery_confirmed,
             :input_admitted,
             :wait_resumed,
             :result_accepted
           ]
  end

  test "the governed-review card repaints on a decision and not on the run's own progress" do
    claim = claim_episode!("approval-repaints")
    assert :ok = KnowledgeSnapshot.expose(claim, [])

    assert {:ok, recorded} =
             Tools.call(
               "record_emisar_approval",
               approval_arguments(),
               binding: %{state_token: Records.token(claim.turn), session: claim.session}
             )

    {:ok, fake} =
      FakeWorkCoopAPI.start_link([
        approval_reply(recorded["record_ref"]),
        final_reply("The governed action completed.")
      ])

    assert {:ok, first} = Executor.run(claim, executor_options(fake))
    assert first.status == :accepted
    assert first.turn.delivery_document["outcome"]["state"] == "waiting_for_event"
    assert {:ok, delivery} = Custody.claim_next("repaint-card-delivery", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               first.turn.delivery_ref,
               first.episode.destination_transport,
               first.episode.destination_conversation_ref,
               first.episode.destination_thread_ref,
               "1788019200.000200"
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
    {:ok, slack} = SlackAPI.start_link(self())

    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{workspaces: %{"TEC879C5EE335" => %{api: SlackAPI, client: slack}}},
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    approval = Approvals.get_by_request_id(@connection_ref, "apr-e2e")
    held = held_run_state(review(1, "pending"))

    # The first receipt is a change: the card gains the tally and the rationale.
    assert :ok = ApprovalPresenter.publish(approval, held, adapters)
    assert_receive {:approval_status_update, _, _, %{"emisar_approval_status" => shown}, _}
    assert shown["review"]["approved_count"] == 1

    approval = Approvals.get_by_request_id(@connection_ref, "apr-e2e")
    held = held_run_state(review(1, "pending"))

    # The first receipt is a change: the card gains the tally and the rationale.
    assert :ok = ApprovalPresenter.publish(approval, held, adapters)
    assert_receive {:approval_status_update, _, _, %{"emisar_approval_status" => shown}, _}
    assert shown["review"]["approved_count"] == 1

    assert {:ok, %{approval: observed}} =
             Approvals.observe(@connection_ref, "apr-e2e", lease!(), held, 5)

    assert observed.review_digest == Review.digest(held.review)

    # Emisar re-reporting the same review is not news, however often the monitor
    # polls it.
    assert :ok = ApprovalPresenter.publish(observed, held, adapters)
    refute_receive {:approval_status_update, _, _, _, _}

    # A decision is.
    released = %{held | status: "sent", review: review(2, "approved")}
    assert :ok = ApprovalPresenter.publish(observed, released, adapters)
    assert_receive {:approval_status_update, _, _, %{"emisar_approval_status" => decided}, _}
    assert decided["review"]["status"] == "approved"

    # Once that decision is on the card, the released run's own march through
    # execution changes nothing on it: execution belongs to the episode, not to
    # a stream of repaints of a settled review. (The monitor's next observation
    # is parked behind its poll interval, so the presented row is spelled out
    # rather than claimed a second time.)
    presented = %{observed | remote_status: "sent", review_digest: Review.digest(released.review)}

    for status <- ~w(running success) do
      assert :ok = ApprovalPresenter.publish(presented, %{released | status: status}, adapters)
      refute_receive {:approval_status_update, _, _, _, _}
    end
  end

  defp lease! do
    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "repaint-monitor", 60)

    lease_ref
  end

  defp held_run_state(review) do
    %{terminal_run_state() | status: "pending_approval", review: review}
  end

  defp review(approved_count, status) do
    decisions =
      Enum.take(
        [
          %{
            "actor" => "Jane Doe",
            "decision" => "approve",
            "decided_at" => "2026-09-11T08:07:23.379141Z"
          },
          %{
            "actor" => "Sam Reviewer",
            "decision" => "approve",
            "decided_at" => "2026-09-11T08:09:10.100000Z"
          }
        ],
        approved_count
      )

    %{
      "request_id" => "apr-e2e",
      "status" => status,
      "required_approvals" => 2,
      "approved_count" => approved_count,
      "argument_count" => 1,
      "reason" => "Restart the exact governed allocation and verify it.",
      "command" => %{
        "kind" => "preview",
        "text" => "nomad alloc restart 9f2c",
        "truncated" => false
      },
      "decisions" => decisions
    }
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

    assert {:ok, _session} =
             Custody.pin_episode(
               id,
               "work-read-only",
               @policy_digest,
               nil,
               nil,
               nil,
               nil,
               @environment_ref
             )

    Episode
    |> Repo.get!(id)
    |> Ecto.Changeset.change(updated_at: ~U[2000-01-01 00:00:00.000000Z])
    |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("emisar-e2e:#{suffix}", 60, :work)
    assert claim.episode.id == id
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
