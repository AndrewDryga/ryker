defmodule Ryker.Slack.Client.Assistant do
  @moduledoc """
  Slack's assistant endpoints: the status line a thread shows while Ryker
  works on it, and a context search made with an action token.

  The search document is checked against the fields and values it may carry
  before the token is spent, and a reply is handed on only within the
  retained bound and with a readable cursor.
  """
  alias Ryker.Slack.Client.{Fields, Transport}

  def set_thread_status(client, channel, thread_ref, status) do
    with :ok <- Fields.slack_id(channel),
         :ok <- Fields.message_timestamp(thread_ref),
         :ok <- Fields.thread_status(status),
         {:ok, response} <-
           Transport.request(client, :post, "/assistant.threads.setStatus", %{
             "channel_id" => channel,
             "status" => status,
             "thread_ts" => thread_ref
           }),
         {:ok, _body} <- Transport.response(response) do
      :ok
    end
  end

  def search_context(client, action_token, document) do
    with :ok <- action_token(action_token),
         :ok <- search_document(document),
         {:ok, response} <-
           Transport.request(
             client,
             :post,
             "/assistant.search.context",
             Map.put(document, "action_token", action_token)
           ),
         {:ok, body} <- Transport.response(response) do
      search_response(body)
    end
  end

  defp action_token(value) do
    if Fields.bounded_text(value, 4_096) == :ok and :binary.match(value, <<0>>) == :nomatch,
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :action_token}}
  end

  defp search_document(%{"query" => query} = document) do
    allowed =
      ~w(after before channel_types content_types context_channel_id cursor include_bots include_context_messages limit query sort sort_dir)

    valid =
      Enum.all?([
        Map.keys(document) -- allowed == [],
        Fields.bounded_text(query, 2_048) == :ok,
        optional_enum_list?(
          document["channel_types"],
          ~w(public_channel private_channel mpim im)
        ),
        optional_enum_list?(document["content_types"], ~w(messages files channels users)),
        optional_boolean?(document["include_bots"]),
        optional_boolean?(document["include_context_messages"]),
        optional_positive_integer?(document["after"]),
        optional_positive_integer?(document["before"]),
        optional_limit?(document["limit"]),
        optional_text?(document["cursor"], 1_024),
        optional_slack_id?(document["context_channel_id"]),
        optional_enum?(document["sort"], ~w(score timestamp)),
        optional_enum?(document["sort_dir"], ~w(asc desc))
      ])

    if valid, do: :ok, else: {:error, {:invalid_slack_api_request, :search}}
  end

  defp search_document(_document), do: {:error, {:invalid_slack_api_request, :search}}

  # Slack puts the continuation in `response_metadata.next_cursor`; the result
  # carries it as `next_cursor`, "" on the last page, which the search tool hands
  # to the model and audits completeness by.
  defp search_response(%{"results" => %{} = _results} = body) do
    cursor = get_in(body, ["response_metadata", "next_cursor"]) || ""

    result =
      body
      |> Map.drop(["next_cursor", "ok", "response_metadata"])
      |> Map.put("next_cursor", cursor)

    if Fields.bounded_result(result, :search) == :ok and search_cursor?(cursor),
      do: {:ok, result},
      else: {:error, {:slack_protocol_error, :search}}
  end

  defp search_response(_body), do: {:error, {:slack_protocol_error, :search}}

  defp optional_enum?(nil, _allowed), do: true
  defp optional_enum?(value, allowed), do: value in allowed

  defp optional_enum_list?(nil, _allowed), do: true

  defp optional_enum_list?(values, allowed) when is_list(values) and length(values) in 1..8,
    do: Enum.uniq(values) == values and Enum.all?(values, &(&1 in allowed))

  defp optional_enum_list?(_values, _allowed), do: false

  defp optional_boolean?(nil), do: true
  defp optional_boolean?(value), do: is_boolean(value)

  defp optional_positive_integer?(nil), do: true
  defp optional_positive_integer?(value), do: is_integer(value) and value > 0

  defp optional_limit?(nil), do: true
  defp optional_limit?(value), do: is_integer(value) and value in 1..20

  defp optional_text?(nil, _maximum), do: true
  defp optional_text?(value, maximum), do: Fields.bounded_text(value, maximum) == :ok

  defp optional_slack_id?(nil), do: true
  defp optional_slack_id?(value), do: Fields.slack_id(value) == :ok

  defp search_cursor?(value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= 4_096
end
