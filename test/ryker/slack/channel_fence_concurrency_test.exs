defmodule Ryker.Slack.ChannelFenceConcurrencyTest do
  @moduledoc """
  Writes that name one channel go side by side; only a change to the channel
  waits for them.

  Every write that names a channel checked it under one exclusive lock, so two
  messages in a busy channel took turns for the whole of their transactions,
  and tests sharing a channel id queued behind each other until one timed out
  after fifteen seconds (gate runs of 2026-10-04 and 2026-10-05).

  These commit for real, on connections of their own; they write nothing.
  """
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Repo
  alias Ryker.Slack.ChannelFence

  @conversation "slack:TFENCE:CFENCE"

  test "two writes to one channel do not wait on each other, and a channel change waits for them" do
    Sandbox.unboxed_run(Repo, fn ->
      parent = self()

      holder =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            :ok = ChannelFence.authorize_in_transaction("slack", @conversation)
            send(parent, {:holding, backend_pid()})

            receive do
              :release -> :ok
            after
              5_000 -> :ok
            end
          end)
        end)

      assert_receive {:holding, holder_backend}, 5_000

      writer =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            ChannelFence.authorize_in_transaction("slack", @conversation)
          end)
        end)

      # The change starts only once the write is done: PostgreSQL queues a
      # shared request behind an exclusive one already waiting, so a change
      # that got there first made the write wait too (gate, 2026-10-05).
      try do
        assert Task.yield(writer, 2_000) == {:ok, {:ok, :ok}},
               "a second write to the channel waited for the first"

        change =
          unboxed_task(fn ->
            send(parent, {:changing, backend_pid()})
            Repo.transaction(fn -> ChannelFence.lock_in_transaction("TFENCE", "CFENCE") end)
          end)

        try do
          assert_receive {:changing, change_backend}, 5_000
          assert await_blocked_by(change_backend, holder_backend) == :ok

          send(holder.pid, :release)
          assert Task.await(holder, 5_000) == {:ok, :ok}
          assert Task.await(change, 5_000) == {:ok, :ok}
        after
          stop_tasks([change])
        end
      after
        stop_tasks([holder, writer])
      end
    end)
  end
end
