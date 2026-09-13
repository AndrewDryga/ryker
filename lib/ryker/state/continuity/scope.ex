defmodule Ryker.State.Continuity.Scope do
  @moduledoc """
  Where a destination's continuity lives and how far it travels.

  A destination resolves to a workspace, a visibility and an identity key. The
  visibility decides who may recall a summary: a joined, internal, public Slack
  channel shares with the other public channels of its workspace, while a
  private, externally shared, direct or unknown channel and every other
  transport stay inside their own conversation.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Repo
  alias Ryker.Slack.ChannelMembership
  alias Ryker.State.ConversationSummary
  alias Ryker.State.Scope, as: WorkspaceScope

  @doc """
  The continuity scope of an episode's destination: its transport, conversation,
  thread, workspace, visibility, identity key and repository.
  """
  @spec destination_context(map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def destination_context(episode, repository_ref) do
    with {:ok, workspace_ref, visibility} <-
           destination_scope(episode.destination_transport, episode.destination_conversation_ref) do
      identity_key =
        CanonicalJSON.digest(%{
          "conversation_ref" => episode.destination_conversation_ref,
          "thread_ref" => episode.destination_thread_ref,
          "transport" => episode.destination_transport
        })

      {:ok,
       %{
         conversation_ref: episode.destination_conversation_ref,
         identity_key: identity_key,
         repository_ref: repository_ref,
         thread_ref: episode.destination_thread_ref,
         transport: episode.destination_transport,
         visibility: visibility,
         workspace_ref: workspace_ref
       }}
    end
  end

  # The workspace is the plain `Ryker.State.Scope` derivation. This also
  # validates the destination shape and resolves the Slack channel's visibility.
  defp destination_scope("slack", "slack:" <> rest = conversation_ref) do
    workspace_ref = WorkspaceScope.workspace_ref("slack", conversation_ref)

    case String.split(rest, ":", parts: 2) do
      [_workspace, "D" <> _channel] ->
        {:ok, workspace_ref, :direct}

      [workspace, channel_ref] ->
        {:ok, workspace_ref, slack_visibility(workspace, channel_ref)}

      _invalid ->
        {:ok, workspace_ref, :conversation}
    end
  end

  defp destination_scope("github", "github:" <> rest = conversation_ref) do
    case String.split(rest, ":", parts: 2) do
      [binding_ref, _conversation] when binding_ref != "" ->
        {:ok, WorkspaceScope.workspace_ref("github", conversation_ref), :conversation}

      _invalid ->
        {:ok, conversation_ref, :conversation}
    end
  end

  defp destination_scope("control_plane", "control-plane:" <> _rest = conversation_ref),
    do: {:ok, conversation_ref, :conversation}

  defp destination_scope(transport, conversation_ref)
       when is_binary(transport) and byte_size(transport) in 1..64 and
              is_binary(conversation_ref) and byte_size(conversation_ref) in 1..1_024,
       do: {:ok, conversation_ref, :conversation}

  defp destination_scope(_transport, _conversation_ref),
    do: {:error, :conversation_summary_destination}

  @doc """
  Whether a summary comes from a Slack channel the host has joined that is
  neither private nor externally shared. Only such a channel shares its
  continuity with the other public channels of its workspace.
  """
  @spec public_source_visible?(term()) :: boolean()
  def public_source_visible?(%ConversationSummary{} = summary) do
    case slack_channel(summary) do
      {workspace_ref, channel_ref} ->
        Repo.exists?(
          from(membership in ChannelMembership,
            where:
              membership.workspace_ref == ^workspace_ref and
                membership.channel_ref == ^channel_ref and membership.status == :joined and
                membership.private == false and membership.external_shared == false
          )
        )

      nil ->
        false
    end
  end

  def public_source_visible?(_non_slack), do: false

  @doc """
  The visibility of a Slack channel: `:public` for a joined internal channel,
  `:private` for a joined private or externally shared one, and `:conversation`
  when the host has not joined it.
  """
  @spec slack_visibility(String.t(), String.t()) :: :public | :private | :conversation
  def slack_visibility(workspace_ref, channel_ref) do
    case Repo.one(
           from(membership in ChannelMembership,
             where:
               membership.workspace_ref == ^workspace_ref and
                 membership.channel_ref == ^channel_ref and membership.status == :joined,
             select: {membership.private, membership.external_shared}
           )
         ) do
      {false, false} ->
        :public

      {private, external_shared}
      when is_boolean(private) and is_boolean(external_shared) ->
        :private

      _unknown ->
        :conversation
    end
  end

  @doc """
  The `{workspace_ref, channel_ref}` a Slack summary belongs to, or nil when it
  is not a Slack summary or its conversation does not sit inside its workspace.

  The host writes a Slack conversation as `slack:<workspace>:<channel>`. A
  channel ref may contain colons; a workspace ref never does.
  """
  @spec slack_channel(term()) :: {String.t(), String.t()} | nil
  def slack_channel(%{
        transport: "slack",
        workspace_ref: "slack:" <> workspace_ref,
        conversation_ref: conversation_ref
      }) do
    case String.split(conversation_ref, ":", parts: 3) do
      ["slack", ^workspace_ref, channel_ref] -> {workspace_ref, channel_ref}
      _invalid -> nil
    end
  end

  def slack_channel(_other), do: nil
end
