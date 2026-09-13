defmodule Ryker.ControlPlane.SourcePage do
  @moduledoc false

  # The first page is centered. A signed consumed interval lets later pages
  # expand on both sides without repeating originals or storing their bodies.
  def read(messages, anchor, arguments, binding, limit) do
    scope = {binding.episode.id, binding.turn.id, Map.delete(arguments, "cursor")}
    secret = Map.get(binding, :cursor_secret)

    with {:ok, previous} <- restore(arguments["cursor"], scope, secret) do
      selected = select(messages, anchor, previous, limit)
      interval = interval(selected, previous, anchor)
      complete = not Enum.any?(messages, &outside?(&1, interval))

      with {:ok, cursor} <- continuation(complete, scope, interval, secret) do
        {:ok,
         %{
           "anchor" => anchor,
           "messages" => selected,
           "cursor" => cursor,
           "complete" => complete,
           "coverage" => %{
             "basis" => "retained_conversation",
             "status" => if(complete, do: "complete", else: "partial"),
             "after" => arguments["after"],
             "before" => arguments["before"],
             "oldest" => time(List.first(selected)),
             "latest" => time(List.last(selected))
           }
         }}
      end
    end
  end

  defp select(messages, nil, nil, limit), do: Enum.take(messages, limit)

  defp select(messages, anchor, nil, limit) do
    case Enum.find_index(messages, &(&1["source_ref"] == anchor["source_ref"])) do
      nil -> []
      index -> Enum.slice(messages, max(0, index - div(limit, 2)), limit)
    end
  end

  defp select(messages, _anchor, {oldest, latest}, limit) do
    before = if oldest, do: Enum.filter(messages, &(key(&1) < oldest)), else: []
    after_messages = Enum.filter(messages, &(key(&1) > latest))
    after_count = min(limit - min(div(limit, 2), length(before)), length(after_messages))
    Enum.take(before, -(limit - after_count)) ++ Enum.take(after_messages, after_count)
  end

  defp interval([], previous, _anchor), do: previous

  defp interval(selected, nil, anchor),
    do: {if(anchor, do: key(hd(selected))), key(List.last(selected))}

  defp interval(selected, {oldest, latest}, _anchor),
    do: {if(oldest, do: min(oldest, key(hd(selected)))), max(latest, key(List.last(selected)))}

  defp outside?(_message, nil), do: false
  defp outside?(message, {nil, latest}), do: key(message) > latest
  defp outside?(message, {oldest, latest}), do: key(message) < oldest or key(message) > latest
  defp key(message), do: {message["occurred_at"], message["source_ref"]}
  defp time(nil), do: nil
  defp time(message), do: message["occurred_at"]

  defp restore(nil, _scope, _secret), do: {:ok, nil}

  defp restore(cursor, scope, secret) when is_binary(secret) and byte_size(secret) >= 16 do
    case Plug.Crypto.verify(secret, "lab-source-read", cursor, max_age: 3_600) do
      {:ok, {^scope, interval}} -> {:ok, interval}
      _ -> {:error, :invalid_source_cursor}
    end
  end

  defp restore(_cursor, _scope, _secret), do: {:error, :invalid_source_cursor}
  defp continuation(true, _scope, _interval, _secret), do: {:ok, ""}

  defp continuation(false, scope, interval, secret)
       when is_binary(secret) and byte_size(secret) >= 16,
       do: {:ok, Plug.Crypto.sign(secret, "lab-source-read", {scope, interval}, max_age: 3_600)}

  defp continuation(_complete, _scope, _interval, _secret), do: {:error, :invalid_source_cursor}
end
