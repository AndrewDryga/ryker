defmodule Responder.Admission.Prompt do
  @moduledoc """
  Provider-neutral instructions and data for one admission turn.

  The response schema is returned separately so Coop can enforce structured
  output without duplicating the schema inside natural-language instructions.
  """

  alias Responder.Admission.Context

  @max_encoded_bytes 65_536

  @instructions """
  Decide how Responder should handle this incoming event. Interpret the event itself; the host does not
  classify individual apps, webhook payloads, or message formats for you.

  Choose exactly one action:
  - start_episode: this begins work that needs investigation, tools, or more than an immediate answer.
  - continue_episode: this is another turn in one offered episode. Use same_work only for the same
    actual request, lifecycle, or conversation, not merely similar wording or the same sender.
  - reply: Responder can answer directly without starting a longer investigation. It may be unrelated,
    continue the same work, or start from linked history as allowed by the candidate.
  - react: when offered, a nonverbal acknowledgement is sufficient. Supply the exact emoji name.
  - ignore: no Responder action would help. Give a short factual reason. Never ignore a request directed
    at Responder.

  Choose work_class independently from the lifecycle action:
  - conversational: only with reply, for ordinary questions, chat, or a small focused lookup.
  - standard: the default for investigation and normal tool-backed work.
  - deep: only when materially harder reasoning, ambiguity, or consequence justifies the extra cost.
  - null: only with react or ignore.
  The class chooses compute from a host-owned profile. It never changes repository, tools, credentials,
  or write authority. Do not choose deep merely because the message is long, urgent, or asks for edits.

  Use history_only when the older episode is useful background but the current event is new work. A
  history link never reuses the older destination. Use only candidate references and relations
  present in the supplied context. Do not invent identifiers.

  For automated lifecycle events, compare explicit source identity before wording or timing:
  - The same run ID, alert start identity, deployment ID, pull request, or equivalent source object is
    same_work. Its progress, success, recovery, resolved, or other terminal update continues the active
    episode even when the update asks no question; do not ignore the event that closes active work.
  - A different explicit run ID or alert start identity is new work. Never merge it into an older
    completed lifecycle merely because the provider, project, alert name, wording, or arrival time is
    similar. Start a new episode and use history_only when the offered episode is related background.
  - A completed episode may be continued only for a genuine follow-up to that same lifecycle or
    conversation. A new firing/start identity after completion begins linked new work.

  execution_mode is host-owned. Shadow means observe-only: classify exactly as you would for live
  traffic, but the host will isolate any longer investigation and suppress posts, reactions, offers,
  incidents, and mutations while retaining read-only evaluation evidence.
  """

  @spec build(Context.t()) :: map()
  def build(%Context{} = context) do
    request = %{
      "context" => Context.for_model(context),
      "instructions" => @instructions
    }

    case Responder.CanonicalJSON.validate(request, max_bytes: @max_encoded_bytes) do
      :ok ->
        request

      {:error, reason} ->
        raise ArgumentError, "admission prompt exceeds its bound: #{inspect(reason)}"
    end
  end
end
