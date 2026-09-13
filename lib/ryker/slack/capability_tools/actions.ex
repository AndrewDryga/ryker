defmodule Ryker.Slack.CapabilityTools.Actions do
  @moduledoc """
  The two Slack tools that change something: a reaction frozen into platform
  custody, and an additional post offered for human confirmation. Neither
  reaches Slack from here; both leave an exact durable intent behind.
  """

  alias Ryker.CanonicalJSON
  alias Ryker.Slack.SourceRef
  alias Ryker.State.Records

  @doc "The platform action a reaction request freezes on the current human input."
  @spec reaction_attributes(map(), map(), String.t(), String.t()) :: map()
  def reaction_attributes(input, source, action, emoji_name) do
    %{
      conversation_ref: input["destination"]["conversation_ref"],
      document: %{"action" => action, "emoji_name" => emoji_name},
      host_slot: "reaction",
      kind: :reaction,
      source_item_ref: source.message_ref,
      thread_ref: input["destination"]["thread_ref"],
      tool: :set_slack_reaction,
      transport: "slack"
    }
  end

  # Removal is limited to a reaction Ryker itself delivered on that message.
  @spec removal_authorized(String.t(), map(), map(), String.t(), map()) ::
          :ok | {:error, :unauthorized}
  def removal_authorized("add", _binding, _source, _emoji_name, _options), do: :ok

  def removal_authorized("remove", binding, source, emoji_name, options) do
    conversation_ref = "slack:#{source.workspace_ref}:#{source.channel_ref}"

    if options.reaction_added.(
         binding.episode.id,
         conversation_ref,
         source.message_ref,
         emoji_name
       ),
       do: :ok,
       else: {:error, :unauthorized}
  end

  @doc "The inert slack_post_offer record a human must confirm before anything is posted."
  @spec post_offer_payload(map(), map(), String.t(), String.t()) :: map()
  def post_offer_payload(destination, instruction, message, actor_ref) do
    destination_ref = SourceRef.encode(destination)
    instruction_ref = SourceRef.encode(instruction)

    %{
      "conversation_ref" => "slack:#{destination.workspace_ref}:#{destination.channel_ref}",
      "destination_ref" => destination_ref,
      "instruction_ref" => instruction_ref,
      "message" => message,
      "requested_by_actor_ref" => actor_ref,
      "thread_ref" => if(destination.kind == :thread, do: destination.message_ref, else: nil),
      "transport" => "slack"
    }
  end

  @spec propose_slack_post(map(), map()) :: {:ok, map()} | {:error, term()}
  def propose_slack_post(%{state_token: state_token}, payload) when is_binary(state_token) do
    operation_id =
      "slack-post:" <>
        (payload
         |> CanonicalJSON.digest()
         |> binary_part(0, 32))

    Records.create(state_token, operation_id, "slack_post_offer", payload)
  end

  def propose_slack_post(_binding, _payload), do: {:error, :unauthorized}
end
