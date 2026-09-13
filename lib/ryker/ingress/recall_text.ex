defmodule Ryker.Ingress.RecallText do
  @moduledoc "Meaningful, bounded search text; the submitted source document remains unchanged."
  alias Ryker.CanonicalJSON
  @fields ~w(title text body description summary fallback)

  def from(content) do
    case content |> fragments(0) |> Enum.reject(&(String.trim(&1) == "")) |> Enum.uniq() do
      [] -> String.slice(CanonicalJSON.encode!(content), 0, 4000)
      texts -> texts |> Enum.take(16) |> Enum.map_join("\n", &String.slice(&1, 0, 512))
    end
  end

  defp fragments(value, depth) when is_map(value) and depth < 16 do
    value
    |> Enum.sort_by(fn {key, _} -> {Enum.find_index(@fields, &(&1 == key)) || 99, key} end)
    |> Enum.flat_map(fn
      {key, text} when key in @fields and is_binary(text) -> [text]
      {_key, nested} -> fragments(nested, depth + 1)
    end)
  end

  defp fragments(value, depth) when is_list(value) and depth < 16,
    do: Enum.flat_map(value, &fragments(&1, depth + 1))

  defp fragments(_, _), do: []
end
