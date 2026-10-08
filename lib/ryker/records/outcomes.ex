defmodule Ryker.Records.Outcomes do
  @moduledoc """
  Rebuilds bounded, destination-scoped continuity from durable episode state.

  Outcomes are a model-facing projection, never a second lifecycle authority.
  Completed episodes remain recallable while a remotely settled blocked owner
  is labelled unverified. Cancelled or reopened work disappears automatically
  because its current kernel state no longer qualifies.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Records.DerivedContext
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Work

  @maximum_candidates 24
  @maximum_outcomes 6
  @maximum_records 12
  @trigger_bytes 2 * 1_024
  @result_bytes 4 * 1_024
  @record_bytes 2 * 1_024

  @spec recall(Episodes.Episode.t(), String.t() | nil) :: [map()]
  def recall(current, repository \\ nil)

  def recall(%Episodes.Episode{} = current, repository) do
    current
    |> candidate_episodes()
    |> Enum.flat_map(&build_outcome/1)
    |> Enum.map(&DerivedContext.outcome/1)
    |> DerivedContext.filter(current, repository)
    |> Enum.map(& &1["document"])
    |> Enum.sort_by(&sort_key(&1, current), :desc)
    |> Enum.take(@maximum_outcomes)
  end

  def recall(_episode, _repository), do: []

  defp candidate_episodes(current) do
    current |> Episodes.Episode.Query.recent_neighbors(@maximum_candidates) |> Repo.all()
  end

  defp build_outcome(%Episodes.Episode{state: :complete} = episode) do
    case latest_settled_turn(episode.id) do
      %Work.Turn{} = turn -> [document(episode, turn, "complete")]
      nil -> []
    end
  end

  defp build_outcome(%Episodes.Episode{state: :working, owner_kind: :turn} = episode) do
    case blocked_owner_turn(episode.id, episode.owner_ref) do
      %Work.Turn{} = turn -> [document(episode, turn, "blocked")]
      nil -> []
    end
  end

  defp build_outcome(_episode), do: []

  defp latest_settled_turn(episode_id),
    do: episode_id |> Work.Turn.Query.latest_settled_with_result() |> Repo.one()

  defp blocked_owner_turn(episode_id, owner_ref),
    do: episode_id |> Work.Turn.Query.blocked_owner(owner_ref) |> Repo.one()

  defp document(episode, turn, state) do
    records = episode.id |> outcome_records() |> Enum.map(&record_document/1)
    event = trigger_event(episode.id)
    projection(turn, event, records, state)
  end

  @doc false
  def projection(turn, event, records, state) do
    %{
      "blocker" =>
        if(state == "blocked", do: get_in(turn.cancellation_intent || %{}, ["reason"])),
      "episode_ref" => turn.episode_id,
      "finished_at" => finished_at(turn),
      "records" => records,
      "result" => CanonicalJSON.bounded(turn.delivery_document, @result_bytes),
      "state" => state,
      "source_turn_ref" => turn.id,
      "source_event_ref" => if(event, do: event.id),
      "trigger" => if(event, do: CanonicalJSON.bounded(event.payload["payload"], @trigger_bytes)),
      "verified" => state == "complete" and explicitly_verified?(records)
    }
  end

  defp outcome_records(episode_id) do
    episode_id
    |> Record.Query.outcome_records(@maximum_records)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp trigger_event(episode_id) do
    episode_id
    |> Episodes.Event.Query.by_episode_id()
    |> Episodes.Event.Query.by_kind(:input_admitted)
    |> Episodes.Event.Query.ordered_by_sequence()
    |> Episodes.Event.Query.limit_to(1)
    |> Repo.one()
  end

  defp record_document(record) do
    %{
      "kind" => record.kind,
      "payload" => CanonicalJSON.bounded(record.payload, @record_bytes),
      "ref" => record.ref
    }
  end

  defp explicitly_verified?(records) do
    Enum.any?(records, fn
      %{
        "kind" => "alert_assessment",
        "payload" => %{"verdict" => verdict, "verification" => verification}
      }
      when verdict in ["confirmed_issue", "likely_issue"] and is_binary(verification) ->
        String.trim(verification) != ""

      _record ->
        false
    end)
  end

  defp finished_at(turn) do
    (turn.delivered_at || turn.accepted_at || turn.cancelled_at || turn.inserted_at)
    |> DateTime.to_iso8601()
  end

  defp sort_key(outcome, current) do
    linked = if outcome["episode_ref"] == current.linked_episode_id, do: 1, else: 0
    finished = outcome["finished_at"] || ""
    {linked, finished, outcome["episode_ref"]}
  end
end
