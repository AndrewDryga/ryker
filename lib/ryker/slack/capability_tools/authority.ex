defmodule Ryker.Slack.CapabilityTools.Authority do
  @moduledoc """
  What a Slack capability call is allowed to touch.

  The Work binding names the current channel; the episode's active human
  inputs name the message a reaction may answer, the instruction that granted
  an additional post and the event whose action token search checks out; and
  Slack's own conversation record decides whether a channel is visible.
  """

  import Ecto.Query

  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Repo
  alias Ryker.Slack.CapabilityTools.Arguments
  alias Ryker.Work.Turn

  # A post may only land in a joined, non-shared channel; a private one only
  # when it is the current channel.
  @spec post_destination_authorized(map(), map(), String.t()) :: :ok | {:error, atom()}
  def post_destination_authorized(
        %{
          "id" => channel_ref,
          "is_archived" => archived,
          "is_ext_shared" => external,
          "is_private" => private
        } = conversation,
        %{channel_ref: channel_ref},
        current_channel_ref
      )
      when is_boolean(archived) and is_boolean(external) and is_boolean(private) do
    current = channel_ref == current_channel_ref
    joined = Map.get(conversation, "is_member", current) == true

    if not archived and not external and joined and (not private or current),
      do: :ok,
      else: {:error, :unauthorized}
  end

  def post_destination_authorized(_conversation, _destination, _current_channel_ref),
    do: {:error, :slack_protocol_error}

  # A source is readable when its channel is not externally shared and, if
  # private, is the current channel.
  @spec source_authorized(map(), map(), String.t()) :: :ok | {:error, atom()}
  def source_authorized(
        %{
          "id" => channel_ref,
          "is_archived" => archived,
          "is_ext_shared" => external,
          "is_private" => private
        },
        %{channel_ref: channel_ref},
        current_channel_ref
      )
      when is_boolean(archived) and is_boolean(external) and is_boolean(private) do
    if not external and (not private or channel_ref == current_channel_ref),
      do: :ok,
      else: {:error, :unauthorized}
  end

  def source_authorized(_conversation, _source, _current_channel_ref),
    do: {:error, :slack_protocol_error}

  @doc "The current channel of a live Slack Work binding, or :unauthorized."
  @spec binding(term(), String.t()) :: {:ok, String.t()} | {:error, :unauthorized}
  def binding(
        %{
          episode: %Episode{
            destination_conversation_ref: "slack:" <> _rest = conversation_ref,
            destination_transport: "slack"
          },
          turn: %Turn{id: turn_id}
        },
        workspace_ref
      )
      when is_binary(turn_id) do
    case Arguments.conversation(conversation_ref, workspace_ref) do
      {:ok, channel_ref} -> {:ok, channel_ref}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  def binding(_binding, _workspace_ref), do: {:error, :unauthorized}

  @doc "The active human input on exactly this message, which a reaction may answer."
  @spec current_slack_input(term(), map()) :: {:ok, map()} | {:error, :unauthorized}
  def current_slack_input(%{episode: %Episode{} = episode}, source) do
    conversation_ref = "slack:#{source.workspace_ref}:#{source.channel_ref}"

    episode
    |> active_input_events()
    |> Enum.find_value({:error, :unauthorized}, fn event ->
      case event.payload do
        %{
          "payload" =>
            %{
              "actor" => %{"kind" => "user"},
              "destination" => %{
                "conversation_ref" => ^conversation_ref,
                "transport" => "slack"
              },
              "source" => %{"kind" => "slack", "ref" => workspace_ref},
              "source_capabilities" => %{"react" => _capability},
              "source_item_ref" => message_ref
            } = input
        }
        when workspace_ref == source.workspace_ref and message_ref == source.message_ref ->
          {:ok, input}

        _other ->
          nil
      end
    end)
  end

  def current_slack_input(_binding, _source), do: {:error, :unauthorized}

  @doc false
  @spec authorized_post_instruction?(map(), String.t()) :: boolean()
  def authorized_post_instruction?(
        %{
          "source_capabilities" => %{
            "post_slack_message" => %{"destination_refs" => destination_refs}
          }
        },
        destination_ref
      )
      when is_list(destination_refs) and is_binary(destination_ref) do
    destination_ref in destination_refs
  end

  def authorized_post_instruction?(_input, _destination_ref), do: false

  @doc "The actor of the active human instruction that granted this exact destination."
  @spec current_slack_instruction(term(), map(), String.t()) ::
          {:ok, %{actor_ref: String.t()}} | {:error, :unauthorized}
  def current_slack_instruction(%{episode: %Episode{} = episode}, source, destination_ref) do
    conversation_ref = "slack:#{source.workspace_ref}:#{source.channel_ref}"

    episode
    |> active_input_events()
    |> Enum.find_value(
      {:error, :unauthorized},
      &post_instruction_authority(&1, source, conversation_ref, destination_ref)
    )
  end

  def current_slack_instruction(_binding, _source, _destination_ref),
    do: {:error, :unauthorized}

  defp post_instruction_authority(
         %{
           payload: %{
             "actor_ref" => "slack:user:" <> _user_ref = actor_ref,
             "payload" =>
               %{
                 "actor" => %{"kind" => "user"},
                 "destination" => %{
                   "conversation_ref" => conversation_ref,
                   "transport" => "slack"
                 },
                 "source" => %{"kind" => "slack", "ref" => workspace_ref},
                 "source_item_ref" => message_ref
               } = input
           }
         },
         %{workspace_ref: workspace_ref, message_ref: message_ref},
         conversation_ref,
         destination_ref
       ) do
    if authorized_post_instruction?(input, destination_ref),
      do: {:ok, %{actor_ref: actor_ref}},
      else: nil
  end

  defp post_instruction_authority(_event, _source, _conversation_ref, _destination_ref),
    do: nil

  @doc "The event whose process-local action token search may check out."
  @spec current_event_ref(term()) :: {:ok, String.t()} | {:error, atom()}
  def current_event_ref(%{episode: %Episode{} = episode}) do
    episode
    |> active_input_events()
    |> Enum.find_value({:error, :slack_action_token_unavailable}, fn event ->
      input = get_in(event.payload, ["payload"])

      if get_in(input, ["source", "kind"]) == "slack" and is_binary(input["event_ref"]),
        do: {:ok, input["event_ref"]}
    end)
  end

  def current_event_ref(_binding), do: {:error, :slack_action_token_unavailable}

  @spec current_requester_ref(term()) :: {:ok, String.t()} | {:error, atom()}
  def current_requester_ref(%{episode: %Episode{} = episode}) do
    episode
    |> active_input_events()
    |> Enum.find_value({:error, :slack_requester_unavailable}, fn event ->
      case event.payload do
        # Attribution is not authorization: channel visibility was checked
        # before this audit. Retain the host-admitted actor, including durable
        # system wakeups; never invent a human requester for automated work.
        %{"actor_ref" => actor_ref} when is_binary(actor_ref) and byte_size(actor_ref) > 0 ->
          {:ok, actor_ref}

        _payload ->
          nil
      end
    end)
  end

  def current_requester_ref(_binding), do: {:error, :slack_requester_unavailable}

  defp active_input_events(%Episode{id: episode_id, active_input_refs: refs}) do
    refs = Enum.uniq(refs)

    if refs == [] do
      []
    else
      Repo.all(
        from(event in Event,
          where:
            event.episode_id == ^episode_id and event.kind == :input_admitted and
              event.dedupe_key in ^refs,
          order_by: [desc: event.sequence]
        )
      )
    end
  end

  # Search runs from a live, non-shared channel; private is fine here because
  # every result is then checked for public visibility on its own.
  @spec search_destination_authorized(map(), String.t()) :: :ok | {:error, atom()}
  def search_destination_authorized(
        %{
          "id" => channel_ref,
          "is_archived" => archived,
          "is_ext_shared" => external,
          "is_private" => private
        },
        channel_ref
      )
      when is_boolean(archived) and is_boolean(external) and is_boolean(private) do
    if not archived and not external, do: :ok, else: {:error, :unauthorized}
  end

  def search_destination_authorized(_conversation, _channel_ref),
    do: {:error, :slack_protocol_error}

  @doc "Whether a conversation is a live public channel a search result may cite."
  @spec public_search_conversation(map(), String.t()) :: {:ok, boolean()} | {:error, atom()}
  def public_search_conversation(
        %{
          "id" => channel_ref,
          "is_archived" => archived,
          "is_ext_shared" => external,
          "is_private" => private
        },
        channel_ref
      )
      when is_boolean(archived) and is_boolean(external) and is_boolean(private),
      do: {:ok, not archived and not external and not private}

  def public_search_conversation(_conversation, _channel_ref),
    do: {:error, :slack_protocol_error}
end
