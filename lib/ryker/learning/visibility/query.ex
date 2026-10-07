defmodule Ryker.Learning.Visibility.Query do
  @moduledoc """
  Where something learned from a conversation may be read: in that
  conversation, and, for what was learned in a public Slack channel, in the
  workspace's other public channels. Observations, topics and summaries all
  compose this, by the first binding of the query they are given.
  """
  use Ryker, :query
  alias Ryker.Slack.ChannelMembership

  @doc "Rows readable from `scope`'s conversation."
  def visible_from(queryable, scope), do: where(queryable, ^condition(scope))

  defp condition(%{transport: "slack", visibility: :public} = scope) do
    public = ChannelMembership.Query.public_conversation_refs(scope.workspace_ref)

    dynamic(
      [row],
      row.conversation_ref == ^scope.conversation_ref or
        (row.visibility == :public and row.conversation_ref in subquery(public))
    )
  end

  defp condition(scope), do: dynamic([row], row.conversation_ref == ^scope.conversation_ref)
end
