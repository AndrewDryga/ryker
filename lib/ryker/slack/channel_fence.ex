defmodule Ryker.Slack.ChannelFence do
  @moduledoc """
  Whether a write may still name a Slack channel, checked under the channel's
  lock: a write lands before a channel change commits, and is erased or
  refused by it, or after, and sees it.

  A write takes the lock shared, so two messages in one channel never take
  turns; a change to the channel (`lock_in_transaction/2`) takes it alone and
  waits for every write in flight. Taking it shared for every write is new on
  2026-10-05: the exclusive lock made a busy channel's messages queue for the
  whole of each other's transactions.
  """

  import Ecto.Query

  alias Ryker.Repo
  alias Ryker.Slack.ChannelMembership

  @spec authorize_in_transaction(String.t(), String.t()) :: :ok | {:error, term()}
  def authorize_in_transaction("slack", "slack:" <> rest) do
    if Repo.in_transaction?() do
      authorize_slack_destination(slack_destination(rest))
    else
      {:error, :slack_channel_fence_transaction_required}
    end
  end

  def authorize_in_transaction(_transport, _conversation_ref) do
    if Repo.in_transaction?(),
      do: :ok,
      else: {:error, :slack_channel_fence_transaction_required}
  end

  @spec authorize_public_in_transaction(String.t(), String.t()) :: :ok | {:error, term()}
  def authorize_public_in_transaction("slack", "slack:" <> rest) do
    if Repo.in_transaction?() do
      authorize_public_destination(slack_destination(rest))
    else
      {:error, :slack_channel_fence_transaction_required}
    end
  end

  def authorize_public_in_transaction(_transport, _conversation_ref) do
    if Repo.in_transaction?(),
      do: {:error, :slack_channel_not_public},
      else: {:error, :slack_channel_fence_transaction_required}
  end

  defp authorize_slack_destination(:direct), do: :ok
  defp authorize_slack_destination(:invalid), do: :ok

  defp authorize_slack_destination({:channel, workspace_ref, channel_ref}) do
    case share_in_transaction(workspace_ref, channel_ref) do
      :ok -> channel_status(workspace_ref, channel_ref)
      {:error, _reason} = error -> error
    end
  end

  defp authorize_public_destination({:channel, workspace_ref, channel_ref}) do
    case share_in_transaction(workspace_ref, channel_ref) do
      :ok -> public_channel_status(workspace_ref, channel_ref)
      {:error, _reason} = error -> error
    end
  end

  defp authorize_public_destination(_direct_or_invalid), do: {:error, :slack_channel_not_public}

  defp channel_status(workspace_ref, channel_ref) do
    case Repo.one(
           from(membership in ChannelMembership,
             where:
               membership.workspace_ref == ^workspace_ref and
                 membership.channel_ref == ^channel_ref,
             select: membership.status
           )
         ) do
      :deleted -> {:error, :slack_channel_deleted}
      _other -> :ok
    end
  end

  defp public_channel_status(workspace_ref, channel_ref) do
    case Repo.one(
           from(membership in ChannelMembership,
             where:
               membership.workspace_ref == ^workspace_ref and
                 membership.channel_ref == ^channel_ref,
             select: {membership.status, membership.private, membership.external_shared}
           )
         ) do
      {:joined, false, false} -> :ok
      _not_public -> {:error, :slack_channel_not_public}
    end
  end

  defp slack_destination(rest) do
    case String.split(rest, ":", parts: 2) do
      [_workspace_ref, "D" <> _direct] ->
        :direct

      [workspace_ref, channel_ref] when workspace_ref != "" and channel_ref != "" ->
        {:channel, workspace_ref, channel_ref}

      _invalid ->
        :invalid
    end
  end

  @doc "Holds the channel's lock alone until the transaction ends: a change to the channel."
  @spec lock_in_transaction(String.t(), String.t()) :: :ok | {:error, term()}
  def lock_in_transaction(workspace_ref, channel_ref),
    do: take(workspace_ref, channel_ref, "pg_advisory_xact_lock")

  defp share_in_transaction(workspace_ref, channel_ref),
    do: take(workspace_ref, channel_ref, "pg_advisory_xact_lock_shared")

  defp take(workspace_ref, channel_ref, function) do
    if Repo.in_transaction?() do
      key = "slack-configuration:#{workspace_ref}:#{channel_ref}"

      case Repo.query("SELECT #{function}(hashtextextended($1, 0))", [key]) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, {:store_failed, :configuration_lock, reason}}
      end
    else
      {:error, :slack_channel_fence_transaction_required}
    end
  end
end
