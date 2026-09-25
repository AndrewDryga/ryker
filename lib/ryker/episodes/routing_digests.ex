defmodule Ryker.Episodes.RoutingDigests do
  @moduledoc """
  Host-maintained, source-backed summary of what one episode is about.

  A routing decision compares evidence. First and latest input previews are
  not evidence: the message that names the failing resource is usually in the
  middle. The digest keeps the objective, the latest material development,
  bounded searchable text drawn from every retained input, the identifiers
  those inputs actually contained, and its own coverage — so a stale digest
  says what it covers rather than inventing an up-to-date narrative.

  It is derived deterministically in the admitting transaction and rebuilt
  from retained inputs. The one exception is the title: a single line the Work
  turn that named the episode wrote, stored with that turn's id. It is Ryker's
  own name for the work, so routing reads it beside the source text, never as
  evidence for it.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Episodes.{Episode, Event, Origins, RoutingDigest}
  alias Ryker.Ingress.RecallText
  alias Ryker.Repo
  alias Ryker.State.KnowledgeAnchors
  alias Ryker.Work.{CandidateResponse, Final, Turn}

  @objective_bytes 1_024
  @development_bytes 1_024
  @search_bytes 8 * 1_024
  @maximum_anchors 64
  @maximum_conversations 32

  @doc """
  Builds a bounded OR query from the incoming text.

  Real operational messages contain URLs, run identifiers and alert names, so
  every term is quoted: an unquoted `https:` or `firing:1` is not a word, and
  one such message would otherwise fail the whole retrieval.
  """
  # Words that say nothing about which work a message belongs to: English
  # function words, and the conversational filler people type around a
  # question ("please", "see", "keep", "check"). Searching for them matched
  # unrelated work that happened to be phrased the same way.
  @filler ~w(
    about above after again against all also and any are aren't because been before being below
    between both but can can't cannot could couldn't did didn't does doesn't doing don't down
    during each few for from further had hadn't has hasn't have haven't having her here hers
    herself him himself his how into isn't it's its itself just let more most myself nor not now
    off once only other our ours ourselves out over own same she should shouldn't some such than
    that the their theirs them themselves then there these they this those through too under
    until very was wasn't were weren't what when where which while who whom why will with won't
    would wouldn't you your yours yourself yourselves
    please thanks thank hey hello okay yes yeah see look looks looking keep kept need needs want
    wants help check checking get got getting make made say said tell told know think like still
    keeps keeping since ago via per etc
    today yesterday tomorrow maybe one two new use using used thing things something anything
    everything way lot bit really actually quick quickly short explain question questions answer
    ryker don doesn didn isn wasn weren aren haven hasn hadn couldn wouldn shouldn won
  ) |> MapSet.new()

  @spec search_terms(String.t() | nil) :: String.t()
  def search_terms(text), do: text |> search_words() |> Enum.map_join(" | ", &"'#{&1}'")

  @doc """
  The words that query is made of, in the order the message used them: what
  a person reads when asking which words the search looked for.
  """
  @spec search_words(String.t() | nil) :: [String.t()]
  def search_words(text) do
    # Links are matched whole by the identifier search; as words they were
    # cut at 80 characters into fragments such as "bes/" that match nothing.
    text = (text || "") |> String.slice(0, 4_000) |> String.replace(~r{https?://\S+}u, " ")

    ~r/[\p{L}\p{N}][\p{L}\p{N}_.:\/-]{2,79}/u
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.map(&String.trim(&1, ":"))
    |> Enum.map(&String.replace(&1, ~r/['\\]/, ""))
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(@filler, &1))
    |> Enum.take(24)
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

  @doc "Each episode's current title, for the episodes that have one."
  @spec titles([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => String.t()}
  def titles([]), do: %{}

  def titles(episode_ids) do
    Repo.all(
      from(digest in RoutingDigest,
        where: digest.episode_id in ^episode_ids and not is_nil(digest.title),
        select: {digest.episode_id, digest.title}
      )
    )
    |> Map.new()
  end

  @doc """
  Adopts the title an accepted Work answer set, inside the transaction that
  accepts it.

  The accepted candidate's exact bytes are the source: a title of null keeps
  the current one, and an answer recorded before titles existed has none.
  """
  @spec accept_title_in_transaction(Episode.t(), Turn.t()) :: :ok
  def accept_title_in_transaction(%Episode{id: episode_id}, %Turn{} = turn) do
    case accepted_title(turn) do
      nil ->
        :ok

      title ->
        now = Repo.now!()

        Repo.update_all(
          from(digest in RoutingDigest,
            where: digest.episode_id == ^episode_id,
            where: is_nil(digest.title) or digest.title != ^title
          ),
          set: [title: title, title_turn_id: turn.id, title_updated_at: now, updated_at: now]
        )

        :ok
    end
  end

  defp accepted_title(%Turn{id: turn_id, candidate_attempt: attempt}) when is_integer(attempt) do
    with %CandidateResponse{body: body} when is_binary(body) <-
           Repo.get_by(CandidateResponse, turn_id: turn_id, candidate_attempt: attempt),
         {:ok, %{} = document} <- Jason.decode(body),
         {:ok, %Final{title: title}} <- Final.parse(document) do
      title
    else
      _unreadable -> nil
    end
  end

  defp accepted_title(_turn), do: nil

  @doc "Indexed keys for source-backed identity clues; never an authority or uniqueness claim."
  @spec anchor_keys([String.t()]) :: [String.t()]
  def anchor_keys(anchors) do
    anchors
    |> Enum.map(&KnowledgeAnchors.normalize/1)
    |> Enum.map(&CanonicalJSON.digest(%{"anchor" => &1}))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  What routing reads about one episode beyond its messages: the name Ryker gave
  it and how many messages and conversations it spans. The first and latest
  messages travel as the candidate's own messages, not again as digest text.
  """
  @spec document(RoutingDigest.t() | nil) :: map() | nil
  def document(nil), do: nil

  def document(%RoutingDigest{} = digest) do
    %{
      "conversations" => length(digest.conversation_refs),
      "message_count" => digest.input_count,
      "title" => digest.title
    }
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
