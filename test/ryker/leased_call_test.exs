defmodule Ryker.LeasedCallTest do
  use ExUnit.Case, async: true

  alias Ryker.LeasedCall

  test "an answer comes back only after the lease is renewed once more" do
    parent = self()

    assert LeasedCall.run(
             fn -> :answered end,
             fn ->
               send(parent, :renewed)
               {:ok, :lease}
             end,
             60,
             :test_call_exit
           ) == :answered

    assert_received :renewed
  end

  test "a lease that cannot be renewed ends the call with the renewal's error" do
    parent = self()

    call = fn ->
      send(parent, {:call_started, self()})
      receive do: (:never -> :unreachable)
    end

    assert LeasedCall.run(call, fn -> {:error, :lease_lost} end, 1, :test_call_exit) ==
             {:error, :lease_lost}

    assert_received {:call_started, pid}
    refute Process.alive?(pid)
  end

  test "a call that dies answers with the caller's exit reason under a renewed lease" do
    parent = self()

    renew = fn ->
      send(parent, :renewed)
      {:ok, :lease}
    end

    assert LeasedCall.run(fn -> Process.exit(self(), :kill) end, renew, 60, :test_call_exit) ==
             {:error, {:test_call_exit, :killed}}

    assert_received :renewed
  end
end
