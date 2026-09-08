defmodule Responder.State.MemorySourceLink do
  @moduledoc false
  alias Responder.Slack.SourceRef

  # Return a usable existing reader invocation, not an invented original quote.
  # The platform reader rechecks current source access when this is followed.
  def message("slack", conversation, message)
      when is_binary(conversation) and is_binary(message) do
    with ["slack", workspace, channel] <- String.split(conversation, ":"),
         ref = "slack-source:v1:#{workspace}:#{channel}:message:#{message}",
         {:ok, _} <- SourceRef.parse(ref, workspace) do
      %{
        "tool" => "read_slack_source",
        "arguments" => %{"source_ref" => ref, "view" => "surrounding", "limit" => 20}
      }
    else
      _ -> nil
    end
  end

  def message(_, _, _), do: nil
end
