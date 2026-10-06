defmodule Ryker.GitHub.Events do
  @moduledoc """
  Idempotent custody and health projection for authenticated GitHub deliveries.

  A delivery recorded, repeated or processed is announced after the outermost
  commit (`subscribe_deliveries/0`), so a page showing a repository's GitHub
  health can say it again.

  A delivery is taken once. One whose processing failed, or that a crash left
  unprocessed for ten minutes, is taken again when it comes again, from
  GitHub's "Redeliver" or `Ryker.GitHub.DeliveryPoller`; every other copy is a
  duplicate.
  """

  import Ecto.Query
  alias Ecto.Changeset
  alias Ryker.{CanonicalJSON, Repo}
  alias Ryker.GitHub.{Binding, Event}
  alias Ryker.Settings.GitHubBinding

  @dispositions ~w(metadata routed continued duplicate failed)
  @abandoned_seconds 10 * 60

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
      {0, []} ->
        retry_or_duplicate(binding.name, delivery_ref, attributes.payload_digest, now)

      {1, [%Event{} = event]} ->
        broadcast_delivery_updated(event.binding_ref)
        {:ok, event}

      _unexpected ->
        {:error, :github_event_persistence_failed}
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
    |> tap(fn _result -> broadcast_delivery_updated(event.binding_ref) end)
  end

  def complete(:duplicate, _disposition, _reason), do: {:ok, :duplicate}

  @doc """
  The deliveries among `delivery_refs` that were taken and will not be taken
  again: recorded, and neither failed nor abandoned.
  """
  @spec settled([String.t()]) :: MapSet.t(String.t())
  def settled([]), do: MapSet.new()

  def settled(delivery_refs) when is_list(delivery_refs) do
    recorded = from(event in Event, where: event.delivery_ref in ^delivery_refs)
    retryable = where(recorded, ^retryable(Repo.now!()))

    MapSet.difference(
      MapSet.new(Repo.all(select(recorded, [event], event.delivery_ref))),
      MapSet.new(Repo.all(select(retryable, [event], event.delivery_ref)))
    )
  end

  @doc """
  What GitHub's deliveries for a repository say, as its page shows them: how
  many wait to be taken, how many failed, how many duplicate copies were
  ignored, and when the last one arrived. One query; it took five, for
  fields no page showed (2026-10-04 review).
  """
  @spec repository_health(String.t()) :: %{
          duplicate_count: non_neg_integer(),
          failed: non_neg_integer(),
          last_event_at: DateTime.t() | nil,
          pending: non_neg_integer()
        }
  def repository_health(repository_ref) when is_binary(repository_ref) do
    Repo.one!(
      from(event in Event,
        join: binding in GitHubBinding,
        on: binding.name == event.binding_ref,
        where: binding.repository_ref == ^repository_ref,
        select: %{
          duplicate_count: coalesce(sum(event.duplicate_count), 0),
          failed: filter(count(event.id), event.disposition == "failed"),
          last_event_at: max(event.occurred_at),
          pending: filter(count(event.id), event.disposition == "received")
        }
      )
    )
  end

  # Only one of two racing copies wins the update, so a retried delivery is
  # processed once. Its earlier failure is cleared; the copy is not counted as an
  # ignored duplicate, because it is not ignored.
  defp retry_or_duplicate(binding_ref, delivery_ref, digest, now) do
    query =
      from(event in Event,
        where:
          event.binding_ref == ^binding_ref and event.delivery_ref == ^delivery_ref and
            event.payload_digest == ^digest,
        where: ^retryable(now),
        select: event
      )

    case Repo.update_all(query, set: [disposition: "received", reason: nil, processed_at: nil]) do
      {1, [event]} ->
        broadcast_delivery_updated(binding_ref)
        {:ok, event}

      {0, []} ->
        duplicate(binding_ref, delivery_ref, digest, now)
    end
  end

  defp retryable(now) do
    abandoned_before = DateTime.add(now, -@abandoned_seconds, :second)

    dynamic(
      [event],
      event.disposition == "failed" or
        (event.disposition == "received" and event.inserted_at < ^abandoned_before)
    )
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

        broadcast_delivery_updated(binding_ref)
        {:ok, :duplicate}

      %Event{} ->
        {:error, :github_event_conflict}

      nil ->
        {:error, :github_event_persistence_failed}
    end
  end

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

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to GitHub deliveries: `{:github_delivery_updated,
  binding_ref}` once a delivery for that GitHub binding is recorded,
  repeated or processed, and that change has committed.
  """
  def subscribe_deliveries, do: Ryker.PubSub.subscribe(deliveries_topic())

  def unsubscribe_deliveries, do: Ryker.PubSub.unsubscribe(deliveries_topic())

  defp deliveries_topic, do: "github:deliveries"

  defp broadcast_delivery_updated(binding_ref) do
    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(deliveries_topic(), {:github_delivery_updated, binding_ref})
    end)
  end
end
