defmodule Ryker.Ingress.RecallText do
  @moduledoc """
  Meaningful, bounded search text; the submitted source document remains unchanged.

  A message is searched by its own text (`Ryker.Ingress.MessageText`), so a
  Slack message counts its words once, as the timeline shows it. Any other
  payload is searched by its titles, bodies and descriptions.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.Ingress.MessageText

  # A voice message's transcript is what it said; one Ryker could not
  # transcribe says so.
  @fields ~w(title text transcript transcript_unavailable body description summary fallback)

  def from(content) do
    case MessageText.parts(content) do
      nil -> fields(content)
      parts -> bounded(parts)
    end
  end

  @doc """
  One input as a model reads it among others: a message's whole text, for the
  reader to shorten where it says so, and any other payload as its search text.
  """
  @spec prose(term()) :: String.t()
  def prose(content) do
    case MessageText.parts(content) do
      nil -> fields(content)
      parts -> Enum.join(parts, "\n")
    end
  end

  defp fields(content) do
    case content |> fragments(0) |> Enum.reject(&(String.trim(&1) == "")) |> Enum.uniq() do
      [] -> String.slice(CanonicalJSON.encode!(content), 0, 4000)
      texts -> bounded(texts)
    end
  end

  defp bounded(texts),
    do: texts |> Enum.take(16) |> Enum.map_join("\n", &String.slice(&1, 0, 512))

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
