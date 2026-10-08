defmodule Ryker.Slack.CapabilityTools.Arguments do
  @moduledoc """
  Validates the arguments of every Slack capability tool into the exact
  provider document the host will send, refusing anything outside the
  published schema before a credential is touched.
  """
  alias Ryker.Maps
  alias Ryker.Slack.{Id, SourceRef}

  @content_types ~w(messages files channels users)
  @search_fields ~w(after author_ref before content_types conversation_refs cursor limit query)
  @list_fields ~w(configured_only cursor include_archived include_resources kinds limit query)
  @resources_channels 25
  # Slack's search sends at most this much query (`Ryker.Slack.Client.Assistant`).
  @maximum_query_bytes 2_048
  @read_fields ~w(after anchor_ref before cursor limit source_ref view)
  @reaction_fields ~w(action emoji message_ref)
  @post_fields ~w(destination_ref instruction_ref message)
  @maximum_update 2_000
  @emoji_name ~r/\A[a-z0-9_+\-]{1,100}\z/

  @doc "The exact content kinds search_slack can ask for."
  @spec content_types() :: [String.t()]
  def content_types, do: @content_types

  @spec search_document(term(), String.t()) :: {:ok, map(), [String.t()]} | {:error, atom()}
  def search_document(%{} = arguments, workspace_ref) do
    keys = Map.keys(arguments)

    with true <-
           Enum.all?(keys, &is_binary/1) and Map.has_key?(arguments, "query") and
             keys -- @search_fields == [],
         {:ok, query} <- text(arguments["query"], @maximum_query_bytes),
         {:ok, content_types} <- content_types(Map.get(arguments, "content_types", ["messages"])),
         {:ok, conversations} <-
           conversations(Map.get(arguments, "conversation_refs", []), workspace_ref),
         {:ok, author} <- author(Map.get(arguments, "author_ref")),
         {:ok, after_time} <- timestamp(Map.get(arguments, "after")),
         {:ok, before_time} <- timestamp(Map.get(arguments, "before")),
         {:ok, cursor} <- optional_text(Map.get(arguments, "cursor"), 4_096),
         {:ok, limit} <- limit(Map.get(arguments, "limit", 20)),
         {:ok, query} <- bounded_query(query, conversations, author) do
      {:ok,
       %{
         "channel_types" => ["public_channel"],
         "content_types" => content_types,
         "include_context_messages" => true,
         "limit" => limit,
         "query" => query
       }
       |> Maps.put_present("after", after_time)
       |> Maps.put_present("before", before_time)
       |> Maps.put_present("cursor", cursor), conversations}
    else
      false -> {:error, :invalid_arguments}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, _reason} -> {:error, :invalid_arguments}
    end
  end

  def search_document(_arguments, _workspace_ref), do: {:error, :invalid_arguments}

  @spec list_document(term()) :: {:ok, map(), map()} | {:error, atom()}
  def list_document(%{} = arguments) do
    keys = Map.keys(arguments)

    with true <- Enum.all?(keys, &is_binary/1) and keys -- @list_fields == [],
         {:ok, query} <- optional_text(Map.get(arguments, "query"), 256),
         {:ok, kinds} <- kinds(Map.get(arguments, "kinds", ["public_channel"])),
         {:ok, configured_only} <- boolean(Map.get(arguments, "configured_only", false)),
         {:ok, include_archived} <- boolean(Map.get(arguments, "include_archived", false)),
         {:ok, include_resources} <- boolean(Map.get(arguments, "include_resources", false)),
         {:ok, cursor} <- optional_text(Map.get(arguments, "cursor"), 4_096),
         {:ok, limit} <- channel_limit(Map.get(arguments, "limit", 50)),
         :ok <- resources_limit(include_resources, limit) do
      {:ok,
       %{
         "exclude_archived" => not include_archived,
         "limit" => limit,
         "types" => kinds
       }
       |> Maps.put_present("cursor", cursor),
       %{
         configured_only: configured_only,
         include_resources: include_resources,
         query: query
       }}
    else
      false -> {:error, :invalid_arguments}
      {:error, _reason} -> {:error, :invalid_arguments}
    end
  end

  def list_document(_arguments), do: {:error, :invalid_arguments}

  @spec read_document(term(), String.t()) :: {:ok, map(), atom(), map()} | {:error, atom()}
  def read_document(%{} = arguments, workspace_ref) do
    keys = Map.keys(arguments)

    with true <- Enum.all?(keys, &is_binary/1) and keys -- @read_fields == [],
         {:ok, source_ref} <- text(Map.get(arguments, "source_ref"), 1_024),
         {:ok, source} <- SourceRef.parse(source_ref, workspace_ref),
         {:ok, view} <- source_view(Map.get(arguments, "view"), source.kind),
         {:ok, source} <- source_anchor_ref(Map.get(arguments, "anchor_ref"), source, view),
         {:ok, after_time} <- slack_timestamp(Map.get(arguments, "after")),
         {:ok, before_time} <- slack_timestamp(Map.get(arguments, "before")),
         {:ok, cursor} <- optional_text(Map.get(arguments, "cursor"), 8_192),
         {:ok, limit} <- source_limit(Map.get(arguments, "limit", 100)),
         {:ok, document} <-
           source_read_bounds(source, view, after_time, before_time, cursor, limit) do
      {:ok, source, view, document}
    else
      false -> {:error, :invalid_arguments}
      {:error, :invalid_slack_source_ref} -> {:error, :unauthorized}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, _reason} -> {:error, :invalid_arguments}
    end
  end

  def read_document(_arguments, _workspace_ref), do: {:error, :invalid_arguments}

  defp source_anchor_ref(nil, source, _view), do: {:ok, source}

  defp source_anchor_ref(ref, %{kind: :thread} = source, :thread) do
    with {:ok, %{kind: :message, channel_ref: channel, message_ref: timestamp}} <-
           SourceRef.parse(ref, source.workspace_ref),
         true <-
           channel == source.channel_ref and
             timestamp_value(timestamp) >= timestamp_value(source.message_ref) do
      {:ok, Map.put(source, :anchor_message_ref, timestamp)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp source_anchor_ref(_ref, _source, _view), do: {:error, :invalid_arguments}

  @spec reaction_document(term(), String.t()) ::
          {:ok, map(), String.t(), String.t()} | {:error, atom()}
  def reaction_document(%{} = arguments, workspace_ref) do
    with true <- Map.keys(arguments) |> Enum.sort() == @reaction_fields,
         {:ok, source_ref} <- text(arguments["message_ref"], 1_024),
         {:ok, %{kind: :message} = source} <- SourceRef.parse(source_ref, workspace_ref),
         action when action in ["add", "remove"] <- arguments["action"],
         emoji_name when is_binary(emoji_name) <- arguments["emoji"],
         true <- Regex.match?(@emoji_name, emoji_name) do
      {:ok, source, action, emoji_name}
    else
      {:error, :invalid_slack_source_ref} -> {:error, :unauthorized}
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def reaction_document(_arguments, _workspace_ref), do: {:error, :invalid_arguments}

  @spec post_document(term(), String.t()) :: {:ok, map(), map(), String.t()} | {:error, atom()}
  def post_document(%{} = arguments, workspace_ref) do
    with true <- Map.keys(arguments) |> Enum.sort() == @post_fields,
         {:ok, destination_ref} <- text(arguments["destination_ref"], 1_024),
         {:ok, destination} <- SourceRef.parse(destination_ref, workspace_ref),
         true <- destination.kind in [:channel, :thread],
         {:ok, instruction_ref} <- text(arguments["instruction_ref"], 1_024),
         {:ok, %{kind: :message} = instruction} <-
           SourceRef.parse(instruction_ref, workspace_ref),
         {:ok, message} <- text(arguments["message"], 20_000) do
      {:ok, destination, instruction, message}
    else
      {:error, :invalid_slack_source_ref} -> {:error, :unauthorized}
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def post_document(_arguments, _workspace_ref), do: {:error, :invalid_arguments}

  @doc """
  The words of one Work update: a short message the Work model posts into its
  own conversation while it works. Slack and Chat read the same arguments.
  """
  @spec update_message(term()) :: {:ok, String.t()} | {:error, :invalid_arguments}
  def update_message(%{"message" => message} = arguments) when map_size(arguments) == 1 do
    if is_binary(message) and String.valid?(message) and String.trim(message) != "" and
         String.length(message) <= @maximum_update and :binary.match(message, <<0>>) == :nomatch,
       do: {:ok, message},
       else: {:error, :invalid_arguments}
  end

  def update_message(_arguments), do: {:error, :invalid_arguments}

  @doc false
  def maximum_update, do: @maximum_update

  defp source_view("metadata", _kind), do: {:ok, :metadata}
  defp source_view("channel", :channel), do: {:ok, :channel}
  defp source_view("surrounding", :message), do: {:ok, :surrounding}
  defp source_view("thread", :thread), do: {:ok, :thread}

  defp source_view("document", kind) when kind in [:bookmark, :canvas, :file],
    do: {:ok, :document}

  defp source_view(_view, _kind), do: {:error, :view}

  defp source_read_bounds(_source, :metadata, _after_time, _before_time, cursor, limit),
    do: {:ok, %{"cursor" => cursor, "inclusive" => true, "limit" => limit}}

  defp source_read_bounds(source, :surrounding, after_time, before_time, cursor, limit) do
    seconds = source.message_ref |> String.split(".", parts: 2) |> hd() |> String.to_integer()
    oldest = after_time || "#{max(seconds - 86_400, 0)}.000000"
    latest = before_time || "#{seconds + 86_400}.999999"

    if timestamp_value(oldest) <= timestamp_value(source.message_ref) and
         timestamp_value(source.message_ref) <= timestamp_value(latest) do
      {:ok,
       %{
         "cursor" => cursor,
         "inclusive" => true,
         "latest" => latest,
         "limit" => limit,
         "oldest" => oldest
       }}
    else
      {:error, :range}
    end
  end

  defp source_read_bounds(_source, _view, after_time, before_time, cursor, limit) do
    {:ok,
     %{
       "cursor" => cursor,
       "inclusive" => true,
       "latest" => before_time,
       "limit" => limit,
       "oldest" => after_time
     }}
  end

  @doc "A Slack message timestamp as microseconds, so two of them compare as numbers."
  @spec timestamp_value(String.t()) :: non_neg_integer()
  def timestamp_value(value) do
    [seconds, fraction] = String.split(value, ".", parts: 2)

    String.to_integer(seconds) * 1_000_000 +
      String.to_integer(String.pad_trailing(fraction, 6, "0"))
  end

  defp bounded_query(query, conversations, author) do
    suffix =
      Enum.map(conversations, &"in:<##{&1}>") ++
        if(author, do: ["from:<@#{author}>"], else: [])

    # The query Slack is sent, filters and all, holds the client's bound: the
    # tool let it reach 4,096 bytes while the client sends 2,048, and the
    # model met a failure it could not act on (2026-10-04 review).
    prepared = Enum.join([query | suffix], " ")
    if byte_size(prepared) <= @maximum_query_bytes, do: {:ok, prepared}, else: {:error, :query}
  end

  # The read_slack_source call that continues from a search hit or a file
  # share: the thread anchored on the exact message when there is one, the
  # surrounding channel window otherwise, inside the same time bounds.
  @spec source_read_arguments(map(), map()) :: map()
  def source_read_arguments(hit, arguments) do
    base = %{
      "source_ref" => hit["source_ref"],
      "view" => "surrounding",
      "limit" => 4,
      "after" => arguments["after"],
      "before" => arguments["before"]
    }

    if hit["thread_source_ref"] do
      Map.merge(base, %{
        "source_ref" => hit["thread_source_ref"],
        "view" => "thread",
        "anchor_ref" => hit["source_ref"]
      })
    else
      base
    end
  end

  defp conversations(values, workspace_ref)
       when is_list(values) and length(values) <= 5 do
    if values == Enum.uniq(values) do
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, channels} ->
        reduce_conversation(value, workspace_ref, channels)
      end)
    else
      {:error, :conversation}
    end
  end

  defp conversations(_values, _workspace_ref), do: {:error, :conversation}

  defp reduce_conversation(value, workspace_ref, channels) do
    case conversation(value, workspace_ref) do
      {:ok, channel_ref} -> {:cont, {:ok, channels ++ [channel_ref]}}
      {:error, :unauthorized} -> {:halt, {:error, :unauthorized}}
      {:error, _reason} -> {:halt, {:error, :conversation}}
    end
  end

  @doc "The channel of a `slack:<workspace>:<channel>` conversation ref in this workspace."
  @spec conversation(term(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def conversation(value, workspace_ref) do
    case String.split(value || "", ":", parts: 3) do
      ["slack", ^workspace_ref, channel_ref] ->
        if Id.valid?(channel_ref), do: {:ok, channel_ref}, else: {:error, :conversation}

      _invalid ->
        {:error, :unauthorized}
    end
  end

  defp author(nil), do: {:ok, nil}

  defp author("slack-user:" <> user_ref) do
    if Id.valid?(user_ref), do: {:ok, user_ref}, else: {:error, :author}
  end

  defp author(_value), do: {:error, :author}

  defp content_types(values) when is_list(values) and length(values) in 1..4 do
    if values == Enum.uniq(values) and Enum.all?(values, &(&1 in @content_types)),
      do: {:ok, values},
      else: {:error, :content_types}
  end

  defp content_types(_values), do: {:error, :content_types}

  defp timestamp(nil), do: {:ok, nil}

  # An RFC 3339 time names one moment whatever its offset; only UTC was
  # accepted (2026-10-04 review).
  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_unix(datetime)}
      _invalid -> {:error, :timestamp}
    end
  end

  defp timestamp(_value), do: {:error, :timestamp}

  defp slack_timestamp(nil), do: {:ok, nil}

  defp slack_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, "#{DateTime.to_unix(datetime)}.000000"}
      _invalid -> {:error, :timestamp}
    end
  end

  defp slack_timestamp(_value), do: {:error, :timestamp}

  defp optional_text(nil, _maximum), do: {:ok, nil}
  defp optional_text(value, maximum), do: text(value, maximum)

  defp text(value, maximum) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "" and
         byte_size(value) <= maximum and :binary.match(value, <<0>>) == :nomatch,
       do: {:ok, value},
       else: {:error, :text}
  end

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: {:error, :boolean}

  defp limit(value) when is_integer(value) and value in 1..20, do: {:ok, value}
  defp limit(_value), do: {:error, :limit}

  defp channel_limit(value) when is_integer(value) and value in 1..200, do: {:ok, value}
  defp channel_limit(_value), do: {:error, :limit}

  # Bookmarks are read one channel at a time, a Tier 2 call each: a listing
  # that read them by default made up to 200 calls (2026-10-04 review).
  defp resources_limit(true, limit) when limit > @resources_channels, do: {:error, :limit}
  defp resources_limit(_include_resources, _limit), do: :ok

  defp source_limit(value) when is_integer(value) and value in 1..100, do: {:ok, value}
  defp source_limit(_value), do: {:error, :limit}

  defp kinds(values) when is_list(values) and length(values) in 1..2 do
    allowed = ["public_channel", "private_channel"]

    if values == Enum.uniq(values) and Enum.all?(values, &(&1 in allowed)),
      do: {:ok, values},
      else: {:error, :kinds}
  end

  defp kinds(_values), do: {:error, :kinds}
end
