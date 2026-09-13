defmodule Ryker.Delivery.RuntimeTest do
  use ExUnit.Case, async: true

  alias Ryker.Delivery.Runtime

  defmodule Publisher do
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.MessagePublisher
    @behaviour Ryker.Delivery.ReactionPublisher

    @impl true
    def transport, do: "test"

    @impl true
    def publish_message(_request, _binding), do: {:error, :not_started}

    @impl true
    def publish_reaction(_request, _binding), do: {:error, :not_started}
  end

  test "builds independent bounded message, reaction, and action worker pools" do
    configuration = [
      action_concurrency: 1,
      adapters: registrations(),
      lease_seconds: 90,
      max_attempts: 5,
      message_concurrency: 2,
      poll_interval_ms: 500,
      reaction_concurrency: 1,
      retry_base_seconds: 2,
      retry_max_seconds: 120,
      worker_ref: "ryker-delivery:vm-1"
    ]

    child = Runtime.child_spec(configuration)
    assert child.id == Runtime
    assert {Runtime, :start_link, [^configuration]} = child.start

    assert {:ok, {_flags, workers}} = Runtime.init(configuration)
    assert length(workers) == 4

    assert Enum.map(workers, & &1.id) == [
             {Ryker.Delivery.Worker, :message, 1},
             {Ryker.Delivery.Worker, :message, 2},
             {Ryker.Delivery.Worker, :reaction, 1},
             {Ryker.Delivery.Worker, :action, 1}
           ]

    Enum.each(workers, fn worker ->
      assert {Ryker.Delivery.Worker, :start_link, [options]} = worker.start
      assert options[:poll_interval_ms] == 500
      dispatcher = options[:dispatcher_options]
      assert dispatcher[:lease_seconds] == 90
      assert dispatcher[:max_attempts] == 5
      assert dispatcher[:retry_base_seconds] == 2
      assert dispatcher[:retry_max_seconds] == 120
      assert is_map(dispatcher[:adapters])
    end)

    [message_1, message_2, reaction_1, action_1] = workers
    assert worker_ref(message_1) == "ryker-delivery:vm-1:message:slot-1"
    assert worker_ref(message_2) == "ryker-delivery:vm-1:message:slot-2"
    assert worker_ref(reaction_1) == "ryker-delivery:vm-1:reaction:slot-1"
    assert worker_ref(action_1) == "ryker-delivery:vm-1:action:slot-1"
  end

  test "rejects unknown, untrusted, and unbounded runtime configuration" do
    invalid = [
      :invalid,
      [adapters: registrations(), worker_ref: "duplicate", worker_ref: "duplicate"],
      %{adapters: registrations()},
      %{adapters: %{}, worker_ref: "delivery:vm"},
      %{adapters: registrations(), message_concurrency: 0, worker_ref: "delivery:vm"},
      %{adapters: registrations(), reaction_concurrency: 33, worker_ref: "delivery:vm"},
      %{adapters: registrations(), action_concurrency: 33, worker_ref: "delivery:vm"},
      %{adapters: registrations(), max_attempts: 0, worker_ref: "delivery:vm"},
      %{adapters: registrations(), poll_interval_ms: 0, worker_ref: "delivery:vm"},
      %{
        adapters: registrations(),
        retry_base_seconds: 2,
        retry_max_seconds: 1,
        worker_ref: "delivery:vm"
      },
      %{adapters: registrations(), worker_ref: ""},
      %{adapters: registrations(), worker_ref: :not_a_string},
      %{adapters: registrations(), surprise: true, worker_ref: "delivery:vm"}
    ]

    Enum.each(invalid, fn configuration ->
      assert_raise ArgumentError, fn -> Runtime.child_spec(configuration) end
    end)
  end

  defp registrations do
    %{
      "test" => %{
        binding: :trusted,
        message_publisher: Publisher,
        reaction_publisher: Publisher
      }
    }
  end

  defp worker_ref(worker) do
    {Ryker.Delivery.Worker, :start_link, [options]} = worker.start
    options[:dispatcher_options][:worker_ref]
  end
end
