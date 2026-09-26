defmodule Ryker.Slack.Client.Reactions do
  @moduledoc """
  Emoji reactions on a message: adding one and taking it away.

  A reaction that is already there, or already gone, is the state that was
  asked for; Slack reports it as an error and the delivery treats it as done.
  """

  alias Ryker.Slack.Client.{Fields, Transport}

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
