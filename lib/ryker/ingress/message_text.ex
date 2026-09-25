defmodule Ryker.Ingress.MessageText do
  @moduledoc """
  One message's content as plain text a model can compare.

  Routing compares earlier work by what its messages said, including the
  alert, run or deployment identity an automated notification carries in its
  attachments and fields. Slack-shaped content keeps its text, attachment
  titles, fields as "title: value" and block text; structured payloads with no
  text become "path: value" lines. Nothing is sent as JSON inside a string.
  """

  @maximum_lines 200

  @spec from(term()) :: String.t()
  def from(%{} = content) do
    case slack_parts(content) do
      [] -> content |> flatten("") |> Enum.take(@maximum_lines) |> Enum.join("\n")
      parts -> parts |> Enum.uniq() |> Enum.join("\n")
    end
  end

  def from(text) when is_binary(text), do: text
  def from(_content), do: ""

  defp slack_parts(content) do
    [content["text"]]
    |> Kernel.++(Enum.flat_map(list(content["attachments"]), &attachment/1))
    |> Kernel.++(Enum.flat_map(list(content["blocks"]), &block/1))
    |> Enum.filter(&text?/1)
  end

  defp attachment(%{} = attachment) do
    parts =
      Enum.map(~w(pretext title text), &attachment[&1]) ++
        Enum.map(list(attachment["fields"]), &field/1) ++
        Enum.flat_map(list(attachment["blocks"]), &block/1) ++
        [attachment["footer"]]

    case Enum.filter(parts, &text?/1) do
      [] -> [attachment["fallback"]]
      parts -> parts
    end
  end

  defp attachment(_attachment), do: []

  defp field(%{"title" => title, "value" => value}) when is_binary(value),
    do: if(text?(title), do: "#{title}: #{value}", else: value)

  defp field(%{"value" => value}) when is_binary(value), do: value
  defp field(_field), do: nil

  defp block(%{"text" => %{"text" => text}} = block),
    do: [text | Enum.flat_map(list(block["fields"]), &block/1)]

  defp block(%{"text" => text}) when is_binary(text), do: [text]
  defp block(%{"fields" => fields}) when is_list(fields), do: Enum.flat_map(fields, &block/1)

  defp block(%{"elements" => elements}) when is_list(elements),
    do: Enum.flat_map(elements, &block/1)

  defp block(_block), do: []

  defp flatten(%{} = value, path) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, nested} -> flatten(nested, join(path, to_string(key))) end)
  end

  defp flatten(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {nested, index} -> flatten(nested, "#{path}[#{index}]") end)
  end

  defp flatten(nil, _path), do: []
  defp flatten(value, ""), do: [to_string(value)]
  defp flatten(value, path) when is_binary(value), do: ["#{path}: #{value}"]
  defp flatten(value, path), do: ["#{path}: #{Jason.encode!(value)}"]

  defp join("", key), do: key
  defp join(path, key), do: path <> "." <> key

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
end
