defmodule Responder.ControlPlane.AdmissionProgress do
  @moduledoc "Observed admission state for the current conversation, without model bodies or private diagnostics."
  import Ecto.Query
  alias Responder.Admission.Attempt
  alias Responder.ControlPlane.{CurrentInputs, InspectionRedactor}
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo

  @labels %{
    "context_prepared" => "Context prepared",
    "execution_requested" => "Preparing or reconciling remote execution",
    "request_frozen" => "Request saved · submitting to provider",
    "provider_queued" => "Provider queued or starting",
    "provider_running" => "Provider running",
    "response_received" => "Response received",
    "host_validation" => "Validating the decision",
    "committed" => "Admission committed"
  }

  def conversation(ref) do
    now = DateTime.utc_now()

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
            fragment(
              "CASE WHEN ? IS NOT NULL THEN NULL WHEN ? = 'delete' THEN 'Message deleted' ELSE left(?::jsonb->>'text', 12000) END",
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
        title: InspectionRedactor.artifact(row.text || "Incoming event", max_bytes: 180).text,
        phase: phase(row, now),
        elapsed_ms: max(DateTime.diff(now, row.received_at, :millisecond), 0),
        observed_at: row.observed_at,
        target: row.target,
        generation: row.generation,
        claims: row.claims,
        retry_at: row.retry_at,
        href: "/episodes/ingress-input%3A#{row.id}"
      }
    end)
  end

  defp phase(%{status: :blocked}, _now), do: "Blocked · operator recovery required"

  defp phase(%{retry_at: %DateTime{} = at} = row, now) do
    if DateTime.compare(at, now) == :gt,
      do: "Waiting to reconcile the existing request",
      else: phase(%{row | retry_at: nil}, now)
  end

  defp phase(%{leased: false}, _now),
    do: "Queued · waiting for a slot or earlier conversation input"

  defp phase(%{phase: phase}, _now) do
    Map.get(@labels, phase, "Classifying · detailed history not recorded")
  end
end
