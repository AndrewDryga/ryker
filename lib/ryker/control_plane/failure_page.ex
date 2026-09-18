defmodule Ryker.ControlPlane.FailurePage do
  @moduledoc "A recovery brief with host facts and redacted, attributed final responses."
  use Phoenix.Component
  alias Ryker.ControlPlane.{Components, SlackMarkdown, SlackNames}

  def render(assigns) do
    row = assigns.row

    assigns =
      assigns
      |> assign(:work, row[:work_recovery])
      |> assign(:ownership_missing, manual_repair?(row))
      |> assign(:cause, cause(row))
      |> assign(:destination, destination(row))
      |> assign(:steps, cleanup_steps(row))
      |> assign(:outcome, request_outcome(row))

    ~H"""
    <section class="failure-detail">
      <div class="failure-heading">
        <h2>
          {cond do
            @work -> @work.headline
            @ownership_missing -> "Temporary files could not be removed"
            true -> @title
          end}
        </h2>
        <p :if={@outcome} class="failure-outcome">{@outcome}</p>
        <div class="failure-meta">
          <span :if={@destination && !@ownership_missing}>{@destination}</span>
          <span :if={!@ownership_missing}>
            {Map.get(@row, :attempt_count, 0)} {if @row[:attempt_count] == 1,
              do: "attempt",
              else: "attempts"}
          </span>
          <time>Updated {Components.timestamp(@row.updated_at)}</time>
        </div>
      </div>

      <div :if={@row[:episode_ref]} class="failure-request">
        <span>Related request</span>
        <a href={"/timeline/" <> URI.encode_www_form(@row.episode_ref)}>
          {Map.get(@row, :request_title) || "Open request"}
        </a>
      </div>

      <div :if={@row.kind == "admission" && !@row[:episode_ref]} class="failure-request">
        <span>Original input</span>
        <a href={"/timeline/" <> URI.encode_www_form(@row.ref)}>Open message and routing</a>
      </div>

      <div class="failure-explanation">
        <section>
          <h3>Why it stopped</h3>
          <p>{if @work, do: @work.cause, else: @cause}</p>
        </section>
        <section :if={@work} class="recovery-preserved">
          <h3>{if @work[:not_started], do: "What happened", else: "What is preserved"}</h3>
          <p>{@work.workspace}</p>
          <p :if={@work[:not_started]}>{@work.delivery}</p>
          <p :if={@work.model_output}>The worker’s final response is retained. {@work.delivery}</p>
          <p :if={!@work.model_output && !@work[:not_started]}>
            No retained, accepted final response is available.
          </p>
        </section>
        <section class="failure-next-step">
          <h3>{if @work, do: "What you need to do", else: "Next step"}</h3>
          <p :if={@ownership_missing}>
            Leave the folder in place for now. Do not retry cleanup.
          </p>
          <p :if={@ownership_missing}>
            There is no supported recovery command for this older session yet. Freeing this disk space needs a cleanup fix in Coop, not a change to your request or configuration.
          </p>
          <p :if={!@ownership_missing}>{if @work, do: @work.next_step, else: next_step(@row)}</p>
          <a :if={@work && @work[:setup_href]} href={@work.setup_href} class="ui-button secondary">View required setup</a>
          <div :if={!@ownership_missing && @recovery != ""} class="failure-recovery">
            {Phoenix.HTML.raw(@recovery)}
            <p>{if @work, do: @work.retry_effect, else: recovery_effect(@row.kind)}</p>
          </div>
        </section>
        <details :if={@work && @work.model_output} class="recovery-worker-report">
          <summary>Worker’s saved response</summary>
          <p class="recovery-attribution">
            The worker reported the following. Check claims are not independently verified by this page.
          </p>
          <div class="recovery-model-output">
            {Phoenix.HTML.raw(SlackMarkdown.preview(@work.model_output))}
          </div>
        </details>
      </div>

      <details class="failure-diagnostics">
        <summary>Technical details</summary>
        <dl>
          <dt>Operation</dt><dd>{@row.kind}</dd>
          <dt :if={@ownership_missing}>Attempts</dt>
          <dd :if={@ownership_missing}>{Map.get(@row, :attempt_count, 0)}</dd>
          <dt :if={@row[:diagnosis]}>Worker response</dt>
          <dd :if={@row[:diagnosis]}>HTTP {@row.diagnosis.http_status}</dd>
          <dt>Error code</dt><dd>{get_in(@row, [:diagnosis, :code]) || @row.summary}</dd>
          <dt>Record</dt><dd>{@row.ref}</dd>
          <dt :if={@row[:source]}>Source</dt><dd :if={@row[:source]}>{@row.source}</dd>
          <dt :if={@destination && @ownership_missing}>Conversation</dt>
          <dd :if={@destination && @ownership_missing}>{@destination}</dd>
          <dt :if={@row[:detail]}>Fingerprint</dt><dd :if={@row[:detail]}>{@row.detail}</dd>
        </dl>
        <ol :if={@steps != []} class="failure-progress" aria-label="Cleanup progress">
          <li :for={step <- @steps} class={step.state}>
            <span class="failure-step-state">{step.status}</span><strong>{step.label}</strong>
          </li>
        </ol>
        <div :if={@ownership_missing && @recovery != ""} class="failure-recovery">
          <p>
            This retries the same cleanup check. It cannot restore the missing ownership record.
          </p>
          {Phoenix.HTML.raw(@recovery)}
        </div>
      </details>
      <a class="failure-back" href="/failures">← All failures</a>
    </section>
    """
  end

  def cause(%{kind: "retention", diagnosis: %{reason: :missing_ownership}}),
    do:
      "The worker is missing the record linking this run to its temporary folder. It stopped cleanup to avoid deleting another run's files."

  def cause(%{diagnosis: %{code: "invalid_session_state"}}),
    do: "Coop rejected the operation because the saved session is not in a state that allows it."

  def cause(%{diagnosis: %{code: "revision_conflict"}}),
    do: "The worker session changed before this operation could finish."

  def cause(%{diagnosis: %{code: "session_not_found"}}),
    do: "Coop could not find the saved worker session."

  def cause(%{diagnosis: %{code: "session_cleanup_error"}}),
    do: "Coop encountered an error while cleaning up the worker session."

  # Publishing has its own two long-running failures, and both were reading as
  # "no recognized explanation" while the host held the exact code.
  def cause(%{kind: "publication", summary: "publication_coop_protocol_error"}),
    do:
      "The worker session it was reviewing is no longer in a state that allows it. A review needs that exact session, so retrying alone cannot clear this; queue a fresh review from the task card."

  def cause(%{kind: "publication", summary: "publication_repository_not_configured"}),
    do:
      "The repository has no connected GitHub App for Ryker to publish through. The change is saved and waits for that connection."

  def cause(%{summary: code}) when code in ~w(coop_unavailable coop_transport_error),
    do: "Ryker could not reach the worker to finish this operation."

  def cause(%{summary: "coop_worker_command_timeout"}),
    do: "The worker did not take or finish this operation's command in time."

  def cause(%{diagnosis: %{http_status: status}}) when status >= 500,
    do: "Coop returned a server error before Ryker could confirm the operation."

  def cause(%{diagnosis: %{http_status: 429}}),
    do: "Coop asked Ryker to slow down. Automatic retries have stopped."

  # A blocked turn's recovery brief already reads its saved error through
  # FailureCause; this list says the same thing rather than calling it unknown.
  def cause(%{kind: "work", work_recovery: %{explained: true, cause: cause}}), do: cause

  def cause(_row),
    do:
      "The operation stopped before Ryker could confirm it had finished. No recognized error explanation is available in the saved record."

  def manual_repair?(%{kind: "retention", diagnosis: %{reason: :missing_ownership}}), do: true
  def manual_repair?(_row), do: false

  defp request_outcome(%{kind: "retention", request_state: :complete}),
    do: "The request is complete. Only automatic cleanup failed."

  defp request_outcome(%{kind: "retention", request_state: :cancelled}),
    do: "The request was cancelled. Its automatic cleanup failed."

  defp request_outcome(_row), do: nil

  defp next_step(%{summary: code})
       when code in ~w(coop_unavailable coop_transport_error coop_worker_command_timeout),
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
