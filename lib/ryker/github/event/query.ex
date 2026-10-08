defmodule Ryker.GitHub.Event.Query do
  @moduledoc "GitHub's webhook deliveries, for every read of `github_repository_events`."
  use Ryker, :query
  alias Ryker.GitHub.Event
  alias Ryker.Settings

  def all, do: from(events in Event, as: :github_repository_events)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [github_repository_events: e], e.id == ^id)

  def by_delivery_refs(queryable \\ all(), delivery_refs),
    do: where(queryable, [github_repository_events: e], e.delivery_ref in ^delivery_refs)

  def by_delivery(queryable \\ all(), binding_ref, delivery_ref) do
    where(
      queryable,
      [github_repository_events: e],
      e.binding_ref == ^binding_ref and e.delivery_ref == ^delivery_ref
    )
  end

  def by_payload_digest(queryable, digest),
    do: where(queryable, [github_repository_events: e], e.payload_digest == ^digest)

  @doc """
  Deliveries GitHub may send again and Ryker take: failed, or received and
  not processed since before `abandoned_before`.
  """
  def retryable(queryable, abandoned_before) do
    where(
      queryable,
      [github_repository_events: e],
      e.disposition == "failed" or
        (e.disposition == "received" and e.inserted_at < ^abandoned_before)
    )
  end

  @doc """
  What a repository's deliveries say, as its page shows them: how many wait
  to be taken, how many failed, how many duplicate copies were ignored, and
  when the last one arrived.
  """
  def repository_health(repository_ref) do
    all()
    |> join(:inner, [github_repository_events: e], b in Settings.GitHubBinding,
      on: b.name == e.binding_ref,
      as: :github_binding_settings
    )
    |> where([github_binding_settings: b], b.repository_ref == ^repository_ref)
    |> select([github_repository_events: e], %{
      duplicate_count: coalesce(sum(e.duplicate_count), 0),
      failed: filter(count(e.id), e.disposition == "failed"),
      last_event_at: max(e.occurred_at),
      pending: filter(count(e.id), e.disposition == "received")
    })
  end

  def select_delivery_refs(queryable),
    do: select(queryable, [github_repository_events: e], e.delivery_ref)

  def select_rows(queryable), do: select(queryable, [github_repository_events: e], e)

  def inserted_since(queryable \\ all(), since),
    do: where(queryable, [github_repository_events: e], e.inserted_at >= ^since)

  @doc "How many events each disposition holds, as `{disposition, count}`."
  def count_by_disposition(queryable) do
    queryable
    |> group_by([github_repository_events: e], e.disposition)
    |> select([github_repository_events: e], {e.disposition, count(e.id)})
  end
end
