defmodule Ryker.Slack.ChannelConfigurationsConcurrencyTest do
  @moduledoc """
  Slack deletes a channel while a person's edit or deletion of a message in it
  is being recorded.

  Recording the edit takes the memory review lock and then the channel's
  lock, the order every memory write takes them in. Deleting the channel took
  the channel's lock first and the review lock after it, to erase what Ryker
  remembered of the channel. Each waited on the other until the database
  cancelled one: the edit or deletion was lost, or the channel's deletion
  failed and what Ryker kept of it stayed (found in review, 2026-09-28).

  These commit for real, on connections of their own, and remove what they
  wrote.
  """
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelConfigurations, ChannelMembership, ChannelMembershipEvent}
  alias Ryker.Slack.Input, as: SlackInput

  @workspace "TCHANNELRACE"
  @channel "CCHANNELRACE"

  for {kind, revision} <- [edit: "an edit", delete: "a deletion"] do
    test "#{revision} recorded while its channel is deleted waits instead of deadlocking" do
      Sandbox.unboxed_run(Repo, fn ->
        message_ref = unique_message_ref()

        try do
          assert {:ok, %{status: :recorded}} = Inbox.record(said!(message_ref, :message, 1))
          parent = self()

          deleter =
            unboxed_task(fn ->
              pause_after_locking_the_channel!(parent)

              try do
                safely(&delete_channel/0)
              after
                :telemetry.detach({__MODULE__, self()})
              end
            end)

          assert_receive {:channel_locked, deleter_backend}, 5_000

          recorder =
            unboxed_task(fn ->
              send(parent, {:recorder_ready, backend_pid()})
              safely(fn -> Inbox.record(said!(message_ref, unquote(kind), 2)) end)
            end)

          try do
            assert_receive {:recorder_ready, recorder_backend}, 5_000
            await_blocked_by(recorder_backend, deleter_backend)
            send(deleter.pid, :resume)

            recorded = Task.await(recorder, 10_000)
            deleted = Task.await(deleter, 10_000)

            assert match?({:ok, %{status: :recorded}}, recorded),
                   "#{unquote(revision)} was not recorded: #{inspect(recorded)}"

            assert match?({:ok, %{membership: %{status: :deleted}}}, deleted),
                   "the channel was not deleted: #{inspect(deleted)}"
          after
            send(deleter.pid, :resume)
            stop_tasks([deleter, recorder])
          end
        after
          clean!(message_ref)
        end
      end)
    end
  end

  defp delete_channel do
    ChannelConfigurations.observe_membership(
      %{
        actor_ref: nil,
        channel_ref: @channel,
        event_ref: "event:channel-race:#{Ecto.UUID.generate()}",
        kind: :deleted,
        occurred_at: DateTime.utc_now(),
        workspace_ref: @workspace
      },
      %{default_environment: nil, environments: []}
    )
  end

  # A deadlock is raised in the transaction the database cancels.
  defp safely(fun) do
    fun.()
  rescue
    error in Postgrex.Error -> {:raised, error.postgres[:code]}
  end

  defp pause_after_locking_the_channel!(parent) do
    :ok =
      :telemetry.attach(
        {__MODULE__, self()},
        [:ryker, :repo, :query],
        &__MODULE__.pause_deletion/4,
        {self(), parent, backend_pid()}
      )
  end

  # Once the deletion holds the channel's lock it has not yet erased what
  # Ryker remembered of the channel.
  def pause_deletion(_event, _measurements, %{params: params}, {deleter, parent, backend}) do
    if self() == deleter and not Process.get(:paused?, false) and
         params == ["slack-configuration:#{@workspace}:#{@channel}"] do
      Process.put(:paused?, true)
      :telemetry.detach({__MODULE__, deleter})
      send(parent, {:channel_locked, backend})

      receive do
        :resume -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  def pause_deletion(_event, _measurements, _metadata, _config), do: :ok

  defp said!(message_ref, kind, revision) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "UCHANNELRACE"},
               channel_ref: @channel,
               content: %{
                 "text" =>
                   if(kind == :edit,
                     do: "the staging account is acme-stg",
                     else: "the staging account is acme-staging"
                   )
               },
               event_kind: kind,
               event_ref: "Ev-channel-race-#{kind}-#{message_ref}",
               message_ref: message_ref,
               occurred_at: DateTime.add(DateTime.utc_now(), revision * 60 - 300, :second),
               revision: revision,
               thread_ref: nil,
               workspace_ref: @workspace
             })

    input
  end

  defp unique_message_ref,
    do: "1790400000." <> String.pad_leading("#{System.unique_integer([:positive])}", 6, "0")

  defp clean!(message_ref) do
    delete_entries!(
      from(entry in Entry,
        where: entry.source_ref == @workspace and entry.source_item_ref == ^message_ref
      )
    )

    Repo.delete_all(
      from(note in ConversationObservation, where: note.workspace_ref == ^"slack:#{@workspace}")
    )

    Repo.delete_all(
      from(event in ChannelMembershipEvent, where: event.workspace_ref == @workspace)
    )

    Repo.delete_all(
      from(membership in ChannelMembership, where: membership.workspace_ref == @workspace)
    )
  end
end
