defmodule Ryker.ControlPlane.SourceText do
  @moduledoc "Plain source-message content shared by the timeline and request inspector."

  alias Ryker.GitHub.Input, as: GitHubInput

  def from_content(%{} = content) do
    text = content["text"]
    blocks = if present?(text), do: [], else: list(content["blocks"])

    [text | Enum.flat_map(list(content["attachments"]), &attachment/1)]
    |> Kernel.++(Enum.flat_map(blocks, &block/1))
    |> Kernel.++(Enum.flat_map(list(content["files"]), &transcript/1))
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> case do
      [] -> GitHubInput.body(content)
      parts -> Enum.join(parts, "\n\n")
    end
  end

  def from_content(_), do: nil
  defp list(value) when is_list(value), do: value
  defp list(_), do: []
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp attachment(%{} = value) do
    parts =
      (Enum.map(~w(pretext title text), &value[&1]) ++
         Enum.flat_map(list(value["blocks"]), &block/1))
      |> Enum.filter(&present?/1)

    if parts == [], do: [value["fallback"]], else: parts
  end

  defp attachment(_), do: []

  # A voice message or video reads as what it said, labelled as a transcript,
  # or says that Ryker could not transcribe it.
  defp transcript(%{"transcript" => words} = file) when is_binary(words),
    do: ["#{recording(file["media_type"])} transcript: #{words}"]

  defp transcript(%{"transcript_unavailable" => note}) when is_binary(note),
    do: [sentence(note)]

  defp transcript(_), do: []

  defp recording("video/" <> _format), do: "Video"
  defp recording(_media_type), do: "Voice message"

  defp sentence(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest <> "."
  defp sentence(note), do: note
  defp block(%{"text" => %{"text" => text}}), do: [text]
  defp block(%{"text" => text}) when is_binary(text), do: [text]

  defp block(%{"elements" => elements}) when is_list(elements),
    do: Enum.flat_map(elements, &block/1)

  defp block(_), do: []
end
