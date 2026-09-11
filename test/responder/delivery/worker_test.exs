defmodule Responder.Delivery.WorkerTest do
  use Responder.DataCase, async: false

  @moduletag isolation: "REPEATABLE READ"

  alias Responder.Admission
  alias Responder.Admission.Decision
  alias Responder.Delivery.{Adapters, ReactionCustody, Worker}
  alias Responder.Ingress.Inbox
  alias Responder.Slack.Input
  alias Responder.Work.DeliveryReceipt

  @now ~U[2026-08-28 12:00:00.000000Z]

  defmodule Publisher do
    @behaviour Responder.Delivery.Platform
    @behaviour Responder.Delivery.MessagePublisher
    @behaviour Responder.Delivery.ReactionPublisher

    @impl true
    def transport, do: "slack"

    @impl true
    def publish_message(_request, _test_pid), do: {:error, :unexpected_message}

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
             kind: :reaction,
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
             case ReactionCustody.fetch_by_input(pending.input_id) do
               {:ok, %{status: :delivered, lease_ref: nil}} -> true
               _other -> false
             end
           end)

    assert Process.alive?(worker)
    assert :ok = stop_supervised(Worker)
  end

  test "invalid dispatcher settings do not crash the polling process" do
    worker =
      start_supervised!(
        {Worker,
         [
           dispatcher_options: [kind: :reaction, worker_ref: "delivery-worker:invalid"],
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
             kind: :reaction,
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
               "reaction" => %{"emoji_name" => "eyes"},
               "relation" => "unrelated",
               "repository_source" => nil,
               "reason" => "Acknowledge without starting work.",
               "work_class" => nil
             })

    assert {:ok, _result} = Admission.commit(context, decision, "decision:worker-reaction")
    assert {:ok, pending} = ReactionCustody.fetch_by_input(entry.id)
    pending
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

  defp eventually(predicate, attempts \\ 100)
  defp eventually(_predicate, 0), do: false

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(5)
      eventually(predicate, attempts - 1)
    end
  end
end
