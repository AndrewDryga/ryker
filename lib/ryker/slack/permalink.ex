defmodule Ryker.Slack.Permalink do
  @moduledoc """
  Builds Slack links from parts the host already holds.

  A permalink is the workspace origin, the channel and the message timestamp.
  The host stored every part but the origin, so a card that wanted to point at
  the exact question or the message it posted could only describe it. The origin
  is one optional setting; without it `message_url/3` returns `nil` and the card
  says nothing rather than linking nowhere.

  Slack's own redirect needs no origin: `app_redirect/2,3` opens a channel, a
  person's messages or a message through slack.com, in the app when it is
  installed.
  """
  alias Ryker.Slack.{Id, Timestamp}

  # Public and private channels and direct messages: only public channels'
  # ids matched until 2026-10-06 (2026-10-04 review).
  @conversation ~r/\Aslack:T[A-Z0-9]{1,20}:([CGD][A-Z0-9]{1,20})\z/
  @message ~r/\A\d{10}\.\d{6}\z/
  @origin ~r/\Ahttps:\/\/[a-z0-9-]{1,64}\.slack\.com\/?\z/

  @spec message_url(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t() | nil
  def message_url(workspace_url, conversation_ref, message_ref)
      when is_binary(workspace_url) and is_binary(conversation_ref) and is_binary(message_ref) do
    with true <- Regex.match?(@origin, workspace_url),
         [_all, channel] <- Regex.run(@conversation, conversation_ref) || :no_channel,
         true <- Regex.match?(@message, message_ref) do
      "#{String.trim_trailing(workspace_url, "/")}/archives/#{channel}/p#{String.replace(message_ref, ".", "")}"
    else
      _unbuildable -> nil
    end
  end

  def message_url(_workspace_url, _conversation_ref, _message_ref), do: nil

  @doc "The pattern a Slack workspace's own origin matches, for a changeset's format check."
  @spec origin_pattern() :: Regex.t()
  def origin_pattern, do: @origin

  @doc """
  Slack's redirect to a channel or a person in a workspace; nil unless both
  ids are Slack's.
  """
  @spec app_redirect(term(), term()) :: String.t() | nil
  def app_redirect(workspace_ref, channel_ref) do
    if Id.valid?(workspace_ref) and Id.valid?(channel_ref),
      do: redirect(team: workspace_ref, channel: channel_ref)
  end

  @doc """
  Slack's redirect to one message in a channel; nil unless the ids and the
  message's timestamp are Slack's.
  """
  @spec app_redirect(term(), term(), term()) :: String.t() | nil
  def app_redirect(workspace_ref, channel_ref, message_ref) do
    if Id.valid?(workspace_ref) and Id.valid?(channel_ref) and Timestamp.valid?(message_ref),
      do: redirect(team: workspace_ref, channel: channel_ref, message_ts: message_ref)
  end

  @doc """
  Slack's link to one message through slack.com, opening a reply in its thread
  when `thread_ref` is a different message; nil unless the channel is a
  channel or a direct message and both timestamps are Slack's.
  """
  @spec archive_url(term(), term(), term()) :: String.t() | nil
  def archive_url(channel_ref, message_ref, thread_ref \\ nil) do
    if conversation_id?(channel_ref) and Timestamp.valid?(message_ref) do
      base = "https://slack.com/archives/#{channel_ref}/p#{String.replace(message_ref, ".", "")}"

      if Timestamp.valid?(thread_ref) and thread_ref != message_ref,
        do: base <> "?" <> URI.encode_query(%{"cid" => channel_ref, "thread_ts" => thread_ref}),
        else: base
    end
  end

  defp conversation_id?(<<prefix, _rest::binary>> = ref) when prefix in [?C, ?D, ?G],
    do: Id.valid?(ref)

  defp conversation_id?(_ref), do: false

  defp redirect(parameters), do: "https://slack.com/app_redirect?" <> URI.encode_query(parameters)
end
