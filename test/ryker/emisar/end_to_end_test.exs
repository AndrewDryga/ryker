defmodule Ryker.Emisar.EndToEndTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ryker.Delivery.Adapters
  alias Ryker.Emisar.{Approval, ApprovalDispatcher, ApprovalPresenter, Approvals, Review}
  alias Ryker.Emisar.RunState
  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Inspectors
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Slack.Publisher
  alias Ryker.StateTools.Tools
  alias Ryker.TestSupport.{FakeSlackAPI, FakeWorkCoopAPI}
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
    def wait_for_run({test_pid, state}, run_id, _wait_seconds) do
      send(test_pid, {:wait_for_run, run_id})
      {:ok, state}
    end

    def cancel_run({test_pid, state}, run_id, reason) do
      send(test_pid, {:cancel_run, run_id, reason})
      {:ok, state}
    end
  end

  test "a governed action waits for Emisar and resumes the same episode after the exact run terminates" do
    claim = claim_episode!("approval-lifecycle")

    # The fake model's approval record is constructed before Executor runs.
    # Normal execution exposes its frozen context before any tool call. Preserve
    # that ordering here; existing records cannot retroactively gain custody.
    assert KnowledgeSnapshot.expose(claim, []) == :ok

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

    {:ok, slack} = FakeSlackAPI.start_link(observer: self())

    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{workspaces: %{"TEC879C5EE335" => %{api: FakeSlackAPI, client: slack}}},
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    assert ApprovalDispatcher.run_once(
             api: EmisarAPI,
             client: {self(), terminal_run_state()},
             connection_ref: @connection_ref,
             lease_seconds: 60,
             poll_seconds: 5,
             presentation: adapters,
             presenter: Ryker.Emisar.ApprovalPresenter,
             retry_base_seconds: 2,
             retry_max_seconds: 60,
             wait_seconds: 20,
             worker_ref: "emisar-approval-monitor"
           ) == {:ok, {:resumed, "apr-e2e", "success"}}

    assert_receive {:wait_for_run, "run-e2e"}
    refresh!(adapters)
    assert_receive {:slack_posted, "C456", _, _, review_ref, message_ref}
    refute message_ref == "1788019200.000100"

    assert_receive {
      :slack_updated,
      "C456",
      ^message_ref,
      %{"emisar_approval_statuses" => [%{"status" => "success"} = status]},
      delivery_ref
    }

    assert status["run_id"] == "run-e2e"
    assert status["approval_url"] =~ "/approvals/apr-e2e"
    assert delivery_ref == review_ref
    assert review_ref == "emisar-review:#{first.turn.id}"

    approval = Inspectors.emisar_approval(@connection_ref, "apr-e2e")
    assert ApprovalPresenter.publish(approval, terminal_run_state(), adapters) == :ok
    refresh!(adapters)
    refute_receive {:slack_updated, _, _, _, _}

    changed = %{terminal_run_state() | error_message: "governed action failed", status: "failure"}

    # Presenter schedules only; unauthenticated supplied state never paints a card.
    assert ApprovalPresenter.publish(approval, changed, adapters) == :ok
    refresh!(adapters)
    refute_receive {:slack_updated, _, _, _, _}

    assert ApprovalPresenter.publish(:invalid, changed, adapters) ==
             {:error, {:invalid_emisar_approval_presentation, :arguments}}

    orphan = %Approval{
      episode_id: Ecto.UUID.generate(),
      record_id: Ecto.UUID.generate(),
      remote_status: "pending_approval"
    }

    assert ApprovalPresenter.publish(orphan, terminal_run_state(), adapters) ==
             {:error, :not_found}

    # A network blip, missing credentials or Slack's own rate limit while repainting the card were
    # permanent: the watch blocked, and the task never resumed after the review until a person
    # rearmed it (2026-10-04 review). What delivery retries, the card retries.
    for transient <- [
          {:delivery_rate_limited, 10, :provider_backoff},
          {:delivery_uncertain, :response_lost},
          {:slack_http_error, 503, "unavailable"},
          {:github_api_error, 502, "unavailable"},
          {:emisar_approval_presentation_unavailable, :offline},
          {:delivery_transport_unavailable, :closed},
          {:delivery_credentials_unavailable, :slack},
          {:slack_api_error, "ratelimited"},
          {:slack_api_error, "internal_error"}
        ] do
      refute ApprovalPresenter.permanent?(transient), inspect(transient)
    end

    assert ApprovalPresenter.permanent?(:invalid_destination)

    assert resumed = Inspectors.episode(first.episode.key)

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

    assert Enum.map(Inspectors.episode_events(first.episode.key), & &1.kind) == [
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
    assert KnowledgeSnapshot.expose(claim, []) == :ok

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
    {:ok, slack} = FakeSlackAPI.start_link(observer: self())

    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{workspaces: %{"TEC879C5EE335" => %{api: FakeSlackAPI, client: slack}}},
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    held = held_run_state(review(1, "pending"))

    assert {:ok, %{approval: observed}} =
             Approvals.observe(@connection_ref, "apr-e2e", lease!(), held, 5)

    refresh!(adapters)
    assert_receive {:slack_posted, _, _, _, _, review_message}

    assert_receive {:slack_updated, _, ^review_message, %{"emisar_approval_statuses" => [shown]},
                    _}

    assert shown["review"]["approved_count"] == 1
    assert observed.review_digest == Review.digest(held.review)

    assert ApprovalPresenter.publish(observed, held, adapters) == :ok
    refresh!(adapters)
    refute_receive {:slack_updated, _, _, _, _}

    released = %{held | status: "sent", review: review(2, "approved")}
    Repo.update_all(Approval.Query.by_id(observed.id), set: [next_attempt_at: Repo.now!()])
    assert {:ok, _} = Approvals.observe(@connection_ref, "apr-e2e", lease!(), released, 5)
    refresh!(adapters)

    assert_receive {:slack_updated, _, ^review_message,
                    %{"emisar_approval_statuses" => [decided]}, _}

    assert decided["review"]["status"] == "approved"

    Repo.update_all(Approval.Query.by_id(observed.id), set: [next_attempt_at: Repo.now!()])

    assert {:ok, _} =
             Approvals.observe(
               @connection_ref,
               "apr-e2e",
               lease!(),
               %{released | status: "running"},
               5
             )

    refresh!(adapters)
    refute_receive {:slack_updated, _, _, _, _}
  end

  # Production asked for the same inspection on two instances in one reply
  # (2026-10-08). Each approval's update drew only its own card over the whole
  # message, so the other approval went from it, and the message showed only
  # whichever approval had changed last.
  test "an update of one approval keeps the other approvals of its reply on the message" do
    claim = claim_episode!("two-approvals")
    assert KnowledgeSnapshot.expose(claim, []) == :ok
    binding = %{state_token: Records.token(claim.turn), session: claim.session}

    refs =
      for id <- ["web-1", "web-2"] do
        assert {:ok, recorded} =
                 Tools.call("record_emisar_approval", approval_arguments(id), binding: binding)

        recorded["record_ref"]
      end

    {:ok, fake} =
      FakeWorkCoopAPI.start_link([approval_reply(refs), final_reply("Both inspections ran.")])

    assert {:ok, %{status: :accepted} = first} = Executor.run(claim, executor_options(fake))
    deliver!(first, "1788019200.000300")
    adapters = slack_adapters!()

    web_1_seen = held_state("web-1", review(1, "pending", "apr-web-1"))

    assert {:ok, %{approval: %{request_id: "apr-web-1"}, lease_ref: lease}} =
             Approvals.claim_next(@connection_ref, "two-approvals-monitor", 60)

    assert {:ok, _} = Approvals.observe(@connection_ref, "apr-web-1", lease, web_1_seen, 5)
    refresh!(adapters)
    assert_receive {:slack_posted, _, _, _, _, review_message}
    refute review_message == "1788019200.000300"
    assert_receive {:slack_updated, _, ^review_message, update, _}
    assert %{"emisar_approval_statuses" => [one, two]} = update
    assert {one["request_id"], one["review"]["approved_count"]} == {"apr-web-1", 1}
    assert {two["request_id"], two["review"]} == {"apr-web-2", nil}
    web_2_seen = held_state("web-2", review(0, "pending", "apr-web-2"))

    assert {:ok, %{approval: %{request_id: "apr-web-2"}, lease_ref: lease}} =
             Approvals.claim_next(@connection_ref, "two-approvals-monitor", 60)

    assert {:ok, _} = Approvals.observe(@connection_ref, "apr-web-2", lease, web_2_seen, 5)
    refresh!(adapters)
    assert_receive {:slack_updated, _, ^review_message, update, _}
    assert %{"emisar_approval_statuses" => [one, two]} = update
    assert {one["request_id"], one["review"]["approved_count"]} == {"apr-web-1", 1}
    assert {two["request_id"], two["review"]["approved_count"]} == {"apr-web-2", 0}
  end

  test "a lost post response is reconciled and repainted with the latest review" do
    # Slack can accept a post and lose its answer. A changed decision before
    # retry must repaint that same message before acknowledging its fingerprint.
    claim = claim_episode!("review-response-loss")
    assert KnowledgeSnapshot.expose(claim, []) == :ok

    assert {:ok, _} =
             Tools.call("record_emisar_approval", approval_arguments(),
               binding: %{state_token: Records.token(claim.turn), session: claim.session}
             )

    {:ok, slack} = FakeSlackAPI.start_link(observer: self(), lose: [:post_message])
    adapters = adapters_for!(slack)

    assert Ryker.Emisar.ApprovalMessageWorker.run_once(message_options(adapters)) ==
             {:ok, :deferred}

    assert_receive {:slack_posted, _, _, _, _, original_message}
    held = held_run_state(review(1, "pending"))
    assert {:ok, _} = Approvals.observe(@connection_ref, "apr-e2e", lease!(), held, 5)

    Repo.update_all(Ryker.Emisar.ApprovalMessage.Query.by_turn_id(claim.turn.id),
      set: [next_attempt_at: Repo.now!()]
    )

    refresh!(adapters)

    assert_receive {:slack_updated, _, ^original_message,
                    %{"emisar_approval_statuses" => [shown]}, _}

    assert shown["review"]["approved_count"] == 1
    refute_receive {:slack_posted, _, _, _, _, _}
    assert length(FakeSlackAPI.state(slack).posts) == 1
  end

  test "a deleted claimed message loses its lease without crashing completion" do
    claim = claim_episode!("review-lease-lost")
    assert KnowledgeSnapshot.expose(claim, []) == :ok

    assert {:ok, _} =
             Tools.call("record_emisar_approval", approval_arguments(),
               binding: %{state_token: Records.token(claim.turn), session: claim.session}
             )

    assert {:ok, message} =
             Ryker.Emisar.ApprovalMessages.claim_next(@connection_ref, "review-deleted", 60)

    assert {:ok, request} = Ryker.Emisar.ApprovalMessages.request(message)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               request.ref,
               request.transport,
               request.conversation_ref,
               request.thread_ref,
               "1788019200.000900"
             )

    Repo.delete!(message)

    assert Ryker.Emisar.ApprovalMessages.mark(message, request, receipt) ==
             {:error, :emisar_approval_message_lease_lost}
  end

  test "a review message honors Slack's retry-after without blocking run observation" do
    claim = claim_episode!("review-rate-limit")
    assert KnowledgeSnapshot.expose(claim, []) == :ok

    assert {:ok, _} =
             Tools.call("record_emisar_approval", approval_arguments(),
               binding: %{state_token: Records.token(claim.turn), session: claim.session}
             )

    ref = "emisar-review:#{claim.turn.id}"

    {:ok, slack} =
      FakeSlackAPI.start_link(
        observer: self(),
        refuse: %{ref => {:delivery_rate_limited, 90, :provider_backoff}}
      )

    adapters = adapters_for!(slack)
    before = Repo.now!()

    assert Ryker.Emisar.ApprovalMessageWorker.run_once(message_options(adapters)) ==
             {:ok, :deferred}

    message = Repo.fetch!(Ryker.Emisar.ApprovalMessage.Query.by_turn_id(claim.turn.id))
    assert DateTime.diff(message.next_attempt_at, before) >= 90

    assert {:ok, %{status: :resumed}} =
             Approvals.observe(@connection_ref, "apr-e2e", lease!(), terminal_run_state(), 5)

    assert Ryker.Emisar.ApprovalMessageWorker.run_once(message_options(adapters)) == {:ok, :idle}
  end

  test "withdrawn producer custody neutralizes even an answered review" do
    claim = claim_episode!("review-source-withdrawal")
    assert KnowledgeSnapshot.expose(claim, []) == :ok

    assert {:ok, _} =
             Tools.call("record_emisar_approval", approval_arguments(),
               binding: %{state_token: Records.token(claim.turn), session: claim.session}
             )

    {:ok, slack} = FakeSlackAPI.start_link(observer: self())
    adapters = adapters_for!(slack)
    refresh!(adapters)
    assert_receive {:slack_posted, _, _, _, _, original_message}
    assert_receive {:slack_updated, _, ^original_message, _, _}

    assert {:ok, _} =
             Approvals.observe(@connection_ref, "apr-e2e", lease!(), terminal_run_state(), 5)

    Repo.update_all(Ryker.Work.Session.Query.by_id(claim.session.id),
      set: [source_exposure_count: 1]
    )

    refresh!(adapters)
    assert_receive {:slack_updated, _, ^original_message, %{"message" => neutral}, _}
    assert neutral =~ "unavailable"
    refute neutral =~ "emisar.example"
  end

  defp adapters_for!(slack) do
    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{workspaces: %{"TEC879C5EE335" => %{api: FakeSlackAPI, client: slack}}},
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    adapters
  end

  defp message_options(adapters),
    do: %{
      connection_ref: @connection_ref,
      worker_ref: "review-message-test",
      lease_seconds: 60,
      presentation: adapters,
      retry_base_seconds: 1,
      retry_max_seconds: 60
    }

  defp refresh!(adapters) do
    assert Ryker.Emisar.ApprovalMessageWorker.run_once(message_options(adapters)) ==
             {:ok, :updated}
  end

  defp deliver!(result, message_ref) do
    assert {:ok, delivery} = Custody.claim_next("#{message_ref}-delivery", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               result.turn.delivery_ref,
               result.episode.destination_transport,
               result.episode.destination_conversation_ref,
               result.episode.destination_thread_ref,
               message_ref
             )

    assert {:ok, _delivered} =
             Custody.confirm_delivery(
               result.episode.id,
               result.episode.key,
               result.turn.turn_ref,
               delivery.lease_ref,
               receipt
             )
  end

  defp slack_adapters! do
    {:ok, slack} = FakeSlackAPI.start_link(observer: self())

    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{workspaces: %{"TEC879C5EE335" => %{api: FakeSlackAPI, client: slack}}},
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    adapters
  end

  defp lease! do
    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "repaint-monitor", 60)

    lease_ref
  end

  defp held_state(id, review) do
    %RunState{
      action_id: "nomad.alloc_restart",
      error_message: nil,
      operation_id: "operation-#{id}",
      pack_ref: "nomad@1#sha256:abc",
      review: review,
      run_id: "run-#{id}",
      run_url: "https://emisar.example/app/acme/runs/run-#{id}",
      runner_ref: id,
      status: "pending_approval"
    }
  end

  defp held_run_state(review) do
    %{terminal_run_state() | status: "pending_approval", review: review}
  end

  defp review(approved_count, status, request_id \\ "apr-e2e") do
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
      "request_id" => request_id,
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
             WorkSessions.pin_episode(id, "work-read-only", @policy_digest,
               environment_ref: @environment_ref
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

  # An approval per runner `id`, which also names its request, run and operation.
  defp approval_arguments(id) do
    %{
      approval_arguments()
      | "approval_url" => "https://emisar.example/app/acme/approvals/apr-#{id}",
        "operation_id" => "operation-#{id}",
        "request_id" => "apr-#{id}",
        "run_id" => "run-#{id}",
        "runner_ref" => id
    }
  end

  defp approval_reply(record_refs) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "Approval is required in Emisar. Slack cannot approve this governed action.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => List.wrap(record_refs),
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
      poll_interval_ms: 0,
      sleep: fn _milliseconds -> :ok end
    ]
  end
end
