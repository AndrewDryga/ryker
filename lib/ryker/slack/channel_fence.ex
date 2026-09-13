defmodule Ryker.Slack.ChannelFence do
  @moduledoc false

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
    case lock_in_transaction(workspace_ref, channel_ref) do
      :ok -> channel_status(workspace_ref, channel_ref)
      {:error, _reason} = error -> error
    end
  end

  defp authorize_public_destination({:channel, workspace_ref, channel_ref}) do
    case lock_in_transaction(workspace_ref, channel_ref) do
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

  @spec lock_in_transaction(String.t(), String.t()) :: :ok | {:error, term()}
  def lock_in_transaction(workspace_ref, channel_ref) do
    if Repo.in_transaction?() do
      key = "slack-configuration:#{workspace_ref}:#{channel_ref}"

      case Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key]) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, {:store_failed, :configuration_lock, reason}}
      end
    else
      {:error, :slack_channel_fence_transaction_required}
    end
  end
end
