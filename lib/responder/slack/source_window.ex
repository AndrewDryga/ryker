defmodule Responder.Slack.SourceWindow do
  @moduledoc false
  alias Responder.Slack.SourceRef

  # History is newest-first; replies are oldest-first. The side opposite that
  # ordering needs a bounded scan before it can claim to contain near neighbors.
  @scan_pages 3
  @page_size 100
  @continuations 10

  def read(read_page, source, document, anchor, root) do
    state = document["cursor"] || %{"before" => nil, "after" => nil, "page" => 0}

    if is_map(state) and state["page"] < @continuations do
      collect(read_page, source, document, anchor, root, state)
    else
      {:error, :invalid_source_cursor}
    end
  end

  defp collect(read_page, source, document, anchor, root, state) do
    before_limit = div(document["limit"], 2)
    after_limit = document["limit"] - before_limit

    with {:ok, before} <-
           side(read_page, source, document, anchor, root, state, "before", before_limit),
         {:ok, after_side} <-
           side(read_page, source, document, anchor, root, state, "after", after_limit) do
      next = %{
        "before" => before.cursor,
        "after" => after_side.cursor,
        "page" => state["page"] + 1
      }

      exhausted = before.cursor == "done" and after_side.cursor == "done"
      ceiling = not exhausted and next["page"] == @continuations

      {:ok,
       %{
         "messages" => before.messages ++ after_side.messages,
         "cursor" => if(exhausted or ceiling, do: "", else: next),
         "complete" =>
           before.coverage["status"] == "complete" and after_side.coverage["status"] == "complete",
         "source_reads" => if(ceiling, do: expansion_reads(source, before, after_side), else: []),
         "coverage" => %{
           "before" => before.coverage,
           "after" => after_side.coverage,
           "provider_pages" => before.pages + after_side.pages,
           "page_limit" => @scan_pages + 1,
           "continuation_limit" => @continuations,
           "continuation_exhausted" => ceiling,
           "range" => Map.take(document, ["oldest", "latest"])
         }
       }}
    end
  end

  defp side(_read, _source, _document, _anchor, _root, _state, _side, 0),
    do:
      {:ok,
       %{
         messages: [],
         cursor: "done",
         pages: 0,
         coverage: %{"status" => "partial", "adjacent" => false}
       }}

  defp side(read, source, document, anchor, root, state, side, limit) do
    if state[side] == "done" do
      {:ok,
       %{
         messages: [],
         cursor: "done",
         pages: 0,
         coverage: %{"status" => "previous_page", "adjacent" => false}
       }}
    else
      read_side(read, source, document, anchor, root, state, side, limit)
    end
  end

  defp read_side(read, source, document, anchor, root, state, side, limit) do
    scan = scan?(source.kind, side)
    {cursor, boundary} = side_position(state[side], anchor["ts"])
    boundary = bounded_edge(document, side, boundary)

    query =
      document
      |> Map.put("cursor", cursor)
      |> Map.put("inclusive", false)
      |> Map.put("limit", if(scan, do: @page_size, else: limit))
      |> Map.put(if(side == "before", do: "latest", else: "oldest"), boundary)

    with {:ok, messages, cursor, limited, pages} <-
           side_pages(read, query, scan) do
      originals = originals(messages, side, anchor, root, document)

      selected = selected(originals, side, limit, scan and cursor != "")

      coverage =
        coverage(
          selected,
          {cursor, limited},
          {scan, state[side], boundary == anchor["ts"]},
          length(originals) == length(selected)
        )

      {:ok,
       %{
         messages: selected,
         cursor:
           side_continuation(
             selected,
             {cursor, limited},
             {scan, length(originals) == length(selected), boundary},
             side
           ),
         pages: pages,
         coverage:
           coverage
           |> Map.put("limit", limit)
           |> Map.put("expansion_anchor", expansion_anchor(selected, originals, side))
       }}
    end
  end

  defp expansion_anchor([], originals, "before"), do: message_time(List.last(originals))
  defp expansion_anchor([], originals, "after"), do: message_time(List.first(originals))
  defp expansion_anchor(selected, _originals, "before"), do: message_time(List.first(selected))
  defp expansion_anchor(selected, _originals, "after"), do: message_time(List.last(selected))

  defp expansion_reads(source, before, after_side) do
    [before, after_side]
    |> Enum.filter(
      &(&1.coverage["status"] == "partial" and is_binary(&1.coverage["expansion_anchor"]))
    )
    |> Enum.map(fn side ->
      ref =
        SourceRef.message(
          source.workspace_ref,
          source.channel_ref,
          side.coverage["expansion_anchor"]
        )

      arguments =
        if source.kind == :thread,
          do: %{
            "source_ref" =>
              SourceRef.thread(source.workspace_ref, source.channel_ref, source.message_ref),
            "view" => "thread",
            "anchor_ref" => ref
          },
          else: %{"source_ref" => ref, "view" => "surrounding"}

      %{"tool" => "read_slack_source", "arguments" => Map.put(arguments, "limit", 20)}
    end)
  end

  defp selected(_originals, _side, _limit, true), do: []
  defp selected(originals, "before", limit, false), do: Enum.take(originals, -limit)
  defp selected(originals, "after", limit, false), do: Enum.take(originals, limit)

  defp bounded_edge(document, side, boundary) do
    bound = document[if(side == "before", do: "latest", else: "oldest")]

    cond do
      is_nil(bound) -> boundary
      side == "before" -> Enum.min_by([bound, boundary], &timestamp/1)
      true -> Enum.max_by([bound, boundary], &timestamp/1)
    end
  end

  defp side_pages(read, query, scan) do
    if query["oldest"] && query["latest"] &&
         timestamp(query["oldest"]) >= timestamp(query["latest"]) do
      {:ok, [], "", false, 0}
    else
      pages(read, query, if(scan, do: @scan_pages, else: 1), [], 0)
    end
  end

  defp side_position(%{"boundary" => boundary, "provider" => cursor}, _anchor),
    do: {cursor, boundary}

  defp side_position(%{"boundary" => boundary}, _anchor), do: {nil, boundary}
  defp side_position(cursor, anchor), do: {cursor, anchor}

  defp side_continuation(selected, {"", false}, {true, false, _boundary}, side) do
    # The provider finished, but the response kept only nearby originals. Seek
    # beyond that emitted edge on the next call rather than losing the rest.
    edge = if side == "before", do: hd(selected), else: List.last(selected)
    %{"boundary" => edge["ts"]}
  end

  defp side_continuation(_selected, {"", _limited}, _selection, _side), do: "done"

  defp side_continuation(_selected, {cursor, _limited}, {true, _all, boundary}, _side),
    do: %{"boundary" => boundary, "provider" => cursor}

  defp side_continuation(_selected, {cursor, _limited}, _selection, _side), do: cursor

  defp originals(messages, side, anchor, root, document) do
    excluded = [anchor["ts"], message_time(root)]

    messages
    |> Enum.reject(&(&1["ts"] in excluded))
    |> Enum.filter(&within_side?(&1, side, anchor, document))
    |> Enum.uniq_by(& &1["ts"])
    |> Enum.sort_by(&timestamp(&1["ts"]))
  end

  defp coverage(messages, {cursor, limited}, {scan, previous, at_anchor}, all_selected) do
    exhausted = cursor == "" and not limited

    %{
      "status" => if(exhausted and all_selected, do: "complete", else: "partial"),
      "adjacent" => at_anchor and if(scan, do: exhausted, else: is_nil(previous)),
      "oldest" => messages |> List.first() |> message_time(),
      "latest" => messages |> List.last() |> message_time()
    }
  end

  defp scan?(:thread, side), do: side == "before"
  defp scan?(_kind, side), do: side == "after"

  defp pages(read, document, remaining, collected, count) do
    with {:ok, %{"messages" => messages, "cursor" => cursor} = page} <- read.(document),
         true <- is_list(messages) and is_binary(cursor),
         true <- Enum.all?(messages, &valid_message?/1) do
      collected = collected ++ messages
      limited = page["has_more"] == true or page["is_limited"] == true

      if remaining > 1 and cursor != "" and cursor != document["cursor"] do
        pages(read, Map.put(document, "cursor", cursor), remaining - 1, collected, count + 1)
      else
        {:ok, collected, cursor, limited, count + 1}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :slack_protocol_error}
    end
  end

  defp valid_message?(%{"ts" => ts}) when is_binary(ts),
    do: Regex.match?(~r/\A\d+\.\d{1,6}\z/, ts)

  defp valid_message?(_), do: false

  defp within_side?(message, side, anchor, document) do
    time = timestamp(message["ts"])

    side_matches =
      if side == "before",
        do: time < timestamp(anchor["ts"]),
        else: time > timestamp(anchor["ts"])

    side_matches and (is_nil(document["oldest"]) or time >= timestamp(document["oldest"])) and
      (is_nil(document["latest"]) or time <= timestamp(document["latest"]))
  end

  defp message_time(nil), do: nil
  defp message_time(message), do: message["ts"]

  defp timestamp(value) do
    [seconds, fraction] = String.split(value, ".", parts: 2)

    String.to_integer(seconds) * 1_000_000 +
      String.to_integer(String.pad_trailing(fraction, 6, "0"))
  end
end
