defmodule Ryker.Records.TaskProgress do
  @moduledoc "Progress of the one engineering task started by an exact admitted input."
  alias Ryker.Episodes
  alias Ryker.Publication
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Work

  def read(%Record{status: :confirmed, confirmed_episode_id: id}), do: build(id)

  def read(%{episode_id: nil} = entry), do: input(entry, "preparing")

  def read(entry) do
    case Repo.fetch(Record.Query.for_source_entry(entry)) do
      {:ok, record} -> read(record)
      {:error, :not_found} -> input(entry, "preparing")
    end
  end

  def input(%{status: :blocked}, _active), do: %{"status" => "needs_attention"}

  def input(%{status: :decided, episode_id: nil}, _active),
    do: %{"status" => "not_started", "terminal" => true}

  def input(%{episode_id: nil}, _active), do: %{"status" => "queued"}
  def input(entry, active), do: episode(entry.episode_id, active)

  defp build(episode_id) do
    publications =
      episode_id
      |> Publication.Publication.Query.by_episode_id()
      |> Publication.Publication.Query.ordered_by_recent()
      |> Publication.Publication.Query.limit_to(2)
      |> Repo.all()

    case publications do
      [%{status: status, pull_request_url: url} = publication | _rest]
      when status in [:published_ready, :published] and is_binary(url) ->
        published(publication)

      [%{status: :discarded} | _rest] ->
        episode(episode_id, "building")

      [%{status: :blocked} | _rest] ->
        %{"status" => "needs_attention"}

      [_publication | _rest] ->
        %{"status" => "checking"}

      [] ->
        episode(episode_id, "building")
    end
  end

  defp published(publication) do
    result = %{
      "status" => "pull_request_ready",
      "url" => publication.pull_request_url,
      "commit" => publication.commit_sha,
      "terminal" => true
    }

    case publication.publication_receipt["target_observation"] do
      %{} = observation ->
        result
        |> Map.put("status", "publication_needs_attention")
        |> Map.put("target_observation", observation)

      nil ->
        result
    end
  end

  defp working(%{owner_kind: :turn} = episode, active) do
    query =
      Work.Turn.Query.by_episode_id(episode.id) |> Work.Turn.Query.by_turn_ref(episode.owner_ref)

    case Repo.fetch(query) do
      {:ok, %{status: :blocked, cancellation_intent: %{"action" => "block"}}} ->
        %{"status" => "stopped"}

      {:ok, %{status: :blocked}} ->
        %{"status" => "needs_attention"}

      _running ->
        %{"status" => active}
    end
  end

  defp working(_episode, active), do: %{"status" => active}

  defp episode(id, active) do
    case Repo.fetch(Episodes.Episode.Query.by_id(id)) do
      {:ok, %{state: :cancelled}} -> %{"status" => "cancelled", "terminal" => true}
      {:ok, %{state: :complete}} -> %{"status" => "finished_without_result", "terminal" => true}
      {:ok, %{state: :waiting_for_input}} -> %{"status" => "needs_input"}
      {:ok, episode} -> working(episode, active)
      {:error, :not_found} -> %{"status" => "history_unavailable", "terminal" => true}
    end
  end
end
