defmodule Ryker.Slack.Client.Reactions do
  @moduledoc """
  Emoji reactions on a message: adding one and taking it away.

  A reaction that is already there, or already gone, is the state that was
  asked for; Slack reports it as an error and the delivery treats it as done.
  """
  alias Ryker.Slack.Client.{Fields, Transport}
  alias Ryker.Slack.EmojiCatalog

  @doc "Lists the workspace's custom emoji names and aliases, with no image URLs."
  def list_emoji(client) do
    with {:ok, response} <- Transport.request(client, :get, "/emoji.list", %{}),
         {:ok, body} <- Transport.response(response) do
      case body do
        %{"emoji" => %{} = emoji} -> {:ok, EmojiCatalog.document(emoji)}
        _invalid -> {:error, {:slack_protocol_error, :emoji}}
      end
    end
  end

  def add_reaction(client, channel, message_ref, emoji_name) do
    with :ok <- Fields.text(channel),
         :ok <- Fields.text(message_ref),
         :ok <- Fields.text(emoji_name),
         {:ok, response} <-
           Transport.request(client, :post, "/reactions.add", %{
             "channel" => channel,
             "name" => emoji_name,
             "timestamp" => message_ref
           }) do
      reaction_response(response, "already_reacted")
    end
  end

  @doc "Read the installed bot's own reaction to this exact message after a lost write response."
  def reaction_present?(client, channel, timestamp, name, bot_user_ref) do
    with :ok <- Fields.slack_id(channel),
         :ok <- Fields.message_timestamp(timestamp),
         :ok <- Fields.text(name),
         :ok <- Fields.slack_id(bot_user_ref),
         path = "/reactions.get?" <> URI.encode_query(channel: channel, timestamp: timestamp),
         {:ok, response} <- Transport.request(client, :get, path, nil),
         {:ok, body} <- Transport.response(response),
         %{
           "channel" => ^channel,
           "type" => "message",
           "message" => %{"ts" => ^timestamp} = message
         } <- body,
         reactions when is_list(reactions) <- Map.get(message, "reactions", []) do
      {:ok,
       Enum.any?(reactions, fn
         %{"name" => ^name, "users" => users} when is_list(users) -> bot_user_ref in users
         _ -> false
       end)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:slack_protocol_error, :reaction}}
    end
  end

  def remove_reaction(client, channel, message_ref, emoji_name) do
    with :ok <- Fields.text(channel),
         :ok <- Fields.text(message_ref),
         :ok <- Fields.text(emoji_name),
         {:ok, response} <-
           Transport.request(client, :post, "/reactions.remove", %{
             "channel" => channel,
             "name" => emoji_name,
             "timestamp" => message_ref
           }) do
      reaction_response(response, "no_reaction")
    end
  end

  defp reaction_response(%{body: %{"error" => settled, "ok" => false}, status: 200}, settled),
    do: :ok

  defp reaction_response(response, _settled),
    do: response |> Transport.response() |> Transport.success()
end
