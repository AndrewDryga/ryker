defmodule Ryker.Admission.CorrelationScope do
  @moduledoc """
  Which conversations one incoming source may be correlated against.

  Read scope is not episode membership and never becomes posting permission.
  Only joined, non-private, non-externally-shared channels of the same Slack
  workspace may correlate with each other. Direct messages, private channels,
  externally shared channels, other workspaces, and every non-Slack transport
  stay inside their own conversation, so bot membership in two restricted
  channels never establishes a common audience.
  """
  alias Ryker.ConversationRef
  alias Ryker.Ingress
  alias Ryker.Repo
  alias Ryker.Slack

  @maximum_conversations 500

  @type t :: %{
          kind: :conversation | :workspace_public,
          conversation_ref: String.t(),
          transport: String.t(),
          conversation_refs: [String.t()],
          truncated: boolean()
        }

  @spec for_input(Ingress.Input.t()) :: t()
  def for_input(%Ingress.Input{destination: destination}), do: for_destination(destination)

  @spec for_destination(map()) :: t()
  def for_destination(%{transport: "slack", conversation_ref: conversation_ref} = destination) do
    case ConversationRef.parse_slack(conversation_ref) do
      {:ok, _workspace_ref, "D" <> _direct_message} ->
        conversation_only(destination)

      {:ok, workspace_ref, channel_ref} ->
        workspace_scope(destination, workspace_ref, channel_ref)

      :error ->
        conversation_only(destination)
    end
  end

  def for_destination(destination), do: conversation_only(destination)

  @doc "True when the episode's every participating conversation is inside this scope."
  @spec eligible?(t(), [String.t()]) :: boolean()
  def eligible?(scope, conversation_refs) do
    allowed = MapSet.new(scope.conversation_refs)
    conversation_refs != [] and Enum.all?(conversation_refs, &MapSet.member?(allowed, &1))
  end

  defp conversation_only(destination) do
    %{
      kind: :conversation,
      conversation_ref: destination.conversation_ref,
      transport: destination.transport,
      conversation_refs: [destination.conversation_ref],
      truncated: false
    }
  end

  defp workspace_scope(destination, workspace_ref, channel_ref) do
    case fetch_membership(workspace_ref, channel_ref) do
      {:ok, {:joined, false, false}} ->
        {refs, truncated?} = public_conversation_refs(workspace_ref)

        %{
          kind: :workspace_public,
          conversation_ref: destination.conversation_ref,
          transport: destination.transport,
          conversation_refs: Enum.uniq([destination.conversation_ref | refs]),
          truncated: truncated?
        }

      _restricted_or_unknown ->
        conversation_only(destination)
    end
  end

  defp fetch_membership(workspace_ref, channel_ref) do
    workspace_ref
    |> Slack.ChannelMembership.Query.by_channel(channel_ref)
    |> Slack.ChannelMembership.Query.select_audience()
    |> Repo.fetch()
  end

  defp public_conversation_refs(workspace_ref) do
    refs =
      ConversationRef.slack_workspace(workspace_ref)
      |> Slack.ChannelMembership.Query.public_conversation_refs()
      |> Slack.ChannelMembership.Query.ordered_by_channel()
      |> Slack.ChannelMembership.Query.limit_to(@maximum_conversations + 1)
      |> Repo.all()

    {Enum.take(refs, @maximum_conversations), length(refs) > @maximum_conversations}
  end
end
