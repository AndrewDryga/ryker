defmodule Ryker.ControlPlane.AdmissionProgress do
  @moduledoc "Observed admission state for the current conversation, without model bodies or private diagnostics."
  import Ecto.Query
  require Ryker.ControlPlane.CurrentInputs
  alias Ryker.Admission.Attempt
  alias Ryker.ControlPlane.{CurrentInputs, InspectionRedactor}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo

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
          retry_at: entry.next_attempt_at,
          leased: not is_nil(entry.lease_ref),
          claims: entry.attempt_count,
          generation: entry.execution_generation,
          phase: attempt.phase,
          observed_at: attempt.updated_at,
          target: attempt.execution_target,
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
        elapsed_ms: max(DateTime.diff(now, row.received_at, :millisecond), 0),
        observed_at: row.observed_at,
        target: row.target,
        generation: row.generation,
        claims: row.claims,
        retry_at: row.retry_at,
        href: "/timeline/ingress-input%3A#{row.id}"
      }
    end)
  end

  # A pruned or attachment-only message has no text to name the row after.
  defp title(text, _secrets) when text in [nil, ""], do: "Incoming event"

  defp title(text, secrets),
    do: InspectionRedactor.artifact(text, secrets: secrets, max_bytes: 180).text

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
