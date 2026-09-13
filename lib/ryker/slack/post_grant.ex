defmodule Ryker.Slack.PostGrant do
  @moduledoc false

  alias Ryker.Slack.SourceRef

  @channel_target ~r/\A<#([A-Z0-9]+)(?:\|[^>\r\n]*)?>\z/u
  @permalink_path ~r/\A\/archives\/([A-Z0-9]+)\/p([0-9]{16,22})\z/u
  @timestamp ~r/\A[0-9]{10,}.[0-9]{1,6}\z/u

  @spec destination_refs(String.t(), String.t(), String.t()) :: [String.t()]
  def destination_refs(text, workspace_ref, bot_user_ref)
      when is_binary(text) and is_binary(workspace_ref) and is_binary(bot_user_ref) do
    bot = Regex.escape(bot_user_ref)

    pattern =
      ~r/\A[ \t]*(?:<@#{bot}>[ \t]+)?[Pp][Oo][Ss][Tt][ \t]+[Tt][Oo][ \t]+(?<target><#[A-Z0-9]+(?:\|[^>\r\n]*)?>|<https:\/\/[^>\r\n]+>)[ \t]*:[ \t]*\S/u

    case Regex.named_captures(pattern, text) do
      %{"target" => target} ->
        case destination_ref(target, workspace_ref) do
          {:ok, ref} -> [ref]
          :error -> []
        end

      nil ->
        []
    end
  rescue
    _error -> []
  end

  def destination_refs(_text, _workspace_ref, _bot_user_ref), do: []

  defp destination_ref(target, workspace_ref) do
    case Regex.run(@channel_target, target) do
      [_whole, channel_ref] -> {:ok, SourceRef.channel(workspace_ref, channel_ref)}
      nil -> permalink_ref(target, workspace_ref)
    end
  end

  defp permalink_ref("<" <> wrapped, workspace_ref) do
    with true <- String.ends_with?(wrapped, ">"),
         value <- String.trim_trailing(wrapped, ">"),
         url <- value |> String.split("|", parts: 2) |> hd(),
         %URI{host: host, path: path, query: query, scheme: "https"} <- URI.parse(url),
         true <- is_binary(host) and String.ends_with?(String.downcase(host), ".slack.com"),
         [_, channel_ref, path_timestamp] <- Regex.run(@permalink_path, path),
         {:ok, message_ref} <- thread_timestamp(query, path_timestamp) do
      {:ok, SourceRef.thread(workspace_ref, channel_ref, message_ref)}
    else
      _invalid -> :error
    end
  end

  defp permalink_ref(_target, _workspace_ref), do: :error

  defp thread_timestamp(query, path_timestamp) do
    parameters = if is_binary(query), do: URI.decode_query(query), else: %{}

    case Map.get(parameters, "thread_ts") do
      nil -> path_timestamp(path_timestamp)
      value when is_binary(value) -> valid_timestamp(value)
      _invalid -> :error
    end
  end

  defp path_timestamp(value) do
    split = byte_size(value) - 6
    <<seconds::binary-size(split), fraction::binary-size(6)>> = value
    valid_timestamp(seconds <> "." <> fraction)
  end

  defp valid_timestamp(value) do
    if Regex.match?(@timestamp, value), do: {:ok, value}, else: :error
  end
end
