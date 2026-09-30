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
  alias Ryker.Knowledge.KnowledgeAnchors
  alias Ryker.Repo
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
    |> Enum.map(&String.trim_trailing(&1, "."))
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

    # New text makes the request's vector stale; the embeddings worker
    # computes it again (`Ryker.Embeddings.Worker`).
    updates =
      attributes
      |> Map.drop([:episode_id])
      |> Map.merge(%{updated_at: now, embedding: nil, embedding_model: nil, embedded_at: nil})
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

  @doc """
  Rebuilds every digest from its retained inputs, one transaction each, and
  returns how many it rebuilt. A digest is otherwise rebuilt only when a new
  message arrives, so a new kind of identifier (2026-09-30: hosts, runs,
  versions, alert rules) reaches existing work only after this runs once.
  Titles stay; vectors are cleared for the embeddings worker to compute again.
  """
  @spec refresh_all() :: non_neg_integer()
  def refresh_all do
    Repo.all(from(digest in RoutingDigest, select: digest.episode_id))
    |> Enum.count(fn episode_id ->
      match?({:ok, :ok}, Repo.transaction(fn -> refresh(episode_id) end))
    end)
  end

  defp refresh(episode_id) do
    with %Episode{} = episode <- Repo.get(Episode, episode_id),
         %Event{} = latest <-
           Repo.one(
             from(event in Event,
               where: event.episode_id == ^episode_id and event.kind == :input_admitted,
               order_by: [desc: event.sequence],
               limit: 1
             )
           ),
         :ok <- refresh_in_transaction(episode, latest) do
      :ok
    else
      _nothing -> Repo.rollback(:not_refreshed)
    end
  end

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
  def accept_title_in_transaction(%Episode{id: episode_id} = episode, %Turn{} = turn) do
    case accepted_title(turn) do
      nil ->
        :ok

      title ->
        now = Repo.now!()
        Ryker.Episodes.broadcast_episode_updated(episode)

        Repo.update_all(
          from(digest in RoutingDigest,
            where: digest.episode_id == ^episode_id,
            where: is_nil(digest.title) or digest.title != ^title
          ),
          set: [
            title: title,
            title_turn_id: turn.id,
            title_updated_at: now,
            updated_at: now,
            embedding: nil,
            embedding_model: nil,
            embedded_at: nil
          ]
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

  @embedding_characters 2_000

  @doc """
  What a request's vector is computed from: Ryker's title for it, its opening
  and latest messages, then the rest of its messages, as far as they fit.
  """
  @spec embedding_text(RoutingDigest.t()) :: String.t()
  def embedding_text(%RoutingDigest{} = digest) do
    [digest.title, digest.objective, digest.latest_development, digest.search_text]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.join("\n")
    |> String.slice(0, @embedding_characters)
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
    |> Enum.flat_map(&(&1 |> input_content() |> input_identifiers()))
    |> Enum.uniq()
    |> anchor_keys()
    |> Enum.take(@maximum_anchors)
  end

  @doc """
  What one input names, as routing searches with it and remembers it: the identifiers in its
  words, and the links and alert labels it carries outside them (`RecallText.references/1`).
  """
  @spec input_identifiers(term()) :: [String.t()]
  def input_identifiers(nil), do: []

  def input_identifiers(content) do
    %{links: links, labels: labels} = RecallText.references(content)

    [RecallText.from(content), Enum.join(links, " ")]
    |> identifiers()
    |> Kernel.++(labels)
    |> Enum.uniq()
    |> Enum.take(64)
  end

  @doc """
  The links and identifiers in `texts` that each name one thing: URLs and
  UUIDs (`Ryker.Knowledge.KnowledgeAnchors.discover/1`), and the names
  operations gives things. Hosts and services numbered like pgsql-prod-01
  or ci-runner-3, run IDs like run-7f2a1c, versions like v2.14.0, alert
  rules like CheckoutLatencyHigh, pull requests and issues like #482,
  commit hashes, and domains like api.example.com.

  Andrew, 2026-09-30: routing's search is "rudimentary and won't actually
  work in real life". It matched only URLs and UUIDs as identifiers, so a
  message naming the failing host or run found its work by wording alone,
  behind unrelated work that happened to be running (the routing search
  benchmark ranked a shared run ID fifth).
  """
  @spec identifiers([String.t()]) :: [String.t()]
  def identifiers(texts) do
    texts = texts |> Enum.filter(&is_binary/1) |> Enum.take(16)

    (Enum.flat_map(KnowledgeAnchors.discover(texts), &link_forms/1) ++
       Enum.flat_map(texts, &names/1))
    |> Enum.uniq()
    |> Enum.take(64)
  end

  # Query parameters that only say when or how often a page was looked at.
  @viewing_parameters ~w(from to time refresh _g)

  # One thing is one identifier however it was linked (ID5, 2026-09-30): a pull request's files
  # or commits tab is the pull request, whose link also names it as #482, and a dashboard opened
  # over another time range is the same dashboard.
  defp link_forms("https://github.com/" <> _rest = link) do
    case Regex.run(
           ~r{\Ahttps://github\.com/([^/?#]+/[^/?#]+)/(pull|issues)/(\d+)(?=[/?#]|\z)},
           link
         ) do
      [_, repository, kind, number] ->
        ["https://github.com/#{String.downcase(repository)}/#{kind}/#{number}", "##{number}"]

      nil ->
        [link]
    end
  end

  defp link_forms(link) do
    uri = URI.parse(link)

    with query when is_binary(query) <- uri.query,
         {:ok, parameters} <- decoded(query) do
      kept = Enum.reject(parameters, fn {name, _value} -> name in @viewing_parameters end)
      query = if kept == [], do: nil, else: URI.encode_query(kept)
      [URI.to_string(%{uri | query: query})]
    else
      _plain -> [link]
    end
  end

  defp decoded(query) do
    {:ok, URI.query_decoder(query) |> Enum.to_list()}
  rescue
    ArgumentError -> :error
  end

  # Words so common in operations text that they name nothing on their own.
  @generic_names ~w(utf-8 utf-16 x86_64 x86-64 ipv4 ipv6 base64 sha256 sha-256 http/1.1 http/2
    tls1.2 tls1.3 github.com gitlab.com google.com slack.com grafana.com amazonaws.com
    cloudflare.com localhost.localdomain)

  # Names sit near the top of what people and alerts write; scanning a pasted
  # log's full 64 KB for them cost seven times what links and UUIDs cost, on
  # every message a request receives.
  @names_characters 8_192

  defp names(text) do
    # Links and UUIDs are found whole above; read again here, a UUID's first block was also a
    # commit hash, so one UUID counted twice or three times (ID2, 2026-09-30).
    text =
      text
      |> String.slice(0, @names_characters)
      |> String.replace(~r{https?://\S+}u, " ")
      |> String.replace(~r/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/iu, " ")

    numbered =
      ~r/(?<![\p{L}\p{N}_.\/#-])[a-z][a-z0-9]*(?:[-_.][a-z0-9]+)+(?![\p{L}\p{N}_\/-])/iu
      |> Regex.scan(text)
      |> List.flatten()
      |> Enum.filter(&(String.length(&1) >= 5 and Regex.match?(~r/\d/, &1)))

    rules =
      ~r/(?<![\p{L}\p{N}])[A-Z][a-z]+(?:[A-Z][a-z0-9]+){2,}(?![\p{L}\p{N}])/u
      |> Regex.scan(text)
      |> List.flatten()

    references =
      ~r/(?<![\p{L}\p{N}&#])#\d{2,7}(?!\d)/u
      |> Regex.scan(text)
      |> List.flatten()

    # In either case: "!tft_update 37357FE72DED74EE prod" never matched (ID3, 2026-09-30).
    hashes =
      ~r/(?<![\p{L}\p{N}])[0-9a-f]{7,40}(?![\p{L}\p{N}])/iu
      |> Regex.scan(text)
      |> List.flatten()
      |> Enum.filter(&(Regex.match?(~r/\d/, &1) and Regex.match?(~r/[a-f]/i, &1)))

    domains =
      ~r/(?<![\p{L}\p{N}@.-])(?:[a-z0-9-]+\.)+(?:com|net|org|io|dev|app|co|cloud|ai|ua|es|de|uk|eu)(?![\p{L}\p{N}-])/iu
      |> Regex.scan(text)
      |> List.flatten()

    (numbered ++ rules ++ references ++ hashes ++ domains ++ unnumbered(text))
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 in @generic_names))
  end

  # Names read once shared identifiers count by how rare they are (ID1), so they no longer need a
  # digit, a "v" or three parts (ID8, 2026-09-30): an incident or ticket number, a bare version,
  # an alert named for what went wrong, a service named for what it is.
  @unnumbered [
    ~r/(?<![\p{L}\p{N}._\/#-])[1-9]\d{6,18}(?![\p{L}\p{N}._\/-])/u,
    ~r/(?<![\p{L}\p{N}.])\d+\.\d+\.\d+(?:-[0-9a-z]+(?:\.[0-9a-z]+)*)?(?![\p{L}\p{N}.])/iu,
    ~r/(?<![\p{L}\p{N}])(?:(?:High|Low)[A-Z][A-Za-z0-9]*|[A-Z][a-z]+(?:Down|Up|Full|Errors?|Failed|Failing|Missing|Latency|Stuck|Unavailable|Unreachable))(?![\p{L}\p{N}])/u,
    ~r/(?<![\p{L}\p{N}_.\/#-])[a-z][a-z0-9]*(?:-[a-z0-9]+)*-(?:api|service|svc|worker|web|db|proxy|gateway|server|app|job|cron|queue|cache|edge|frontend|backend|prod|production|staging|dev)(?![\p{L}\p{N}_\/-])/iu
  ]

  defp unnumbered(text),
    do: Enum.flat_map(@unnumbered, &(&1 |> Regex.scan(text) |> List.flatten()))

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

  defp input_text(event) do
    case input_content(event) do
      nil -> ""
      content -> RecallText.from(content)
    end
  end

  defp input_content(%Event{payload: %{"payload" => payload}}) when is_map(payload),
    do: Map.get(payload, "content", payload)

  defp input_content(%Event{payload: payload}) when is_map(payload), do: payload
  defp input_content(_event), do: nil

  defp bounded(nil, _limit), do: nil

  defp bounded(text, limit) do
    if byte_size(text) <= limit, do: text, else: String.byte_slice(text, 0, limit)
  end
end
