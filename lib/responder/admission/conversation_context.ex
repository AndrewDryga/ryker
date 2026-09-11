defmodule Responder.Admission.ConversationContext do
  @moduledoc """
  The frozen local backdrop one input is decided against.

  A thread reply receives its root and the twenty messages that precede it in
  that exact thread; a channel-root message receives the twenty top-level
  messages that precede it, never replies lifted out of unrelated threads. The
  current message appears once, separately. Everything is ordered by source
  chronology behind an explicit cutoff, so a later message — including one
  already queued for Responder — can never enter an earlier context.

  Retained inputs are authoritative because they carry the revision Responder
  actually captured. A bounded paginated provider read may fill gaps the
  retention horizon has already reclaimed; the manifest always says which
  happened, and it never claims coverage it does not have.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Ingress.RecallText
  alias Responder.Repo
  alias Responder.State.MemorySourceLink

  @default_limit 20
  @minimum_limit 10
  @message_bytes 1_024
  @provider_pages 3

  @type t :: %{bundle: map(), manifest: map()}

  @spec capture(Entry.t(), keyword()) :: t()
  def capture(%Entry{} = entry, options \\ []) do
    limit = validated_limit(Keyword.get(options, :local_history_limit, @default_limit))
    reader = Keyword.get(options, :reader)
    kind = origin_kind(entry)

    retained = retained_predecessors(entry, kind, limit)
    {messages, read_status} = fill(retained, entry, kind, limit, reader)
    root = root_message(entry, kind, messages)

    bundle =
      %{
        "current" => message_document(entry, :current),
        "messages" => messages,
        "root" => root
      }
      |> Map.put("thread_summary", nil)
      |> Map.put("channel_summary", nil)

    %{bundle: bundle, manifest: manifest(entry, kind, limit, messages, root, read_status)}
  end

  @doc "Merges the selected summaries into a captured bundle and its manifest."
  @spec with_summaries(t(), map(), map()) :: t()
  def with_summaries(%{bundle: bundle, manifest: manifest}, thread_summary, channel_summary) do
    %{
      bundle:
        bundle
        |> Map.put("thread_summary", thread_summary["document"])
        |> Map.put("channel_summary", channel_summary["document"]),
      manifest:
        manifest
        |> Map.put("thread_summary", Map.delete(thread_summary, "document"))
        |> Map.put("channel_summary", Map.delete(channel_summary, "document"))
    }
  end

  @doc false
  @spec origin_kind(Entry.t()) :: :thread_reply | :channel_root | :conversation
  def origin_kind(%Entry{
        source_kind: "slack",
        source_item_ref: item,
        destination_thread_ref: thread
      })
      when is_binary(item) and is_binary(thread) do
    if item == thread, do: :channel_root, else: :thread_reply
  end

  def origin_kind(_entry), do: :conversation

  defp validated_limit(limit)
       when is_integer(limit) and limit >= @minimum_limit and limit <= @default_limit,
       do: limit

  defp validated_limit(_limit), do: @default_limit

  # The cutoff is the triggering occurrence. Equal timestamps fall back to the
  # captured source item so two messages in the same Slack second stay ordered.
  defp retained_predecessors(entry, kind, limit) do
    base =
      from(other in Entry,
        where:
          other.destination_transport == ^entry.destination_transport and
            other.destination_conversation_ref == ^entry.destination_conversation_ref and
            other.execution_mode == ^entry.execution_mode and
            other.id != ^entry.id and
            is_nil(other.operational_pruned_at),
        where: other.occurred_at < ^entry.occurred_at
      )

    base = tie_break(base, entry)

    base
    |> scope(entry, kind)
    |> order_by([other], desc: other.occurred_at, desc: other.source_item_ref)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&message_document(&1, :retained))
  end

  # Two Slack messages can share a second. The captured item orders them, but
  # only when this source has one: a webhook occurrence has no item reference.
  defp tie_break(query, %Entry{source_item_ref: nil}), do: query

  defp tie_break(query, %Entry{} = entry) do
    from(other in query,
      or_where:
        other.destination_transport == ^entry.destination_transport and
          other.destination_conversation_ref == ^entry.destination_conversation_ref and
          other.execution_mode == ^entry.execution_mode and
          other.id != ^entry.id and
          is_nil(other.operational_pruned_at) and
          other.occurred_at == ^entry.occurred_at and
          other.source_item_ref < ^entry.source_item_ref
    )
  end

  defp scope(query, entry, :thread_reply),
    do: from(other in query, where: other.destination_thread_ref == ^entry.destination_thread_ref)

  # A Slack root binds its own timestamp as its thread, so top-level messages
  # are exactly the entries whose captured item is their own thread.
  defp scope(query, _entry, :channel_root),
    do: from(other in query, where: other.destination_thread_ref == other.source_item_ref)

  defp scope(query, _entry, :conversation), do: query

  defp fill(retained, _entry, _kind, limit, nil) when length(retained) >= limit,
    do: {retained, "retained"}

  defp fill(retained, _entry, _kind, _limit, nil), do: {retained, "retained_only"}

  defp fill(retained, entry, kind, limit, {module, client}) when length(retained) < limit do
    case provider_messages(module, client, entry, kind, limit - length(retained)) do
      {:ok, provider, complete?} ->
        merged =
          (provider ++ retained)
          |> Enum.uniq_by(& &1["source_message_ref"])
          |> Enum.sort_by(&{&1["occurred_at"], &1["source_message_ref"]})
          |> Enum.take(-limit)

        {merged, if(complete?, do: "provider_paged", else: "provider_incomplete")}

      {:error, reason} ->
        {retained, "provider_unavailable:#{error_code(reason)}"}
    end
  end

  defp fill(retained, _entry, _kind, _limit, _reader), do: {retained, "retained"}

  defp provider_messages(module, client, entry, kind, needed) do
    with {:ok, channel_ref} <- channel_ref(entry) do
      read = %{
        channel_ref: channel_ref,
        client: client,
        entry: entry,
        module: module,
        needed: needed,
        thread_ref: if(kind == :thread_reply, do: entry.destination_thread_ref)
      }

      read_pages(read, nil, @provider_pages, [])
    end
  end

  defp read_pages(_read, _cursor, 0, collected), do: {:ok, collected, false}

  defp read_pages(read, cursor, pages, collected) do
    document =
      %{"limit" => 100, "latest" => read.entry.source_item_ref, "inclusive" => false}
      |> maybe_cursor(cursor)

    case read.module.read_messages(read.client, read.channel_ref, read.thread_ref, document) do
      {:ok, %{"messages" => messages} = page} when is_list(messages) ->
        collected =
          (collected ++
             Enum.flat_map(
               messages,
               &provider_document(&1, read.entry, kind_of(read.thread_ref))
             ))
          |> Enum.uniq_by(& &1["source_message_ref"])

        next = page["cursor"]

        cond do
          length(collected) >= read.needed ->
            {:ok, Enum.take(collected, -read.needed), true}

          is_binary(next) and next != "" ->
            read_pages(read, next, pages - 1, collected)

          true ->
            {:ok, collected, true}
        end

      {:ok, _invalid} ->
        {:error, :provider_shape}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp kind_of(nil), do: :channel_root
  defp kind_of(_thread_ref), do: :thread_reply

  defp maybe_cursor(document, nil), do: document
  defp maybe_cursor(document, cursor), do: Map.put(document, "cursor", cursor)

  defp provider_document(%{"ts" => ts} = message, entry, kind) when is_binary(ts) do
    top_level? = is_nil(message["thread_ts"]) or message["thread_ts"] == ts

    if kind == :channel_root and not top_level? do
      []
    else
      [
        %{
          "actor_ref" => provider_actor(message),
          "content" => %{"text" => bounded_text(message["text"] || "")},
          "occurred_at" => provider_time(ts),
          "revision" => nil,
          "retained" => false,
          "source_message_ref" => ts,
          "source_read" =>
            MemorySourceLink.message(
              entry.destination_transport,
              entry.destination_conversation_ref,
              ts,
              message["thread_ts"]
            )
        }
      ]
    end
  end

  defp provider_document(_message, _entry, _kind), do: []

  defp provider_actor(%{"user" => ref}) when is_binary(ref), do: "slack:user:#{ref}"
  defp provider_actor(%{"bot_id" => ref}) when is_binary(ref), do: "slack:bot:#{ref}"
  defp provider_actor(%{"app_id" => ref}) when is_binary(ref), do: "slack:app:#{ref}"
  defp provider_actor(_message), do: "slack:unknown"

  defp provider_time(ts) do
    case Float.parse(ts) do
      {seconds, _rest} ->
        seconds
        |> Kernel.*(1_000_000)
        |> round()
        |> DateTime.from_unix!(:microsecond)
        |> DateTime.to_iso8601()

      :error ->
        nil
    end
  end

  defp channel_ref(%Entry{destination_conversation_ref: "slack:" <> rest}) do
    case String.split(rest, ":", parts: 2) do
      [_workspace, channel_ref] when channel_ref != "" -> {:ok, channel_ref}
      _invalid -> {:error, :conversation_ref}
    end
  end

  defp channel_ref(_entry), do: {:error, :conversation_ref}

  defp root_message(_entry, kind, _messages) when kind != :thread_reply, do: nil

  defp root_message(entry, :thread_reply, messages) do
    root_ref = entry.destination_thread_ref

    cond do
      Enum.any?(messages, &(&1["source_message_ref"] == root_ref)) ->
        %{"source_message_ref" => root_ref, "status" => "deduplicated"}

      root = retained_root(entry, root_ref) ->
        root |> message_document(:retained) |> Map.put("status", "included")

      true ->
        %{"source_message_ref" => root_ref, "status" => "unavailable"}
    end
  end

  defp retained_root(entry, root_ref) do
    Repo.one(
      from(other in Entry,
        where:
          other.destination_transport == ^entry.destination_transport and
            other.destination_conversation_ref == ^entry.destination_conversation_ref and
            other.execution_mode == ^entry.execution_mode and
            other.source_item_ref == ^root_ref and
            is_nil(other.operational_pruned_at),
        order_by: [desc: other.revision],
        limit: 1
      )
    )
  end

  defp message_document(%Entry{} = entry, origin) do
    %{
      "actor_ref" => entry.actor_ref,
      "content" => %{"text" => entry |> Map.get(:content) |> RecallText.from() |> bounded_text()},
      "occurred_at" => DateTime.to_iso8601(entry.occurred_at),
      "revision" => entry.revision,
      "retained" => origin != :provider,
      "source_message_ref" => entry.source_item_ref || entry.native_input_id,
      "source_read" =>
        MemorySourceLink.message(
          entry.destination_transport,
          entry.destination_conversation_ref,
          entry.source_item_ref,
          entry.destination_thread_ref
        )
    }
  end

  defp manifest(entry, kind, limit, messages, root, read_status) do
    %{
      "kind" => Atom.to_string(kind),
      "requested" => limit,
      "included" => length(messages),
      "cutoff" => DateTime.to_iso8601(entry.occurred_at),
      "range" => range(messages),
      "root" => if(root, do: root["status"] || "included", else: "not_applicable"),
      "source_read" => read_status,
      "bytes" => byte_size(CanonicalJSON.encode!(messages))
    }
  end

  defp range([]), do: nil

  defp range(messages) do
    %{"from" => List.first(messages)["occurred_at"], "to" => List.last(messages)["occurred_at"]}
  end

  defp bounded_text(text) do
    if byte_size(text) <= @message_bytes,
      do: text,
      else: String.byte_slice(text, 0, @message_bytes - 3) <> "..."
  end

  defp error_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp error_code(code) when is_atom(code), do: Atom.to_string(code)
  defp error_code(_reason), do: "error"

  @doc false
  def default_limit, do: @default_limit
end
