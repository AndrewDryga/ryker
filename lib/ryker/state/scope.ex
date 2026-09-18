defmodule Ryker.State.Scope do
  @moduledoc """
  The workspace a destination belongs to.

  Memory, guidance and automations are scoped to a Slack workspace or a GitHub
  binding; every other transport's conversation is its own workspace.
  """

  alias Ryker.Episodes.Episode

  @spec workspace_ref(Episode.t()) :: String.t()
  def workspace_ref(%Episode{} = episode),
    do: workspace_ref(episode.destination_transport, episode.destination_conversation_ref)

  @spec workspace_ref(String.t() | nil, String.t()) :: String.t()
  def workspace_ref("slack", conversation_ref) do
    case String.split(conversation_ref, ":", parts: 3) do
      ["slack", workspace_ref, _channel_ref] -> "slack:#{workspace_ref}"
      _invalid -> conversation_ref
    end
  end

  def workspace_ref("github", conversation_ref) do
    case String.split(conversation_ref, ":", parts: 3) do
      ["github", binding_ref, _rest] -> "github:#{binding_ref}"
      _invalid -> conversation_ref
    end
  end

  def workspace_ref(_transport, conversation_ref), do: conversation_ref
end
