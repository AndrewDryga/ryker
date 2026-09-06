defmodule Responder.ControlPlane.SourceText do
  @moduledoc "Plain source-message content shared by the timeline and request inspector."

  def from_content(%{} = content) do
    text = content["text"]
    blocks = if present?(text), do: [], else: list(content["blocks"])

    [text | Enum.flat_map(list(content["attachments"]), &attachment/1)]
    |> Kernel.++(Enum.flat_map(blocks, &block/1))
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> case do
      [] -> payload(content["payload"])
      parts -> Enum.join(parts, "\n\n")
    end
  end

  def from_content(_), do: nil
  defp list(value) when is_list(value), do: value
  defp list(_), do: []
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp payload(%{} = value),
    do: Enum.find_value(~w(comment review issue pull_request), &body(value[&1]))

  defp payload(_), do: nil

  defp attachment(%{} = value) do
    parts =
      (Enum.map(~w(pretext title text), &value[&1]) ++
         Enum.flat_map(list(value["blocks"]), &block/1))
      |> Enum.filter(&present?/1)

    if parts == [], do: [value["fallback"]], else: parts
  end

  defp attachment(_), do: []
  defp block(%{"text" => %{"text" => text}}), do: [text]
  defp block(%{"text" => text}) when is_binary(text), do: [text]

  defp block(%{"elements" => elements}) when is_list(elements),
    do: Enum.flat_map(elements, &block/1)

  defp block(_), do: []
  defp body(%{"body" => body}) when is_binary(body), do: body
  defp body(_), do: nil
end
