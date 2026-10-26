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
  alias Ryker.Work

  @doc """
  What a background run's worker recorded sending, from
  `Ryker.Work.Activity.prompts_sent/2`; nil
  while the run has no Coop turn, once retention removed its prompt, or when
  its session is gone and with it the records.
  """
  @spec of_run(map(), Work.Session.t() | nil, map(), [String.t()]) :: [map()] | nil
  def of_run(%{coop_turn_id: turn} = run, %Work.Session{id: session_id}, records, secrets)
      when is_binary(turn) do
    if is_nil(Map.get(run, :pruned_at)) do
      records
      |> Map.get(session_id, [])
      |> Enum.filter(&(&1.coop_turn_id == turn))
      |> present(
        %{
          prompt: Map.get(run, :prompt),
          prompt_sha256: run.prompt_sha256,
          output_schema: run.output_schema
        },
        secrets
      )
    end
  end

  def of_run(_run, _session, _records, _secrets), do: nil

  @typedoc """
  What a call saved: its prompt, or only the prompt's digest where the page
  has not read the prompt, and its response format.
  """
  @type saved :: %{
          optional(:prompt) => String.t() | nil,
          optional(:prompt_sha256) => String.t() | nil,
          optional(:output_schema) => map() | nil
        }

  @doc """
  The sends of one call, oldest first, from its `prompt.sent` events and what
  the call saved. A send matches when every part is the call's own prompt or
  response format by digest, or Coop's text as recorded, and together they
  are the size the worker sent; with the prompt at hand, the rebuilt text's
  digest is the one the worker sent too.
  """
  @spec present([map()], saved(), [String.t()]) :: [map()]
  def present(events, saved, secrets) do
    prompt = if is_binary(saved[:prompt]), do: saved[:prompt]
    schema = worker_schema(saved[:output_schema])

    digests = %{
      "caller_prompt" => (prompt && Crypto.sha256_hex(prompt)) || saved[:prompt_sha256],
      "output_schema" => schema && Crypto.sha256_hex(schema)
    }

    events
    |> Enum.map(&send_view(&1.payload, digests, {prompt, schema}, secrets))
    |> titled()
  end

  defp worker_schema(nil), do: nil

  defp worker_schema(schema) do
    CanonicalJSON.worker_encode!(schema)
  rescue
    ArgumentError -> nil
  end

  defp send_view(%{"parts" => parts} = record, digests, texts, secrets) do
    %{
      state: record["state"],
      bytes: record["text_bytes"],
      first?: Enum.any?(parts, &(&1["kind"] == "caller_prompt")),
      matches?: matches?(parts, record, digests, texts),
      parts: Enum.map(parts, &part(&1, digests, secrets)),
      blocks: Enum.map(record["blocks"] || [], &block/1)
    }
  end

  defp send_view(_unreadable, _digests, _texts, _secrets),
    do: %{state: nil, bytes: nil, first?: false, matches?: false, parts: [], blocks: []}

  defp matches?(parts, record, digests, texts) do
    Enum.all?(parts, &same?(&1, digests)) and
      Enum.sum_by(parts, &(&1["bytes"] || 0)) == record["text_bytes"] and
      rebuilt?(parts, record, texts)
  end

  # A part is the call's own when its digest is the one the call saved, and
  # Coop's text is as the worker sent it when it still has its digest.
  defp same?(%{"kind" => "text", "text" => text, "sha256" => digest}, _digests),
    do: Crypto.sha256_hex(text) == digest

  defp same?(%{"kind" => kind, "sha256" => digest}, digests)
       when kind in ["caller_prompt", "output_schema"],
       do: is_binary(digests[kind]) and digests[kind] == digest

  defp same?(_part, _digests), do: false

  defp rebuilt?(_parts, _record, {nil, _schema}), do: true

  defp rebuilt?(parts, record, {prompt, schema}) do
    text =
      Enum.map(parts, fn
        %{"kind" => "caller_prompt"} -> prompt
        %{"kind" => "output_schema"} -> schema || ""
        %{"kind" => "text", "text" => text} -> text
      end)

    Crypto.sha256_hex(IO.iodata_to_binary(text)) == record["text_sha256"]
  end

  defp part(%{"kind" => "caller_prompt"} = part, digests, _secrets) do
    %{
      label: "Prompt text",
      note:
        cond do
          is_nil(digests["caller_prompt"]) -> "No longer kept"
          same?(part, digests) -> "As above, unchanged"
          true -> "Differs from the prompt text above"
        end,
      bytes: part["bytes"]
    }
  end

  defp part(%{"kind" => "output_schema"} = part, digests, _secrets) do
    %{
      label: "Response format",
      note:
        cond do
          is_nil(digests["output_schema"]) -> "No longer kept"
          same?(part, digests) -> "As above, unchanged"
          true -> "Differs from the response format above"
        end,
      bytes: part["bytes"]
    }
  end

  defp part(%{"kind" => "text", "text" => text} = part, _digests, secrets),
    do: %{
      label: "Runtime instructions",
      text: Redactor.redact(text, secrets),
      bytes: part["bytes"]
    }

  defp part(%{"kind" => "withheld"} = part, _digests, _secrets),
    do: %{
      label: "Runtime instructions",
      note: "Withheld by the worker" <> reason(part["reason"]),
      bytes: part["bytes"]
    }

  defp part(part, _digests, _secrets),
    do: %{label: "Runtime instructions", note: "Too large to record", bytes: part["bytes"]}

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
            send.first? and not started? -> {"Initial send", {true, corrections}}
            send.first? -> {"Restarted send", {true, corrections}}
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
      <h5 id={"#{@id}-heading"}>Worker sends</h5>
      <p :if={@sends != []} class="sent-prompts-help">
        co:op adds runtime instructions to the Ryker submission. These are its recorded sends to the model.
      </p>
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
            <Components.inspection_text
              :if={part[:text]}
              text={part.text}
              class="model-document-text"
            />
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
        do: nil,
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
