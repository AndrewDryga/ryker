defmodule Responder.Slack.ReactionEvent do
  @moduledoc """
  Normalizes authenticated Slack emoji feedback on Responder replies.

  Reactions are passive episode context. They never enter generic ingress,
  wake a model turn, or grant authority. Only a user reaction on a message
  authored by this exact configured bot identity is accepted.
  """

  @identity_fields [:bot_ref, :bot_user_ref, :workspace_ref]
  @emoji_name ~r/\A[a-z0-9_+\-]{1,100}\z/

  @spec from_socket(map(), map()) ::
          {:ok, Responder.Episodes.Reactions.attributes()} | :ignore | {:error, term()}
  def from_socket(
        %{
          "payload" => %{
            "event" => %{"type" => type} = event,
            "event_id" => event_ref,
            "team_id" => workspace_ref,
            "type" => "event_callback"
          },
          "type" => "events_api"
        },
        %{workspace_ref: workspace_ref} = identity
      )
      when type in ["reaction_added", "reaction_removed"] do
    with :ok <- identity(identity),
         :ok <- authored_by_responder(event, identity),
         :ok <- not_self(event, identity),
         :ok <- reference(event_ref, :event_ref),
         :ok <- reference(event["user"], :actor_ref),
         :ok <- emoji(event["reaction"]),
         {:ok, item} <- message_item(event["item"]),
         {:ok, occurred_at} <- timestamp(event["event_ts"]) do
      {:ok,
       %{
         action: if(type == "reaction_added", do: :add, else: :remove),
         actor_ref: event["user"],
         emoji_name: event["reaction"],
         event_ref: event_ref,
         occurred_at: occurred_at,
         source: %{kind: "slack", ref: workspace_ref},
         target: %{
           conversation_ref: "slack:#{workspace_ref}:#{item.channel_ref}",
           message_ref: item.message_ref,
           transport: "slack"
         }
       }}
    end
  end

  def from_socket(_envelope, _identity), do: :ignore

  defp authored_by_responder(%{"item_user" => bot_user_ref}, %{bot_user_ref: bot_user_ref}),
    do: :ok

  defp authored_by_responder(%{"item_user" => item_user}, _identity)
       when is_binary(item_user) and item_user != "",
       do: :ignore

  defp authored_by_responder(_event, _identity),
    do: {:error, {:invalid_slack_reaction_event, :item_user}}

  defp not_self(%{"user" => bot_user_ref}, %{bot_user_ref: bot_user_ref}), do: :ignore
  defp not_self(_event, _identity), do: :ok

  defp message_item(%{"channel" => channel_ref, "ts" => message_ref, "type" => "message"}) do
    with :ok <- reference(channel_ref, :channel_ref),
         :ok <- reference(message_ref, :message_ref) do
      {:ok, %{channel_ref: channel_ref, message_ref: message_ref}}
    end
  end

  defp message_item(%{}), do: {:error, {:invalid_slack_reaction_event, :item}}
  defp message_item(_item), do: {:error, {:invalid_slack_reaction_event, :item}}

  defp timestamp(value) do
    case Regex.run(~r/\A([0-9]{10,})\.([0-9]{1,6})\z/, value || "") do
      [_whole, seconds, fraction] ->
        microseconds =
          String.to_integer(seconds) * 1_000_000 +
            ((fraction <> String.duplicate("0", 6 - byte_size(fraction))) |> String.to_integer())

        case DateTime.from_unix(microseconds, :microsecond) do
          {:ok, datetime} -> {:ok, datetime}
          {:error, _reason} -> {:error, {:invalid_slack_reaction_event, :timestamp}}
        end

      _invalid ->
        {:error, {:invalid_slack_reaction_event, :timestamp}}
    end
  end

  defp identity(%{} = identity) do
    if Map.keys(identity) |> Enum.sort() == Enum.sort(@identity_fields) and
         Enum.all?(@identity_fields, &(reference(Map.fetch!(identity, &1), &1) == :ok)),
       do: :ok,
       else: {:error, {:invalid_slack_reaction_event, :identity}}
  end

  defp identity(_identity), do: {:error, {:invalid_slack_reaction_event, :identity}}

  defp emoji(value) do
    if is_binary(value) and Regex.match?(@emoji_name, value),
      do: :ok,
      else: {:error, {:invalid_slack_reaction_event, :emoji_name}}
  end

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: {:error, {:invalid_slack_reaction_event, field}}
  end
end
