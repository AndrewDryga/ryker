defmodule Ryker.Delivery.DispatcherTest do
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [digest: 1]

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureIO

  @moduletag isolation: "REPEATABLE READ"

  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.Ryker.Delivery, as: DeliveryTask
  alias Ryker.Admission
  alias Ryker.Admission.Decision
  alias Ryker.Artifacts.Outputs

  alias Ryker.Delivery.{
    Adapters,
    Dispatcher,
    PlatformAction,
    PlatformActionCustody,
    RoutingResponse
  }

  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Input, as: IngressInput
  alias Ryker.Operator.Delivery, as: DeliveryOperator
  alias Ryker.PollingWorker
  alias Ryker.Records
  alias Ryker.Slack.Input
  alias Ryker.Slack.Mentions
  alias Ryker.Slack.Publisher, as: SlackPublisher
  alias Ryker.TestSupport.FakeSlackAPI
  alias Ryker.Work.{Custody, DeliveryReceipt, Result, Submission, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]

  defmodule Publisher do
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.MessagePublisher
    @behaviour Ryker.Delivery.ReactionPublisher

    alias Ryker.Work.DeliveryReceipt

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
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.MessagePublisher
    @behaviour Ryker.Delivery.ReactionPublisher

    alias Ryker.Work.DeliveryReceipt

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
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.MessagePublisher
    @behaviour Ryker.Delivery.ReactionPublisher

    @impl true
    def transport, do: "slack"

    @impl true
    def publish_message(_request, _binding), do: throw(:provider_bug)

    @impl true
    def publish_reaction(request, binding), do: publish_message(request, binding)
  end

  defmodule ExitingPublisher do
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.MessagePublisher
    @behaviour Ryker.Delivery.ReactionPublisher

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

  test "an answer is published to the thread its question was asked in" do
    # Evidence from several conversations meets in one episode, but the episode
    # keeps one progress home. Deriving every reply from that home answered a
    # colleague who asked in their own thread somewhere they were not reading.
    accepted = delivery_pending!("cross-origin", question_from: "slack:T123:C-engineering")
    {:ok, publisher} = Agent.start_link(fn -> %{calls: [], responses: []} end)

    assert {:ok, {:delivered, :message, _delivery_ref}} =
             Dispatcher.run_once(dispatcher_options(:message, publisher))

    assert [{:message, request}] = Agent.get(publisher, &Enum.reverse(&1.calls))
    assert request.conversation_ref == "slack:T123:C-engineering"
    assert request.thread_ref == "1787832500.000100"

    # The target is frozen on the accepted turn, so a retry or a later input
    # from somewhere else cannot move an answer that is already accepted.
    settled = Repo.get!(Turn, accepted.turn.id)
    assert settled.delivery_target["conversation_ref"] == "slack:T123:C-engineering"
  end

  test "a cited task offer is materialized from the owning episode for platform rendering" do
    task = %{
      "kind" => "engineering",
      "prompt" => "Change the parser and run focused tests.",
      "repository" => "ryker",
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

    assert {:ok, {:deferred, :routing, delivery_ref, {:delivery_uncertain, :closed}}} =
             Dispatcher.run_once(dispatcher_options(:routing, publisher))

    assert delivery_ref == pending.delivery_ref
    deferred = Repo.get_by!(RoutingResponse, input_id: pending.input_id)
    assert deferred.status == :pending
    assert deferred.lease_ref == nil
    assert deferred.attempt_count == 1
    assert deferred.last_error_code == "delivery_uncertain"

    Repo.update_all(Ryker.Delivery.RoutingResponse, set: [next_attempt_at: @now])

    assert {:ok, {:delivered, :routing, ^delivery_ref}} =
             Dispatcher.run_once(dispatcher_options(:routing, publisher))

    delivered = Repo.get_by!(RoutingResponse, input_id: pending.input_id)
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

    delivered = Repo.get_by!(PlatformAction, action_ref: action_ref)
    assert delivered.status == :delivered
    assert delivered.external_receipt["delivery_ref"] == action_ref
  end

  # Andrew, 2026-09-26: the Work model may post into its thread while it works
  # "to make it really live". An update reaches Slack as the answer does: in
  # the answer's thread, rendered with the people its answer may name, and
  # once, even when Slack took the post but its answer was lost. Without its
  # own mention authority a named person stopped the update for good, and the
  # answer that waits for it with it.
  test "a Work update reaches the answer's thread once, naming whom the answer may" do
    claim = work_claim!("update-delivery")

    assert {:ok, %{action: update, status: :created}} =
             PlatformActionCustody.enqueue_in_turn(claim, %{
               conversation_ref: "slack:T123:C456",
               document: %{"message" => "On it, [@Uno](slack-user:U1): checking the deploy."},
               kind: :message,
               source_item_ref: nil,
               thread_ref: "1787832000.000100",
               tool: :post_slack_update,
               transport: "slack"
             })

    {:ok, slack} =
      FakeSlackAPI.start_link(
        lose: [:post_message],
        render: true,
        message_ref: fn _n -> "1787832000.000900" end
      )

    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{
                   mention_authority: &Mentions.authority_for_delivery/1,
                   workspaces: %{"T123" => %{api: FakeSlackAPI, client: slack}}
                 },
                 message_publisher: SlackPublisher,
                 reaction_publisher: SlackPublisher
               }
             })

    options = [
      adapters: adapters,
      kind: :action,
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "delivery:action:update"
    ]

    action_ref = update.action_ref

    assert {:ok, {:deferred, :action, ^action_ref, {:delivery_uncertain, _lost}}} =
             Dispatcher.run_once(options)

    Repo.update_all(PlatformAction, set: [next_attempt_at: DateTime.add(@now, -1, :second)])
    assert {:ok, {:delivered, :action, ^action_ref}} = Dispatcher.run_once(options)

    assert [%{channel: "C456", thread: "1787832000.000100", delivery_ref: ^action_ref} = post] =
             FakeSlackAPI.state(slack).posts

    assert post.document["text"] == "On it, <@U1>: checking the deploy."

    assert %PlatformAction{status: :delivered, external_receipt: receipt} =
             Repo.get!(PlatformAction, update.id)

    assert receipt["message_ref"] == "1787832000.000900"
  end

  # Accepting an answer clears the episode's active inputs, and the publisher worked out whom the
  # answer may name from those inputs again: a final reply naming the person who asked was refused
  # as unauthorized when it was posted, and blocked for good (2026-10-04 review).
  test "a final reply may name the person whose message it answers" do
    delivery_pending!("names-requester", message: "Done, [@Uno](slack-user:U1).")

    {:ok, slack} =
      FakeSlackAPI.start_link(render: true, message_ref: fn _n -> "1787832000.000901" end)

    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{
                   mention_authority: &Mentions.authority_for_delivery/1,
                   workspaces: %{"T123" => %{api: FakeSlackAPI, client: slack}}
                 },
                 message_publisher: SlackPublisher,
                 reaction_publisher: SlackPublisher
               }
             })

    options = [
      adapters: adapters,
      kind: :message,
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "delivery:message:names-requester"
    ]

    assert {:ok, {:delivered, :message, _delivery_ref}} = Dispatcher.run_once(options)
    assert [post] = FakeSlackAPI.state(slack).posts
    assert post.document["text"] == "Done, <@U1>."
  end

  # Andrew, 2026-09-26: the Work model should send "some emojis" too, not
  # only one: a second reaction in a turn was refused as temporarily
  # unavailable. Two reactions in one turn now both reach Slack, each once,
  # in the order the model asked for them.
  test "two different emoji in one turn both reach Slack, once each, in order" do
    claim = work_claim!("two-reactions")

    for emoji <- ~w(eyes white_check_mark) do
      assert {:ok, %{status: :created}} =
               PlatformActionCustody.enqueue_in_turn(claim, %{
                 conversation_ref: "slack:T123:C456",
                 document: %{"action" => "add", "emoji_name" => emoji},
                 kind: :reaction,
                 source_item_ref: "1787832000.000100",
                 thread_ref: "1787832000.000100",
                 tool: :set_slack_reaction,
                 transport: "slack"
               })
    end

    {:ok, slack} = FakeSlackAPI.start_link()

    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{workspaces: %{"T123" => %{api: FakeSlackAPI, client: slack}}},
                 message_publisher: SlackPublisher,
                 reaction_publisher: SlackPublisher
               }
             })

    options = [
      adapters: adapters,
      kind: :action,
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "delivery:action:reactions"
    ]

    assert {:ok, {:delivered, :action, first_ref}} = Dispatcher.run_once(options)
    assert {:ok, {:delivered, :action, second_ref}} = Dispatcher.run_once(options)
    assert {:ok, :idle} = Dispatcher.run_once(options)
    refute first_ref == second_ref

    assert FakeSlackAPI.state(slack).reacted == [
             {"C456", "1787832000.000100", "eyes"},
             {"C456", "1787832000.000100", "white_check_mark"}
           ]

    assert Enum.map(
             Repo.all(
               from(action in PlatformAction,
                 where: action.turn_id == ^claim.turn.id,
                 order_by: action.host_slot
               )
             ),
             &{&1.action_ref, &1.status}
           ) == [{first_ref, :delivered}, {second_ref, :delivered}]
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
            }} = DeliveryOperator.fetch(action_ref)

    assert {:ok, blocked} = DeliveryOperator.list_blocked()
    assert Enum.any?(blocked, &(&1.delivery_ref == action_ref and &1.kind == :platform_action))

    assert {:ok, %{status: :pending, retry_generation: 1}} = DeliveryOperator.rearm(action_ref)
  end

  # The Work prompt has the model cite the ref every tool returned for what
  # its reply says it did, and a reaction's is a platform action's. Delivery
  # read every cited ref as a durable record, found none and blocked the
  # reply; on 2026-09-26 a "Hi again! 👋 Your 👍 reaction is queued." sat
  # undelivered for two hours in #test while its turn crashed every five
  # minutes, 23 times, on the same lookup before delivery.
  test "a reply that cites the reaction it added is delivered, without a card for the reaction" do
    accepted = delivery_pending!("cited-reaction", cited_reaction: true)
    [action_ref] = accepted.turn.delivery_document["outcome"]["record_refs"]
    assert String.starts_with?(action_ref, "platform-action:")

    {:ok, publisher} = Agent.start_link(fn -> %{calls: [], responses: []} end)

    assert {:ok, {:delivered, :message, delivery_ref}} =
             Dispatcher.run_once(dispatcher_options(:message, publisher))

    assert delivery_ref == accepted.turn.delivery_ref
    assert [{:message, request}] = Agent.get(publisher, &Enum.reverse(&1.calls))
    assert request.document == %{"message" => "Finished from generic delivery."}
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

    assert {:ok, [listed]} = DeliveryOperator.list_blocked()
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

    assert_raise Mix.Error, ~r/usage: mix ryker.delivery/, fn ->
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

  # With 8 attempts from 1 s to a 60 s cap, a reply waited for a person after about two
  # minutes of any Slack, GitHub or network outage, and so did every routing response and
  # weekly report queued behind it (2026-10-04 review). An outage is waited out for about
  # three hours, trying again at least every five minutes, before anyone is asked to click.
  test "a reply rides out a three-hour outage before it waits for a person" do
    accepted = delivery_pending!("long-outage")
    outage = {:error, {:slack_http_error, 503, "service unavailable"}}

    {:ok, publisher} =
      Agent.start_link(fn -> %{calls: [], responses: List.duplicate(outage, 100)} end)

    # Given no retry settings, the dispatcher uses the shipped ones.
    options =
      :message
      |> dispatcher_options(publisher, Publisher)
      |> Keyword.drop([:retry_base_seconds, :retry_max_seconds])

    waits =
      Enum.reduce_while(1..100, [], fn _attempt, waits ->
        case Dispatcher.run_once(options) do
          {:ok, {:deferred, :message, _ref, _reason}} ->
            turn = Repo.get!(Turn, accepted.turn.id)
            wait = DateTime.diff(turn.next_attempt_at, Repo.now!(), :second)

            Repo.update_all(from(row in Turn, where: row.id == ^turn.id),
              set: [next_attempt_at: DateTime.add(Repo.now!(), -1, :second)]
            )

            {:cont, [wait | waits]}

          {:ok, {:blocked, :message, _ref, _reason}} ->
            {:halt, waits}
        end
      end)

    assert Enum.sum(waits) >= 3 * 3_600
    assert Enum.max(waits) <= 5 * 60
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

    options = dispatcher_options(:routing, publisher, Publisher, max_attempts: 1)

    assert {:ok, {:blocked, :routing, delivery_ref, {:delivery_transport_unavailable, :closed}}} =
             Dispatcher.run_once(options)

    assert delivery_ref == pending.delivery_ref
    blocked = Repo.get_by!(RoutingResponse, input_id: pending.input_id)
    assert blocked.status == :blocked
    assert {:ok, :idle} = Dispatcher.run_once(options)

    assert {:ok, rearmed} = DeliveryOperator.rearm(delivery_ref)
    assert rearmed.status == :pending
    assert rearmed.attempt_count == 0
    assert rearmed.retry_generation == 1
    assert {:ok, {:delivered, :routing, ^delivery_ref}} = Dispatcher.run_once(options)
  end

  test "each delivery phase is independently idle" do
    {:ok, publisher} = Agent.start_link(fn -> %{calls: [], responses: []} end)

    assert {:ok, :idle} = Dispatcher.run_once(dispatcher_options(:message, publisher))
    assert {:ok, :idle} = Dispatcher.run_once(dispatcher_options(:routing, publisher))
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

  # A rescued renewal exception keeps the poller alive, so caller-death monitoring
  # alone leaves a publishing child running beyond the failed custody renewal.
  test "a rescued database renewal failure reaps the actual provider before polling returns" do
    pool = renewal_pool!()
    previous_pool = Repo.put_dynamic_repo(pool)
    accepted = delivery_pending!("renewal-pool-failure")
    parent = self()

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        Repo.put_dynamic_repo(pool)
        {:monitors, initial_monitors} = Process.info(self(), :monitors)

        delay =
          PollingWorker.run(:delivery, 10, fn ->
            Dispatcher.run_once(
              dispatcher_options(:message, %{observer: parent}, BlockingPublisher,
                lease_seconds: 1,
                worker_ref: "delivery:message:renewal-pool-failure"
              )
            )

            :unexpected_delivery_return
          end)

        receive do
          {:provider_under_test, provider} ->
            send(parent, {:poll_returned, self(), delay, Process.alive?(provider)})
        end

        receive do
          :inspect_poll_mailbox ->
            {:monitors, monitors} = Process.info(self(), :monitors)
            {:messages, messages} = Process.info(self(), :messages)
            send(parent, {:poll_mailbox, monitors -- initial_monitors, messages})
        end

        receive do: (:stop_poll_worker -> :ok)
      end)

    assert_receive {:delivery_publish_started, provider}, 1_000
    provider_monitor = Process.monitor(provider)
    send(worker, {:provider_under_test, provider})
    holder = hold_renewal_connection!(pool)

    try do
      assert_receive {:poll_returned, ^worker, delay, provider_alive}, 5_000
      refute provider_alive, "the fake provider outlived the failed lease renewal"
      assert delay == 1_000
      assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :killed}, 1_000
      assert Process.alive?(worker)

      send(holder, :release_renewal_connection)
      assert_receive {:renewal_connection_released, ^holder}, 1_000

      send(worker, :inspect_poll_mailbox)
      assert_receive {:poll_mailbox, [], []}, 1_000

      pending = Repo.get!(Turn, accepted.turn.id)
      assert pending.status == :delivery_pending
      assert pending.delivery_ref == accepted.turn.delivery_ref
      assert pending.delivery_document == accepted.turn.delivery_document
      assert pending.delivery_attempt_count == 1
      assert is_binary(pending.lease_ref)
      assert pending.external_receipt == nil
    after
      send(holder, :release_renewal_connection)
      Process.exit(provider, :kill)
      Process.exit(worker, :kill)
      Process.demonitor(provider_monitor, [:flush])
      Process.demonitor(worker_monitor, [:flush])
      Repo.put_dynamic_repo(previous_pool)
    end
  end

  test "malformed dispatcher settings cannot claim delivery custody" do
    invalid = [
      :invalid,
      [],
      [adapters: %{}, kind: :routing, worker_ref: "delivery:test"],
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

  defp joined_question_refs(command, options) do
    case Keyword.fetch(options, :question_from) do
      {:ok, conversation_ref} -> [join_question!(command, conversation_ref)]
      :error -> nil
    end
  end

  # A question asked in another channel joins the episode with its own origin:
  # membership is per message, and the place it arrived in is retained.
  defp join_question!(command, conversation_ref) do
    {:ok, question} =
      Input.new(%{
        actor: %{kind: :user, ref: "UALICE"},
        channel_ref: conversation_ref |> String.split(":") |> List.last(),
        content: %{"text" => "Is the failover finished?"},
        event_kind: :message,
        event_ref: "Ev-question-#{command.episode_id}",
        message_ref: "1787832500.000200",
        occurred_at: DateTime.add(@now, 60, :second),
        revision: 1,
        thread_ref: "1787832500.000100",
        workspace_ref: conversation_ref |> String.split(":") |> Enum.at(1)
      })

    joined = %{
      command
      | actor_ref: IngressInput.actor_ref(question),
        native_input_id: question.native_input_id,
        occurred_at: question.occurred_at,
        payload: IngressInput.document(question)
    }

    assert {:ok, _transition} = Episodes.apply(joined)
    Command.dedupe_key(joined)
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

  defp renewal_pool! do
    # The shared pool's 10-second queue poll can reject a renewal just after the
    # old 20-second assertion deadline. One full gate failed on that timer phase.
    # Exercise the real exhausted pool with short timers, not a longer assertion
    # or a synthetic renewal result; keep fixture writes sandboxed.
    pool =
      start_supervised!(
        Supervisor.child_spec(
          {Repo, name: nil, pool_size: 1, queue_target: 10, queue_interval: 10},
          id: :delivery_renewal_pool
        )
      )

    owner = Sandbox.start_owner!(pool, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Sandbox.stop_owner(owner) end)
    pool
  end

  defp hold_renewal_connection!(pool) do
    parent = self()

    holder =
      spawn_link(fn ->
        Repo.put_dynamic_repo(pool)

        Repo.checkout(
          fn ->
            send(parent, {:renewal_connection_held, self()})

            receive do
              :release_renewal_connection -> :ok
            after
              30_000 -> raise "test did not release its held renewal connection"
            end
          end,
          timeout: 35_000
        )

        send(parent, {:renewal_connection_released, self()})
      end)

    on_exit(fn -> send(holder, :release_renewal_connection) end)
    assert_receive {:renewal_connection_held, ^holder}, 1_000
    holder
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

    assert {:ok, transition} = Episodes.apply(command)

    # Work freezes the inputs its turn answers, as the executor does.
    selected_input_refs =
      joined_question_refs(command, options) || transition.episode.active_input_refs

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

    reaction = cited_reaction!(claim, options)
    output_artifact = Keyword.get(options, :output_artifact)

    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => id},
               "Handle the frozen episode.",
               %{"type" => "object"},
               "work-final-live-v3"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(id, claim.turn.turn_ref, claim.lease_ref, submission,
               selected_input_refs: selected_input_refs
             )

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

    record_refs = cited_refs(record, reaction)

    message = Keyword.get(options, :message, "Finished from generic delivery.")

    delivery_document =
      case {record_refs, artifact_refs} do
        {[], []} ->
          %{"message" => message}

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

  # A reaction the reply cites beside its records, as the Work prompt asks.
  defp cited_reaction!(claim, options) do
    if Keyword.get(options, :cited_reaction) do
      assert {:ok, %{action: action, status: :created}} =
               PlatformActionCustody.enqueue_in_turn(claim, %{
                 conversation_ref: "slack:T123:C456",
                 document: %{"action" => "add", "emoji_name" => "thumbsup"},
                 kind: :reaction,
                 source_item_ref: "1787832000.000100",
                 thread_ref: "1787832000.000100",
                 tool: :set_slack_reaction,
                 transport: "slack"
               })

      action
    end
  end

  defp cited_refs(record, reaction),
    do: Enum.reject([record && record.ref, reaction && reaction.action_ref], &is_nil/1)

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
               "messages" => nil,
               "reactions" => [emoji_name],
               "relation" => "unrelated",
               "repository" => nil,
               "repository_source" => nil,
               "reason" => "Acknowledge without starting an episode.",
               "work_class" => nil
             })

    assert {:ok, _result} = Admission.commit(context, decision, "decision:#{suffix}")
    Repo.get_by!(RoutingResponse, input_id: entry.id)
  end

  defp work_claim!(suffix) do
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
    claim
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
             PlatformActionCustody.enqueue_in_turn(claim, %{
               conversation_ref: "slack:T123:C456",
               document: %{"action" => "add", "emoji_name" => "eyes"},
               kind: :reaction,
               source_item_ref: "1787832000.000100",
               thread_ref: "1787832000.000100",
               tool: :set_slack_reaction,
               transport: "slack"
             })

    action
  end
end
