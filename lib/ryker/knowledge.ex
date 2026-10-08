defmodule Ryker.Knowledge do
  @moduledoc """
  Maintained conversation topics with versioned, revocable source dependencies.

  A topic learned, revised, forgotten or pruned is announced after the
  outermost commit (`subscribe_knowledge/0`).
  """
  alias Ryker.AdvisoryLock
  alias Ryker.{CanonicalJSON, ConversationRef, Repo, UTCDateTime}
  alias Ryker.Crypto
  alias Ryker.Ingress
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Knowledge.KnowledgeAnchors
  alias Ryker.Knowledge.KnowledgeRevision
  alias Ryker.Knowledge.KnowledgeSource
  alias Ryker.Knowledge.KnowledgeUpdate
  alias Ryker.Learning
  alias Ryker.Memories

  @stale {:error, {:admission_rejected, :context_stale}}

  @doc """
  Internal — the query for which of topics `ids` the conversation of `scope`
  may still use: valid, learned there whatever repository it was learned
  with, and in a Slack channel also the workspace's public topics it
  inherits. Rebuilds and the console's conversation memory read it.
  """
  def availability_query(scope, ids) do
    # The conversation's topics, whatever repository each was learned with
    # (`scope_key/1`).
    base =
      Learning.LearningSources.retention_seconds()
      |> ConversationKnowledge.Query.valid()
      |> ConversationKnowledge.Query.by_ids(ids)
      |> ConversationKnowledge.Query.by_conversation(scope.transport, scope.conversation_ref)
      |> ConversationKnowledge.Query.select_ids()

    local = Learning.LearningSources.eligible(base, %{scope | visibility: :conversation})

    case slack_channel(scope) do
      {:channel, workspace, channel} ->
        inherited = Learning.LearningSources.eligible(base, %{scope | visibility: :public})
        ConversationKnowledge.Query.available_in_channel(local, inherited, workspace, channel)

      :local ->
        local
    end
  end

  defp slack_channel(%{transport: "slack", conversation_ref: conversation_ref}) do
    case ConversationRef.parse_slack(conversation_ref) do
      {:ok, _workspace, "D" <> _direct} -> :local
      {:ok, workspace, channel} -> {:channel, workspace, channel}
      :error -> :local
    end
  end

  defp slack_channel(_), do: :local

  @doc """
  The learned topics a request in `destination` may be shown for
  `repository_ref`, best matches for `search` first, at most `limit` (1 to
  32) within `search_scope`: each topic's document, or `[]` when the
  conversation's scope cannot be read.
  """
  def context(destination, repository_ref, search \\ "", limit \\ 16, search_scope \\ "workspace") do
    case Repo.transaction(fn ->
           recall_locked(destination, repository_ref, search, limit, search_scope)
         end) do
      {:ok, items} -> items
      _ -> []
    end
  end

  defp recall_locked(destination, repository_ref, search, limit, search_scope) do
    case Learning.Observations.fetch_and_lock_scope(destination, repository_ref) do
      {:ok, scope} ->
        query =
          visible_query(scope)
          |> within_scope(scope, search_scope)
          |> ConversationKnowledge.Query.matching(search)

        items = select_items(query, scope, search, min(max(limit, 1), 32))
        documents(Learning.Observations.authorized_notes(items, scope), scope)

      _ ->
        []
    end
  end

  @doc """
  Internal — one step of `search_memory`'s topic lane for a Work turn:
  `{:ok, document, position}`, `{:skip, position}` for a match the turn may
  not see, or `:done`. `Ryker.Memories.MemorySearch` pages through it.
  """
  def search_page(destination, repository_ref, page) do
    case Learning.Observations.fetch_and_lock_scope(destination, repository_ref) do
      {:ok, scope} -> search_page_locked(scope, page)
      _ -> :done
    end
  end

  defp search_page_locked(scope, page) do
    fields = ConversationKnowledge.Query.search_fields()

    query =
      visible_query(scope)
      |> within_scope(scope, page.scope)
      |> Memories.SearchPage.Query.related_sources(page)
      |> ConversationKnowledge.Query.lock_for_share()

    case Memories.MemorySearchPage.one(query, page, fields.text, fields.changed, fields.source) do
      {:ok, item, position} ->
        case documents(Learning.Observations.authorized_notes([item], scope), scope) do
          [document] -> {:ok, document, position}
          [] -> {:skip, position}
        end

      :done ->
        :done
    end
  end

  @doc """
  Whether the topics `frozen` holds are still exactly what `destination` sees
  now, version for version: what routing and learning were offered must be
  current when they act, or the decision is made again. A Work session keeps
  what it saw while it stays valid instead (`KnowledgeSnapshot.still_valid/3`);
  both were called `reauthorize/3` (2026-10-04 review).
  """
  def still_current(_destination, _repository_ref, []), do: :ok

  def still_current(destination, repository_ref, frozen)
      when is_list(frozen) and length(frozen) <= 32 do
    case Repo.transaction(fn -> current_locked?(destination, repository_ref, frozen) end) do
      {:ok, true} -> :ok
      _ -> @stale
    end
  rescue
    error in Postgrex.Error ->
      if Repo.conflict?(error), do: @stale, else: reraise(error, __STACKTRACE__)
  end

  def still_current(_, _, _), do: @stale

  defp current_locked?(destination, repository_ref, frozen) do
    with {:ok, scope} <- Learning.Observations.fetch_and_lock_scope(destination, repository_ref),
         ids = Enum.map(frozen, &id(&1["source_ref"])),
         true <- Enum.all?(ids, &is_binary/1) do
      # Learning may update a reauthorized target later in this transaction.
      # Take the bounded set in one order; upgrading shared locks can deadlock
      # with another transaction's selected topic.
      items =
        scope
        |> visible_query()
        |> ConversationKnowledge.Query.by_ids(ids)
        |> ConversationKnowledge.Query.ordered_by_id()
        |> ConversationKnowledge.Query.lock_for_update()
        |> Repo.all()

      current = documents(Learning.Observations.authorized_notes(items, scope), scope)
      MapSet.new(current) == MapSet.new(frozen)
    else
      _ -> false
    end
  end

  @doc "Learn from retained raw inputs without changing their earlier observations or decisions."
  def record_sources_in_transaction(entries, proposal, offered, context) do
    with {:ok, scope, source, proposal} <- source_update(entries, proposal, offered, context) do
      apply_update(scope, source, proposal, offered)
    end
  end

  @doc "Check the same source/update contract without creating a topic or a revision."
  def check_sources_in_transaction(entries, proposal, offered, context) do
    with {:ok, scope, source, proposal} <- source_update(entries, proposal, offered, context),
         {:ok, _plan} <- plan_update(scope, source, proposal, offered) do
      :ok
    end
  end

  @doc "Check an operator-pinned rebuild without changing its unavailable topic."
  def check_rebuild_sources_in_transaction(entries, proposal, offered, context) do
    with {:ok, scope, source, proposal} <- rebuild_sources(entries, proposal, offered, context),
         {:ok, _plan} <- plan_rebuild(scope, source, proposal, context.rebuild) do
      :ok
    end
  end

  @doc "Replace only an unavailable topic's current generation from freshly selected raw inputs."
  def rebuild_sources_in_transaction(entries, proposal, offered, context) do
    with {:ok, scope, source, proposal} <- rebuild_sources(entries, proposal, offered, context),
         {:ok, plan} <- plan_rebuild(scope, source, proposal, context.rebuild) do
      save_bounded_update(plan, scope, source)
    end
  end

  defp rebuild_sources(
         entries,
         %{"target_ref" => nil, "expected_version" => 0} = proposal,
         [],
         %{rebuild: _, rebuild_source_entries: selected, source_dependencies: dependencies} =
           context
       )
       when is_list(entries) and length(entries) in 1..16 and is_list(selected) and
              length(selected) in 1..16 do
    with true <- fresh_rebuild_sources?(entries, selected, dependencies),
         {:ok, _, _, _} = result <- source_update(entries, proposal, [], context) do
      result
    else
      {:error, :knowledge_anchor_not_sourced} -> {:error, :knowledge_anchor_not_sourced}
      _ -> {:error, :learning_source_stale}
    end
  end

  defp rebuild_sources(_, _, _, _), do: {:error, :learning_source_stale}

  defp fresh_rebuild_sources?(entries, selected, dependencies) do
    raw =
      selected
      |> Enum.map(&Learning.LearningSources.for_entry/1)
      |> Learning.LearningSources.merge()

    identities = MapSet.new(selected, &{&1.id, &1.revision, &1.event_fingerprint})

    dependencies == raw and Enum.all?(selected, &same_source_scope?(&1, hd(entries))) and
      Enum.all?(entries, &MapSet.member?(identities, {&1.id, &1.revision, &1.event_fingerprint}))
  end

  defp plan_rebuild(scope, source, proposal, %{
         topic_id: id,
         version: version,
         generation: generation
       })
       when is_integer(version) and version > 0 and is_integer(generation) and generation > 0 do
    key = scope_key(scope)
    lock_scope(key)

    with {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, %ConversationKnowledge{} = head_topic} <- fetch_and_lock_topic(id),
         true <-
           is_nil(head_topic.forgotten_at) and head_topic.scope_key == key and
             head_topic.version == version and
             head_topic.source_generation == generation,
         false <- Repo.exists?(availability_query(scope, [head_topic.id])),
         {:ok, plan} <- bounded_plan(head_topic, key, source, proposal) do
      {:ok,
       %{
         plan
         | topic_key: head_topic.topic_key,
           generation: generation + 1,
           latest_source_at: source.occurred_at
       }}
    else
      {:error, :knowledge_capacity_exceeded} -> {:error, :knowledge_capacity_exceeded}
      _ -> {:error, :knowledge_rebuild_conflict}
    end
  end

  defp plan_rebuild(_, _, _, _), do: {:error, :knowledge_rebuild_conflict}

  defp fetch_and_lock_topic(id) do
    id
    |> ConversationKnowledge.Query.by_id()
    |> ConversationKnowledge.Query.lock_for_update()
    |> Repo.fetch()
  end

  defp source_update(entries, proposal, offered, %{
         result_ref: result_ref,
         source_dependencies: dependencies,
         omissions: _omissions
       })
       when is_list(entries) and length(entries) in 1..16 and is_binary(result_ref) and
              byte_size(result_ref) in 1..512 do
    entry = hd(entries)

    with true <- Repo.in_transaction?(),
         true <- Enum.all?(entries, &same_source_scope?(&1, entry)),
         {:ok, proposal} when not is_nil(proposal) <- KnowledgeUpdate.prepare(proposal),
         :ok <- validate_anchors(entries, proposal, offered),
         {:ok, scope} <- Learning.Observations.fetch_and_lock_scope(entry, entry.repository_ref),
         {:ok, source} <- raw_sources(entries, dependencies, result_ref, scope, offered),
         :ok <- still_current(entry, entry.repository_ref, offered) do
      {:ok, scope, source, proposal}
    else
      {:error, :knowledge_anchor_not_sourced} -> {:error, :knowledge_anchor_not_sourced}
      _ -> @stale
    end
  end

  defp source_update(_, _, _, _), do: @stale

  defp validate_anchors(entries, proposal, offered) do
    inherited =
      offered
      |> Enum.filter(&(&1["source_ref"] == proposal["target_ref"]))
      |> Enum.flat_map(&(&1["anchors"] || []))

    texts = KnowledgeAnchors.source_texts(entries)
    KnowledgeAnchors.validate(proposal["anchors"], texts, inherited)
  end

  @doc """
  Internal — takes the topic lock of `destination`'s conversation inside the
  caller's transaction, the lock every topic write holds: `:ok`, or
  `{:error, {:admission_rejected, :context_stale}}` outside a transaction or
  for a conversation that cannot be read. Learning's apply and rebuilds call
  it before they change topics.
  """
  def lock_scope_in_transaction(destination, repository_ref) do
    with true <- Repo.in_transaction?(),
         {:ok, scope} <- Learning.Observations.fetch_and_lock_scope(destination, repository_ref) do
      lock_scope(scope_key(scope))
      :ok
    else
      _ -> @stale
    end
  end

  @doc "Check proposed new subjects before accepting a different name as proof of novelty."
  def check_creates_in_transaction([entry | _] = entries, proposals, offered) do
    with {:ok, scope} <- Learning.Observations.fetch_and_lock_scope(entry, entry.repository_ref),
         :ok <- known_create_targets(scope, proposals) do
      check_visible_creates(entries, proposals, offered)
    end
  end

  defp known_create_targets(scope, proposals) do
    creates = Enum.filter(proposals, &(&1["action"] == "create"))
    topic_keys = Enum.map(creates, & &1["topic_key"])

    anchors =
      creates
      |> Enum.flat_map(& &1["anchors"])
      |> then(&KnowledgeAnchors.keys(scope_key(scope), &1))

    known =
      scope
      |> scope_key()
      |> ConversationKnowledge.Query.matching_topics_or_anchors(topic_keys, anchors)
      |> ConversationKnowledge.Query.kept()
      |> ConversationKnowledge.Query.ordered_by_id()
      |> ConversationKnowledge.Query.limit_to(9)
      |> ConversationKnowledge.Query.select_ids()
      |> ConversationKnowledge.Query.lock_for_share()
      |> Repo.all()

    cond do
      length(known) > 8 ->
        {:error, :knowledge_match_ambiguous}

      known == [] ->
        :ok

      true ->
        available =
          scope
          |> visible_query()
          |> ConversationKnowledge.Query.by_ids(known)
          |> Repo.all()
          |> documents(scope)

        if length(available) == length(known),
          do: :ok,
          else: {:error, :knowledge_target_unavailable}
    end
  end

  defp check_visible_creates([entry | _] = entries, proposals, offered) do
    offered_refs = MapSet.new(offered, & &1["source_ref"])

    proposals
    |> Enum.filter(&(&1["action"] == "create"))
    |> Enum.flat_map(fn proposal ->
      exact =
        recall_locked(
          entry,
          entry.repository_ref,
          {:topic_keys, [proposal["topic_key"]]},
          8,
          "writable"
        )

      subject = Enum.join([proposal["title"] | proposal["topics"]], " ")

      related =
        recall_locked(entry, entry.repository_ref, {:related, subject}, 8, "writable")

      anchored =
        recall_locked(entry, entry.repository_ref, {:anchors, proposal["anchors"]}, 8, "writable")

      threads =
        entries
        |> Enum.filter(&(&1.id in proposal["source_input_ids"]))
        |> Enum.map(&(&1.destination_thread_ref || &1.source_item_ref || &1.native_input_id))

      replies = recall_locked(entry, entry.repository_ref, {:threads, threads}, 8, "writable")

      exact ++
        Enum.reject(
          anchored ++ replies ++ related,
          &MapSet.member?(offered_refs, &1["source_ref"])
        )
    end)
    |> Enum.uniq_by(& &1["source_ref"])
    |> Enum.take(8)
    |> Enum.map(& &1["source_ref"])
    |> case do
      [] -> :ok
      references -> {:error, {:learning_match_required, references}}
    end
  end

  # A topic is its conversation's (`scope_key/1`), so its sources may come
  # from messages whose work used different repositories.
  defp same_source_scope?(
         %Ingress.Inbox.Entry{status: :decided} = source_entry,
         %Ingress.Inbox.Entry{} = entry
       ) do
    source_entry.destination_transport == entry.destination_transport and
      source_entry.destination_conversation_ref == entry.destination_conversation_ref
  end

  defp same_source_scope?(_, _), do: false

  defp raw_sources(entries, dependencies, result_ref, scope, offered) do
    sources = entries |> Enum.sort_by(& &1.id) |> Enum.map(&current_source/1)

    roots =
      Learning.LearningSources.merge(
        Enum.map(entries, &Learning.LearningSources.for_entry/1) ++
          Enum.map(offered, &Learning.LearningSources.document_sources/1)
      )

    with true <- Enum.all?(sources, &match?(%Learning.ConversationObservation{}, &1)),
         true <- Learning.LearningSources.valid?(dependencies, scope),
         ^dependencies <- Learning.LearningSources.merge([dependencies, roots]) do
      primary =
        Enum.max_by(
          sources,
          &{DateTime.to_unix(&1.occurred_at, :microsecond), &1.source_input_id}
        )

      {:ok,
       Map.merge(Map.from_struct(primary), %{
         direct_sources: sources,
         source_dependencies: dependencies,
         source_result_ref: result_ref
       })}
    else
      _ -> @stale
    end
  end

  @doc """
  Internal — the query for the observations a valid topic of `scope` rests on
  directly, so `Ryker.Learning.Observations` offers only the ones no topic
  holds yet.
  """
  def current_source_ids_query(scope) do
    valid_query()
    |> Learning.LearningSources.eligible(scope)
    |> ConversationKnowledge.Query.select_id_generations()
    |> KnowledgeSource.Query.direct_observation_ids()
  end

  @doc """
  Internal — the query for valid topics: each source still current and
  unchanged in its conversation, none older than learning's retention
  window. The capacity test measures its plan.
  """
  def valid_query,
    do: ConversationKnowledge.Query.valid(Learning.LearningSources.retention_seconds())

  defp visible_query(scope) do
    valid_query()
    |> ConversationKnowledge.Query.by_workspace_ref(scope.workspace_ref)
    |> Learning.Visibility.Query.visible_from(scope)
    |> Learning.LearningSources.eligible(scope)
  end

  defp select_items(query, scope, {:related, text}, limit) when is_binary(text),
    do: select_items(query, scope, {:related, [text]}, limit)

  defp select_items(query, scope, {:related, texts}, limit) when is_list(texts) do
    anchored = select_items(query, scope, {:anchors, KnowledgeAnchors.discover(texts)}, limit)

    groups =
      texts
      |> Enum.filter(&is_binary/1)
      |> Enum.take(16)
      |> Enum.map(&related_items(query, scope, &1, limit))

    # Give every input a relevant hit before taking its second hit. A large
    # first message must not monopolize the bounded context of a later one.
    ranked =
      0..(limit - 1)
      |> Enum.flat_map(fn rank -> Enum.map(groups, &Enum.at(&1, rank)) end)
      |> Enum.reject(&is_nil/1)

    (anchored ++ ranked)
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(limit)
  end

  defp select_items(query, scope, {:anchors, anchors}, limit) do
    keys = KnowledgeAnchors.keys(scope_key(scope), Enum.take(anchors, 64))

    query
    |> ConversationKnowledge.Query.by_scope_key(scope_key(scope))
    |> ConversationKnowledge.Query.by_anchor_keys(keys)
    |> ConversationKnowledge.Query.ordered_by_latest_source_at_desc()
    |> ConversationKnowledge.Query.limit_to(limit)
    |> ConversationKnowledge.Query.lock_for_share()
    |> Repo.all()
  end

  defp select_items(query, scope, {:topic_keys, keys}, limit) when is_list(keys) do
    # A failed judgment may name an existing but unoffered subject. The fresh
    # attempt can offer that head only inside the same authorized update scope.
    keys = keys |> Enum.filter(&is_binary/1) |> Enum.take(16)

    query
    |> ConversationKnowledge.Query.by_topic_keys(keys)
    |> ConversationKnowledge.Query.by_scope_key(scope_key(scope))
    |> ConversationKnowledge.Query.ordered_by_id()
    |> ConversationKnowledge.Query.limit_to(limit)
    |> ConversationKnowledge.Query.lock_for_share()
    |> Repo.all()
  end

  defp select_items(query, scope, {:threads, references}, limit) do
    groups =
      references
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.take(16)
      |> Enum.map(&thread_items(query, scope, &1, limit))

    # A batch can contain several threads. Give each its first directly
    # supported subject before a busy thread takes its second candidate slot.
    0..(limit - 1)
    |> Enum.flat_map(fn rank -> Enum.map(groups, &Enum.at(&1, rank)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(limit)
  end

  defp select_items(query, scope, {:references, references}, limit) do
    ids = references |> Enum.map(&id/1) |> Enum.reject(&is_nil/1) |> Enum.take(8)

    query
    |> ConversationKnowledge.Query.by_ids(ids)
    |> ConversationKnowledge.Query.by_scope_key(scope_key(scope))
    |> ConversationKnowledge.Query.ordered_by_id()
    |> ConversationKnowledge.Query.limit_to(limit)
    |> ConversationKnowledge.Query.lock_for_share()
    |> Repo.all()
  end

  defp select_items(query, scope, _, limit) do
    query
    |> ConversationKnowledge.Query.ordered_by_conversation_and_latest_source(
      scope.conversation_ref
    )
    |> ConversationKnowledge.Query.limit_to(limit)
    |> ConversationKnowledge.Query.lock_for_share()
    |> Repo.all()
  end

  defp thread_items(query, scope, reference, limit) do
    # A cached empty-heap plan kept scanning the grown observation table once
    # per receipt and exhausted learning's 15-second transaction. Replan this
    # cardinality-sensitive recall; keep the same authorization and source locks.
    query
    |> ConversationKnowledge.Query.supported_in_thread(
      scope_key(scope),
      scope.conversation_ref,
      reference
    )
    |> ConversationKnowledge.Query.ordered_by_latest_source_at_desc()
    |> ConversationKnowledge.Query.limit_to(limit)
    |> ConversationKnowledge.Query.lock_for_share()
    |> Repo.all(prepare: :unnamed)
  end

  defp related_items(query, scope, text, limit) do
    terms =
      Regex.scan(~r/[\p{L}\p{N}]{3,80}/u, String.slice(text, 0, 4000))
      |> List.flatten()
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
      |> Enum.reject(
        &(&1 in ~w(the and that this what when where why how you are was were with from for can could would should))
      )
      |> Enum.take(24)
      |> Enum.join(" | ")

    if terms == "" do
      []
    else
      query
      |> ConversationKnowledge.Query.related_to(terms, scope.conversation_ref)
      |> ConversationKnowledge.Query.limit_to(limit)
      |> ConversationKnowledge.Query.lock_for_share()
      |> Repo.all()
    end
  end

  defp current_source(entry) do
    identity = Learning.Observations.source_identity(entry)

    source =
      identity
      |> Learning.ConversationObservation.Query.by_identity()
      |> Learning.ConversationObservation.Query.lock_for_share()
      |> Repo.peek()

    cond do
      source && source.revision > entry.revision ->
        :superseded

      entry.event_kind == :delete or not is_nil(entry.operational_pruned_at) ->
        :superseded

      current_identity?(source, entry) ->
        source

      true ->
        nil
    end
  end

  defp current_identity?(nil, _entry), do: false

  defp current_identity?(source, entry) do
    source.source_input_id == entry.id and source.revision == entry.revision and
      source.source_fingerprint == entry.event_fingerprint
  end

  defp apply_update(scope, source, proposal, offered) do
    with {:ok, plan} <- plan_update(scope, source, proposal, offered) do
      save_bounded_update(plan, scope, source)
    end
  end

  defp plan_update(scope, source, proposal, offered) do
    scope_key = scope_key(scope)
    lock_scope(scope_key)

    existing =
      scope_key
      |> ConversationKnowledge.Query.by_scope_key()
      |> ConversationKnowledge.Query.by_topic_key(proposal["topic_key"])
      |> ConversationKnowledge.Query.lock_for_update()
      |> Repo.peek()
      |> release_if_gone(proposal)

    cond do
      existing && is_nil(proposal["target_ref"]) &&
          not (scope
               |> visible_query()
               |> ConversationKnowledge.Query.by_id(existing.id)
               |> Repo.exists?()) ->
        {:error, :knowledge_target_unavailable}

      allowed_update?(existing, proposal, offered) ->
        bounded_plan(existing, scope_key, source, proposal)

      true ->
        @stale
    end
  end

  # A topic that is forgotten or expired gives its subject to the next topic
  # learned about it. It kept its key and anchors, matched every later topic on
  # the same subject and refused it as unavailable, so a recurring subject
  # stopped being learned once its first topic expired (2026-10-04 review).
  # The old row stays for its history under a key nothing proposes.
  defp release_if_gone(%ConversationKnowledge{} = head_topic, %{"target_ref" => nil}) do
    if head_topic.forgotten_at || head_topic.state == %{"retention" => "pruned"} do
      {1, _released} =
        Repo.update_all(ConversationKnowledge.Query.by_id(head_topic.id),
          set: [topic_key: "retired:" <> head_topic.id, anchor_keys: []]
        )

      nil
    else
      head_topic
    end
  end

  defp release_if_gone(head, _proposal), do: head

  # A conversation's topics are the conversation's, whichever repository its
  # work used when each was learned. With the repository in the key, #test's
  # "Emisar MCP access" topic, learned while the channel worked on one
  # repository, was never offered to a later pass once the channel's
  # environment moved to another: every later pass saw no topic at all, and
  # the topic kept saying access was unverified (2026-09-28). The repository
  # stays on the topic as where it was last learned.
  defp scope_key(scope) do
    scope
    |> Map.take([:transport, :workspace_ref, :conversation_ref])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> CanonicalJSON.digest()
  end

  defp lock_scope(key) do
    # Matching is a scope decision, not a title/key decision. Keep the unique
    # key index as the final fence while serializing differently named creates.
    AdvisoryLock.hold!(Crypto.lock_key("knowledge-scope:" <> key))
  end

  # A new topic: no row of this conversation has its key. A topic left out of
  # the offer for its sources' capacity would be that row, so the clause that
  # checked omissions (by the repository topics were once keyed by) could not
  # refuse anything (2026-10-04 review).
  defp allowed_update?(nil, %{"target_ref" => nil, "expected_version" => 0}, _offered), do: true

  defp allowed_update?(%{id: key, version: version}, proposal, offered) do
    reference = "knowledge:" <> key

    proposal["target_ref"] == reference and proposal["expected_version"] == version and
      Enum.any?(offered, &(&1["source_ref"] == reference and &1["version"] == version))
  end

  defp allowed_update?(_existing, _proposal, _offered), do: false

  defp bounded_plan(existing, scope_key, source, proposal) do
    state =
      Map.take(proposal, ~w(title summary topics))
      |> Map.put(
        "anchors",
        proposal["anchors"] |> Enum.map(&KnowledgeAnchors.normalize/1) |> Enum.uniq()
      )

    version = if existing, do: existing.version + 1, else: 1
    previous = if existing && proposal["target_ref"], do: existing.source_dependencies, else: []
    dependencies = Learning.LearningSources.merge([previous, source.source_dependencies])

    if is_nil(dependencies) do
      {:error, :knowledge_capacity_exceeded}
    else
      {:ok,
       %{
         existing: existing,
         scope_key: scope_key,
         topic_key: proposal["topic_key"],
         state: state,
         version: version,
         generation: if(existing, do: existing.source_generation, else: 1),
         latest_source_at:
           if(existing,
             do: Enum.max([existing.latest_source_at, source.occurred_at], DateTime),
             else: source.occurred_at
           ),
         dependencies: dependencies
       }}
    end
  end

  defp save_bounded_update(plan, scope, source) do
    %{
      existing: existing,
      scope_key: scope_key,
      state: state,
      version: version,
      generation: generation,
      dependencies: dependencies
    } = plan

    id = if existing, do: existing.id, else: Repo.generate_id()
    roots = Learning.LearningSources.expand(dependencies)
    reference = [Learning.LearningSources.knowledge_reference(id, generation, version)]
    now = Repo.now!()

    attrs =
      Map.merge(
        Map.take(scope, [
          :transport,
          :workspace_ref,
          :conversation_ref,
          :repository_ref,
          :visibility
        ]),
        %{
          scope_key: scope_key,
          topic_key: plan.topic_key,
          anchor_keys: KnowledgeAnchors.keys(scope_key, state["anchors"]),
          state: state,
          version: version,
          source_generation: generation,
          source_dependencies: reference,
          source_input_id: source.source_input_id,
          source_episode_id: source.source_episode_id,
          inserted_at: if(existing, do: existing.inserted_at, else: now),
          updated_at: now,
          latest_source_at: plan.latest_source_at
        }
      )

    item =
      if existing do
        existing
        |> Ecto.Changeset.change(attrs)
        |> Ecto.Changeset.force_change(:updated_at, now)
        |> Repo.update!()
      else
        attrs = Map.put(attrs, :id, id)
        Repo.insert!(struct!(ConversationKnowledge, attrs))
      end

    persist_memberships(item, roots, source.direct_sources, version)
    broadcast_knowledge_updated(item.id)

    if Repo.exists?(ConversationKnowledge.Query.by_id(valid_query(), item.id)) do
      Repo.insert!(%KnowledgeRevision{
        knowledge_id: item.id,
        version: version,
        source_generation: generation,
        source_dependencies: reference,
        state: state,
        source_input_id: source.source_input_id,
        source_result_ref: source.source_result_ref,
        source_at: source.occurred_at,
        inserted_at: now
      })

      :ok
    else
      @stale
    end
  end

  defp persist_memberships(item, roots, direct_sources, version) do
    existing =
      item.id
      |> KnowledgeSource.Query.by_generation(item.source_generation)
      |> Repo.all()
      |> Map.new(&{&1.receipt_fingerprint, &1})

    direct = Map.new(direct_sources, &{&1.id, &1})

    {rows, promotions} =
      Enum.reduce(roots, {[], []}, fn receipt, {rows, promotions} ->
        fingerprint = CanonicalJSON.digest(receipt)
        support = direct[receipt["observation_id"]]

        case existing[fingerprint] do
          nil ->
            row = membership_row(item, receipt, fingerprint, support, version)

            {[row | rows], promotions}

          %{direct_support_version: nil} when not is_nil(support) ->
            {rows, [fingerprint | promotions]}

          _ ->
            {rows, promotions}
        end
      end)

    rows |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(KnowledgeSource, &1))

    if promotions != [] do
      query =
        item.id
        |> KnowledgeSource.Query.by_generation(item.source_generation)
        |> KnowledgeSource.Query.indirect(promotions)

      Repo.update_all(query, set: [direct_support_version: version])
    end
  end

  defp membership_row(item, receipt, fingerprint, support, version) do
    {:ok, retained_at} = UTCDateTime.parse(receipt["retained_at"])

    %{
      knowledge_id: item.id,
      generation: item.source_generation,
      receipt_fingerprint: fingerprint,
      receipt: receipt,
      observation_id: receipt["observation_id"],
      source_revision: receipt["revision"],
      source_fingerprint: receipt["fingerprint"],
      retained_at: retained_at,
      introduced_version: version,
      direct_support_version: if(support, do: version)
    }
  end

  defp documents([], _scope), do: []

  defp documents(items, scope) do
    ids = Enum.map(items, & &1.id)
    # Lock source rows too: under REPEATABLE READ a source edited after the
    # frozen snapshot must reject the read instead of submitting its old facts.
    sources =
      ids
      |> KnowledgeSource.Query.direct_support()
      |> KnowledgeSource.Query.lock_for_share()
      |> Repo.all()
      |> Enum.uniq_by(&{&1.knowledge_id, &1.id})
      |> Enum.group_by(& &1.knowledge_id)

    # READ COMMITTED can observe an edit while waiting for the source locks.
    # Recheck after acquiring them; a pre-lock eligibility test is not a receipt.
    valid_ids =
      valid_query()
      |> ConversationKnowledge.Query.by_ids(ids)
      |> ConversationKnowledge.Query.select_ids()
      |> Repo.all()
      |> MapSet.new()

    items =
      Enum.flat_map(items, fn item ->
        with true <- MapSet.member?(valid_ids, item.id),
             {:ok, roots} <-
               Learning.LearningSources.validated_roots(item.source_dependencies, scope) do
          [{item, roots}]
        else
          _ -> []
        end
      end)

    Enum.map(items, fn {item, roots} ->
      support = Map.fetch!(sources, item.id)
      dates = Enum.map(support, & &1.retained_at)

      source_reads =
        support
        |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
        |> Stream.map(
          &Memories.MemorySourceLink.message(
            &1.transport,
            &1.conversation_ref,
            &1.source_message_ref,
            &1.thread_ref
          )
        )
        |> Stream.reject(&is_nil/1)
        |> Stream.uniq()
        |> Enum.take(3)

      expires =
        case Learning.LearningSources.retention_seconds() do
          nil ->
            nil

          seconds ->
            dates
            |> Enum.min_by(&DateTime.to_unix(&1, :microsecond))
            |> then(&Learning.LearningSources.oldest(roots, &1))
            |> DateTime.add(seconds)
            |> DateTime.to_iso8601()
        end

      Map.merge(item.state, %{
        "kind" => "conversation_knowledge",
        "source_ref" => "knowledge:#{item.id}",
        "topic_key" => item.topic_key,
        "version" => item.version,
        "can_update" => item.scope_key == scope_key(scope),
        "conversation_ref" => item.conversation_ref,
        "repository_ref" => item.repository_ref,
        "source_count" => length(dates),
        "source_reads" => source_reads,
        "latest_source_at" => DateTime.to_iso8601(item.latest_source_at),
        "expires_at" => expires
      })
    end)
  end

  defp within_scope(query, scope, search_scope),
    do: ConversationKnowledge.Query.within_scope(query, scope_key(scope), scope, search_scope)

  defp id("knowledge:" <> id), do: if(Ecto.UUID.cast(id) == {:ok, id}, do: id)
  defp id(_), do: nil

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to learned topic changes: `{:knowledge_updated,
  knowledge_id}` once a topic is learned, revised, relearned, forgotten or
  expires, or a run is shown it, and that change has committed.
  """
  def subscribe_knowledge, do: Ryker.PubSub.subscribe(knowledge_topic())

  @doc """
  Stops the announcements `subscribe_knowledge/0` started. A page leaves a
  topic by this twin of its subscription (`WorkbenchLive`).
  """
  def unsubscribe_knowledge, do: Ryker.PubSub.unsubscribe(knowledge_topic())

  @doc """
  Internal — announces, after the outermost commit, that topic
  `knowledge_id` changed. Forgetting and retention, which change topics
  outside this module, call it too.
  """
  @spec broadcast_knowledge_updated(Ecto.UUID.t()) :: :ok
  def broadcast_knowledge_updated(knowledge_id) do
    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(knowledge_topic(), {:knowledge_updated, knowledge_id})
    end)
  end

  defp knowledge_topic, do: "knowledge"
end
