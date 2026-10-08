defmodule Ryker.Slack.Client.Messages do
  @moduledoc """
  Messages: posting, editing and finding Ryker's own deliveries, a private
  line to one person, and reading a channel's or thread's history.

  Posted messages carry host-owned metadata naming their delivery ref. A retry
  walks the exact channel or thread until that metadata is found, so a lost
  HTTP response cannot duplicate a visible reply; the file shares in
  `Client.Files` are found by the same walk.
  """
  alias Ryker.Slack.Client
  alias Ryker.Slack.Client.{Fields, Pagination, Transport}
  alias Ryker.Slack.Renderer
  alias Ryker.Slack.Renderer.Blocks

  @page_size 100

  def find_message(client, channel, thread, delivery_ref),
    do: find_message(client, channel, thread, delivery_ref, nil)

  @doc """
  Where a search for a message posted no earlier than `at` starts: its Slack
  timestamp, an hour early for Slack's clock.
  """
  @spec oldest(DateTime.t()) :: String.t()
  def oldest(%DateTime{} = at), do: "#{at |> DateTime.add(-3_600) |> DateTime.to_unix()}.000000"

  @doc """
  Like `find_message/4`, walking only the messages posted after `oldest`, a
  Slack timestamp: a delivery that cannot have been posted before then need
  not walk a whole channel, which for a busy channel runs past the walk's
  bound before it reaches the start. A nil `oldest` walks it all.
  """
  def find_message(client, channel, thread, delivery_ref, oldest) do
    with :ok <- Fields.text(channel),
         :ok <- Fields.optional_text(thread),
         :ok <- Fields.text(delivery_ref),
         :ok <- Fields.optional_message_timestamp(oldest) do
      Pagination.find(
        client,
        &(channel |> history_path(thread, &1) |> since(oldest)),
        &history/1,
        &find_delivery(&1, delivery_ref),
        @page_size
      )
    end
  end

  def post_message(client, channel, thread, body, delivery_ref) do
    with {:ok, rendered} <- render(body),
         :ok <- Fields.text(channel),
         :ok <- Fields.optional_text(thread),
         :ok <- Fields.text(delivery_ref),
         document = channel |> message_document(rendered, delivery_ref) |> put_thread(thread),
         {:ok, response} <- Transport.request(client, :post, "/chat.postMessage", document),
         {:ok, response_body} <- Transport.response(response) do
      case response_body do
        %{"ts" => message_ref} when is_binary(message_ref) and message_ref != "" ->
          {:ok, message_ref}

        _invalid ->
          {:error, {:slack_protocol_error, :message}}
      end
    end
  end

  def post_ephemeral(client, channel, actor, thread, text) do
    with :ok <- Fields.text(channel),
         :ok <- Fields.text(actor),
         :ok <- Fields.optional_text(thread),
         :ok <- Fields.text(text),
         document = put_thread(%{"channel" => channel, "text" => text, "user" => actor}, thread),
         {:ok, response} <- Transport.request(client, :post, "/chat.postEphemeral", document),
         {:ok, _body} <- Transport.response(response) do
      :ok
    end
  end

  def update_message(client, channel, message_ref, body, delivery_ref) do
    with {:ok, rendered} <- render(body),
         :ok <- Fields.text(channel),
         :ok <- Fields.text(message_ref),
         :ok <- Fields.text(delivery_ref),
         # An edit is parsed as the post was: chat.update otherwise parses
         # the text as a client would, and keeps that for the message.
         document =
           channel
           |> message_document(rendered, delivery_ref)
           |> Map.merge(%{"parse" => "none", "ts" => message_ref}),
         {:ok, response} <- Transport.request(client, :post, "/chat.update", document),
         {:ok, response_body} <- Transport.response(response),
         true <- response_body["ts"] == message_ref and response_body["channel"] == channel do
      :ok
    else
      false -> {:error, {:slack_protocol_error, :message_update}}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_messages(client, channel_ref, thread_ref, document) do
    with :ok <- Fields.slack_id(channel_ref),
         :ok <- Fields.optional_message_timestamp(thread_ref),
         {:ok, parameters} <- history_document(document) do
      read_page(client, channel_ref, thread_ref, parameters)
    end
  end

  # A page larger than a read keeps is read again at half its size until it
  # fits, and its cursor goes on from the smaller page: a busy channel's 100
  # messages can carry more than the bound in blocks and files, and that read
  # failed the same way every time (2026-10-04 review).
  defp read_page(client, channel_ref, thread_ref, parameters) do
    path = source_history_path(channel_ref, thread_ref, parameters)

    with {:ok, response} <- Transport.request(client, :get, path, nil),
         {:ok, body} <- Transport.response(response),
         {:ok, messages, cursor} <- history(body) do
      result =
        Map.merge(
          %{"cursor" => cursor, "messages" => messages},
          Map.take(body, ["has_more", "is_limited"])
        )

      case {Fields.bounded_result(result, :history), List.keyfind(parameters, "limit", 0)} do
        {:ok, _limit} ->
          {:ok, result}

        {{:error, _reason}, {"limit", limit}} when limit > 1 ->
          halved = List.keyreplace(parameters, "limit", 0, {"limit", div(limit, 2)})
          read_page(client, channel_ref, thread_ref, halved)

        {{:error, _reason} = error, _limit} ->
          error
      end
    end
  end

  # --- what messages and file shares both use --------------------------------

  @doc """
  Walks a channel or thread, page by bounded page, until `match` finds what an
  earlier delivery left there. Metadata comes along, so the delivery ref is on
  every message.
  """
  @spec find_in_history(
          Client.t(),
          String.t(),
          String.t() | nil,
          ([map()] -> {:ok, term()} | :not_found | {:error, term()}),
          String.t() | nil
        ) :: {:ok, term()} | :not_found | {:error, term()}
  def find_in_history(%Client{} = client, channel, thread, match, oldest \\ nil) do
    Pagination.find(
      client,
      &(channel |> history_path(thread, &1) |> since(oldest)),
      &history/1,
      match,
      @page_size
    )
  end

  @doc "A message body as Slack takes it: plain text escaped, a document rendered to blocks."
  @spec render(term()) :: {:ok, map()} | {:error, term()}
  def render(body) when is_binary(body) do
    with :ok <- Fields.text(body) do
      {:ok, %{"text" => Blocks.escape(body)}}
    end
  end

  def render(%{} = document), do: Renderer.render(document)
  def render(_body), do: {:error, {:invalid_slack_api_request, :message}}

  @doc "Places a document in a thread, when there is one."
  @spec put_thread(map(), String.t() | nil) :: map()
  def put_thread(document, nil), do: document
  def put_thread(document, thread), do: Map.put(document, "thread_ts", thread)

  # --- messages -------------------------------------------------------------

  defp message_document(channel, rendered, delivery_ref) do
    Map.merge(rendered, %{
      "channel" => channel,
      "metadata" => %{
        "event_payload" => %{"id" => delivery_ref},
        "event_type" => "ryker_delivery"
      },
      "mrkdwn" => false,
      "unfurl_links" => false,
      "unfurl_media" => false
    })
  end

  defp find_delivery(messages, delivery_ref) do
    Enum.reduce_while(messages, :not_found, fn
      %{
        "metadata" => %{
          "event_payload" => %{"id" => ^delivery_ref},
          "event_type" => "ryker_delivery"
        },
        "ts" => message_ref
      },
      :not_found
      when is_binary(message_ref) and message_ref != "" ->
        {:halt, {:ok, message_ref}}

      %{}, :not_found ->
        {:cont, :not_found}

      _invalid, :not_found ->
        {:halt, {:error, {:slack_protocol_error, :message}}}
    end)
  end

  # --- history --------------------------------------------------------------

  defp history_path(channel, nil, cursor) do
    Pagination.query(
      "/conversations.history",
      [{"channel", channel}, {"limit", @page_size}, {"include_all_metadata", true}],
      cursor
    )
  end

  defp history_path(channel, thread, cursor) do
    Pagination.query(
      "/conversations.replies",
      [
        {"channel", channel},
        {"ts", thread},
        {"limit", @page_size},
        {"include_all_metadata", true}
      ],
      cursor
    )
  end

  defp since(path, nil), do: path
  defp since(path, oldest), do: path <> "&" <> URI.encode_query([{"oldest", oldest}])

  defp history(%{"messages" => messages} = body) when is_list(messages) do
    case Pagination.next_cursor(body) do
      {:ok, cursor} -> {:ok, messages, cursor}
      {:error, _reason} -> {:error, {:slack_protocol_error, :history}}
    end
  end

  defp history(_body), do: {:error, {:slack_protocol_error, :history}}

  # The conversations.history or conversations.replies query for a source read.
  defp history_document(%{} = document) do
    allowed = ~w(cursor inclusive latest limit oldest)
    keys = Map.keys(document)
    oldest = Map.get(document, "oldest")
    latest = Map.get(document, "latest")

    with true <- Enum.all?(keys, &is_binary/1) and keys -- allowed == [],
         {:ok, cursor} <- Fields.listing_cursor(Map.get(document, "cursor")),
         {:ok, inclusive} <- Fields.listing_boolean(Map.get(document, "inclusive", false)),
         {:ok, limit} <- source_limit(Map.get(document, "limit", 100)),
         :ok <- Fields.optional_message_timestamp(oldest),
         :ok <- Fields.optional_message_timestamp(latest) do
      {:ok,
       [
         {"inclusive", inclusive},
         {"limit", limit}
       ]
       |> maybe_query_parameter("cursor", cursor)
       |> maybe_query_parameter("latest", latest)
       |> maybe_query_parameter("oldest", oldest)}
    else
      _invalid -> {:error, {:invalid_slack_api_request, :history}}
    end
  end

  defp history_document(_document), do: {:error, {:invalid_slack_api_request, :history}}

  defp source_limit(value) when is_integer(value) and value in 1..100, do: {:ok, value}
  defp source_limit(_value), do: {:error, :limit}

  defp maybe_query_parameter(parameters, _key, nil), do: parameters
  defp maybe_query_parameter(parameters, key, value), do: parameters ++ [{key, value}]

  defp source_history_path(channel_ref, nil, parameters),
    do: "/conversations.history?" <> URI.encode_query([{"channel", channel_ref} | parameters])

  defp source_history_path(channel_ref, thread_ref, parameters) do
    "/conversations.replies?" <>
      URI.encode_query([{"channel", channel_ref}, {"ts", thread_ref} | parameters])
  end
end
