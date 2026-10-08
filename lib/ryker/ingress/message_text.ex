defmodule Ryker.Ingress.MessageText do
  @moduledoc """
  One message's content as plain text a model can compare.

  Routing compares earlier work by what its messages said, including the
  alert, run or deployment identity an automated notification carries in its
  attachments and fields. A Slack message reads as its text. Slack sends a
  person's message again as rich text blocks with the same words, so the
  blocks are read only when a message has no text of its own. Attachment
  titles, fields as "title: value" and the transcript of a voice message
  follow. A message with none of these reads as the names of the files it
  carried: its ids, types and flags are never words. Structured payloads with
  no text become "path: value" lines. Nothing is sent as JSON inside a string.
  """
  alias Ryker.Reference

  @maximum_lines 200

  @spec from(term()) :: String.t()
  def from(%{} = content) do
    case parts(content) do
      nil -> content |> flatten("") |> Enum.take(@maximum_lines) |> Enum.join("\n")
      parts -> Enum.join(parts, "\n")
    end
  end

  def from(text) when is_binary(text), do: text
  def from(_content), do: ""

  @doc """
  A message's text in the order it reads, each part once, or nil when the
  content is a structured payload rather than a message.
  """
  @spec parts(term()) :: [String.t()] | nil
  def parts(%{} = content) do
    parts =
      (words(content) ++
         Enum.flat_map(list(content["attachments"]), &attachment/1) ++
         Enum.flat_map(list(content["files"]), &file/1))
      |> Enum.filter(&Reference.text?/1)
      |> Enum.uniq()

    cond do
      parts != [] -> parts
      is_binary(content["text"]) -> file_names(content)
      true -> nil
    end
  end

  def parts(_content), do: nil

  defp words(content) do
    if Reference.text?(content["text"]),
      do: [content["text"]],
      else: Enum.flat_map(list(content["blocks"]), &block/1)
  end

  # A voice message says its transcript, or that it has none.
  defp file(%{"transcript" => words}) when is_binary(words), do: [words]
  defp file(%{"transcript_unavailable" => note}) when is_binary(note), do: [note]
  defp file(_file), do: []

  defp file_names(content) do
    content["files"]
    |> list()
    |> Enum.map(&if(is_map(&1), do: &1["name"]))
    |> Enum.filter(&Reference.text?/1)
  end

  defp attachment(%{} = attachment) do
    parts =
      Enum.map(~w(pretext title text), &attachment[&1]) ++
        Enum.map(list(attachment["fields"]), &field/1) ++
        Enum.flat_map(list(attachment["blocks"]), &block/1) ++
        [attachment["footer"]]

    case Enum.filter(parts, &Reference.text?/1) do
      [] -> [attachment["fallback"]]
      parts -> parts
    end
  end

  defp attachment(_attachment), do: []

  defp field(%{"title" => title, "value" => value}) when is_binary(value),
    do: if(Reference.text?(title), do: "#{title}: #{value}", else: value)

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
end
