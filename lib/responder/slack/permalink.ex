defmodule Responder.Slack.Permalink do
  @moduledoc """
  Builds a Slack message link from parts the host already holds.

  A permalink is the workspace origin, the channel and the message timestamp.
  The host stored every part but the origin, so a card that wanted to point at
  the exact question or the message it posted could only describe it. The origin
  is one optional setting; without it this returns `nil` and the card says
  nothing rather than linking nowhere.
  """

  @conversation ~r/\Aslack:T[A-Z0-9]{1,20}:(C[A-Z0-9]{1,20})\z/
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
end
