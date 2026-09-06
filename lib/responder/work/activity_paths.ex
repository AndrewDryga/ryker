defmodule Responder.Work.ActivityPaths do
  @moduledoc "Bounded, worker-reported lexical path facts; never filesystem containment authority."
  @source ~r"\A/(input/(path|file_path|directory|paths/[0-9]{1,4})|(locations|content)/[0-9]{1,4}/path)\z"
  @scheme ~r/\A[A-Za-z][A-Za-z0-9+.-]*:/

  def sanitize(%{"basis" => "lexical", "paths" => paths} = value) when is_list(paths) do
    selected = Enum.take(paths, 16)
    kept = selected |> Enum.map(&item/1) |> Enum.reject(&is_nil/1)
    partial = value["partial"] == true || length(paths) > 16 || length(kept) != length(selected)
    result = %{"basis" => "lexical", "paths" => kept}

    cond do
      partial -> Map.put(result, "partial", true)
      kept != [] -> result
      true -> nil
    end
  end

  def sanitize(_), do: nil

  defp item(%{"source" => source, "scope" => _scope} = value)
       when is_binary(source) and byte_size(source) <= 128 do
    if String.valid?(source) && Regex.match?(@source, source), do: scoped_item(value)
  end

  defp item(_), do: nil

  defp scoped_item(%{"scope" => "project"} = value) do
    if relative?(value["path"]), do: Map.take(value, ~w(source scope path))
  end

  defp scoped_item(%{"scope" => scope} = value) when scope in ["outside", "unknown"],
    do: Map.take(value, ~w(source scope))

  defp scoped_item(_), do: nil

  defp relative?(path) when is_binary(path) and byte_size(path) in 1..512 do
    String.valid?(path) && !String.starts_with?(path, ["/", "~"]) &&
      !String.contains?(path, ["\\", "\n", "\r", <<0>>]) && !Regex.match?(@scheme, path) &&
      (path == "." || Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."])))
  end

  defp relative?(_), do: false
end
