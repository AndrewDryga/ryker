defmodule Responder.ControlPlane.FailurePage do
  @moduledoc "A recovery brief built from saved, payload-free failure evidence."
  use Phoenix.Component
  alias Responder.ControlPlane.{Components, SlackNames}

  def render(assigns) do
    row = assigns.row

    assigns =
      assigns
      |> assign(:ownership_missing, get_in(row, [:diagnosis, :reason]) == :missing_ownership)
      |> assign(:cause, cause(row))
      |> assign(:destination, destination(row))
      |> assign(:steps, cleanup_steps(row))

    ~H"""
    <section class="failure-detail">
      <div class="failure-heading">
        <span class="failure-kicker">{@title}</span>
        <h2>
          {if @ownership_missing, do: "Ownership proof is missing", else: "This step needs attention"}
        </h2>
        <div class="failure-meta">
          <span :if={@row.kind == "retention" && @row[:source]}>{@row.source}</span>
          <span :if={@destination}>{@destination}</span>
          <span>{Map.get(@row, :attempt_count, 0)} attempts</span>
          <time>{Components.timestamp(@row.updated_at)}</time>
        </div>
      </div>

      <div :if={@row[:episode_ref]} class="failure-request">
        <span>Related request</span>
        <a href={"/episodes/" <> URI.encode_www_form(@row.episode_ref)}>
          {Map.get(@row, :request_title) || "Open request"}
        </a>
      </div>

      <div :if={@row.kind == "admission" && !@row[:episode_ref]} class="failure-request">
        <span>Original input</span>
        <a href={"/admission/" <> URI.encode_www_form(String.replace_prefix(@row.ref, "ingress-input:", ""))}>Open message and routing</a>
      </div>

      <ol :if={@steps != []} class="failure-progress" aria-label="Cleanup progress">
        <li :for={step <- @steps} class={step.state}>
          <span class="failure-step-state">{step.status}</span><strong>{step.label}</strong>
        </li>
      </ol>

      <div class="failure-explanation">
        <section>
          <h3>What happened</h3>
          <p>{@cause}</p>
          <p :if={@row[:diagnosis]} class="failure-response">
            Coop returned HTTP {@row.diagnosis.http_status}.
          </p>
          <p :if={@row.kind == "retention" && !@row[:discarded_at]}>
            Responder has no confirmed removal receipt for this working copy. The request history remains available.
          </p>
        </section>
        <section class="failure-next-step">
          <h3>What to do</h3>
          <p :if={@ownership_missing}>
            Preserve the working copy before recreating this older session in Coop. Retrying alone will not repair the missing record.
          </p>
          <p :if={!@ownership_missing}>{next_step(@row)}</p>
          <div :if={@recovery != ""} class="failure-recovery">
            {Phoenix.HTML.raw(@recovery)}
            <p>{recovery_effect(@row.kind)}</p>
          </div>
        </section>
      </div>

      <details class="failure-diagnostics">
        <summary>Diagnostic reference</summary>
        <dl>
          <dt>Operation</dt><dd>{@row.kind}</dd>
          <dt>Error code</dt><dd>{get_in(@row, [:diagnosis, :code]) || @row.summary}</dd>
          <dt>Record</dt><dd>{@row.ref}</dd>
          <dt :if={@row[:source]}>Source</dt><dd :if={@row[:source]}>{@row.source}</dd>
          <dt :if={@row[:detail]}>Fingerprint</dt><dd :if={@row[:detail]}>{@row.detail}</dd>
        </dl>
      </details>
      <a class="failure-back" href="/failures">← All failures</a>
    </section>
    """
  end

  def cause(%{diagnosis: %{reason: :missing_ownership}}),
    do:
      "Coop cannot prove that this older session owns its working copy, so it refused cleanup. This safety check prevents removal of a directory that might belong to other work."

  def cause(%{diagnosis: %{code: "invalid_session_state"}}),
    do: "Coop rejected the operation because the saved session is not in a state that allows it."

  def cause(%{diagnosis: %{code: "revision_conflict"}}),
    do: "The worker session changed before this operation could finish."

  def cause(%{diagnosis: %{code: "session_not_found"}}),
    do: "Coop could not find the saved worker session."

  def cause(%{diagnosis: %{code: "session_cleanup_error"}}),
    do: "Coop encountered an error while cleaning up the worker session."

  def cause(%{summary: code}) when code in ~w(coop_unavailable coop_transport_error),
    do: "Responder could not reach the worker to finish this operation."

  def cause(%{diagnosis: %{http_status: status}}) when status >= 500,
    do: "Coop returned a server error before Responder could confirm the operation."

  def cause(%{diagnosis: %{http_status: 429}}),
    do: "Coop asked Responder to slow down. Automatic retries have stopped."

  def cause(_row),
    do:
      "The operation stopped before Responder could confirm it had finished. No recognized error explanation is available in the saved record."

  defp next_step(%{summary: code}) when code in ~w(coop_unavailable coop_transport_error),
    do: "Restore the worker connection, then retry the interrupted step."

  defp next_step(%{diagnosis: %{code: code}})
       when code in ~w(invalid_session_state session_not_found),
       do: "Check this session in Coop and resolve its state or availability before retrying."

  defp next_step(%{kind: "retention"}),
    do:
      "Check the working copy and the worker before retrying. Do not remove the directory manually while it may contain unfinished work."

  defp next_step(_row),
    do:
      "Open the related request to inspect the interrupted step. Retry after its underlying error has been resolved."

  defp recovery_effect("retention"),
    do:
      "Checks the same saved session again. It does not recreate the session or bypass ownership checks."

  defp recovery_effect("delivery"),
    do: "Retries the accepted reply; it does not ask the model to generate another answer."

  defp recovery_effect("admission"), do: "Retries routing for this saved input."
  defp recovery_effect("work"), do: "Retries the interrupted work on this request."
  defp recovery_effect("emisar"), do: "Resumes checking the existing approval request."
  defp recovery_effect("slack_incident"), do: "Resumes setup of this incident room."
  defp recovery_effect("slack_interaction"), do: "Retries updating the existing Slack message."
  defp recovery_effect(_kind), do: "Retries the interrupted operation."

  defp cleanup_steps(%{kind: "retention", cleanup_phase: phase} = row) do
    [
      step("Close session", :close_pending, phase, not is_nil(row[:closed_at])),
      step(
        "Check whether removal is safe",
        :plan_pending,
        phase,
        phase == :discard_pending or not is_nil(row[:discarded_at])
      ),
      step("Remove working copy", :discard_pending, phase, not is_nil(row[:discarded_at]))
    ]
  end

  defp cleanup_steps(_row), do: []

  defp step(label, _stage, _phase, true), do: %{label: label, state: "done", status: "Confirmed"}

  defp step(label, phase, phase, false),
    do: %{label: label, state: "blocked", status: "Stopped here"}

  defp step(label, _stage, _phase, false),
    do: %{label: label, state: "pending", status: "Not confirmed"}

  defp destination(row) do
    case row[:destination] do
      value when is_binary(value) ->
        value |> String.split(" / ", parts: 2) |> hd() |> SlackNames.destination()

      _missing ->
        nil
    end
  end
end
