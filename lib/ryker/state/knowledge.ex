defmodule Ryker.State.Knowledge do
  @moduledoc "Maintained conversation topics with versioned, revocable source dependencies."
  import Ecto.Query
  alias Ryker.{CanonicalJSON, Repo}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Slack.ChannelMembership

  alias Ryker.State.{
    ConversationKnowledge,
    ConversationObservation,
    KnowledgeAnchors,
    KnowledgeRevision,
    KnowledgeSource,
    KnowledgeUpdate,
    LearningSources,
    MemorySearchPage,
    MemorySourceLink,
    Observations
  }

  @stale {:error, {:admission_rejected, :context_stale}}

  @doc false
  def availability_query(scope, ids) do
    base =
      valid_query()
      |> where([item], item.id in ^ids)
      |> where(
        [item],
        item.transport == ^scope.transport and
          item.conversation_ref == ^scope.conversation_ref and
          fragment("? IS NOT DISTINCT FROM ?", item.repository_ref, ^scope.repository_ref)
      )
      |> select([item], item.id)

    local = LearningSources.eligible(base, %{scope | visibility: :conversation})

    case slack_channel(scope) do
      {:channel, workspace, channel} ->
        membership =
          from(m in ChannelMembership,
            where: m.workspace_ref == ^workspace and m.channel_ref == ^channel,
            select: 1
          )

        deleted = where(membership, [m], m.status == :deleted)

        public =
          where(membership, [m], m.status == :joined and not m.private and not m.external_shared)

        local = where(local, not exists(subquery(deleted)))

        inherited =
          base
          |> LearningSources.eligible(%{scope | visibility: :public})
          |> where(exists(subquery(public)))

        union(local, ^inherited)

      :local ->
        local
    end
  end

  defp slack_channel(%{transport: "slack", conversation_ref: "slack:" <> rest}) do
    case String.split(rest, ":", parts: 2) do
      [_workspace, "D" <> _] ->
        :local

      [workspace, channel] when workspace != "" and channel != "" ->
        {:channel, workspace, channel}

      _ ->
        :local
    end
  end

  defp slack_channel(_), do: :local

  def context(destination, repository_ref, search \\ "", limit \\ 16, search_scope \\ "workspace") do
    case Repo.transaction(fn ->
           recall_locked(destination, repository_ref, search, limit, search_scope)
         end) do
      {:ok, items} -> items
      _ -> []
    end
  end

  defp recall_locked(destination, repository_ref, search, limit, search_scope) do
    case Observations.locked_scope(destination, repository_ref) do
      {:ok, scope} ->
        query = visible_query(scope) |> within_scope(scope, search_scope) |> matching(search)
        items = select_items(query, scope, search, min(max(limit, 1), 32))
        documents(Observations.authorized_notes(items, scope), scope)

      _ ->
        []
    end
  end

  @doc false
  def search_page(destination, repository_ref, page) do
    case Observations.locked_scope(destination, repository_ref) do
      {:ok, scope} -> search_page_locked(scope, page)
      _ -> :done
    end
  end

  defp search_page_locked(scope, page) do
    query =
      visible_query(scope)
      |> within_scope(scope, page.scope)
      |> MemorySearchPage.related_sources(page)

    query = from(k in query, lock: "FOR SHARE")

    case MemorySearchPage.one(
           query,
           page,
           dynamic([k], k.state),
           dynamic([k], k.updated_at),
           dynamic([k], k.latest_source_at)
         ) do
      {:ok, item, position} ->
        case documents(Observations.authorized_notes([item], scope), scope) do
          [document] -> {:ok, document, position}
          [] -> {:skip, position}
        end

      :done ->
        :done
    end
  end

  def reauthorize(_destination, _repository_ref, []), do: :ok

  def reauthorize(destination, repository_ref, frozen)
      when is_list(frozen) and length(frozen) <= 32 do
    case Repo.transaction(fn -> reauthorize_locked(destination, repository_ref, frozen) end) do
      {:ok, true} -> :ok
      _ -> @stale
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] in [:serialization_failure, :deadlock_detected],
        do: @stale,
        else: reraise(error, __STACKTRACE__)
  end

  def reauthorize(_, _, _), do: @stale

  defp reauthorize_locked(destination, repository_ref, frozen) do
    with {:ok, scope} <- Observations.locked_scope(destination, repository_ref),
         ids = Enum.map(frozen, &id(&1["source_ref"])),
         true <- Enum.all?(ids, &is_binary/1) do
      # Learning may update a reauthorized target later in this transaction.
      # Take the bounded set in one order; upgrading shared locks can deadlock
      # with another transaction's selected topic.
      items =
        Repo.all(
          from(k in visible_query(scope),
            where: k.id in ^ids,
            order_by: [asc: k.id],
            lock: "FOR UPDATE"
          )
        )

      current = documents(Observations.authorized_notes(items, scope), scope)
      MapSet.new(current) == MapSet.new(frozen)
    else
      _ -> false
    end
  end

  @doc "Learn from retained raw inputs without changing their earlier observations or decisions."
  def record_sources_in_transaction(entries, proposal, offered, context) do
    with {:ok, scope, source, proposal} <- source_update(entries, proposal, offered, context) do
      apply_update(scope, source, proposal, offered, context.omissions)
    end
  end

  @doc "Check the same source/update contract without creating a topic or a revision."
  def check_sources_in_transaction(entries, proposal, offered, context) do
    with {:ok, scope, source, proposal} <- source_update(entries, proposal, offered, context),
         {:ok, _plan} <- plan_update(scope, source, proposal, offered, context.omissions) do
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
      {:error, :knowledge_anchor_not_sourced} = error -> error
      _ -> {:error, :learning_source_stale}
    end
  end

  defp rebuild_sources(_, _, _, _), do: {:error, :learning_source_stale}

  defp fresh_rebuild_sources?(entries, selected, dependencies) do
    raw = selected |> Enum.map(&LearningSources.for_entry/1) |> LearningSources.merge()
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
         %ConversationKnowledge{} = head <-
           Repo.one(from(k in ConversationKnowledge, where: k.id == ^id, lock: "FOR UPDATE")),
         true <-
           head.scope_key == key and head.version == version and
             head.source_generation == generation,
         false <- Repo.exists?(availability_query(scope, [head.id])),
         {:ok, plan} <- bounded_plan(head, key, source, proposal) do
      {:ok,
       %{
         plan
         | topic_key: head.topic_key,
           generation: generation + 1,
           latest_source_at: source.occurred_at
       }}
    else
      {:error, :knowledge_capacity_exceeded} = error -> error
      _ -> {:error, :knowledge_rebuild_conflict}
    end
  end

  defp plan_rebuild(_, _, _, _), do: {:error, :knowledge_rebuild_conflict}

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
         {:ok, scope} <- Observations.locked_scope(entry, entry.repository_ref),
         {:ok, source} <- raw_sources(entries, dependencies, result_ref, scope, offered),
         :ok <- reauthorize(entry, entry.repository_ref, offered) do
      {:ok, scope, source, proposal}
    else
      {:error, :knowledge_anchor_not_sourced} = error -> error
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

  @doc false
  def lock_scope_in_transaction(destination, repository_ref) do
    with true <- Repo.in_transaction?(),
         {:ok, scope} <- Observations.locked_scope(destination, repository_ref) do
      lock_scope(scope_key(scope))
      :ok
    else
      _ -> @stale
    end
  end

  @doc "Check proposed new subjects before accepting a different name as proof of novelty."
  def check_creates_in_transaction([entry | _] = entries, proposals, offered) do
    with {:ok, scope} <- Observations.locked_scope(entry, entry.repository_ref),
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
      Repo.all(
        from(k in ConversationKnowledge,
          where:
            k.scope_key == ^scope_key(scope) and
              (k.topic_key in ^topic_keys or fragment("? && ?::text[]", k.anchor_keys, ^anchors)),
          order_by: [asc: k.id],
          limit: 9,
          select: k.id,
          lock: "FOR SHARE"
        )
      )

    cond do
      length(known) > 8 ->
        {:error, :knowledge_match_ambiguous}

      known == [] ->
        :ok

      true ->
        available =
          Repo.all(from(k in visible_query(scope), where: k.id in ^known)) |> documents(scope)

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

  defp same_source_scope?(%Entry{status: :decided} = source, %Entry{} = entry) do
    source.destination_transport == entry.destination_transport and
      source.destination_conversation_ref == entry.destination_conversation_ref and
      source.repository_ref == entry.repository_ref
  end

  defp same_source_scope?(_, _), do: false

  defp raw_sources(entries, dependencies, result_ref, scope, offered) do
    sources = entries |> Enum.sort_by(& &1.id) |> Enum.map(&current_source/1)

    roots =
      LearningSources.merge(
        Enum.map(entries, &LearningSources.for_entry/1) ++
          Enum.map(offered, &LearningSources.document_sources/1)
      )

    with true <- Enum.all?(sources, &match?(%ConversationObservation{}, &1)),
         true <- LearningSources.valid?(dependencies, scope),
         ^dependencies <- LearningSources.merge([dependencies, roots]) do
      primary =
        Enum.max_by(
          sources,
          &{DateTime.to_unix(&1.occurred_at, :microsecond), &1.source_input_id}
        )

      {:ok,
       Map.merge(Map.from_struct(primary), %{
         # Raw learning never disclosed old derived notes. Do not copy their
         # prose into this generation without their inherited retention roots.
         direct_sources: Enum.map(sources, &%{&1 | note: nil}),
         source_dependencies: dependencies,
         source_result_ref: result_ref
       })}
    else
      _ -> @stale
    end
  end

  def history(reference) do
    case id(reference) do
      nil ->
        []

      id ->
        Repo.all(
          from(r in KnowledgeRevision, where: r.knowledge_id == ^id, order_by: [asc: r.version])
        )
    end
  end

  @doc false
  def current_source_ids_query(scope) do
    eligible =
      valid_query()
      |> LearningSources.eligible(scope)
      |> select([k], %{id: k.id, source_generation: k.source_generation})

    # Flattening this join made PostgreSQL validate one topic's 128 roots once
    # per source row. Evaluate eligibility once, in this same statement snapshot.
    from(s in KnowledgeSource,
      join: k in "eligible_conversation_knowledge",
      on: k.id == s.knowledge_id and k.source_generation == s.generation,
      where: not is_nil(s.direct_support_version),
      select: s.observation_id
    )
    |> with_cte("eligible_conversation_knowledge", as: ^eligible, materialized: true)
  end

  @doc false
  def valid_query do
    changed_source = changed_source()
    changed_scope = changed_scope()

    # The full gate's stale statistics turned the inverse validity join into
    # 50 million pair comparisons for 10,000 roots. Keep every observation read
    # parameterized by its receipt; OFFSET 0 prevents flattening that lookup.
    observation =
      from(o in ConversationObservation,
        where: o.id == parent_as(:knowledge_membership).observation_id,
        offset: 0
      )

    invalid =
      from(s in KnowledgeSource,
        as: :knowledge_membership,
        left_lateral_join: o in subquery(observation),
        on: true,
        where:
          s.knowledge_id == parent_as(:knowledge).id and
            s.generation == parent_as(:knowledge).source_generation,
        where:
          ^dynamic(
            [s, o],
            ^changed_source or (not is_nil(s.direct_support_version) and ^changed_scope)
          ),
        select: 1
      )

    invalid = expire_memberships(invalid, retention_seconds())

    any =
      from(s in KnowledgeSource,
        where:
          s.knowledge_id == parent_as(:knowledge).id and
            s.generation == parent_as(:knowledge).source_generation,
        select: 1
      )

    from(k in ConversationKnowledge,
      as: :knowledge,
      where: exists(subquery(any)) and not exists(subquery(invalid)),
      where: fragment(~s(?::jsonb <> '{"retention":"pruned"}'::jsonb), k.state)
    )
  end

  defp expire_memberships(invalid, seconds) do
    case seconds do
      nil ->
        invalid

      seconds ->
        or_where(
          invalid,
          [s, o],
          s.knowledge_id == parent_as(:knowledge).id and
            s.generation == parent_as(:knowledge).source_generation and
            (s.retained_at <= ago(^seconds, "second") or o.updated_at <= ago(^seconds, "second"))
        )
    end
  end

  defp changed_source do
    dynamic(
      [s, o],
      is_nil(o.id) or o.revision != s.source_revision or
        o.source_fingerprint != s.source_fingerprint
    )
  end

  defp changed_scope do
    dynamic(
      [_s, o],
      o.conversation_ref != parent_as(:knowledge).conversation_ref or
        o.workspace_ref != parent_as(:knowledge).workspace_ref or
        fragment("? IS DISTINCT FROM ?", o.repository_ref, parent_as(:knowledge).repository_ref)
    )
  end

  defp visible_query(scope) do
    allowed = Observations.visible_conversations(scope)

    from(k in valid_query(), where: k.workspace_ref == ^scope.workspace_ref, where: ^allowed)
    |> LearningSources.eligible(scope)
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

    Repo.all(
      from(k in query,
        where:
          k.scope_key == ^scope_key(scope) and fragment("? && ?::text[]", k.anchor_keys, ^keys),
        order_by: [desc: k.latest_source_at, asc: k.id],
        limit: ^limit,
        lock: "FOR SHARE"
      )
    )
  end

  defp select_items(query, scope, {:topic_keys, keys}, limit) when is_list(keys) do
    # A failed judgment may name an existing but unoffered subject. The fresh
    # attempt can offer that head only inside the same authorized update scope.
    keys = keys |> Enum.filter(&is_binary/1) |> Enum.take(16)

    Repo.all(
      from(k in query,
        where: k.topic_key in ^keys and k.conversation_ref == ^scope.conversation_ref,
        where: fragment("? IS NOT DISTINCT FROM ?", k.repository_ref, ^scope.repository_ref),
        order_by: [asc: k.id],
        limit: ^limit,
        lock: "FOR SHARE"
      )
    )
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

    Repo.all(
      from(k in query,
        where: k.id in ^ids and k.conversation_ref == ^scope.conversation_ref,
        where: fragment("? IS NOT DISTINCT FROM ?", k.repository_ref, ^scope.repository_ref),
        order_by: [asc: k.id],
        limit: ^limit,
        lock: "FOR SHARE"
      )
    )
  end

  defp select_items(query, scope, _, limit) do
    Repo.all(
      from(k in query,
        order_by: [
          desc: k.conversation_ref == ^scope.conversation_ref,
          desc: k.latest_source_at,
          asc: k.id
        ],
        limit: ^limit,
        lock: "FOR SHARE"
      )
    )
  end

  defp thread_items(query, scope, reference, limit) do
    direct_source =
      from(s in KnowledgeSource,
        join: o in ConversationObservation,
        on: o.id == s.observation_id,
        where:
          s.knowledge_id == parent_as(:knowledge).id and
            s.generation == parent_as(:knowledge).source_generation,
        where: not is_nil(s.direct_support_version),
        where: o.conversation_ref == ^scope.conversation_ref,
        where: fragment("COALESCE(?, ?) = ?", o.thread_ref, o.source_message_ref, ^reference),
        select: 1
      )

    # A cached empty-heap plan kept scanning the grown observation table once
    # per receipt and exhausted learning's 15-second transaction. Replan this
    # cardinality-sensitive recall; keep the same authorization and source locks.
    Repo.all(
      from(k in query,
        where: k.scope_key == ^scope_key(scope) and exists(subquery(direct_source)),
        order_by: [desc: k.latest_source_at, asc: k.id],
        limit: ^limit,
        lock: "FOR SHARE"
      ),
      prepare: :unnamed
    )
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
      query =
        from(k in query,
          where: fragment("to_tsvector('simple', ?) @@ to_tsquery('simple', ?)", k.state, ^terms),
          order_by: [
            desc:
              fragment(
                "ts_rank_cd(to_tsvector('simple', ?), to_tsquery('simple', ?))",
                k.state,
                ^terms
              ),
            desc: k.conversation_ref == ^scope.conversation_ref,
            desc: k.latest_source_at,
            asc: k.id
          ],
          limit: ^limit,
          lock: "FOR SHARE"
        )

      Repo.all(query)
    end
  end

  defp current_source(entry) do
    identity = Observations.source_identity(entry)

    source =
      Repo.one(
        from(o in ConversationObservation, where: o.identity_key == ^identity, lock: "FOR SHARE")
      )

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

  defp apply_update(scope, source, proposal, offered, omissions) do
    with {:ok, plan} <- plan_update(scope, source, proposal, offered, omissions) do
      save_bounded_update(plan, scope, source)
    end
  end

  defp plan_update(scope, source, proposal, offered, omissions) do
    scope_key = scope_key(scope)
    lock_scope(scope_key)

    existing =
      Repo.one(
        from(k in ConversationKnowledge,
          where: k.scope_key == ^scope_key and k.topic_key == ^proposal["topic_key"],
          lock: "FOR UPDATE"
        )
      )

    cond do
      existing && is_nil(proposal["target_ref"]) &&
          not Repo.exists?(from(k in visible_query(scope), where: k.id == ^existing.id)) ->
        {:error, :knowledge_target_unavailable}

      allowed_update?(existing, proposal, offered, omissions, scope) ->
        bounded_plan(existing, scope_key, source, proposal)

      true ->
        @stale
    end
  end

  defp scope_key(scope) do
    scope
    |> Map.take([:transport, :workspace_ref, :conversation_ref, :repository_ref])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> CanonicalJSON.digest()
  end

  defp lock_scope(key) do
    # Matching is a scope decision, not a title/key decision. Keep the unique
    # key index as the final fence while serializing differently named creates.
    <<lock::signed-64, _::binary>> = :crypto.hash(:sha256, "knowledge-scope:" <> key)
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock])
  end

  defp allowed_update?(nil, %{"target_ref" => nil, "expected_version" => 0}, _, [], _), do: true

  defp allowed_update?(
         nil,
         %{"target_ref" => nil, "expected_version" => 0} = proposal,
         _,
         omissions,
         scope
       ),
       do:
         not Enum.any?(
           omissions,
           &(&1["topic_key"] == proposal["topic_key"] and
               &1["conversation_ref"] == scope.conversation_ref and
               &1["repository_ref"] == scope.repository_ref and &1["reason"] == "source_capacity")
         )

  defp allowed_update?(%{id: key, version: version}, proposal, offered, _, _) do
    reference = "knowledge:" <> key

    proposal["target_ref"] == reference and proposal["expected_version"] == version and
      Enum.any?(offered, &(&1["source_ref"] == reference and &1["version"] == version))
  end

  defp allowed_update?(_, _, _, _, _), do: false

  defp bounded_plan(existing, scope_key, source, proposal) do
    state =
      Map.take(proposal, ~w(title summary topics))
      |> Map.put(
        "anchors",
        proposal["anchors"] |> Enum.map(&KnowledgeAnchors.normalize/1) |> Enum.uniq()
      )

    version = if existing, do: existing.version + 1, else: 1
    previous = if existing && proposal["target_ref"], do: existing.source_dependencies, else: []
    dependencies = LearningSources.merge([previous, source.source_dependencies])

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

    id = if existing, do: existing.id, else: Ecto.UUID.generate()
    roots = LearningSources.expand(dependencies)
    reference = [LearningSources.knowledge_reference(id, generation, version)]
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
      if existing,
        do:
          existing
          |> Ecto.Changeset.change(attrs)
          |> Ecto.Changeset.force_change(:updated_at, now)
          |> Repo.update!(),
        else: Repo.insert!(struct!(ConversationKnowledge, Map.put(attrs, :id, id)))

    persist_memberships(item, roots, source.direct_sources, version)

    if Repo.exists?(from(k in valid_query(), where: k.id == ^item.id)) do
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
      Repo.all(
        from(s in KnowledgeSource,
          where: s.knowledge_id == ^item.id and s.generation == ^item.source_generation,
          select: %{
            receipt_fingerprint: s.receipt_fingerprint,
            direct_support_version: s.direct_support_version
          }
        )
      )
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
      Repo.update_all(
        from(s in KnowledgeSource,
          where: s.knowledge_id == ^item.id and s.generation == ^item.source_generation,
          where: s.receipt_fingerprint in ^promotions and is_nil(s.direct_support_version)
        ),
        set: [direct_support_version: version]
      )
    end
  end

  defp membership_row(item, receipt, fingerprint, support, version) do
    {:ok, retained_at, 0} = DateTime.from_iso8601(receipt["retained_at"])

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
      direct_support_version: if(support, do: version),
      source_note: if(support, do: support.note)
    }
  end

  defp documents([], _scope), do: []

  defp documents(items, scope) do
    ids = Enum.map(items, & &1.id)
    # Lock source rows too: under REPEATABLE READ a source edited after the
    # frozen snapshot must reject the read instead of submitting its old facts.
    sources =
      Repo.all(
        from(s in KnowledgeSource,
          join: k in ConversationKnowledge,
          on: k.id == s.knowledge_id and k.source_generation == s.generation,
          join: o in ConversationObservation,
          on: o.id == s.observation_id,
          where: s.knowledge_id in ^ids and not is_nil(s.direct_support_version),
          order_by: [asc: o.id],
          lock: "FOR SHARE",
          select: %{
            knowledge_id: s.knowledge_id,
            id: o.id,
            retained_at: s.retained_at,
            occurred_at: o.occurred_at,
            transport: o.transport,
            conversation_ref: o.conversation_ref,
            thread_ref: o.thread_ref,
            source_message_ref: o.source_message_ref
          }
        )
      )
      |> Enum.uniq_by(&{&1.knowledge_id, &1.id})
      |> Enum.group_by(& &1.knowledge_id)

    # READ COMMITTED can observe an edit while waiting for the source locks.
    # Recheck after acquiring them; a pre-lock eligibility test is not a receipt.
    valid_ids =
      Repo.all(from(k in valid_query(), where: k.id in ^ids, select: k.id)) |> MapSet.new()

    items =
      Enum.flat_map(items, fn item ->
        with true <- MapSet.member?(valid_ids, item.id),
             {:ok, roots} <- LearningSources.validated_roots(item.source_dependencies, scope) do
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
          &MemorySourceLink.message(
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
        case retention_seconds() do
          nil ->
            nil

          seconds ->
            dates
            |> Enum.min_by(&DateTime.to_unix(&1, :microsecond))
            |> then(&LearningSources.oldest(roots, &1))
            |> DateTime.add(seconds)
            |> DateTime.to_iso8601()
        end

      Map.merge(item.state, %{
        "kind" => "conversation_knowledge",
        "source_ref" => "knowledge:#{item.id}",
        "topic_key" => item.topic_key,
        "version" => item.version,
        "can_update" =>
          item.conversation_ref == scope.conversation_ref and
            item.repository_ref == scope.repository_ref,
        "conversation_ref" => item.conversation_ref,
        "repository_ref" => item.repository_ref,
        "source_count" => length(dates),
        "source_reads" => source_reads,
        "latest_source_at" => DateTime.to_iso8601(item.latest_source_at),
        "expires_at" => expires
      })
    end)
  end

  defp within_scope(query, _, "workspace"), do: query

  defp within_scope(query, scope, "writable"),
    do: from(k in query, where: k.scope_key == ^scope_key(scope))

  defp within_scope(query, scope, "current_channel"),
    do: from(k in query, where: k.conversation_ref == ^scope.conversation_ref)

  defp within_scope(query, %{repository_ref: ref}, "repository") when is_binary(ref),
    do: from(k in query, where: k.repository_ref == ^ref)

  defp within_scope(query, _, _), do: from(k in query, where: false)

  defp matching(query, search) when is_binary(search) do
    search = String.slice(String.trim(search), 0, 200)
    from(k in query, where: fragment("position(lower(?) in lower(?)) > 0", ^search, k.state))
  end

  defp matching(query, _), do: query
  defp id("knowledge:" <> id), do: if(Ecto.UUID.cast(id) == {:ok, id}, do: id)
  defp id(_), do: nil

  defp retention_seconds do
    settings = Application.get_env(:ryker, :retention) || %{}

    value =
      if is_list(settings),
        do: Keyword.get(settings, :conversation_memory_seconds),
        else: Map.get(settings, :conversation_memory_seconds)

    if is_integer(value) and value > 0, do: value
  end
end
