defmodule Ryker.Slack.Permalink do
  @moduledoc """
  Builds Slack links from parts the host already holds.

  A permalink is the workspace origin, the channel and the message timestamp.
  The host stored every part but the origin, so a card that wanted to point at
  the exact question or the message it posted could only describe it. The origin
  is one optional setting; without it `archive_url/4` returns `nil` and the card
  says nothing rather than linking nowhere.

  Slack's own redirect needs no origin for channels and people. Messages
  require their workspace's origin; a generic archive URL opens whichever
  workspace the browser defaults to, not necessarily the source workspace.
  """
  alias Ryker.Slack.{ID, Timestamp}

  # Public and private channels and direct messages: only public channels'
  # ids matched until 2026-10-06 (2026-10-04 review).
  @archive_path ~r/\A\/archives\/([CGD][A-Z0-9]{1,256})\/p(\d{10})(\d{6})\z/
  @origin ~r/\Ahttps:\/\/[a-z0-9-]{1,64}\.slack\.com\/?\z/

  @doc "The pattern a Slack workspace's own origin matches, for a changeset's format check."
  @spec origin_pattern() :: Regex.t()
  def origin_pattern, do: @origin

  @doc """
  Slack's redirect to a channel or a person in a workspace; nil unless both
  ids are Slack's.
  """
  @spec app_redirect(term(), term()) :: String.t() | nil
  def app_redirect(workspace_ref, channel_ref) do
    if ID.valid?(workspace_ref) and ID.valid?(channel_ref),
      do: redirect(team: workspace_ref, channel: channel_ref)
  end

  @doc """
  One message in its workspace, opening a reply in its parent thread.
  Unknown origins and invalid identities yield no link, never the browser's
  default workspace. The format is Slack's chat.getPermalink response.
  """
  @spec archive_url(term(), term(), term(), term()) :: String.t() | nil
  def archive_url(workspace_url, channel_ref, message_ref, thread_ref \\ nil) do
    if workspace_origin?(workspace_url) and conversation_id?(channel_ref) and
         Timestamp.valid?(message_ref) do
      origin = String.trim_trailing(workspace_url, "/")
      base = "#{origin}/archives/#{channel_ref}/p#{String.replace(message_ref, ".", "")}"

      if Timestamp.valid?(thread_ref) and thread_ref != message_ref,
        do: base <> "?" <> URI.encode_query(%{"cid" => channel_ref, "thread_ts" => thread_ref}),
        else: base
    end
  end

  @doc "Whether a URL is an exact workspace permalink this builder can produce."
  @spec archive_url?(term()) :: boolean()
  def archive_url?(url) when is_binary(url) and byte_size(url) in 1..2_000 do
    uri = URI.parse(url)

    with host when is_binary(host) <- uri.host,
         path when is_binary(path) <- uri.path,
         [_, channel, seconds, micros] <- Regex.run(@archive_path, path) do
      parameters = URI.decode_query(uri.query || "")

      archive_url("https://" <> host, channel, seconds <> "." <> micros, parameters["thread_ts"]) ==
        url
    else
      _invalid -> false
    end
  rescue
    ArgumentError -> false
  end

  def archive_url?(_url), do: false

  defp workspace_origin?(url) when is_binary(url) do
    Regex.match?(@origin, url) and URI.parse(url).host not in ["app.slack.com", "api.slack.com"]
  end

  defp workspace_origin?(_url), do: false

  defp conversation_id?(<<prefix, _rest::binary>> = ref) when prefix in [?C, ?D, ?G],
    do: ID.valid?(ref)

  defp conversation_id?(_ref), do: false

  defp redirect(parameters), do: "https://slack.com/app_redirect?" <> URI.encode_query(parameters)
end
