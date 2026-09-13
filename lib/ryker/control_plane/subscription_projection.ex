defmodule Ryker.ControlPlane.SubscriptionProjection do
  @moduledoc """
  The event-subscription directory: every wait the host is holding, named by
  the episode it belongs to, with its matcher, cursor and last observation
  reduced to digests so no external payload crosses the page boundary.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{Activity, InspectionRedactor, Search, SubscriptionPresentation}
  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.State.{EventSubscription, Record}

  @list_limit 100
  @statuses ~w(active resolved timed_out cancelled)a

  def list(params) when is_map(params) do
    query =
      from(subscription in EventSubscription,
        left_join: episode in Episode,
        on: episode.id == subscription.episode_id,
        join: record in Record,
        on: record.id == subscription.record_id,
        order_by: [asc: subscription.status, desc: subscription.updated_at, desc: subscription.id],
        limit: @list_limit,
        select: %{
          cursor: subscription.cursor,
          deadline_at: subscription.deadline_at,
          episode_ref: episode.key,
          last_observation: subscription.last_observation,
          last_observed_at: subscription.last_observed_at,
          matcher: subscription.matcher,
          poll_after: subscription.poll_after,
          ref: subscription.ref,
          resolution_kind: subscription.resolution_kind,
          revision: subscription.revision,
          source_kind: subscription.source_kind,
          status: subscription.status,
          trigger_type: fragment("?::jsonb -> 'event_matcher' ->> 'type'", record.payload),
          updated_at: subscription.updated_at
        }
      )
      |> subscription_status(Search.one_of(params["status"], @statuses))

    search = Search.term(params["q"])
    items = subscription_rows(query, search)
    episodes = Activity.request_titles(Enum.map(items, & &1.episode_ref))
    secrets = InspectionRedactor.configured_secrets()

    items
    |> Enum.map(fn item ->
      item
      |> SubscriptionPresentation.project(episodes[item.episode_ref], secrets)
      |> sanitize_subscription()
    end)
    |> subscription_search(search)
  end

  def list(_params), do: list(%{})

  defp subscription_rows(query, nil), do: Repo.all(query)

  defp subscription_rows(query, search) do
    case Repo.all(from(subscription in query, where: subscription.ref == ^search)) do
      [] -> Repo.all(query)
      exact -> exact
    end
  end

  defp subscription_status(query, nil), do: query

  defp subscription_status(query, status),
    do: from(subscription in query, where: subscription.status == ^status)

  defp subscription_search(items, nil), do: items

  defp subscription_search(items, search) do
    search = String.downcase(search)

    Enum.filter(items, fn item ->
      item
      |> Map.take([
        :ref,
        :episode_ref,
        :source_label,
        :title,
        :condition,
        :episode_title,
        :context_label
      ])
      |> Map.values()
      |> Enum.join(" ")
      |> String.downcase()
      |> String.contains?(search)
    end)
  end

  defp sanitize_subscription(subscription) do
    subscription
    |> Map.put(:cursor_digest, document_digest(subscription.cursor))
    |> Map.put(:last_observation_digest, document_digest(subscription.last_observation))
    |> Map.put(:matcher_digest, document_digest(subscription.matcher))
    |> Map.drop([:cursor, :last_observation, :matcher])
  end

  defp document_digest(nil), do: nil
  defp document_digest(document), do: CanonicalJSON.digest(document)
end
