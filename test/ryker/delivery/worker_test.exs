defmodule Ryker.Delivery.WorkerTest do
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [eventually: 1]

  @moduletag isolation: "REPEATABLE READ"

  alias Ryker.Admission
  alias Ryker.Admission.Decision

  alias Ryker.Delivery.{
    Adapters,
    PlatformAction,
    PlatformActionCustody,
    RoutingResponse,
    RoutingResponseCustody,
    Worker
  }

  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Slack.Input
  alias Ryker.Work.{Custody, DeliveryReceipt, Result, Submission, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]

  defmodule Publisher do
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.MessagePublisher
    @behaviour Ryker.Delivery.ReactionPublisher

    @impl true
    def transport, do: "slack"

    @impl true
    def publish_message(request, test_pid) do
      send(test_pid, {:message_published, request})

      DeliveryReceipt.new(
        request.ref,
        request.transport,
        request.conversation_ref,
        request.thread_ref,
        request.source_item_ref || "1787832999.000999"
      )
    end

    @impl true
    def publish_reaction(request, test_pid) do
      send(test_pid, {:reaction_published, request})

      DeliveryReceipt.new(
        request.ref,
        request.transport,
        request.conversation_ref,
        request.thread_ref,
        request.source_item_ref
      )
    end
  end

  test "a polling reaction worker settles the durable outbox without owning routing" do
    pending = reaction_pending!()
    adapters = adapters!(self())

    worker =
      start_supervised!(
        {Worker,
         [
           dispatcher_options: [
             adapters: adapters,
             kind: :routing,
             lease_seconds: 60,
             retry_base_seconds: 1,
             retry_max_seconds: 60,
             worker_ref: "delivery-worker:reaction"
           ],
           poll_interval_ms: 10
         ]}
      )

    assert_receive {:reaction_published, request}, 1_000
    assert request.ref == pending.delivery_ref
    assert request.document == %{"emoji_name" => "eyes"}

    assert eventually(fn ->
             match?(
               %{status: :delivered, lease_ref: nil},
               Repo.get_by(RoutingResponse, input_id: pending.input_id)
             )
           end)

    assert Process.alive?(worker)
    assert :ok = stop_supervised(Worker)
  end

  test "invalid dispatcher settings do not crash the polling process" do
    worker =
      start_supervised!(
        {Worker,
         [
           dispatcher_options: [kind: :routing, worker_ref: "delivery-worker:invalid"],
           name: __MODULE__.InvalidWorker,
           poll_interval_ms: 10
         ]}
      )

    Process.sleep(30)
    assert Process.alive?(worker)
    assert :ok = stop_supervised(Worker)
  end

  test "an idle named delivery worker keeps polling" do
    worker =
      start_supervised!(
        {Worker,
         [
           dispatcher_options: [
             adapters: adapters!(self()),
             kind: :routing,
             lease_seconds: 60,
             retry_base_seconds: 1,
             retry_max_seconds: 60,
             worker_ref: "delivery-worker:idle"
           ],
           name: __MODULE__.IdleWorker,
           poll_interval_ms: 10
         ]}
      )

    Process.sleep(30)
    assert Process.alive?(worker)
    assert Process.whereis(__MODULE__.IdleWorker) == worker
    assert :ok = stop_supervised(Worker)
  end

  # On 2026-09-27 an idle install committed about 125 transactions a second;
  # eight delivery lanes polled their queues every 250 ms. A lane now sleeps
  # until something it could send is announced, so each lane's announcement
  # has to wake it: a reaction routing chose, a Work reply, a model's action.
  test "a reaction routing chose while its lane is idle is sent at once, not at the next timer" do
    worker = start_supervised!({Worker, sleeping_options(:routing)})
    # Its first poll found nothing, and its next timer is a minute away.
    _state = :sys.get_state(worker)

    pending = reaction_pending!()
    assert_receive {:reaction_published, %{ref: ref}}, 500
    assert ref == pending.delivery_ref
    assert_recorded(RoutingResponse, :delivery_ref, ref)
  end

  test "a Work reply accepted while its lane is idle is sent at once, not at the next timer" do
    worker = start_supervised!({Worker, sleeping_options(:message)})
    _state = :sys.get_state(worker)

    accepted = message_pending!("woken")
    assert_receive {:message_published, %{ref: ref}}, 500
    assert ref == accepted.turn.delivery_ref
    assert_recorded(Turn, :turn_ref, accepted.turn.turn_ref)
  end

  test "an action a turn asked for while its lane is idle is sent at once, not at the next timer" do
    worker = start_supervised!({Worker, sleeping_options(:action)})
    _state = :sys.get_state(worker)

    action = action_pending!("woken")
    assert_receive {:reaction_published, %{ref: ref}}, 500
    assert ref == action.action_ref
    assert_recorded(PlatformAction, :action_ref, ref)
  end

  # A failed send is retried after a backoff of a second and up, and only the
  # clock says when: a lane sleeping its whole safety-net interval would send
  # every retry up to ten seconds late.
  test "a reaction whose retry falls due is sent then, not at the safety-net interval" do
    pending = reaction_pending!()
    {:ok, claim} = RoutingResponseCustody.claim_next("delivery:earlier", 60)

    {:ok, _deferred} =
      RoutingResponseCustody.defer(pending.delivery_ref, claim.lease_ref, 1, "slack", "retry")

    start_supervised!({Worker, sleeping_options(:routing)})

    refute_receive {:reaction_published, _request}, 500
    assert_receive {:reaction_published, _request}, 1_500
    assert_recorded(RoutingResponse, :delivery_ref, pending.delivery_ref)
  end

  test "a Work reply whose retry falls due is sent then, not at the safety-net interval" do
    accepted = message_pending!("due")
    {:ok, claim} = Custody.claim_next("delivery:earlier", 60, :delivery)

    {:ok, _turn} =
      Custody.defer(
        accepted.turn.episode_id,
        claim.turn.turn_ref,
        claim.lease_ref,
        1,
        "slack",
        "retry"
      )

    start_supervised!({Worker, sleeping_options(:message)})

    refute_receive {:message_published, _request}, 500
    assert_receive {:message_published, _request}, 1_500
    assert_recorded(Turn, :turn_ref, accepted.turn.turn_ref)
  end

  test "an action whose retry falls due is sent then, not at the safety-net interval" do
    action = action_pending!("due")
    {:ok, claim} = PlatformActionCustody.claim_next("delivery:earlier", 60)

    {:ok, _deferred} =
      PlatformActionCustody.defer(action.action_ref, claim.lease_ref, 1, "slack", "retry")

    start_supervised!({Worker, sleeping_options(:action)})

    refute_receive {:reaction_published, _request}, 500
    assert_receive {:reaction_published, _request}, 1_500
    assert_recorded(PlatformAction, :action_ref, action.action_ref)
  end

  # A send is finished when its receipt is saved. These tests ended at the
  # send, so the worker was stopped in the middle of that write and every run
  # logged a dropped database connection.
  defp assert_recorded(schema, field, ref) do
    assert eventually(fn ->
             match?(%{delivered_at: %DateTime{}}, Repo.get_by(schema, [{field, ref}]))
           end)
  end

  defp sleeping_options(kind) do
    [
      dispatcher_options: [
        adapters: adapters!(self()),
        kind: kind,
        lease_seconds: 60,
        retry_base_seconds: 1,
        retry_max_seconds: 60,
        worker_ref: "delivery-worker:#{kind}"
      ],
      idle_interval_ms: 60_000,
      poll_interval_ms: 60_000
    ]
  end

  # A turn whose reply Work accepted: admitted, claimed, submitted, validated.
  defp message_pending!(suffix) do
    {id, command, claim} = work_claim!(suffix)

    {:ok, submission} =
      Submission.new(
        %{"episode_id" => id},
        "Handle the frozen episode.",
        %{"type" => "object"},
        "work-final-live-v3"
      )

    {:ok, _turn} =
      Custody.freeze_submission(id, claim.turn.turn_ref, claim.lease_ref, submission,
        selected_input_refs: nil
      )

    {:ok, session} =
      Custody.bind_session(
        id,
        claim.turn.turn_ref,
        claim.lease_ref,
        claim.session.generation,
        claim.session.create_generation,
        "coop-session:delivery-worker:#{suffix}"
      )

    {:ok, turn} =
      Custody.bind_turn(
        id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        claim.turn.submit_generation,
        "coop-turn:delivery-worker:#{suffix}"
      )

    candidate = ~s({"delivery":"reply","message":"Finished by the delivery worker."})
    candidate_sha256 = Ryker.TestHelpers.digest(candidate)

    {:ok, _turn} =
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

    {:ok, result} = Result.new(:reply, %{"message" => "Finished by the delivery worker."})

    {:ok, _turn} =
      Custody.prepare_validation(
        id,
        turn.turn_ref,
        claim.lease_ref,
        candidate_sha256,
        1,
        :accept,
        result
      )

    {:ok, accepted} =
      Custody.accept_result(
        id,
        command.episode_key,
        turn.turn_ref,
        claim.lease_ref,
        candidate_sha256,
        1,
        "validation-receipt:#{suffix}"
      )

    accepted
  end

  defp action_pending!(suffix) do
    {_id, _command, claim} = work_claim!(suffix)

    {:ok, %{action: action, status: :created}} =
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
        episode_key: "delivery-worker:#{suffix}:#{id}",
        native_input_id: "slack-message:delivery-worker:#{suffix}:#{id}",
        occurred_at: @now,
        turn_ref: "turn:delivery-worker:#{suffix}:#{id}"
      })

    {:ok, _transition} = Episodes.apply(command)
    {:ok, _session} = Custody.pin_episode(id, "work-read-only", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("work:delivery-worker:#{suffix}", 60, :work)
    {id, command, claim}
  end

  defp reaction_pending! do
    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please acknowledge this."},
               event_kind: :message,
               event_ref: "Ev-worker-reaction",
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
               "reactions" => ["eyes"],
               "relation" => "unrelated",
               "repository" => nil,
               "repository_source" => nil,
               "reason" => "Acknowledge without starting work.",
               "work_class" => nil
             })

    assert {:ok, _result} = Admission.commit(context, decision, "decision:worker-reaction")
    Repo.get_by!(RoutingResponse, input_id: entry.id)
  end

  defp adapters!(test_pid) do
    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: test_pid,
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    adapters
  end
end
