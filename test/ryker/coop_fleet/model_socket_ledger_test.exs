defmodule Ryker.CoopFleet.ModelSocketLedgerTest do
  use ExUnit.Case, async: true
  alias Ryker.CoopFleet.ModelSocketLedger, as: Ledger

  test "parallel lanes bind independently and same-lane creates retain FIFO order" do
    ledger =
      %Ledger{}
      |> Ledger.enqueue(nil, :first)
      |> Ledger.enqueue(nil, :second)
      |> Ledger.enqueue("other", :parallel)

    assert {:bind, ledger, {:parallel, "b"}} = Ledger.receive_event(ledger, created("b", "other"))
    assert {:bind, ledger, {:first, "a"}} = Ledger.receive_event(ledger, created("a"))
    assert {:bind, ledger, {:second, "c"}} = Ledger.receive_event(ledger, created("c"))
    assert {:complete, ledger, {:parallel, "b"}} = Ledger.receive_event(ledger, terminal("b"))
    assert ledger.active == %{"a" => :first, "c" => :second}
    assert {:ok, ^ledger, nil} = Ledger.receive_event(ledger, terminal("b"))
    assert {:ok, ^ledger, nil} = Ledger.receive_event(ledger, terminal("unknown"))
  end

  test "uncorrelated errors never select a pending or active request to release" do
    ledger = %Ledger{} |> Ledger.enqueue(nil, :pending)

    assert {:error, %{"type" => "error"}} =
             Ledger.receive_event(ledger, ~s({"type":"error","status":429}))

    assert ledger.pending == %{nil => [:pending]}
    assert Ledger.receive_event(ledger, created("unknown", "another")) == :invalid
    assert {:bind, ledger, {:pending, "a"}} = Ledger.receive_event(ledger, created("a"))
    assert Ledger.receive_event(ledger, created("a")) == :invalid
  end

  test "interrupt acknowledgements do not end the inference request" do
    ledger = %Ledger{} |> Ledger.enqueue(nil, :request)
    assert {:bind, ledger, {:request, "a"}} = Ledger.receive_event(ledger, created("a"))

    assert {:ok, ^ledger, nil} =
             Ledger.receive_event(
               ledger,
               ~s({"type":"response.interrupt.accepted","response_id":"a"})
             )

    assert {:complete, ledger, {:request, "a"}} = Ledger.receive_event(ledger, terminal("a"))
    assert ledger.active == %{}
  end

  defp created(id, lane \\ nil) do
    event = %{"type" => "response.created", "response" => %{"id" => id}}
    Jason.encode!(if lane, do: Map.put(event, "stream_id", lane), else: event)
  end

  defp terminal(id), do: Jason.encode!(%{type: "response.completed", response: %{id: id}})
end
