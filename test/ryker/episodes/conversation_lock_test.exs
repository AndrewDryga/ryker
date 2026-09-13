defmodule Ryker.Episodes.ConversationLockTest do
  use ExUnit.Case, async: true

  alias Ryker.Episodes.ConversationLock

  defmodule FailingRepo do
    def query(_statement, _parameters), do: {:error, :database_unavailable}
  end

  test "returns a tagged store error when the routing lock cannot be acquired" do
    destination = %{transport: "slack", conversation_ref: "workspace:channel"}

    expected = {:error, {:store_failed, :conversation_lock, :database_unavailable}}

    assert ConversationLock.lock(FailingRepo, destination) == expected
    assert ConversationLock.lock_many(FailingRepo, [destination, destination]) == expected
  end
end
