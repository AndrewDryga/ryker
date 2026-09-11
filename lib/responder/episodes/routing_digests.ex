defmodule Responder.Episodes.RoutingDigests do
  @moduledoc """
  Host-maintained, source-backed summary of what one episode is about.

  A routing decision compares evidence. First and latest input previews are
  not evidence: the message that names the failing resource is usually in the
  middle. The digest keeps the objective, the latest material development,
  bounded searchable text drawn from every retained input, the identifiers
  those inputs actually contained, and its own coverage — so a stale digest
  says what it covers rather than inventing an up-to-date narrative.

  It is derived deterministically in the admitting transaction. No model
  writes it, and it is rebuilt from retained inputs.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Episodes.{Episode, Event, Origins, RoutingDigest}
  alias Responder.Ingress.RecallText
  alias Responder.Repo
  alias Responder.State.KnowledgeAnchors

  @objective_bytes 1_024
  @development_bytes 1_024
  @search_bytes 8 * 1_024
  @maximum_anchors 64
  @maximum_conversations 32
  @freshness_window 24 * 60 * 60

  @doc """
  Builds a bounded OR query from the incoming text.

  Real operational messages contain URLs, run identifiers and alert names, so
  every term is quoted: an unquoted `https:` or `firing:1` is not a word, and
  one such message would otherwise fail the whole retrieval.
  """
  @spec search_terms(String.t() | nil) :: String.t()
  def search_terms(text) do
    ~r/[\p{L}\p{N}][\p{L}\p{N}_.:\/-]{2,79}/u
    |> Regex.scan(String.slice(text || "", 0, 4_000))
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.map(&String.trim(&1, ":"))
    |> Enum.map(&String.replace(&1, ~r/['\\]/, ""))
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
    |> Enum.reject(
      &(&1 in ~w(the and that this what when where why how you are was were with from for can could would should has have not but its))
    )
    |> Enum.take(24)
    |> Enum.map_join(" | ", &"'#{&1}'")
  end

  @doc false
  @spec refresh_in_transaction(Episode.t(), Event.t()) :: :ok | {:error, term()}
  def refresh_in_transaction(%Episode{} = episode, %Event{kind: :input_admitted} = event) do
    events = admitted_events(episode.id, event)

    attributes = %{
      episode_id: episode.id,
      objective: bounded(objective(events), @objective_bytes),
      latest_development: bounded(latest_development(events), @development_bytes),
      search_text: bounded(search_text(events), @search_bytes),
      anchor_keys: anchor_keys_for(events),
      conversation_refs: conversation_refs(events),
      input_count: length(events),
      covered_through_sequence: events |> List.last() |> Map.fetch!(:sequence),
      covered_through_at: events |> List.last() |> Map.fetch!(:occurred_at),
      latest_revision: latest_revision(events)
    }

    now = DateTime.utc_now()
    row = attributes |> Map.put(:inserted_at, now) |> Map.put(:updated_at, now)

    updates =
      attributes
      |> Map.drop([:episode_id])
      |> Map.put(:updated_at, now)
      |> Map.to_list()

    case Repo.insert_all(RoutingDigest, [row],
           on_conflict: [set: updates],
           conflict_target: [:episode_id]
         ) do
      {1, _} -> :ok
      other -> {:error, {:persistence_failed, :episode_routing_digest, other}}
    end
  end

  def refresh_in_transaction(_episode, _event), do: :ok

  @spec fetch(Ecto.UUID.t()) :: RoutingDigest.t() | nil
  def fetch(episode_id), do: Repo.get_by(RoutingDigest, episode_id: episode_id)

  @spec fetch_many([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => RoutingDigest.t()}
  def fetch_many([]), do: %{}

  def fetch_many(episode_ids) do
    Repo.all(from(digest in RoutingDigest, where: digest.episode_id in ^episode_ids))
    |> Map.new(&{&1.episode_id, &1})
  end

  @doc "Indexed keys for source-backed identity clues; never an authority or uniqueness claim."
  @spec anchor_keys([String.t()]) :: [String.t()]
  def anchor_keys(anchors) do
    anchors
    |> Enum.map(&KnowledgeAnchors.normalize/1)
    |> Enum.map(&CanonicalJSON.digest(%{"anchor" => &1}))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The bounded model-visible digest; it states coverage instead of claiming currency."
  @spec document(RoutingDigest.t() | nil, DateTime.t()) :: map() | nil
  def document(nil, _now), do: nil

  def document(%RoutingDigest{} = digest, %DateTime{} = now) do
    %{
      "objective" => digest.objective,
      "latest_development" => digest.latest_development,
      "input_count" => digest.input_count,
      "conversations" => length(digest.conversation_refs),
      "covered_through" => DateTime.to_iso8601(digest.covered_through_at),
      "freshness" => freshness(digest, now)
    }
  end

  defp freshness(digest, now) do
    if DateTime.diff(now, digest.covered_through_at, :second) <= @freshness_window,
      do: "current",
      else: "stale"
  end

  defp admitted_events(episode_id, %Event{} = event) do
    stored =
      Repo.all(
        from(stored in Event,
          where:
            stored.episode_id == ^episode_id and stored.kind == :input_admitted and
              stored.dedupe_key != ^event.dedupe_key,
          order_by: [asc: stored.sequence]
        )
      )

    Enum.sort_by(stored ++ [event], & &1.sequence)
  end

  defp objective([first | _rest]), do: input_text(first)

  defp latest_development([_only]), do: nil
  defp latest_development(events), do: events |> List.last() |> input_text()

  defp search_text(events) do
    events
    |> Enum.map(&input_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join("\n")
  end

  defp anchor_keys_for(events) do
    events
    |> Enum.map(&input_text/1)
    |> KnowledgeAnchors.discover()
    |> anchor_keys()
    |> Enum.take(@maximum_anchors)
  end

  defp conversation_refs(events) do
    events
    |> Enum.map(&Origins.from_event/1)
    |> Enum.map(& &1.conversation_ref)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@maximum_conversations)
  end

  defp latest_revision(events) do
    events
    |> Enum.map(&(&1.payload["revision"] || 1))
    |> Enum.max()
  end

  defp input_text(%Event{payload: %{"payload" => payload}}) when is_map(payload),
    do: payload |> Map.get("content", payload) |> RecallText.from()

  defp input_text(%Event{payload: payload}) when is_map(payload),
    do: RecallText.from(payload)

  defp input_text(_event), do: ""

  defp bounded(nil, _limit), do: nil

  defp bounded(text, limit) do
    if byte_size(text) <= limit, do: text, else: String.byte_slice(text, 0, limit)
  end
end
