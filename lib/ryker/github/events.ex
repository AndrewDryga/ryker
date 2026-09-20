defmodule Ryker.GitHub.Events do
  @moduledoc "Idempotent custody and health projection for authenticated GitHub deliveries."

  import Ecto.Query

  alias Ecto.Changeset
  alias Ryker.{CanonicalJSON, Repo}
  alias Ryker.GitHub.{Binding, Event}

  @dispositions ~w(metadata routed continued duplicate failed)

  def record(%Binding{} = binding, delivery_ref, event_ref, event_name, payload) do
    now = Repo.now!()

    attributes = %{
      id: Ecto.UUID.generate(),
      delivery_ref: delivery_ref,
      binding_ref: binding.name,
      repository_id: binding.repository_id,
      event_name: event_name,
      action: payload["action"],
      event_ref: event_ref,
      payload_digest: CanonicalJSON.digest(payload),
      disposition: "received",
      occurred_at: event_time(payload, now),
      inserted_at: now
    }

    case Repo.insert_all(Event, [attributes],
           on_conflict: :nothing,
           returning: true
         ) do
      {0, []} -> duplicate(binding.name, delivery_ref, attributes.payload_digest, now)
      {1, [%Event{} = event]} -> {:ok, event}
      _unexpected -> {:error, :github_event_persistence_failed}
    end
  end

  def complete(event, disposition, reason \\ nil)

  def complete(%Event{} = event, disposition, reason)
      when disposition in @dispositions do
    event
    |> Changeset.change(%{
      disposition: disposition,
      reason: bounded(reason),
      processed_at: Repo.now!()
    })
    |> Repo.update()
  end

  def complete(:duplicate, _disposition, _reason), do: {:ok, :duplicate}

  def health(binding_ref) when is_binary(binding_ref) do
    latest =
      Repo.one(
        from(event in Event,
          where: event.binding_ref == ^binding_ref,
          order_by: [desc: event.occurred_at, desc: event.id],
          limit: 1
        )
      )

    pending =
      Repo.aggregate(
        from(event in Event,
          where: event.binding_ref == ^binding_ref and event.disposition == "received"
        ),
        :count
      )

    failed =
      Repo.aggregate(
        from(event in Event,
          where: event.binding_ref == ^binding_ref and event.disposition == "failed"
        ),
        :count
      )

    processed =
      Repo.one(
        from(event in Event,
          where: event.binding_ref == ^binding_ref and not is_nil(event.processed_at),
          order_by: [desc: event.processed_at, desc: event.id],
          limit: 1
        )
      )

    duplicate_count =
      Repo.one(
        from(event in Event,
          where: event.binding_ref == ^binding_ref,
          select: coalesce(sum(event.duplicate_count), 0)
        )
      )

    %{
      duplicate_count: duplicate_count,
      failed: failed,
      last_event_at: latest && latest.occurred_at,
      last_disposition: latest && latest.disposition,
      last_processed_at: processed && processed.processed_at,
      pending: pending,
      processing_lag_seconds: processing_lag(latest, processed)
    }
  end

  defp duplicate(binding_ref, delivery_ref, digest, now) do
    query =
      from(event in Event,
        where: event.binding_ref == ^binding_ref and event.delivery_ref == ^delivery_ref
      )

    case Repo.one(query) do
      %Event{payload_digest: ^digest} = event ->
        {_count, _rows} =
          Repo.update_all(from(row in Event, where: row.id == ^event.id),
            inc: [duplicate_count: 1],
            set: [last_duplicate_at: now]
          )

        {:ok, :duplicate}

      %Event{} ->
        {:error, :github_event_conflict}

      nil ->
        {:error, :github_event_persistence_failed}
    end
  end

  defp processing_lag(nil, _processed), do: nil
  defp processing_lag(_latest, nil), do: nil

  defp processing_lag(latest, processed),
    do: max(DateTime.diff(latest.occurred_at, processed.occurred_at, :second), 0)

  defp event_time(payload, fallback) do
    candidates = [
      get_in(payload, ["workflow_run", "updated_at"]),
      get_in(payload, ["workflow_job", "completed_at"]),
      get_in(payload, ["check_run", "completed_at"]),
      get_in(payload, ["check_suite", "updated_at"]),
      get_in(payload, ["pull_request", "updated_at"]),
      get_in(payload, ["issue", "updated_at"]),
      get_in(payload, ["release", "published_at"]),
      get_in(payload, ["deployment_status", "updated_at"]),
      get_in(payload, ["deployment", "created_at"])
    ]

    Enum.find_value(candidates, fallback, fn
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, time, 0} -> force_microsecond_precision(time)
          _invalid -> nil
        end

      _value ->
        nil
    end)
  end

  defp bounded(nil), do: nil
  defp bounded(reason), do: reason |> to_string() |> String.slice(0, 256)

  defp force_microsecond_precision(%DateTime{microsecond: {value, _precision}} = time),
    do: %{time | microsecond: {value, 6}}
end
