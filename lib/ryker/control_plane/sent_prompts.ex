defmodule Ryker.ControlPlane.SentPrompts do
  @moduledoc """
  What the worker recorded sending the model for one call: one entry for each
  prompt it sent, from the call's `prompt.sent` records (`Ryker.Work.Activity`).

  A record names Ryker's prompt and response format by digest and carries the
  text Coop wrote around them, so each send is rebuilt from the call's saved
  prompt and checked against the digest of the whole text the worker sent. A
  send that cannot be rebuilt says which part is missing, and a call whose
  worker kept no record says that; nothing is rebuilt from today's templates.
  """
  use Phoenix.Component
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{Components, Units}
  alias Ryker.Crypto
  alias Ryker.InspectionRedactor, as: Redactor

  @doc """
  The sends of one call, oldest first, from its `prompt.sent` events and the
  submission they were sent for.
  """
  @spec present([map()], map(), [String.t()]) :: [map()]
  def present(events, submission, secrets) do
    prompt = if is_binary(submission["prompt"]), do: submission["prompt"]
    schema = worker_schema(submission["output_schema"])

    events
    |> Enum.map(&send_view(&1.payload, prompt, schema, secrets))
    |> titled()
  end

  defp worker_schema(nil), do: nil

  defp worker_schema(schema) do
    CanonicalJSON.worker_encode!(schema)
  rescue
    ArgumentError -> nil
  end

  defp send_view(%{"parts" => parts} = record, prompt, schema, secrets) do
    matches? =
      case rebuild(parts, prompt, schema) do
        {:ok, text} -> Crypto.sha256_hex(text) == record["text_sha256"]
        :missing -> false
      end

    %{
      state: record["state"],
      bytes: record["text_bytes"],
      first?: Enum.any?(parts, &(&1["kind"] == "caller_prompt")),
      matches?: matches?,
      parts: Enum.map(parts, &part(&1, prompt, schema, secrets)),
      blocks: Enum.map(record["blocks"] || [], &block/1)
    }
  end

  defp send_view(_unreadable, _prompt, _schema, _secrets),
    do: %{state: nil, bytes: nil, first?: false, matches?: false, parts: [], blocks: []}

  defp rebuild(parts, prompt, schema) do
    parts
    |> Enum.reduce_while([], fn part, text ->
      case rebuilt_part(part, prompt, schema) do
        nil -> {:halt, nil}
        value -> {:cont, [text | value]}
      end
    end)
    |> case do
      nil -> :missing
      text -> {:ok, IO.iodata_to_binary(text)}
    end
  end

  defp rebuilt_part(%{"kind" => "caller_prompt"} = part, prompt, _schema),
    do: if(same?(prompt, part), do: prompt)

  defp rebuilt_part(%{"kind" => "output_schema"} = part, _prompt, schema),
    do: if(same?(schema, part), do: schema)

  defp rebuilt_part(%{"kind" => "text", "text" => text}, _prompt, _schema), do: text
  defp rebuilt_part(_part, _prompt, _schema), do: nil

  defp same?(text, %{"sha256" => digest}) when is_binary(text),
    do: Crypto.sha256_hex(text) == digest

  defp same?(_text, _part), do: false

  defp part(%{"kind" => "caller_prompt"} = part, prompt, _schema, _secrets) do
    %{
      label: "Prompt text",
      note:
        cond do
          is_nil(prompt) -> "No longer kept"
          same?(prompt, part) -> "As above, unchanged"
          true -> "Differs from the prompt text above"
        end,
      bytes: part["bytes"]
    }
  end

  defp part(%{"kind" => "output_schema"} = part, _prompt, schema, _secrets) do
    %{
      label: "Response format",
      note:
        cond do
          is_nil(schema) -> "No longer kept"
          same?(schema, part) -> "As above, unchanged"
          true -> "Differs from the response format above"
        end,
      bytes: part["bytes"]
    }
  end

  defp part(%{"kind" => "text", "text" => text} = part, _prompt, _schema, secrets),
    do: %{label: "Added by Coop", text: Redactor.redact(text, secrets), bytes: part["bytes"]}

  defp part(%{"kind" => "withheld"} = part, _prompt, _schema, _secrets),
    do: %{
      label: "Added by Coop",
      note: "Withheld by the worker" <> reason(part["reason"]),
      bytes: part["bytes"]
    }

  defp part(part, _prompt, _schema, _secrets),
    do: %{label: "Added by Coop", note: "Too large to record", bytes: part["bytes"]}

  defp reason(reason) when is_binary(reason), do: ": " <> reason
  defp reason(_reason), do: ""

  defp block(block) do
    %{
      label: block["name"] || "Attachment",
      note:
        [block["media_type"], is_integer(block["bytes"]) && Units.bytes(block["bytes"])]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" · ")
    }
  end

  # The first send carries the prompt; one later that carries it again started
  # over (on another model, or in a fresh box), and one that does not is a
  # correction Coop wrote on its own.
  defp titled(sends) do
    {titled, _seen} =
      Enum.map_reduce(sends, {false, 0}, fn send, {started?, corrections} ->
        {title, seen} =
          cond do
            is_nil(send.state) -> {"Unreadable record", {started?, corrections}}
            send.first? and not started? -> {"First message", {true, corrections}}
            send.first? -> {"Sent again from the start", {true, corrections}}
            true -> {"Correction #{corrections + 1}", {started?, corrections + 1}}
          end

        {Map.put(send, :title, title), seen}
      end)

    titled
  end

  attr(:id, :string, required: true)
  attr(:sends, :list, default: nil, doc: "From `present/3`; nil when nothing was looked up")

  @doc "Every prompt the call's worker sent, each behind a disclosure of its own."
  def list(assigns) do
    ~H"""
    <section :if={is_list(@sends)} class="sent-prompts" aria-labelledby={"#{@id}-heading"}>
      <h5 id={"#{@id}-heading"}>Sent to the model</h5>
      <p :if={@sends == []} class="sent-prompts-none">Not recorded for this call.</p>
      <Components.disclosure
        :for={{send, index} <- Enum.with_index(@sends, 1)}
        id={"#{@id}-#{index}"}
        label={send.title}
        kind={:source}
        class="sent-prompt"
      >
        <:meta>{meta(send)}</:meta>
        <ol class="sent-prompt-parts">
          <li :for={part <- send.parts}>
            <p>
              <strong>{part.label}</strong>
              <span :if={part[:bytes]}>{Units.bytes(part.bytes)}</span>
              <span :if={part[:note]}>{part.note}</span>
            </p>
            <Components.copy_block :if={part[:text]} label="Copy Coop's text">
              <pre class="model-document-text" tabindex="0">{part.text}</pre>
            </Components.copy_block>
          </li>
          <li :for={block <- send.blocks}>
            <p>
              <strong>Attachment</strong>
              <span>{block.label}</span>
              <span :if={block.note != ""}>{block.note}</span>
            </p>
          </li>
        </ol>
      </Components.disclosure>
    </section>
    """
  end

  defp meta(%{state: nil}), do: "The worker's record could not be read"

  defp meta(send) do
    [
      if(is_integer(send.bytes), do: Units.bytes(send.bytes)),
      state(send.state),
      if(send.matches?,
        do: "matches what was sent",
        else: "could not be checked against what was sent"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp state("sent"), do: nil
  defp state("failed"), do: "not delivered"
  defp state("uncertain"), do: "may not have been delivered"
end
