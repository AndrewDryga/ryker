defmodule Responder.Delivery.DispatcherTest do
  use Responder.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureIO

  @moduletag isolation: "REPEATABLE READ"

  alias Mix.Tasks.Responder.Delivery, as: DeliveryTask
  alias Responder.Admission
  alias Responder.Admission.Decision
  alias Responder.Artifacts.Outputs

  alias Responder.Delivery.{
    Adapters,
    Dispatcher,
    Operator,
    PlatformActionCustody,
    ReactionCustody
  }

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.Slack.Input
  alias Responder.State.Records
  alias Responder.Work.{Custody, DeliveryReceipt, Result, Submission, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]

  defmodule Publisher do
    @behaviour Responder.Delivery.Platform
    @behaviour Responder.Delivery.MessagePublisher
    @behaviour Responder.Delivery.ReactionPublisher

    alias Responder.Work.DeliveryReceipt

    @impl true
    def transport, do: "slack"

    @impl true
    def publish_message(request, agent), do: publish(:message, request, agent)

    @impl true
    def publish_reaction(request, agent), do: publish(:reaction, request, agent)

    defp publish(kind, request, agent) do
      Agent.get_and_update(agent, fn state ->
        calls = [{kind, request} | state.calls]

        case state.responses do
          [{:error, reason} | remaining] ->
            {{:error, reason}, %{state | calls: calls, responses: remaining}}

          [:crossed | remaining] ->
            {:ok, receipt} =
              DeliveryReceipt.new(
                request.ref,
                request.transport,
                "slack:T123:C999",
                request.thread_ref,
                request.source_item_ref || "1787832999.000999"
              )

            {{:ok, receipt}, %{state | calls: calls, responses: remaining}}

          responses ->
            message_ref = request.source_item_ref || "1787832999.000999"

            {:ok, receipt} =
              DeliveryReceipt.new(
                request.ref,
                request.transport,
                request.conversation_ref,
                request.thread_ref,
                message_ref
              )

            {{:ok, receipt}, %{state | calls: calls, responses: responses}}
        end
      end)
    end
  end

  defmodule BlockingPublisher do
    @behaviour Responder.Delivery.Platform
    @behaviour Responder.Delivery.MessagePublisher
    @behaviour Responder.Delivery.ReactionPublisher

    alias Responder.Work.DeliveryReceipt

    @impl true
    def transport, do: "slack"

    @impl true
    def publish_message(request, %{observer: observer}) do
      send(observer, {:delivery_publish_started, self()})

      receive do
        :finish_delivery_publish ->
          DeliveryReceipt.new(
            request.ref,
            request.transport,
            request.conversation_ref,
            request.thread_ref,
            "1787832999.000999"
          )
      end
    end

    @impl true
    def publish_reaction(request, binding), do: publish_message(request, binding)
  end

  defmodule ThrowingPublisher do
    @behaviour Responder.Delivery.Platform
    @behaviour Responder.Delivery.MessagePublisher
    @behaviour Responder.Delivery.ReactionPublisher

    @impl true
    def transport, do: "slack"

    @impl true
    def publish_message(_request, _binding), do: throw(:provider_bug)

    @impl true
    def publish_reaction(request, binding), do: publish_message(request, binding)
  end

  defmodule ExitingPublisher do
    @behaviour Responder.Delivery.Platform
    @behaviour Responder.Delivery.MessagePublisher
    @behaviour Responder.Delivery.ReactionPublisher

    @impl true
    def transport, do: "slack"

    @impl true
    def publish_message(_request, _binding), do: Process.exit(self(), :kill)

    @impl true
    def publish_reaction(request, binding), do: publish_message(request, binding)
  end

  test "a Work reply is published from its frozen destination and settles atomically" do
    accepted = delivery_pending!("message")
    {:ok, publisher} = Agent.start_link(fn -> %{calls: [], responses: []} end)

    assert {:ok, {:delivered, :message, delivery_ref}} =
             Dispatcher.run_once(dispatcher_options(:message, publisher))

    assert delivery_ref == accepted.turn.delivery_ref

    settled = Repo.get!(Turn, accepted.turn.id)
    assert settled.status == :settled
    assert settled.external_receipt["delivery_ref"] == accepted.turn.delivery_ref

    assert [{:message, request}] = Agent.get(publisher, &Enum.reverse(&1.calls))
    assert request.document == %{"message" => "Finished from generic delivery."}
    assert request.transport == "slack"
    assert request.conversation_ref == "slack:T123:C456"
    assert request.thread_ref == "1787832000.000100"
    assert request.source_item_ref == nil
  end

  test "a cited task offer is materialized from the owning episode for platform rendering" do
    task = %{
      "kind" => "engineering",
      "prompt" => "Change the parser and run focused tests.",
      "repository" => "responder",
      "title" => "Fix parser retries"
    }

    accepted = delivery_pending!("task-offer", task_offer: task)
    {:ok, publisher} = Agent.start_link(fn -> %{calls: [], responses: []} end)

    assert {:ok, {:delivered, :message, _delivery_ref}} =
             Dispatcher.run_once(dispatcher_options(:message, publisher))

    assert [{:message, request}] = Agent.get(publisher, &Enum.reverse(&1.calls))

    assert request.document == %{
             "message" => "Finished from generic delivery.",
             "records" => [
               %{
                 "kind" => "task_offer",
                 "payload" => task,
                 "ref" => accepted.record.ref,
                 "status" => "open"
               }
             ]
           }
  end

  test "an accepted generated image reaches the publisher as verified bytes" do
    data = <<137, 80, 78, 71, 13, 10, 26, 10, "delivery-chart">>
    sha256 = digest(data)
    ref = "artifact_#{binary_part(sha256, 0, 24)}"

    artifact = %{
      "bytes" => byte_size(data),
      "data" => data,
      "id" => ref,
      "media_type" => "image/png",
      "name" => "delivery-chart.png",
      "sha256" => sha256
    }

    accepted = delivery_pending!("artifact", output_artifact: artifact)
    {:ok, publisher} = Agent.start_link(fn -> %{calls: [], responses: []} end)

    assert {:ok, {:delivered, :message, _delivery_ref}} =
             Dispatcher.run_once(dispatcher_options(:message, publisher))

    assert [{:message, request}] = Agent.get(publisher, &Enum.reverse(&1.calls))

    assert [published] = request.artifacts
    assert published["ref"] == ref
    assert published["data"] == data
    assert published["sha256"] == sha256
    assert request.document["message"] == "Finished from generic delivery."
    assert accepted.turn.delivery_document["outcome"]["artifact_refs"] == [ref]
  end

  test "a reaction provider failure releases custody and retries the same immutable intent" do
    pending = reaction_pending!("reaction-retry", "rocket")

    {:ok, publisher} =
      Agent.start_link(fn ->
        %{calls: [], responses: [{:error, {:delivery_uncertain, :closed}}]}
      end)

    assert {:ok, {:deferred, :reaction, delivery_ref, {:delivery_uncertain, :closed}}} =
             Dispatcher.run_once(dispatcher_options(:reaction, publisher))

    assert delivery_ref == pending.delivery_ref
    assert {:ok, deferred} = ReactionCustody.fetch_by_input(pending.input_id)
    assert deferred.status == :pending
    assert deferred.lease_ref == nil
    assert deferred.attempt_count == 1
    assert deferred.last_error_code == "delivery_uncertain"

    Repo.update_all(Responder.Delivery.Reaction, set: [next_attempt_at: @now])

    assert {:ok, {:delivered, :reaction, ^delivery_ref}} =
             Dispatcher.run_once(dispatcher_options(:reaction, publisher))

    assert {:ok, delivered} = ReactionCustody.fetch_by_input(pending.input_id)
    assert delivered.status == :delivered
    assert delivered.attempt_count == 2

    calls = Agent.get(publisher, &Enum.reverse(&1.calls))
    assert [{:reaction, first}, {:reaction, second}] = calls
    assert first == second
    assert first.document == %{"emoji_name" => "rocket"}
    assert first.source_item_ref == "1787832001.000200"
  end

  test "a model-requested platform action is published from its immutable outbox intent" do
    pending = platform_action_pending!("action-delivery")
    {:ok, publisher} = Agent.start_link(fn -> %{calls: [], responses: []} end)

    assert {:ok, {:delivered, :action, action_ref}} =
             Dispatcher.run_once(dispatcher_options(:action, publisher))

    assert action_ref == pending.action_ref
    assert [{:reaction, request}] = Agent.get(publisher, &Enum.reverse(&1.calls))
    assert request.ref == action_ref
    assert request.document == %{"action" => "add", "emoji_name" => "eyes"}

    assert {:ok, delivered} = PlatformActionCustody.fetch(action_ref)
    assert delivered.status == :delivered
    assert delivered.external_receipt["delivery_ref"] == action_ref
  end

  test "a blocked model-requested action is visible and rearmed through delivery recovery" do
    pending = platform_action_pending!("action-recovery")

    {:ok, publisher} =
      Agent.start_link(fn ->
        %{calls: [], responses: [{:error, {:slack_api_error, "missing_scope"}}]}
      end)

    assert {:ok, {:blocked, :action, action_ref, {:slack_api_error, "missing_scope"}}} =
             Dispatcher.run_once(dispatcher_options(:action, publisher))

    assert action_ref == pending.action_ref

    assert {:ok,
            %{
              delivery_ref: ^action_ref,
              kind: :platform_action,
              status: :blocked,
              tool: :set_slack_reaction
            }} = Operator.fetch(action_ref)

    assert {:ok, blocked} = Operator.list_blocked()
    assert Enum.any?(blocked, &(&1.delivery_ref == action_ref and &1.kind == :platform_action))

    assert {:ok, %{status: :pending, retry_generation: 1}} = Operator.rearm(action_ref)
  end

  test "a publisher receipt for another destination never settles this intent" do
    accepted = delivery_pending!("crossed")
    {:ok, publisher} = Agent.start_link(fn -> %{calls: [], responses: [:crossed]} end)

    assert {:ok, {:blocked, :message, delivery_ref, :work_delivery_destination_mismatch}} =
             Dispatcher.run_once(dispatcher_options(:message, publisher))

    assert delivery_ref == accepted.turn.delivery_ref
    blocked = Repo.get!(Turn, accepted.turn.id)
    assert blocked.status == :blocked
    assert blocked.lease_ref == nil
    assert blocked.external_receipt == nil
    assert blocked.last_error_code == "work_delivery_destination_mismatch"
  end

  test "a permanent message error is durably blocked until an operator rearms the intent" do
    accepted = delivery_pending!("permanent-message-error")

    {:ok, publisher} =
      Agent.start_link(fn ->
        %{calls: [], responses: [{:error, {:slack_api_error, "missing_scope"}}]}
      end)

    assert {:ok, {:blocked, :message, delivery_ref, {:slack_api_error, "missing_scope"}}} =
             Dispatcher.run_once(dispatcher_options(:message, publisher))

    assert delivery_ref == accepted.turn.delivery_ref
    blocked = Repo.get!(Turn, accepted.turn.id)
    assert blocked.status == :blocked
    assert blocked.lease_ref == nil
    assert blocked.last_error_code == "slack_api_error"
    assert blocked.delivery_attempt_count == 1
    assert blocked.delivery_retry_generation == 0
    assert {:ok, :idle} = Dispatcher.run_once(dispatcher_options(:message, publisher))

    assert {:ok, [listed]} = Operator.list_blocked()
    assert listed.delivery_ref == delivery_ref
    assert listed.episode_id == accepted.episode.id
    assert listed.turn_ref == accepted.turn.turn_ref

    listed_output =
      capture_io(fn -> DeliveryTask.run(["list"]) end)
      |> Jason.decode!()

    assert [%{"delivery_ref" => ^delivery_ref, "status" => "blocked"}] = listed_output

    shown =
      capture_io(fn -> DeliveryTask.run(["show", delivery_ref]) end)
      |> Jason.decode!()

    assert shown["delivery_ref"] == delivery_ref
    assert shown["status"] == "blocked"

    rearmed =
      capture_io(fn -> DeliveryTask.run(["rearm", delivery_ref]) end)
      |> Jason.decode!()

    assert rearmed["status"] == "delivery_pending"
    assert rearmed["attempt_count"] == 0
    assert rearmed["retry_generation"] == 1

    Agent.update(publisher, fn state ->
      %{state | responses: [{:error, {:delivery_transport_unavailable, :closed}}]}
    end)

    assert {:ok, {:deferred, :message, ^delivery_ref, {:delivery_transport_unavailable, :closed}}} =
             Dispatcher.run_once(dispatcher_options(:message, publisher))

    turn_id = accepted.turn.id

    Repo.update_all(
      from(turn in Turn, where: turn.id == ^turn_id),
      set: [next_attempt_at: @now]
    )

    assert {:ok, {:delivered, :message, ^delivery_ref}} =
             Dispatcher.run_once(dispatcher_options(:message, publisher))
  end

  test "the delivery operator command rejects unknown refs and malformed invocations" do
    assert_raise Mix.Error, ~r/delivery_not_found/, fn ->
      DeliveryTask.run(["show", "delivery:missing"])
    end

    assert_raise Mix.Error, ~r/usage: mix responder.delivery/, fn ->
      DeliveryTask.run(["invalid"])
    end
  end

  test "a transient message failure releases the exact delivery for retry" do
    accepted = delivery_pending!("transient-message-error")

    {:ok, publisher} =
      Agent.start_link(fn ->
        %{calls: [], responses: [{:error, {:github_api_error, 503, "unavailable"}}]}
      end)

    assert {:ok, {:deferred, :message, delivery_ref, {:github_api_error, 503, "unavailable"}}} =
             Dispatcher.run_once(dispatcher_options(:message, publisher))

    assert delivery_ref == accepted.turn.delivery_ref
    deferred = Repo.get!(Turn, accepted.turn.id)
    assert deferred.status == :delivery_pending
    assert deferred.lease_ref == nil
    assert deferred.last_error_code == "github_api_error"
  end

  test "provider rate-limit timing outranks generic retry backoff" do
    accepted = delivery_pending!("provider-rate-limit")
    before = DateTime.utc_now()

    error =
      {:delivery_rate_limited, 45,
       {:github_api_error, 403, %{"message" => "API rate limit exceeded"}}}

    {:ok, publisher} =
      Agent.start_link(fn -> %{calls: [], responses: [{:error, error}]} end)

    assert {:ok, {:deferred, :message, delivery_ref, ^error}} =
             Dispatcher.run_once(
               dispatcher_options(:message, publisher, Publisher,
                 retry_base_seconds: 1,
                 retry_max_seconds: 2
               )
             )

    assert delivery_ref == accepted.turn.delivery_ref
    deferred = Repo.get!(Turn, accepted.turn.id)
    assert DateTime.diff(deferred.next_attempt_at, before, :second) in 44..46
  end

  test "an ordinary GitHub forbidden response is blocked instead of retried as a rate limit" do
    accepted = delivery_pending!("github-forbidden")
    error = {:github_api_error, 403, %{"message" => "Resource not accessible"}}
    {:ok, publisher} = Agent.start_link(fn -> %{calls: [], responses: [{:error, error}]} end)

    assert {:ok, {:blocked, :message, delivery_ref, ^error}} =
             Dispatcher.run_once(dispatcher_options(:message, publisher))

    assert delivery_ref == accepted.turn.delivery_ref
    assert Repo.get!(Turn, accepted.turn.id).status == :blocked
  end

  test "publisher throws and untrappable exits are contained as retryable delivery failures" do
    thrown = delivery_pending!("throwing-publisher")

    assert {:ok,
            {:deferred, :message, thrown_ref,
             {:delivery_publisher_crashed, :throw, :provider_bug}}} =
             Dispatcher.run_once(
               dispatcher_options(:message, :trusted, ThrowingPublisher,
                 worker_ref: "delivery:message:throwing"
               )
             )

    assert thrown_ref == thrown.turn.delivery_ref

    exited = delivery_pending!("exiting-publisher")

    assert {:ok, {:deferred, :message, exited_ref, {:delivery_publisher_exit, :killed}}} =
             Dispatcher.run_once(
               dispatcher_options(:message, :trusted, ExitingPublisher,
                 worker_ref: "delivery:message:exiting"
               )
             )

    assert exited_ref == exited.turn.delivery_ref
  end

  test "a malformed durable message is blocked before any platform call" do
    accepted = delivery_pending!("malformed-message")
    turn_id = accepted.turn.id

    Repo.update_all(
      from(turn in Turn, where: turn.id == ^turn_id),
      set: [delivery_document: %{"unexpected" => true}]
    )

    {:ok, publisher} = Agent.start_link(fn -> %{calls: [], responses: []} end)

    assert {:ok, {:blocked, :message, delivery_ref, {:invalid_delivery_message, :document}}} =
             Dispatcher.run_once(dispatcher_options(:message, publisher))

    assert delivery_ref == accepted.turn.delivery_ref
    assert Agent.get(publisher, & &1.calls) == []
    assert Repo.get!(Turn, accepted.turn.id).status == :blocked
  end

  test "a transient reaction stops at the configured attempt bound and can be rearmed" do
    pending = reaction_pending!("reaction-attempt-bound", "eyes")

    {:ok, publisher} =
      Agent.start_link(fn ->
        %{calls: [], responses: [{:error, {:delivery_transport_unavailable, :closed}}]}
      end)

    options = dispatcher_options(:reaction, publisher, Publisher, max_attempts: 1)

    assert {:ok, {:blocked, :reaction, delivery_ref, {:delivery_transport_unavailable, :closed}}} =
             Dispatcher.run_once(options)

    assert delivery_ref == pending.delivery_ref
    assert {:ok, blocked} = ReactionCustody.fetch_by_input(pending.input_id)
    assert blocked.status == :blocked
    assert {:ok, :idle} = Dispatcher.run_once(options)

    assert {:ok, rearmed} = Operator.rearm(delivery_ref)
    assert rearmed.status == :pending
    assert rearmed.attempt_count == 0
    assert rearmed.retry_generation == 1
    assert {:ok, {:delivered, :reaction, ^delivery_ref}} = Dispatcher.run_once(options)
  end

  test "each delivery phase is independently idle" do
    {:ok, publisher} = Agent.start_link(fn -> %{calls: [], responses: []} end)

    assert {:ok, :idle} = Dispatcher.run_once(dispatcher_options(:message, publisher))
    assert {:ok, :idle} = Dispatcher.run_once(dispatcher_options(:reaction, publisher))
    assert {:ok, :idle} = Dispatcher.run_once(dispatcher_options(:action, publisher))
  end

  test "a slow provider call renews custody before a second worker can reclaim it" do
    accepted = delivery_pending!("slow-provider")
    test_pid = self()

    observer =
      spawn_link(fn ->
        receive do
          {:delivery_publish_started, publisher_pid} ->
            Process.sleep(1_200)

            competing =
              Custody.claim_next("delivery:message:competing", 1, :delivery)

            send(test_pid, {:competing_delivery_claim, competing})
            send(publisher_pid, :finish_delivery_publish)
        end
      end)

    options =
      dispatcher_options(
        :message,
        %{observer: observer},
        BlockingPublisher,
        lease_seconds: 1
      )

    assert {:ok, {:delivered, :message, delivery_ref}} = Dispatcher.run_once(options)
    assert delivery_ref == accepted.turn.delivery_ref
    assert_receive {:competing_delivery_claim, {:ok, nil}}
  end

  test "dispatcher death terminates its provider before another worker reclaims delivery" do
    accepted = delivery_pending!("dispatcher-crash")
    test_pid = self()

    task =
      Task.async(fn ->
        Dispatcher.run_once(
          dispatcher_options(
            :message,
            %{observer: test_pid},
            BlockingPublisher,
            lease_seconds: 60,
            worker_ref: "delivery:message:crashing"
          )
        )
      end)

    assert_receive {:delivery_publish_started, provider}, 1_000
    provider_monitor = Process.monitor(provider)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :killed}, 1_000

    turn_id = accepted.turn.id

    Repo.update_all(
      from(turn in Turn, where: turn.id == ^turn_id),
      set: [lease_expires_at: @now]
    )

    {:ok, publisher} = Agent.start_link(fn -> %{calls: [], responses: []} end)

    assert {:ok, {:delivered, :message, delivery_ref}} =
             Dispatcher.run_once(
               dispatcher_options(:message, publisher, Publisher,
                 worker_ref: "delivery:message:reclaimed"
               )
             )

    assert delivery_ref == accepted.turn.delivery_ref
    assert [{:message, _request}] = Agent.get(publisher, & &1.calls)
  end

  test "malformed dispatcher settings cannot claim delivery custody" do
    invalid = [
      :invalid,
      [],
      [adapters: %{}, kind: :reaction, worker_ref: "delivery:test"],
      [adapters: %{"slack" => %{}}, kind: :unknown, worker_ref: "delivery:test"],
      [
        adapters: %{"slack" => %{}},
        kind: :message,
        retry_base_seconds: 2,
        retry_max_seconds: 1,
        worker_ref: "delivery:test"
      ]
    ]

    Enum.each(invalid, fn options ->
      assert {:error, {:invalid_delivery_dispatcher, _field}} = Dispatcher.run_once(options)
    end)
  end

  defp dispatcher_options(kind, binding, publisher_module \\ Publisher, overrides \\ []) do
    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: binding,
                 message_publisher: publisher_module,
                 reaction_publisher: publisher_module
               }
             })

    Keyword.merge(
      [
        adapters: adapters,
        kind: kind,
        lease_seconds: 60,
        retry_base_seconds: 1,
        retry_max_seconds: 60,
        worker_ref: "delivery:#{kind}:worker"
      ],
      overrides
    )
  end

  defp delivery_pending!(suffix, options \\ []) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: "slack:T123:C456",
          thread_ref: "1787832000.000100",
          transport: "slack"
        },
        episode_id: id,
        episode_key: "delivery-dispatcher:#{suffix}:#{id}",
        native_input_id: "slack-message:#{suffix}:#{id}",
        occurred_at: @now,
        turn_ref: "turn:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)
    assert {:ok, _session} = Custody.pin_episode(id, "work-read-only", String.duplicate("a", 64))
    assert {:ok, claim} = Custody.claim_next("work:prepare:#{suffix}", 60, :work)

    record =
      case Keyword.fetch(options, :task_offer) do
        {:ok, payload} ->
          assert {:ok, record} =
                   Records.create(Records.token(claim.turn), "task-offer", "task_offer", payload)

          record

        :error ->
          nil
      end

    output_artifact = Keyword.get(options, :output_artifact)

    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => id},
               "Handle the frozen episode.",
               %{"type" => "object"},
               "work-final-v1"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(id, claim.turn.turn_ref, claim.lease_ref, submission)

    assert {:ok, session} =
             Custody.bind_session(
               id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:delivery:#{suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:delivery:#{suffix}"
             )

    artifact_refs =
      case output_artifact do
        nil ->
          []

        artifact ->
          assert {:ok, [_stored]} = Outputs.put_many(turn.id, [artifact])
          [artifact["id"]]
      end

    candidate = ~s({"delivery":"reply","message":"Finished from generic delivery."})
    candidate_sha256 = digest(candidate)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               id,
               turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               candidate_sha256,
               1
             )

    record_refs = if record, do: [record.ref], else: []

    delivery_document =
      case {record_refs, artifact_refs} do
        {[], []} ->
          %{"message" => "Finished from generic delivery."}

        _with_references ->
          %{
            "decision_reason" => nil,
            "delivery" => "reply",
            "message" => "Finished from generic delivery.",
            "outcome" => %{
              "artifact_refs" => artifact_refs,
              "record_refs" => record_refs,
              "state" => "complete"
            }
          }
      end

    assert {:ok, result} = Result.new(:reply, delivery_document)

    assert {:ok, _turn} =
             Custody.prepare_validation(
               id,
               turn.turn_ref,
               claim.lease_ref,
               candidate_sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               id,
               command.episode_key,
               turn.turn_ref,
               claim.lease_ref,
               candidate_sha256,
               1,
               "validation-receipt:#{suffix}"
             )

    Map.put(accepted, :record, record)
  end

  defp reaction_pending!(suffix, emoji_name) do
    event_ref = "Ev-#{suffix}"

    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Acknowledge this."},
               event_kind: :message,
               event_ref: event_ref,
               message_ref: "1787832001.000200",
               occurred_at: @now,
               revision: 1,
               thread_ref: "1787832000.000100",
               workspace_ref: "T123"
             })

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
               "action" => "react",
               "episode_ref" => nil,
               "reaction" => %{"emoji_name" => emoji_name},
               "relation" => "unrelated",
               "reason" => "Acknowledge without starting an episode."
             })

    assert {:ok, _result} = Admission.commit(context, decision, "decision:#{suffix}")
    assert {:ok, pending} = ReactionCustody.fetch_by_input(entry.id)
    pending
  end

  defp platform_action_pending!(suffix) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: "slack:T123:C456",
          thread_ref: "1787832000.000100",
          transport: "slack"
        },
        episode_id: id,
        episode_key: "platform-action-dispatcher:#{suffix}:#{id}",
        native_input_id: "platform-action-dispatcher:input:#{suffix}:#{id}",
        occurred_at: @now,
        turn_ref: "platform-action-dispatcher:turn:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)
    assert {:ok, _session} = Custody.pin_episode(id, "work-read-only", String.duplicate("a", 64))
    assert {:ok, claim} = Custody.claim_next("work:platform-action:#{suffix}", 60, :work)

    assert {:ok, %{action: action, status: :created}} =
             PlatformActionCustody.enqueue(claim, %{
               conversation_ref: "slack:T123:C456",
               document: %{"action" => "add", "emoji_name" => "eyes"},
               host_slot: "reaction",
               kind: :reaction,
               source_item_ref: "1787832000.000100",
               thread_ref: "1787832000.000100",
               tool: :set_slack_reaction,
               transport: "slack"
             })

    action
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
