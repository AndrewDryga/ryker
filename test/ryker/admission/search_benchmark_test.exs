defmodule Ryker.Admission.SearchBenchmarkTest do
  # Andrew, 2026-09-30, of a request's search for earlier work: "I think the
  # way we search is rudimentary and won't actually work in real life". Live
  # had 58 requests, too few to tell. This benchmark asks the search the
  # questions a team asks (testdata/routing_search/benchmark.json): the same
  # host or link, the same words, other words for the same thing, Ukrainian
  # or Spanish about English work, look-alikes that belong elsewhere, and new
  # requests that belong nowhere. It scores where the right work lands among
  # what routing is offered, and how much unrelated work a new request drags
  # in. The floors below are what the search reaches; a change that lowers
  # one fails here. RYKER_SEARCH_BENCHMARK=1 prints the table.
  # Apart from the async suite and with minutes to run: it builds 170 pieces
  # of work and asks 68 questions, and on a small CI runner sharing the
  # database with every async test it once took more than the default minute.
  use Ryker.DataCase, async: false

  @moduletag timeout: 300_000

  import Ecto.Query

  alias Ryker.Admission.{CandidateSearch, CorrelationScope, Ranking}
  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Episode, RoutingDigest, RoutingDigests}
  alias Ryker.Ingress.Input
  alias Ryker.Repo
  alias Ryker.Slack.ChannelMembership
  alias Ryker.Slack.Input, as: SlackInput

  @workspace "TBENCH"
  @now ~U[2026-09-30 12:00:00.000000Z]
  @corpus "testdata/routing_search/benchmark.json"
  @vectors "testdata/routing_search/embeddings.json"
  @offered 20

  setup_all do
    %{corpus: @corpus |> File.read!() |> Jason.decode!()}
  end

  test "the search finds the work a message belongs to, and little else for a new request",
       %{corpus: corpus} do
    Enum.each(corpus["channels"], &joined!/1)
    work = Map.new(corpus["work"] ++ corpus["distractors"], &{&1["id"], work!(&1)})
    ids = Map.new(work, fn {name, episode} -> {episode.id, name} end)
    vectors = vectors!(Map.values(work), corpus["messages"])
    embed_work!(Map.values(work), vectors)

    searched = Enum.map(corpus["messages"], &{&1, search!(&1, vectors)})
    if System.get_env("RYKER_SEARCH_TUNE"), do: tune(searched, ids)

    # The same questions by words and identifiers alone: what routing does
    # while the embedding server is down.
    words_only = Enum.map(corpus["messages"], &{&1, search!(&1, nil)})

    results = results(searched, ids)
    fallback = results(words_only, ids)
    summary = summary(results)
    words = summary(fallback)

    if System.get_env("RYKER_SEARCH_BENCHMARK") do
      report("by words, identifiers and meaning", results, summary)
      report("by words and identifiers alone", fallback, words)
    end

    # Floors: what the search reaches today (2026-09-30). Raise them as it
    # improves; the words-only search before this benchmark reached a mean
    # reciprocal rank of 0.55 and put the right work first in 45%.
    assert summary["identity"].hit1 == 1.0
    assert summary["wording"].hit1 == 1.0
    assert summary["paraphrase"].hit1 == 1.0
    assert summary["language"].hit1 == 1.0
    assert summary["all"].hit8 >= 0.96
    assert summary["all"].mrr >= 0.95
    assert summary["new"].noise <= 0.5

    assert words["identity"].hit1 == 1.0
    assert words["wording"].hit1 == 1.0
    assert words["lookalike"].hit3 == 1.0
    assert words["all"].mrr >= 0.68
    assert words["new"].noise <= 0.5
  end

  defp results(searched, ids) do
    Enum.map(searched, fn {message, result} ->
      offered = Enum.map(result.selected, &Map.fetch!(ids, &1.episode.id))
      fuzzy = for entry <- result.selected, fuzzy_only?(entry), do: ids[entry.episode.id]

      %{
        kind: message["kind"],
        text: message["text"],
        expect: message["expect"],
        rank: rank(offered, message["expect"]),
        top: result.selected |> Enum.take(3) |> Enum.map(&{ids[&1.episode.id], &1.score}),
        noise: if(is_nil(message["expect"]), do: fuzzy, else: [])
      }
    end)
  end

  # Tries weights over a grid on the same pools and prints the best by mean
  # reciprocal rank, then by how little a new request drags in. The pools
  # are searched once; only ranking runs again.
  defp tune(searched, ids) do
    grid =
      for relevance <- [200, 250, 300],
          same_conversation <- [0, 15, 30, 60],
          active <- [0, 15, 30],
          recency <- [0, 30, 60, 100],
          recency_half_life <- [6 * 3600, 24 * 3600, 72 * 3600],
          meaning_unrelated <- [0.45, 0.5],
          meaning_related <- [0.75, 0.85],
          disagreement <- [0.25, 0.5],
          offer_relevance <- [0.2, 0.3] do
        %{
          relevance: relevance,
          same_conversation: same_conversation,
          active: active,
          recency: recency,
          recency_half_life: recency_half_life,
          meaning_unrelated: meaning_unrelated,
          meaning_related: meaning_related,
          disagreement: disagreement,
          offer_relevance: offer_relevance
        }
      end

    ranked =
      grid
      |> Task.async_stream(&{&1, trial(searched, ids, &1)}, ordered: false, timeout: :infinity)
      |> Enum.map(fn {:ok, trial} -> trial end)
      |> Enum.sort_by(fn {_weights, s} -> {-s["all"].mrr, -s["all"].hit1, s["new"].noise} end)

    IO.puts("\nbest of #{length(grid)} weightings")

    for {weights, s} <- Enum.take(ranked, 5) do
      IO.puts(
        "mrr=#{Float.round(s["all"].mrr, 3)} hit@1=#{pct(s["all"].hit1)} " <>
          "noise=#{Float.round(s["new"].noise, 2)} #{inspect(weights)}"
      )
    end
  end

  defp trial(searched, ids, weights) do
    searched
    |> Enum.map(fn {message, result} ->
      request = Map.put(result.request, :weights, weights)
      %{selected: selected} = Ranking.select(result.pool, request)
      offered = Enum.map(selected, &Map.fetch!(ids, &1.episode.id))
      fuzzy = for entry <- selected, fuzzy_only?(entry), do: ids[entry.episode.id]

      %{
        kind: message["kind"],
        expect: message["expect"],
        rank: rank(offered, message["expect"]),
        noise: if(is_nil(message["expect"]), do: fuzzy, else: [])
      }
    end)
    |> summary()
  end

  # Offered only because of how it was worded, with nothing that ties it to
  # the message: no shared link or ID, thread, occurrence or running work.
  defp fuzzy_only?(%{features: features}) do
    not features.occurrence_identity and features.direct_reference == 0 and
      not features.same_thread and not features.active and features.topic_fit > 0
  end

  defp rank(_offered, nil), do: nil

  defp rank(offered, expect) do
    case Enum.find_index(offered, &(&1 == expect)) do
      nil -> :missed
      index -> index + 1
    end
  end

  defp summary(results) do
    groups = Enum.group_by(results, & &1.kind)

    groups
    |> Map.put("all", Enum.reject(results, &(&1.kind == "new")))
    |> Map.new(fn {kind, rows} -> {kind, scores(rows)} end)
  end

  defp scores(rows) do
    expected = Enum.reject(rows, &is_nil(&1.expect))
    ranks = Enum.map(expected, & &1.rank)
    count = max(length(expected), 1)
    hit = fn k -> Enum.count(ranks, &(is_integer(&1) and &1 <= k)) / count end

    %{
      count: length(rows),
      hit1: hit.(1),
      hit3: hit.(3),
      hit8: hit.(8),
      hit20: hit.(@offered),
      mrr: Enum.sum(for r <- ranks, is_integer(r), do: 1 / r) / count,
      noise:
        if(expected == [],
          do: Enum.sum(Enum.map(rows, &length(&1.noise))) / max(length(rows), 1),
          else: 0.0
        )
    }
  end

  defp report(title, results, summary) do
    IO.puts("\nrouting search benchmark, #{title}")

    for kind <- ~w(identity wording paraphrase language lookalike followup all new),
        %{} = s <- [summary[kind]] do
      IO.puts(
        String.pad_trailing(kind, 11) <>
          " n=#{s.count} hit@1=#{pct(s.hit1)} hit@3=#{pct(s.hit3)} hit@8=#{pct(s.hit8)} " <>
          "hit@20=#{pct(s.hit20)} mrr=#{Float.round(s.mrr, 2)} noise=#{Float.round(s.noise, 2)}"
      )
    end

    for row <- results, row.rank not in [1, nil] or row.noise != [] do
      IO.puts(
        "  #{row.kind} #{inspect(row.rank || row.noise)} want #{row.expect} top #{inspect(row.top)}" <>
          " ← #{String.slice(row.text, 0, 60)}"
      )
    end
  end

  defp pct(value), do: "#{round(value * 100)}%"

  # bge-m3's vectors for every text, recorded once from the real model
  # (`scripts/embedding-service.sh`) and kept as 8-bit numbers with a scale.
  # A text that has none yet is recorded when RYKER_EMBEDDINGS_RECORD=1 and
  # RYKER_EMBEDDINGS_URL names the server; otherwise the benchmark says so.
  defp vectors!(episodes, messages) do
    texts =
      Enum.map(episodes, &embedding_text/1) ++ Enum.map(messages, & &1["text"])

    stored =
      case File.read(@vectors) do
        {:ok, body} -> Jason.decode!(body)
        {:error, :enoent} -> %{"model" => Ryker.Embeddings.model(), "vectors" => %{}}
      end

    missing = texts |> Enum.uniq() |> Enum.reject(&Map.has_key?(stored["vectors"], key(&1)))

    stored =
      cond do
        missing == [] ->
          stored

        System.get_env("RYKER_EMBEDDINGS_RECORD") == "1" ->
          record!(stored, missing)

        true ->
          flunk(
            "#{length(missing)} benchmark texts have no recorded vector: run with " <>
              "RYKER_EMBEDDINGS_RECORD=1 RYKER_EMBEDDINGS_URL=http://127.0.0.1:8180"
          )
      end

    Map.new(stored["vectors"], fn {key, encoded} -> {key, decode(encoded)} end)
    |> Map.put(:model, stored["model"])
  end

  defp record!(stored, missing) do
    recorded =
      missing
      |> Enum.chunk_every(16)
      |> Enum.flat_map(fn batch ->
        {:ok, vectors} = Ryker.Embeddings.embed(batch, timeout_ms: 60_000)
        Enum.zip(Enum.map(batch, &key/1), Enum.map(vectors, &encode/1))
      end)

    stored = Map.update!(stored, "vectors", &Map.merge(&1, Map.new(recorded)))
    File.write!(@vectors, Jason.encode_to_iodata!(stored, pretty: true))
    stored
  end

  defp key(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)

  defp encode(vector) do
    scale = vector |> Enum.map(&abs/1) |> Enum.max() |> max(1.0e-9)
    bytes = for value <- vector, into: <<>>, do: <<round(value / scale * 127)::signed-8>>
    %{"scale" => scale, "q" => Base.encode64(bytes)}
  end

  defp decode(%{"scale" => scale, "q" => encoded}) do
    vector = for <<value::signed-8 <- Base.decode64!(encoded)>>, do: value * scale / 127
    norm = vector |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
    Enum.map(vector, &(&1 / norm))
  end

  defp embedding_text(%Episode{id: id}) do
    RoutingDigests.embedding_text(Repo.get_by!(RoutingDigest, episode_id: id))
  end

  # What the embeddings worker does for each digest (`Ryker.Embeddings.Worker`).
  defp embed_work!(episodes, vectors) do
    for episode <- episodes do
      vector = Map.fetch!(vectors, key(embedding_text(episode)))

      Repo.update_all(from(digest in RoutingDigest, where: digest.episode_id == ^episode.id),
        set: [embedding: vector, embedding_model: vectors.model, embedded_at: @now]
      )
    end
  end

  defp search!(message, vectors) do
    destination = %{
      conversation_ref: "slack:#{@workspace}:#{message["channel"]}",
      thread_ref: "1790000000.#{System.unique_integer([:positive])}",
      transport: "slack"
    }

    request = %{
      scope: CorrelationScope.for_destination(destination),
      transport: "slack",
      thread_ref: destination.thread_ref,
      text: message["text"],
      native_input_id: "slack-message:benchmark:#{System.unique_integer([:positive])}",
      execution_mode: :live,
      repository_ref: nil,
      occurrences: [],
      meaning:
        vectors && %{vector: Map.fetch!(vectors, key(message["text"])), model: vectors.model},
      candidate_limit: @offered,
      history_cutoff: DateTime.add(@now, -30 * 24 * 60 * 60, :second),
      now: @now
    }

    request |> CandidateSearch.search() |> Map.put(:request, request)
  end

  # One piece of earlier work: its messages received as Ryker receives them,
  # the title Work gave it, how it stands and when it last moved.
  defp work!(%{"id" => name, "channel" => channel, "messages" => [opening | rest]} = work) do
    at = DateTime.add(@now, -round(work["hours_ago"] * 3600), :second)
    # The same id every run, so equal scores always break the same way.
    <<bytes::binary-size(16), _rest::binary>> = :crypto.hash(:sha256, "benchmark:" <> name)
    id = Ecto.UUID.load!(bytes)
    thread = "#{DateTime.to_unix(at)}.#{System.unique_integer([:positive])}"
    key = "benchmark:#{name}:#{id}"

    for {text, index} <- Enum.with_index([opening | rest]) do
      input = input!(channel, thread, index, text, at)

      {:ok, _transition} =
        Episodes.apply(%Command.AdmitInput{
          actor_ref: Input.actor_ref(input),
          destination: %{input.destination | thread_ref: thread},
          episode_id: id,
          episode_key: key,
          linked_episode_id: nil,
          native_input_id: input.native_input_id,
          occurred_at: at,
          payload: Input.document(input),
          revision: 1,
          turn_ref: "turn:#{id}:#{index}"
        })
    end

    Repo.update_all(from(digest in RoutingDigest, where: digest.episode_id == ^id),
      set: [title: work["title"], title_turn_id: Ecto.UUID.generate(), title_updated_at: at]
    )

    Repo.update_all(from(episode in Episode, where: episode.id == ^id),
      set: [{:updated_at, at} | standing(work["state"])]
    )

    Repo.get!(Episode, id)
  end

  # How the work stands, with the owner the kernel requires for it.
  defp standing("working"), do: []

  defp standing("complete"),
    do: [
      state: :complete,
      owner_kind: nil,
      owner_ref: nil,
      active_input_refs: [],
      queued_input_refs: [],
      queued_input_order_keys: []
    ]

  defp standing("waiting_for_input"),
    do: [
      state: :waiting_for_input,
      owner_kind: :input,
      owner_ref: "input:ask",
      active_input_refs: []
    ]

  defp standing("waiting_for_event"),
    do: [
      state: :waiting_for_event,
      owner_kind: :event,
      owner_ref: "event:wait",
      active_input_refs: []
    ]

  defp input!(channel, thread, index, text, at) do
    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "UBENCH#{index}"},
        channel_ref: channel,
        content: %{"text" => text},
        event_kind: :message,
        event_ref: "Ev-benchmark-#{System.unique_integer([:positive])}",
        message_ref: if(index == 0, do: thread, else: "#{thread}#{index}"),
        occurred_at: at,
        revision: 1,
        thread_ref: if(index == 0, do: nil, else: thread),
        workspace_ref: @workspace
      })

    input
  end

  defp joined!(channel_ref) do
    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: @workspace,
      channel_ref: channel_ref,
      private: false,
      external_shared: false,
      generation: 1,
      status: :joined,
      joined_at: @now
    })
  end
end
