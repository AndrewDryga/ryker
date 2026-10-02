defmodule Ryker.ControlPlane.AdmissionProgress do
  @moduledoc "Observed admission state for the current conversation, without model bodies or private diagnostics."
  import Ecto.Query
  require Ryker.ControlPlane.CurrentInputs
  alias Ryker.Admission.Attempt
  alias Ryker.ControlPlane.{CurrentInputs, Paths}
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.InputCustodyTransition
  alias Ryker.InspectionRedactor
  alias Ryker.Repo
  alias Ryker.Work.FailureCause

  @labels %{
    "context_prepared" => "Starting",
    "execution_requested" => "Starting",
    "request_frozen" => "Starting",
    "provider_queued" => "Starting",
    "provider_running" => "Working",
    "response_received" => "Finishing",
    "host_validation" => "Finishing",
    "committed" => "Finishing"
  }

  def conversation(ref) do
    now = DateTime.utc_now()
    secrets = InspectionRedactor.configured_secrets()

    Repo.all(
      from(entry in Entry,
        join: current in subquery(CurrentInputs.latest()),
        on:
          current.native_input_id == entry.native_input_id and
            current.execution_mode == entry.execution_mode,
        left_join: attempt in Attempt,
        on: attempt.input_id == entry.id and attempt.generation == entry.execution_generation,
        left_join: retried in subquery(latest_retries()),
        on: retried.input_id == entry.id,
        where:
          entry.destination_transport == "control_plane" and
            entry.destination_conversation_ref == ^ref and entry.status in [:pending, :blocked],
        order_by: [asc: entry.inserted_at, asc: entry.id],
        limit: 20,
        select: %{
          id: entry.id,
          native_input_id: entry.native_input_id,
          status: entry.status,
          received_at: entry.inserted_at,
          retried_at: retried.at,
          retry_at: entry.next_attempt_at,
          leased: not is_nil(entry.lease_ref),
          claims: entry.attempt_count,
          generation: entry.execution_generation,
          phase: attempt.phase,
          observed_at: attempt.updated_at,
          target: attempt.execution_target,
          error_detail: entry.last_error_detail,
          text:
            CurrentInputs.visible_text(
              current.operational_pruned_at,
              current.event_kind,
              current.content
            )
        }
      )
    )
    |> Enum.map(fn row ->
      %{
        id: row.id,
        # Lets a conversation page place this progress beside the message that
        # caused it, whichever revision of that message is currently shown.
        native_input_id: row.native_input_id,
        title: title(row.text, secrets),
        phase: phase(row, now),
        elapsed_ms: max(DateTime.diff(now, started_at(row), :millisecond), 0),
        observed_at: row.observed_at,
        target: row.target,
        generation: row.generation,
        claims: row.claims,
        retry_at: row.retry_at,
        href: Paths.request(row.id),
        ref: Inbox.ref(%Entry{id: row.id}),
        cause: stopped_cause(row)
      }
    end)
  end

  # A retried message is routed again from the retry: counting from when it
  # first arrived read "Routing your message 307m 29s" on the live install
  # (2026-09-26) for a message retried five hours after it stopped.
  defp latest_retries do
    from(transition in InputCustodyTransition,
      where: transition.kind == :rearmed,
      group_by: transition.input_id,
      select: %{input_id: transition.input_id, at: max(transition.occurred_at)}
    )
  end

  defp started_at(%{retried_at: %DateTime{} = retried}), do: retried

  defp started_at(%{retried_at: %NaiveDateTime{} = retried}),
    do: DateTime.from_naive!(retried, "Etc/UTC")

  defp started_at(row), do: row.received_at

  # A pruned or attachment-only message has no text to name the row after.
  defp title(text, _secrets) when text in [nil, ""], do: "Incoming event"

  defp title(text, secrets),
    do: InspectionRedactor.artifact(text, secrets: secrets, max_bytes: 180).text

  # Only what a person in the conversation can act on; the failure's own
  # page carries the rest.
  defp stopped_cause(%{status: :blocked, error_detail: detail}) do
    if FailureCause.account_problem?(detail), do: "the AI model account needs attention"
  end

  defp stopped_cause(_row), do: nil

  defp phase(%{status: :blocked}, _now), do: "Needs attention"

  defp phase(%{retry_at: %DateTime{} = at} = row, now) do
    if DateTime.compare(at, now) == :gt,
      do: "Retrying",
      else: phase(%{row | retry_at: nil}, now)
  end

  defp phase(%{leased: false}, _now), do: "Queued"

  defp phase(%{phase: phase}, _now) do
    Map.get(@labels, phase, "Starting")
  end
end
