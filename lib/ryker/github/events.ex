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
  alias Ecto.Changeset
  alias Ryker.{CanonicalJSON, Repo, UTCDateTime}
  alias Ryker.GitHub.{Binding, DeliveryCursor, Event}

  @dispositions ~w(metadata routed continued duplicate failed)
  @abandoned_seconds 10 * 60

  def record(%Binding{} = binding, delivery_ref, event_ref, event_name, payload) do
    now = Repo.now!()

    attributes = %{
      id: Repo.generate_id(),
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
  Where `Ryker.GitHub.DeliveryPoller` stopped reading App `app_id`'s
  deliveries, nil before its first read.
  """
  @spec delivery_cursor(pos_integer()) :: non_neg_integer() | nil
  def delivery_cursor(app_id) do
    app_id
    |> DeliveryCursor.Query.by_app_id()
    |> DeliveryCursor.Query.select_through_delivery_id()
    |> Repo.one()
  end

  @doc "Keeps where `Ryker.GitHub.DeliveryPoller` stopped reading App `app_id`'s deliveries."
  @spec keep_delivery_cursor(pos_integer(), non_neg_integer()) :: :ok | {:error, term()}
  def keep_delivery_cursor(app_id, through) do
    %{app_id: app_id, through_delivery_id: through, updated_at: Repo.now!()}
    |> DeliveryCursor.Changeset.put()
    |> Repo.insert(
      on_conflict: {:replace, [:through_delivery_id, :updated_at]},
      conflict_target: :app_id
    )
    |> case do
      {:ok, _cursor} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The deliveries among `delivery_refs` that were taken and will not be taken
  again: recorded, and neither failed nor abandoned.
  """
  @spec settled([String.t()]) :: MapSet.t(String.t())
  def settled([]), do: MapSet.new()

  def settled(delivery_refs) when is_list(delivery_refs) do
    recorded = Event.Query.by_delivery_refs(delivery_refs)
    retryable = Event.Query.retryable(recorded, abandoned_before(Repo.now!()))

    MapSet.difference(
      MapSet.new(Repo.all(Event.Query.select_delivery_refs(recorded))),
      MapSet.new(Repo.all(Event.Query.select_delivery_refs(retryable)))
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
  def repository_health(repository_ref) when is_binary(repository_ref),
    do: Repo.one!(Event.Query.repository_health(repository_ref))

  # Only one of two racing copies wins the update, so a retried delivery is
  # processed once. Its earlier failure is cleared; the copy is not counted as an
  # ignored duplicate, because it is not ignored.
  defp retry_or_duplicate(binding_ref, delivery_ref, digest, now) do
    query =
      binding_ref
      |> Event.Query.by_delivery(delivery_ref)
      |> Event.Query.by_payload_digest(digest)
      |> Event.Query.retryable(abandoned_before(now))
      |> Event.Query.select_rows()

    case Repo.update_all(query, set: [disposition: "received", reason: nil, processed_at: nil]) do
      {1, [event]} ->
        broadcast_delivery_updated(binding_ref)
        {:ok, event}

      {0, []} ->
        duplicate(binding_ref, delivery_ref, digest, now)
    end
  end

  # A received delivery not processed within this long was abandoned.
  defp abandoned_before(now), do: DateTime.add(now, -@abandoned_seconds, :second)

  defp duplicate(binding_ref, delivery_ref, digest, now) do
    case Repo.one(Event.Query.by_delivery(binding_ref, delivery_ref)) do
      %Event{payload_digest: ^digest} = event ->
        {_count, _rows} =
          event.id
          |> Event.Query.by_id()
          |> Repo.update_all(inc: [duplicate_count: 1], set: [last_duplicate_at: now])

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
        case UTCDateTime.parse(value) do
          {:ok, time} -> UTCDateTime.to_usec(time)
          _invalid -> nil
        end

      _value ->
        nil
    end)
  end

  defp bounded(nil), do: nil
  defp bounded(reason), do: reason |> to_string() |> String.slice(0, 256)

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
