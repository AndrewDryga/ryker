defmodule Ryker.Episodes.ConversationLockTest do
  use Ryker.DataCase, async: true
  alias Ryker.Episodes.ConversationLock

  # Admission and every resume roll back on the error they are handed, so a
  # lock the database refuses is answered, never raised. The lock took the
  # repository as an argument only so this test could pass one that failed;
  # a transaction the database has already aborted refuses it for real.
  test "a conversation lock the database refuses answers a tagged store error" do
    destination = %{transport: "slack", conversation_ref: "workspace:channel"}

    assert {:error, [single, many]} =
             Repo.transaction(fn ->
               assert {:error, %Postgrex.Error{}} = Repo.query("SELECT 1 / 0")
               single = ConversationLock.lock(destination)
               many = ConversationLock.lock_many([destination, destination])
               Repo.rollback([single, many])
             end)

    for refused <- [single, many] do
      assert {:error, {:store_failed, :conversation_lock, %Postgrex.Error{postgres: postgres}}} =
               refused

      assert postgres.code == :in_failed_sql_transaction
    end
  end
end
