defmodule Ryker.ControlPlane.AdmissionProgress do
  @moduledoc "Observed admission state for the current conversation, without model bodies or private diagnostics."
  alias Ryker.ControlPlane.{ConversationQuery, Paths}
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
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

    ref
    |> ConversationQuery.waiting_messages(20)
    |> Repo.all()
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
