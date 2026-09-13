defmodule Ryker.State.Outcomes do
  @moduledoc """
  Rebuilds bounded, destination-scoped continuity from durable episode state.

  Outcomes are a model-facing projection, never a second lifecycle authority.
  Completed episodes remain recallable while a remotely settled blocked owner
  is labelled unverified. Cancelled or reopened work disappears automatically
  because its current kernel state no longer qualifies.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Repo
  alias Ryker.State.{DerivedContext, Record}
  alias Ryker.Work.Turn

  @maximum_candidates 24
  @maximum_outcomes 6
  @maximum_records 12
  @trigger_bytes 2 * 1_024
  @result_bytes 4 * 1_024
  @record_bytes 2 * 1_024
  @truncation_marker "...<truncated>..."

  @spec recall(Episode.t(), String.t() | nil) :: [map()]
  def recall(current, repository \\ nil)

  def recall(%Episode{} = current, repository) do
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
    Repo.all(
      from(episode in Episode,
        where:
          episode.id != ^current.id and
            episode.destination_transport == ^current.destination_transport and
            episode.destination_conversation_ref == ^current.destination_conversation_ref and
            episode.state in [:complete, :working],
        order_by: [desc: episode.updated_at, desc: episode.id],
        limit: @maximum_candidates
      )
    )
  end

  defp build_outcome(%Episode{state: :complete} = episode) do
    case latest_settled_turn(episode.id) do
      %Turn{} = turn -> [document(episode, turn, "complete")]
      nil -> []
    end
  end

  defp build_outcome(%Episode{state: :working, owner_kind: :turn} = episode) do
    case blocked_owner_turn(episode.id, episode.owner_ref) do
      %Turn{} = turn -> [document(episode, turn, "blocked")]
      nil -> []
    end
  end

  defp build_outcome(_episode), do: []

  defp latest_settled_turn(episode_id) do
    Repo.one(
      from(turn in Turn,
        where:
          turn.episode_id == ^episode_id and turn.status == :settled and
            not is_nil(turn.result_ref),
        order_by: [desc: turn.accepted_at, desc: turn.inserted_at, desc: turn.id],
        limit: 1
      )
    )
  end

  defp blocked_owner_turn(episode_id, owner_ref) do
    Repo.one(
      from(turn in Turn,
        where:
          turn.episode_id == ^episode_id and turn.turn_ref == ^owner_ref and
            turn.status == :blocked,
        limit: 1
      )
    )
  end

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
      "result" => compact_value(turn.delivery_document, @result_bytes),
      "state" => state,
      "source_turn_ref" => turn.id,
      "source_event_ref" => if(event, do: event.id),
      "trigger" => if(event, do: compact_value(event.payload["payload"], @trigger_bytes)),
      "verified" => state == "complete" and explicitly_verified?(records)
    }
  end

  defp outcome_records(episode_id) do
    Repo.all(
      from(record in Record,
        where:
          record.episode_id == ^episode_id and
            record.kind in ["evidence", "coverage", "finding", "progress", "alert_assessment"] and
            record.status in [:open, :confirmed],
        order_by: [desc: record.sequence],
        limit: @maximum_records
      )
    )
    |> Enum.reverse()
  end

  defp trigger_event(episode_id) do
    Repo.one(
      from(event in Event,
        where: event.episode_id == ^episode_id and event.kind == :input_admitted,
        order_by: [asc: event.sequence],
        limit: 1
      )
    )
  end

  defp record_document(record) do
    %{
      "kind" => record.kind,
      "payload" => compact_value(record.payload, @record_bytes),
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

  defp compact_value(nil, _maximum), do: nil

  defp compact_value(value, maximum) do
    encoded = CanonicalJSON.encode!(value)

    if byte_size(encoded) <= maximum do
      value
    else
      %{
        "json_preview" => bounded_preview(encoded, maximum),
        "original_bytes" => byte_size(encoded),
        "sha256" => CanonicalJSON.digest(value),
        "truncated" => true
      }
    end
  end

  defp bounded_preview(encoded, maximum) do
    available = maximum - byte_size(@truncation_marker)
    head_bytes = div(available, 2)
    tail_bytes = available - head_bytes

    String.byte_slice(encoded, 0, head_bytes) <>
      @truncation_marker <> String.byte_slice(encoded, -tail_bytes, tail_bytes)
  end
end
