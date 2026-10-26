defmodule Ryker.ControlPlane.SourceText do
  @moduledoc "Plain source-message content shared by the timeline and request inspector."
  alias Ryker.GitHub
  alias Ryker.Ingress
  alias Ryker.Reference
  alias Ryker.UTCDateTime
  alias Ryker.Wording

  @doc "A system input's readable actor and intent, from its retained payload only."
  def event_preview(%{"kind" => "timer_due"} = event) do
    matcher = if is_map(event["event_matcher"]), do: event["event_matcher"], else: %{}

    parts = [
      "A scheduled check is due.",
      matcher["on_timeout"],
      if(is_binary(event["verification"]), do: "What to verify:\n" <> event["verification"]),
      case UTCDateTime.parse(event["deadline_at"]) do
        {:ok, %DateTime{} = at} -> "Watch deadline: " <> UTCDateTime.readable(at)
        _ -> nil
      end
    ]

    %{
      actor: "Scheduled check",
      text: parts |> Enum.filter(&Reference.text?/1) |> Enum.join("\n\n")
    }
  end

  def event_preview(%{"kind" => "scheduled_task", "schedule" => %{} = schedule}) do
    text =
      [schedule["title"], schedule["task"]]
      |> Enum.filter(&Reference.text?/1)
      |> Enum.join("\n\n")

    %{actor: "Scheduled work", text: text}
  end

  def event_preview(%{"content" => %{} = content}), do: event_preview(content)
  def event_preview(_input), do: nil

  def from_content(%{"kind" => kind} = event) when kind in ~w(timer_due scheduled_task) do
    case event_preview(event) do
      %{text: text} -> text
      _ -> nil
    end
  end

  # An answer given with a question card's button carries the chosen option, not text
  # (Andrew, 2026-10-01: the timeline said "Source content not recorded or expired").
  def from_content(%{"choice" => choice, "interaction_kind" => "button"}) when is_binary(choice),
    do: "Answered \"#{choice}\""

  # A webhook carries its sender's JSON (`Ryker.Webhooks.Input`): it reads as its event type,
  # then the payload's text or its fields, as routing reads them. Every webhook event read
  # "Source content not recorded or expired" (2026-10-09).
  def from_content(%{"event_type" => type, "payload" => payload}) do
    event = if Reference.text?(type), do: "Webhook event: " <> type, else: "Webhook event"

    case Ingress.MessageText.from(payload) do
      "" -> event
      text -> event <> "\n\n" <> text
    end
  end

  def from_content(%{} = content) do
    text = content["text"]
    blocks = if Reference.text?(text), do: [], else: list(content["blocks"])

    [text | Enum.flat_map(list(content["attachments"]), &attachment/1)]
    |> Kernel.++(Enum.flat_map(blocks, &block/1))
    |> Kernel.++(Enum.flat_map(list(content["files"]), &transcript/1))
    |> Enum.filter(&Reference.text?/1)
    |> Enum.uniq()
    |> case do
      [] -> GitHub.Input.body(content)
      parts -> Enum.join(parts, "\n\n")
    end
  end

  def from_content(_), do: nil
  defp list(value) when is_list(value), do: value
  defp list(_), do: []

  defp attachment(%{} = value) do
    parts =
      (Enum.map(~w(pretext title text), &value[&1]) ++
         Enum.flat_map(list(value["blocks"]), &block/1))
      |> Enum.filter(&Reference.text?/1)

    if parts == [], do: [value["fallback"]], else: parts
  end

  defp attachment(_), do: []

  # A voice message or video reads as what it said, labelled as a transcript,
  # or says that Ryker could not transcribe it.
  defp transcript(%{"transcript" => words} = file) when is_binary(words),
    do: ["#{recording(file["media_type"])} transcript: #{words}"]

  defp transcript(%{"transcript_unavailable" => note}) when is_binary(note),
    do: [Wording.sentence(note)]

  defp transcript(_), do: []

  defp recording("video/" <> _format), do: "Video"
  defp recording(_media_type), do: "Voice message"

  defp block(%{"text" => %{"text" => text}}), do: [text]
  defp block(%{"text" => text}) when is_binary(text), do: [text]

  defp block(%{"elements" => elements}) when is_list(elements),
    do: Enum.flat_map(elements, &block/1)

  defp block(_), do: []
end
