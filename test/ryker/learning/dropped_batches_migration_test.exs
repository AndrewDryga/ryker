defmodule Ryker.Learning.DroppedBatchesMigrationTest do
  @moduledoc """
  Andrew, 2026-09-27, of a learning batch stuck on a learned topic that lost
  its own messages: "why I can't just forget/delete it?" A person may drop
  such a batch now, and the database has to hold a batch in that state; going
  back turns a dropped batch into the stopped batch it was, which needs a
  person again, instead of refusing to go back or losing the batch.
  """
  # The migrator runs inside this test's sandbox transaction.
  use Ryker.MigrationCase
  import Ecto.Query
  alias Ryker.Learning.Batch

  @version 20_260_927_150_000

  test "a learning batch can be dropped, and going back makes it the stopped batch it was" do
    dropped = batch!(:dropped)
    stopped = batch!(:deferred)

    assert migrate_down(@version) == :ok

    assert Repo.get!(Batch, dropped.id).status == :deferred
    assert Repo.get!(Batch, stopped.id).status == :deferred
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} = drop(stopped)

    assert migrate_up(@version) == :ok

    assert drop(stopped) == {:ok, 1}
    assert Repo.get!(Batch, stopped.id).status == :dropped
  end

  defp batch!(status) do
    Repo.insert!(%Batch{
      id: Ecto.UUID.generate(),
      scope_key: "dropped-migration:#{System.unique_integer([:positive])}",
      transport: "slack",
      conversation_ref: "slack:T123:C456",
      execution_mode: :live,
      policy: "dropped-migration",
      policy_digest: String.duplicate("a", 64),
      status: status,
      input_count: 1,
      start_count: 1,
      error_code: "knowledge_target_unavailable",
      completed_at: DateTime.utc_now()
    })
  end

  # A savepoint keeps the refused write from aborting the test's transaction.
  defp drop(batch) do
    Repo.transaction(fn ->
      {count, nil} =
        Repo.update_all(from(b in Batch, where: b.id == ^batch.id), set: [status: :dropped])

      count
    end)
  rescue
    error in Postgrex.Error -> {:error, error}
  end
end
