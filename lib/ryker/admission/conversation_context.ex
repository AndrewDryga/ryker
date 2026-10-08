defmodule Ryker.Admission.ConversationContext do
  @moduledoc """
  The frozen local backdrop one input is decided against.

  A thread reply receives its root and the twenty messages that precede it in
  that exact thread; a channel-root message receives the twenty top-level
  messages that precede it, never replies lifted out of unrelated threads. The
  current message appears once, separately. Everything is ordered by source
  chronology behind an explicit cutoff, so a later message — including one
  already queued for Ryker — can never enter an earlier context.

  Retained inputs are authoritative because they carry the revision Ryker
  actually captured. A bounded paginated provider read may fill gaps the
  retention horizon has already reclaimed; the manifest always says which
  happened, and it never claims coverage it does not have.
  """
  alias Ryker.Admission.ConversationContext
  alias Ryker.CanonicalJSON
  alias Ryker.ConversationRef
  alias Ryker.Ingress
  alias Ryker.Memories
  alias Ryker.Repo

  @default_limit 20
  @minimum_limit 10
  @message_bytes 1_024
  @provider_pages 3

  @typedoc """
  The frozen bundle and its manifest, and `previous_answer`: the latest of
  Ryker's answers among the bundle's messages (a Work reply or a quick
  reply, not an update posted while it worked), with the request it belongs
  to, or nil when the bundle holds none.
  """
  @type t :: %{bundle: map(), manifest: map(), previous_answer: map() | nil}

  @spec capture(Ingress.Inbox.Entry.t(), keyword()) :: t()
  def capture(%Ingress.Inbox.Entry{} = entry, options \\ []) do
    limit = validated_limit(Keyword.get(options, :local_history_limit, @default_limit))
    reader = Keyword.get(options, :reader)
    kind = origin_kind(entry)
    {ryker, answers} = ryker_messages(entry, kind, limit)

    retained =
      (retained_predecessors(entry, kind, limit) ++ ryker)
      |> Enum.sort_by(&{&1["occurred_at"], &1["source_message_ref"]})
      |> Enum.take(-limit)

    {messages, read_status} = fill(retained, entry, kind, limit, reader)
    root = root_message(entry, kind, messages)

    bundle = %{
      "current" => message_document(entry, :current),
      "messages" => messages,
      "root" => root,
      "thread_summary" => nil
    }

    %{
      bundle: bundle,
      manifest: manifest(entry, kind, limit, messages, root, read_status),
      previous_answer: previous_answer(messages, answers)
    }
  end

  @doc "Merges the selected thread summary into a captured bundle and its manifest."
  @spec with_thread_summary(t(), map()) :: t()
  def with_thread_summary(%{bundle: bundle, manifest: manifest} = captured, thread_summary) do
    {document, summary} = Map.pop(thread_summary, "document")

    %{
      captured
      | bundle: Map.put(bundle, "thread_summary", document),
        manifest: Map.put(manifest, "thread_summary", summary)
    }
  end

  @doc """
  The latest of Ryker's answers still among `bundle`'s messages, from the
  answers a capture found, or nil. Fitting a prompt drops the oldest
  messages, so the answer is looked for again in what is left.
  """
  @spec previous_answer_in(map() | nil, map() | nil) :: map() | nil
  def previous_answer_in(%{"messages" => messages}, %{"message_ref" => ref} = answer)
      when is_list(messages) do
    if Enum.any?(messages, &(&1["actor_ref"] == "ryker" and &1["source_message_ref"] == ref)),
      do: answer
  end

  def previous_answer_in(_bundle, _answer), do: nil

  # Ryker's answers are its Work replies and its quick replies; an update the
  # Work model posted while it worked is not one. The latest the bundle kept
  # is the answer a message sent after it may be reacting to.
  defp previous_answer(messages, answers) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn message ->
      message["actor_ref"] == "ryker" and Map.get(answers, message["source_message_ref"])
    end)
    |> case do
      %{} = answer -> answer
      _none -> nil
    end
  end

  defp origin_kind(%Ingress.Inbox.Entry{
         source_kind: "slack",
         source_item_ref: item,
         destination_thread_ref: thread
       })
       when is_binary(item) and is_binary(thread) do
    if item == thread, do: :channel_root, else: :thread_reply
  end

  defp origin_kind(_entry), do: :conversation

  defp validated_limit(limit)
       when is_integer(limit) and limit >= @minimum_limit and limit <= @default_limit,
       do: limit

  defp validated_limit(_limit), do: @default_limit

  defp retained_predecessors(entry, kind, limit) do
    entry
    |> ConversationContext.Query.retained_predecessors(kind, limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&message_document(&1, :retained))
  end

  # What Ryker itself said in the same place before the cutoff: delivered Work
  # replies, message posts and quick replies, under the same conversation,
  # thread and execution-mode rules as the inputs. Only a delivery receipt
  # proves a message was sent; accepted-but-undelivered answers never enter a
  # context.
  #
  # Each answer (a reply or a quick reply) is also returned by the message it
  # was sent as, with the request it belongs to: `previous_answer/2` reads it.
  defp ryker_messages(entry, kind, limit) do
    sent =
      Repo.all(ConversationContext.Query.delivered_replies(entry, kind, limit)) ++
        Repo.all(ConversationContext.Query.delivered_posts(entry, kind, limit)) ++
        Repo.all(ConversationContext.Query.delivered_quick_replies(entry, kind, limit))

    messages = Enum.flat_map(sent, &ryker_message(&1, entry))

    answers =
      for %{request: request} = answer <- sent,
          request != nil,
          [document] <- [ryker_message(answer, entry)],
          into: %{} do
        {document["source_message_ref"],
         %{
           "at" => document["occurred_at"],
           "message_ref" => document["source_message_ref"],
           "request" => request
         }}
      end

    {messages, answers}
  end

  defp ryker_message(
         %{at: at, document: %{"message" => text}, receipt: %{} = receipt} = sent,
         entry
       )
       when is_binary(text) and text != "" do
    message_ref = receipt["message_ref"]

    [
      %{
        "actor_ref" => "ryker",
        "content" => %{"text" => bounded_text(text)},
        "occurred_at" => DateTime.to_iso8601(at),
        "revision" => nil,
        "retained" => true,
        "source_message_ref" => message_ref,
        "source_read" =>
          Memories.MemorySourceLink.message(
            entry.destination_transport,
            entry.destination_conversation_ref,
            message_ref,
            Map.get(sent, :thread_ref) || receipt["thread_ref"]
          )
      }
    ]
  end

  defp ryker_message(_sent, _entry), do: []

  defp fill(retained, _entry, _kind, limit, nil) when length(retained) >= limit,
    do: {retained, "retained"}

  defp fill(retained, _entry, _kind, _limit, nil), do: {retained, "retained_only"}

  defp fill(retained, entry, kind, limit, {module, client}) when length(retained) < limit do
    case provider_messages(module, client, entry, kind, limit - length(retained)) do
      {:ok, provider, complete?} ->
        merged =
          (retained ++ provider)
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
          "content" => %{"text" => message |> Ingress.RecallText.prose() |> bounded_text()},
          "occurred_at" => provider_time(ts),
          "revision" => nil,
          "retained" => false,
          "source_message_ref" => ts,
          "source_read" =>
            Memories.MemorySourceLink.message(
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

  defp channel_ref(%Ingress.Inbox.Entry{destination_conversation_ref: "slack:" <> _rest = ref}) do
    case ConversationRef.parse_slack(ref) do
      {:ok, _workspace, channel_ref} -> {:ok, channel_ref}
      :error -> {:error, :conversation_ref}
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

  defp retained_root(entry, root_ref),
    do: Repo.peek(ConversationContext.Query.retained_root(entry, root_ref))

  defp message_document(%Ingress.Inbox.Entry{} = entry, origin) do
    %{
      "actor_ref" => entry.actor_ref,
      "content" => %{
        "text" => entry |> Map.get(:content) |> Ingress.RecallText.prose() |> bounded_text()
      },
      "occurred_at" => DateTime.to_iso8601(entry.occurred_at),
      "revision" => entry.revision,
      "retained" => origin != :provider,
      "source_message_ref" => entry.source_item_ref || entry.native_input_id,
      "source_read" =>
        Memories.MemorySourceLink.message(
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
end
