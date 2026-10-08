defmodule Ryker.ControlPlane.SubscriptionProjection do
  @moduledoc """
  The follow-up directory: every event subscription the host is holding,
  named by the request it belongs to, with its matcher, cursor and last
  observation reduced to digests so no external payload crosses the page
  boundary.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{Activity, FollowUp, Search, SubscriptionPresentation}
  alias Ryker.InspectionRedactor
  alias Ryker.Repo

  @list_limit 100

  @doc """
  Every follow-up the host holds: the current view (still waiting, soonest
  first) or the past one (most recently ended first), read one row past
  #{@list_limit} so the page can say when there are more than it shows.
  Search reads the words the page shows over those rows, or finds one exact
  reference anywhere in the view.
  """
  def list(params) when is_map(params) do
    query =
      (@list_limit + 1)
      |> FollowUp.Query.follow_ups()
      |> subscription_view(params["view"])

    search = Search.term(params["q"])
    items = subscription_rows(query, search)
    episodes = Activity.request_titles(Enum.map(items, & &1.episode_ref))
    secrets = InspectionRedactor.configured_secrets()

    items
    |> Enum.map(fn item ->
      item
      |> still_waiting()
      |> SubscriptionPresentation.project(episodes[item.episode_ref], secrets)
      |> sanitize_subscription()
    end)
    |> subscription_search(search)
  end

  def list(_params), do: list(%{})

  defp subscription_rows(query, nil), do: Repo.all(query)

  defp subscription_rows(query, search) do
    exact = query |> FollowUp.Query.by_ref(search) |> Repo.all()
    if exact == [], do: Repo.all(query), else: exact
  end

  defp subscription_view(query, "current"), do: FollowUp.Query.waiting(query)
  defp subscription_view(query, "past"), do: FollowUp.Query.ended(query)
  defp subscription_view(query, _all), do: query

  # A watch whose subscription a timer took still waits.
  defp still_waiting(%{released: true} = item), do: %{item | status: :active, released: false}
  defp still_waiting(item), do: item

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
        :place,
        :repository
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
