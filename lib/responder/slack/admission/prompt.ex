defmodule Responder.Slack.Admission.Prompt do
  @moduledoc """
  Provider-neutral instructions and data for one Slack admission turn.

  The response schema is returned separately so Coop can enforce structured
  output without duplicating the schema inside natural-language instructions.
  """

  alias Responder.Slack.Admission.{Context, Decision}

  @max_encoded_bytes 65_536

  @instructions """
  Decide how Responder should handle this Slack event. Interpret the message itself; the host does not
  classify individual apps or message formats for you.

  Choose exactly one action:
  - start_episode: this begins work that needs investigation, tools, or more than an immediate answer.
  - continue_episode: this is another turn in one offered episode. Use same_work only for the same
    actual request, lifecycle, or conversation, not merely similar wording or the same sender.
  - reply: Responder can answer directly without starting a longer investigation. It may be unrelated,
    continue the same work, or start from linked history as allowed by the candidate.
  - react: a nonverbal acknowledgement is sufficient. Supply the exact Slack emoji name.
  - ignore: no Responder action would help. Give a short factual reason. Never ignore a request directed
    at Responder.

  Use history_only when the older episode is useful background but the current event is new work. A
  history link never reuses the older Slack destination. Use only candidate references and relations
  present in the supplied context. Do not invent identifiers.
  """

  @spec build(Context.t()) :: map()
  def build(%Context{} = context) do
    request = %{
      "context" => Context.for_model(context),
      "instructions" => @instructions,
      "response_schema" => Decision.json_schema()
    }

    case Responder.CanonicalJSON.validate(request, max_bytes: @max_encoded_bytes) do
      :ok ->
        request

      {:error, reason} ->
        raise ArgumentError, "admission prompt exceeds its bound: #{inspect(reason)}"
    end
  end
end
