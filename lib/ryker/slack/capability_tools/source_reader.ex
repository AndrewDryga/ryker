defmodule Ryker.Slack.CapabilityTools.SourceReader do
  @moduledoc """
  Reads one authorized Slack source: a message with its neighbors, a thread
  with its channel context, a channel, or a bookmark, canvas or file.

  Page contents are never source identity: the exact original is rechecked on
  every page, and continuation cursors are sealed to the turn that minted them.
  """

  alias Ryker.Slack.CapabilityTools.{Arguments, Resources}
  alias Ryker.Slack.{SourceRef, SourceWindow}

  @spec read_source(map(), map(), atom(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def read_source(options, %{kind: :bookmark} = source, view, _document, conversation, _binding)
      when view in [:document, :metadata] do
    with {:ok, bookmarks} <- options.api.list_bookmarks(options.client, source.channel_ref),
         {:ok, bookmark} <- Resources.exact_bookmark(bookmarks, source),
         {:ok, normalized} <-
           Resources.normalize_bookmark(bookmark, source.workspace_ref, source.channel_ref) do
      read_bookmark_target(options, source, view, conversation, bookmark, normalized)
    end
  end

  def read_source(options, %{kind: kind} = source, view, _document, conversation, _binding)
      when kind in [:canvas, :file] and view in [:document, :metadata] do
    with {:ok, file} <- options.api.file_info(options.client, source.resource_ref),
         :ok <- Resources.file_authorized(file, source),
         {:ok, document} <- Resources.file_document(file, source) do
      {:ok,
       %{
         "complete" => document["content_complete"],
         "conversation" => conversation,
         "cursor" => "",
         "document" => document,
         "source_ref" => SourceRef.encode(source),
         "view" => Atom.to_string(view)
       }}
    end
  end

  def read_source(_options, source, :metadata, _document, conversation, _binding)
      when source.kind in [:channel, :message, :thread] do
    {:ok,
     %{
       "complete" => true,
       "conversation" => conversation,
       "cursor" => "",
       "messages" => [],
       "source_ref" => SourceRef.encode(source),
       "view" => "metadata"
     }}
  end

  def read_source(options, source, view, document, conversation, binding) do
    thread_ref = if(view == :thread, do: source.message_ref, else: nil)

    with {:ok, document} <- open_source_cursor(document, source, view, binding),
         {:ok, anchor, root} <- source_anchor(options, source, thread_ref),
         {:ok, %{"cursor" => cursor, "messages" => messages} = page} <-
           source_page(options, source, thread_ref, document, anchor, root),
         {:ok, messages} <-
           decorate_source_messages(messages, source.workspace_ref, source.channel_ref),
         {:ok, continuation} <- seal_source_cursor(cursor, document, source, view, binding) do
      result = %{
        "anchor" => anchor,
        "thread_root" => root,
        "complete" =>
          Map.get(
            page,
            "complete",
            cursor == "" and page["has_more"] != true and page["is_limited"] != true
          ),
        "coverage" => Map.get(page, "coverage"),
        "conversation" => conversation,
        "cursor" => continuation,
        "messages" => messages,
        "source_ref" => SourceRef.encode(source),
        "view" => Atom.to_string(view)
      }

      result = Map.merge(result, Map.take(page, ["source_reads"]))
      add_thread_channel_context(options, source, document, root, result, binding)
    end
  end

  defp add_thread_channel_context(_options, %{kind: :thread}, _document, nil, result, _binding),
    do: {:ok, Map.put(result, "channel_context", %{"coverage" => %{"status" => "unavailable"}})}

  defp add_thread_channel_context(
         options,
         %{kind: :thread} = source,
         document,
         root,
         result,
         binding
       ) do
    channel_source =
      %{source | kind: :message, message_ref: root["ts"]} |> Map.delete(:anchor_message_ref)

    arguments = %{
      "source_ref" => SourceRef.encode(channel_source),
      "view" => "surrounding",
      "limit" => 4,
      "after" => source_datetime(document["oldest"]),
      "before" => source_datetime(document["latest"])
    }

    case Arguments.read_document(arguments, source.workspace_ref) do
      {:ok, ^channel_source, :surrounding, channel_document} ->
        with {:ok, context} <-
               channel_window(
                 options,
                 channel_source,
                 channel_document,
                 root,
                 binding,
                 document["cursor"]
               ) do
          {:ok, Map.put(result, "channel_context", link_channel_context(context, arguments))}
        end

      {:error, _unusable_window} ->
        # The channel layer is optional context around an already authorized thread.
        {:ok, Map.put(result, "channel_context", %{"coverage" => %{"status" => "unavailable"}})}
    end
  end

  defp add_thread_channel_context(_options, _source, _document, _root, result, _binding),
    do: {:ok, result}

  defp link_channel_context(context, arguments) do
    cursor = context["cursor"]

    arguments =
      if cursor in [nil, ""],
        do: Map.put(arguments, "limit", 20),
        else: Map.put(arguments, "cursor", cursor)

    Map.put(context, "source_read", %{"tool" => "read_slack_source", "arguments" => arguments})
  end

  defp channel_window(_options, _source, _document, _root, _binding, cursor)
       when not is_nil(cursor),
       do: {:ok, %{"messages" => [], "coverage" => %{"status" => "previous_page"}}}

  defp channel_window(options, source, document, root, binding, nil) do
    read = &message_page(options, source, nil, &1)

    with {:ok, page} <- SourceWindow.read(read, source, document, root, nil),
         {:ok, messages} <-
           decorate_source_messages(page["messages"], source.workspace_ref, source.channel_ref),
         {:ok, cursor} <-
           seal_source_cursor(page["cursor"], document, source, :surrounding, binding) do
      {:ok, %{"messages" => messages, "coverage" => page["coverage"], "cursor" => cursor}}
    end
  end

  defp source_datetime(nil), do: nil

  defp source_datetime(timestamp),
    do:
      timestamp
      |> Arguments.timestamp_value()
      |> DateTime.from_unix!(:microsecond)
      |> DateTime.to_iso8601()

  @spec source_page(map(), map(), String.t() | nil, map(), map() | nil, map() | nil) ::
          {:ok, map()} | {:error, term()}
  def source_page(options, %{kind: :channel} = source, thread, document, _anchor, _root),
    do: message_page(options, source, thread, document)

  def source_page(options, source, thread, document, anchor, root) do
    read = &message_page(options, source, thread, &1)
    SourceWindow.read(read, source, document, anchor, root)
  end

  defp message_page(options, source, thread, document) do
    with {:ok, page} <-
           options.api.read_messages(options.client, source.channel_ref, thread, document) do
      {:ok,
       if(is_nil(thread), do: Map.update(page, "messages", nil, &channel_originals/1), else: page)}
    end
  end

  defp channel_originals(messages) when is_list(messages),
    do: Enum.filter(messages, &channel_original?/1)

  defp channel_originals(messages), do: messages
  defp channel_original?(%{"thread_ts" => thread, "ts" => ts}), do: is_nil(thread) or thread == ts
  defp channel_original?(_message), do: true

  defp open_source_cursor(%{"cursor" => nil} = document, _source, _view, _binding),
    do: {:ok, document}

  defp open_source_cursor(document, source, view, %{cursor_secret: secret} = binding)
       when is_binary(secret) and byte_size(secret) >= 16 do
    scope = source_cursor_scope(document, source, view, binding)

    case Plug.Crypto.verify(secret, "slack-source-read", document["cursor"], max_age: 3_600) do
      {:ok, {^scope, cursor}} when is_binary(cursor) or is_map(cursor) ->
        {:ok, Map.put(document, "cursor", cursor)}

      _ ->
        {:error, :invalid_source_cursor}
    end
  end

  defp open_source_cursor(_document, _source, _view, _binding),
    do: {:error, :invalid_source_cursor}

  # A continuation cursor is signed to the exact source, view, bounds, episode
  # and turn that produced it, so it cannot be replayed elsewhere or later.
  @spec seal_source_cursor(term(), map(), map(), atom(), map()) ::
          {:ok, String.t()} | {:error, atom()}
  def seal_source_cursor("", _document, _source, _view, _binding), do: {:ok, ""}

  def seal_source_cursor(cursor, document, source, view, %{cursor_secret: secret} = binding)
      when is_binary(secret) and byte_size(secret) >= 16 do
    scope = source_cursor_scope(document, source, view, binding)
    {:ok, Plug.Crypto.sign(secret, "slack-source-read", {scope, cursor}, max_age: 3_600)}
  end

  def seal_source_cursor(_cursor, _document, _source, _view, _binding),
    do: {:error, :invalid_source_cursor}

  defp source_cursor_scope(document, source, view, binding),
    do:
      {SourceRef.encode(source), Map.get(source, :anchor_message_ref), view,
       Map.delete(document, "cursor"), binding.episode.id, binding.turn.id}

  @doc "Every message gains the server-issued source_ref the model must cite it by."
  @spec decorate_source_messages(term(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, atom()}
  def decorate_source_messages(messages, workspace_ref, channel_ref) when is_list(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn
      %{"ts" => message_ref} = message, {:ok, decorated} when is_binary(message_ref) ->
        try do
          ref = SourceRef.message(workspace_ref, channel_ref, message_ref)
          {:cont, {:ok, [Map.put(message, "source_ref", ref) | decorated]}}
        rescue
          _error -> {:halt, {:error, :slack_protocol_error}}
        end

      _invalid, _result ->
        {:halt, {:error, :slack_protocol_error}}
    end)
    |> case do
      {:ok, decorated} -> {:ok, Enum.reverse(decorated)}
      {:error, _reason} = error -> error
    end
  end

  def decorate_source_messages(_messages, _workspace_ref, _channel_ref),
    do: {:error, :slack_protocol_error}

  @doc "The exact original a read is anchored on, and its thread root when it has one."
  @spec source_anchor(map(), map(), String.t() | nil) ::
          {:ok, map() | nil, map() | nil} | {:error, term()}
  def source_anchor(_options, %{kind: :channel}, _thread_ref), do: {:ok, nil, nil}

  def source_anchor(options, source, thread_ref) do
    # Page contents are not source identity. Recheck the exact original on every
    # page, including a continuation that no longer contains the anchor.
    timestamp = Map.get(source, :anchor_message_ref, source.message_ref)

    with {:ok, originals} <- exact_source_originals(options, source, thread_ref, timestamp),
         {:ok, anchor} <- required_original(originals, timestamp),
         {:ok, root} <- source_root(options, source, thread_ref, originals),
         do: {:ok, anchor, root}
  end

  defp required_original(originals, timestamp) do
    case Enum.find(originals, &(&1["ts"] == timestamp)) do
      nil -> {:error, :slack_source_not_found}
      original -> {:ok, original}
    end
  end

  defp source_root(_options, _source, nil, _originals), do: {:ok, nil}

  defp source_root(options, source, thread_ref, originals) do
    case Enum.find(originals, &(&1["ts"] == thread_ref)) do
      nil ->
        with {:ok, roots} <- exact_source_originals(options, source, thread_ref, thread_ref),
             do: {:ok, Enum.find(roots, &(&1["ts"] == thread_ref))}

      root ->
        {:ok, root}
    end
  end

  defp exact_source_originals(options, source, thread_ref, timestamp) do
    document = %{
      "oldest" => timestamp,
      "latest" => timestamp,
      "inclusive" => true,
      "limit" => 1
    }

    with {:ok, %{"messages" => messages}} <-
           options.api.read_messages(options.client, source.channel_ref, thread_ref, document),
         do: decorate_source_messages(messages, source.workspace_ref, source.channel_ref)
  end

  defp read_bookmark_target(_options, source, :metadata, conversation, _bookmark, normalized) do
    {:ok,
     %{
       "bookmark" => normalized,
       "complete" => true,
       "conversation" => conversation,
       "cursor" => "",
       "source_ref" => SourceRef.encode(source),
       "view" => "metadata"
     }}
  end

  defp read_bookmark_target(
         options,
         source,
         :document,
         conversation,
         %{"entity_id" => entity_ref, "type" => type},
         normalized
       )
       when is_binary(entity_ref) and type in ["canvas", "file"] do
    kind = String.to_existing_atom(type)

    target = %{source | kind: kind, resource_ref: entity_ref}

    with {:ok, file} <- options.api.file_info(options.client, entity_ref),
         :ok <- Resources.file_authorized(file, target),
         {:ok, document} <- Resources.file_document(file, target) do
      {:ok,
       %{
         "bookmark" => normalized,
         "complete" => document["content_complete"],
         "conversation" => conversation,
         "cursor" => "",
         "document" => document,
         "source_ref" => SourceRef.encode(source),
         "view" => "document"
       }}
    end
  end

  defp read_bookmark_target(_options, source, :document, conversation, _bookmark, normalized) do
    {:ok,
     %{
       "bookmark" => normalized,
       "complete" => true,
       "conversation" => conversation,
       "cursor" => "",
       "source_ref" => SourceRef.encode(source),
       "view" => "document"
     }}
  end
end
