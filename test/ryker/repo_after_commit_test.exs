defmodule Ryker.RepoAfterCommitTest do
  @moduledoc """
  Open pages redraw when a context announces a change (`Ryker.PubSub`), and
  they read the change back the moment they hear of it. Until 2026-09-26 the
  announcement was a PostgreSQL trigger's NOTIFY, which the database holds
  until COMMIT. A broadcast made in the transaction itself would reach a page
  before the rows it names were visible, and would survive a rollback that took
  them away, so every context announces through `Repo.after_commit/1`.
  """
  use Ryker.DataCase, async: true

  alias Ryker.Repo

  setup do
    topic = "after-commit-test:#{System.unique_integer([:positive])}"
    :ok = Ryker.PubSub.subscribe(topic)
    %{topic: topic}
  end

  test "an announcement made inside a transaction arrives only after the commit", %{topic: topic} do
    assert {:ok, :written} =
             Repo.transaction(fn ->
               announce(topic, :changed)
               refute_received {:announced, :changed}
               :written
             end)

    assert_received {:announced, :changed}
  end

  test "a rolled-back change is never announced", %{topic: topic} do
    assert {:error, :refused} =
             Repo.transaction(fn ->
               announce(topic, :changed)
               Repo.rollback(:refused)
             end)

    assert {:error, :failed_step, :refused, %{}} =
             Ecto.Multi.new()
             |> Ecto.Multi.run(:announced, fn _repo, _changes ->
               {:ok, announce(topic, :from_multi)}
             end)
             |> Ecto.Multi.run(:failed_step, fn _repo, _changes -> {:error, :refused} end)
             |> Repo.transaction()

    assert_raise RuntimeError, fn ->
      Repo.transaction(fn ->
        announce(topic, :raised)
        raise "the write failed"
      end)
    end

    refute_received {:announced, _change}
  end

  test "an announcement outside any transaction is sent at once", %{topic: topic} do
    announce(topic, :changed)
    assert_received {:announced, :changed}
  end

  # Custody composes: a context's write joins the caller's transaction, so its
  # announcement must wait for the caller's commit, not its own return.
  test "a nested transaction's announcement waits for the outermost commit", %{topic: topic} do
    {:ok, :outer} =
      Repo.transaction(fn ->
        {:ok, :inner} =
          Repo.transaction(fn ->
            announce(topic, :inner)
            :inner
          end)

        refute_received {:announced, :inner}
        :outer
      end)

    assert_received {:announced, :inner}

    {:error, :outer_refused} =
      Repo.transaction(fn ->
        {:ok, :ok} = Repo.transaction(fn -> announce(topic, :undone) end)
        Repo.rollback(:outer_refused)
      end)

    refute_received {:announced, :undone}
  end

  # PostgreSQL has one transaction per connection, and a nested one that fails
  # dooms it: the outer commit becomes a rollback, so nothing either announced
  # may be sent.
  test "a nested transaction that fails takes every announcement of the transaction with it",
       %{topic: topic} do
    {:error, :rollback} =
      Repo.transaction(fn ->
        announce(topic, :outer)

        {:error, :inner_refused} =
          Repo.transaction(fn ->
            announce(topic, :inner)
            Repo.rollback(:inner_refused)
          end)

        :continued_anyway
      end)

    refute_received {:announced, _change}
  end

  test "the same announcement made twice before one commit is sent once", %{topic: topic} do
    {:ok, _} =
      Repo.transaction(fn ->
        announce(topic, :changed)
        announce(topic, :changed)
        announce(topic, :other)
      end)

    assert_received {:announced, :changed}
    assert_received {:announced, :other}
    refute_received {:announced, :changed}
  end

  test "an announcement that fails does not turn a committed write into an error", %{
    topic: topic
  } do
    {:ok, :written} =
      Repo.transaction(fn ->
        :ok = Repo.after_commit(fn -> raise "the bus is down" end)
        announce(topic, :changed)
        :written
      end)

    assert_received {:announced, :changed}
  end

  defp announce(topic, change),
    do: Repo.after_commit(fn -> Ryker.PubSub.broadcast(topic, {:announced, change}) end)
end
