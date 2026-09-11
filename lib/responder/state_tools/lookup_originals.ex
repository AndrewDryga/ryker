defmodule Responder.StateTools.LookupOriginals do
  @moduledoc false
  alias Responder.CanonicalJSON

  # Keep primary results and exact roots. Optional originals can reference a
  # body already present in this response; references never survive on their own.
  def fit(result, maximum_bytes) do
    candidate = deduplicate(result)

    if byte_size(CanonicalJSON.encode!(candidate)) <= maximum_bytes do
      {:ok, candidate}
    else
      case trim(result) do
        ^result -> {:error, "source_result_too_large"}
        smaller -> fit(smaller, maximum_bytes)
      end
    end
  end

  defp deduplicate(result) do
    hits = get_in(result, ["results", "messages"]) || []
    primaries = if result["anchor"], do: [result["anchor"]], else: result["messages"] || []
    seen = (primaries ++ hits) |> Enum.filter(&body?/1) |> MapSet.new(& &1["source_ref"])

    hit_paths =
      Enum.flat_map(Enum.with_index(hits), fn {_hit, index} ->
        base = ["results", "messages", Access.at(index)]

        [
          base ++ ["thread_root"],
          base ++ ["context_messages", "before"],
          base ++ ["context_messages", "after"]
        ]
      end)

    paths = [["thread_root"], ["messages"] | hit_paths] ++ [["channel_context", "messages"]]

    {result, _seen} =
      Enum.reduce(paths, {result, seen}, fn path, {current, seen} ->
        case get_in(current, path) do
          nil ->
            {current, seen}

          originals ->
            {originals, seen} =
              share(originals, seen, path == ["messages"] and is_nil(result["anchor"]))

            {put_in(current, path, originals), seen}
        end
      end)

    result
  end

  defp share(originals, seen, true), do: {originals, seen}

  defp share(originals, seen, false) when is_list(originals),
    do: Enum.map_reduce(originals, seen, &share(&1, &2, false))

  defp share(%{"source_ref" => ref} = original, seen, false) when is_binary(ref) do
    cond do
      MapSet.member?(seen, ref) -> {%{"source_ref" => ref, "context_reference" => true}, seen}
      body?(original) -> {original, MapSet.put(seen, ref)}
      true -> {original, seen}
    end
  end

  defp share(original, seen, false), do: {original, seen}
  defp body?(original), do: is_binary(original["text"]) or is_binary(original["content"])

  defp trim(%{"channel_context" => %{"messages" => [_ | _]} = context} = result) do
    Map.put(result, "channel_context", context |> Map.put("messages", []) |> partial())
    |> partial()
  end

  defp trim(result) do
    result
    |> trim_source_window()
    |> trim_search_windows()
    |> trim_github_discussion()
    |> then(fn smaller -> if smaller == result, do: result, else: partial(smaller) end)
  end

  defp trim_source_window(%{"anchor" => %{} = anchor, "messages" => [_ | _] = messages} = result) do
    {before, later} = Enum.split_while(messages, &(position(&1) < position(anchor)))

    {remaining, omitted, side} =
      if length(before) > length(later),
        do: {tl(before) ++ later, hd(before), "before"},
        else: {before ++ Enum.drop(later, -1), List.last(later), "after"}

    result
    |> Map.put("messages", remaining)
    |> Map.update(
      "omitted_context",
      %{side => source_read(result, omitted)},
      &Map.put(&1, side, source_read(result, omitted))
    )
  end

  defp trim_source_window(result), do: result

  defp source_read(result, original) do
    arguments =
      if result["view"] == "thread" and
           String.starts_with?(result["source_ref"] || "", "slack-source:") do
        %{
          "source_ref" => result["source_ref"],
          "view" => "thread",
          "anchor_ref" => original["source_ref"]
        }
      else
        %{"source_ref" => original["source_ref"], "view" => "surrounding"}
      end

    %{"tool" => "read_slack_source", "arguments" => Map.put(arguments, "limit", 20)}
  end

  defp trim_search_windows(%{"results" => %{"messages" => hits}} = result),
    do: put_in(result, ["results", "messages"], Enum.map(hits, &trim_hit/1))

  defp trim_search_windows(result), do: result

  defp trim_hit(%{"context_messages" => context} = hit) do
    smaller =
      context
      |> Map.update("before", [], &Enum.drop(&1, 1))
      |> Map.update("after", [], &Enum.drop(&1, -1))

    if smaller == context do
      hit
    else
      hit |> Map.put("context_messages", smaller) |> restart_expansion() |> partial()
    end
  end

  defp trim_hit(hit), do: hit

  defp restart_expansion(%{"source_read" => %{"arguments" => arguments}} = hit),
    do:
      put_in(
        hit,
        ["source_read", "arguments"],
        arguments |> Map.delete("cursor") |> Map.put("limit", 20)
      )

  defp restart_expansion(hit), do: hit

  defp trim_github_discussion(%{"items" => items} = result),
    do: Map.put(result, "items", Enum.map(items, &trim_github_hit/1))

  defp trim_github_discussion(result), do: result

  defp trim_github_hit(%{"discussion_context" => %{"items" => [_ | _] = items} = context} = hit) do
    hit =
      Map.put(
        hit,
        "discussion_context",
        context |> Map.put("items", Enum.drop(items, -1)) |> partial()
      )

    put_in(hit, ["source_read", "arguments", "cursor"], nil)
  end

  defp trim_github_hit(hit), do: hit
  defp position(original), do: original["ts"] || original["occurred_at"] || original["source_ref"]

  defp partial(document) do
    document = Map.put(document, "complete", false)
    key = if Map.has_key?(document, "context_coverage"), do: "context_coverage", else: "coverage"

    Map.update(
      document,
      key,
      %{"status" => "partial", "reason" => "response_byte_limit"},
      &Map.merge(&1, %{"status" => "partial", "reason" => "response_byte_limit"})
    )
  end
end
