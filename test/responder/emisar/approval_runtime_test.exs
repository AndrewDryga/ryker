defmodule Responder.Emisar.ApprovalRuntimeTest do
  use ExUnit.Case, async: true

  alias Responder.Emisar.ApprovalRuntime

  defmodule API do
    def wait_for_run(_client, _run_id), do: {:error, :not_used}
  end

  test "builds a bounded independent approval worker pool" do
    options =
      ApprovalRuntime.options!(
        api: API,
        client: :client,
        concurrency: 3,
        lease_seconds: 45,
        poll_interval_ms: 250,
        poll_seconds: 3,
        presentation: %{},
        presentation_timeout_ms: 30_000,
        retry_base_seconds: 2,
        retry_max_seconds: 120,
        worker_ref: "responder-a:emisar"
      )

    assert options.concurrency == 3
    assert options.worker_ref == "responder-a:emisar"

    assert %{id: ApprovalRuntime, type: :supervisor} =
             ApprovalRuntime.child_spec(Map.delete(options, :client) |> Map.put(:client, :client))

    assert {:ok, {flags, children}} = ApprovalRuntime.init(options)
    assert flags.strategy == :one_for_one
    assert length(children) == 3

    assert Enum.map(children, fn child ->
             {Responder.Emisar.ApprovalWorker, :start_link, [worker_options]} = child.start
             worker_options[:dispatcher_options][:worker_ref]
           end) == [
             "responder-a:emisar:slot-1",
             "responder-a:emisar:slot-2",
             "responder-a:emisar:slot-3"
           ]
  end

  test "rejects malformed APIs, retry bounds, and ambiguous fields" do
    valid = %{
      api: API,
      client: :client,
      presentation: %{},
      presentation_timeout_ms: 0,
      retry_base_seconds: 5,
      retry_max_seconds: 60,
      worker_ref: "responder-a:emisar"
    }

    assert_raise ArgumentError, ~r/API/, fn ->
      ApprovalRuntime.options!(%{valid | api: String})
    end

    assert_raise ArgumentError, ~r/retry_max_seconds/, fn ->
      ApprovalRuntime.options!(%{valid | retry_max_seconds: 1})
    end

    assert_raise ArgumentError, ~r/must exceed presentation timeout/, fn ->
      ApprovalRuntime.options!(
        Map.merge(valid, %{lease_seconds: 30, presentation_timeout_ms: 30_000})
      )
    end

    assert_raise ArgumentError, ~r/missing or unknown/, fn ->
      ApprovalRuntime.options!(Map.put(valid, :extra, true))
    end
  end
end
