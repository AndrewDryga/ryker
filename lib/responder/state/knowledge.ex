defmodule Responder.State.Knowledge do
  @moduledoc "Maintained conversation topics with versioned, revocable source dependencies."
  import Ecto.Query
  alias Responder.{CanonicalJSON, Repo}
  alias Responder.Ingress.Inbox.Entry

  alias Responder.State.{
    ConversationKnowledge,
    ConversationObservation,
    KnowledgeRevision,
    KnowledgeSource,
    KnowledgeUpdate,
    LearningSources,
    Observations
  }

  @stale {:error, {:admission_rejected, :context_stale}}

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
      # Admission can update an offered topic later in this transaction. Take
      # the bounded set in one exclusive order; upgrading shared locks lets
      # two channels wait forever on each other's selected topic.
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

  def record_in_transaction(entry, proposal, offered, omissions \\ [])
  def record_in_transaction(_entry, nil, _offered, _omissions), do: :ok

  def record_in_transaction(%Entry{status: :decided} = entry, proposal, offered, omissions) do
    with true <- Repo.in_transaction?(),
         {:ok, proposal} <- KnowledgeUpdate.prepare(proposal),
         {:ok, scope} <- Observations.locked_scope(entry, entry.repository_ref),
         %ConversationObservation{} = source <- current_source(entry) do
      apply_update(scope, source, proposal, offered, omissions)
    else
      :superseded -> :ok
      _ -> @stale
    end
  end

  def record_in_transaction(_, _, _, _), do: @stale

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
    from(s in KnowledgeSource,
      join: k in subquery(LearningSources.eligible(valid_query(), scope)),
      on: k.id == s.knowledge_id and k.source_generation == s.generation,
      select: s.observation_id
    )
  end

  @doc false
  def valid_query do
    changed_source = changed_source()
    changed_scope = changed_scope()

    invalid =
      from(s in KnowledgeSource,
        left_join: o in ConversationObservation,
        on: o.id == s.observation_id,
        where:
          s.knowledge_id == parent_as(:knowledge).id and
            s.generation == parent_as(:knowledge).source_generation,
        where: ^dynamic([s, o], ^changed_source or ^changed_scope),
        select: 1
      )

    invalid =
      case retention_seconds() do
        nil ->
          invalid

        seconds ->
          or_where(
            invalid,
            [s, o],
            s.knowledge_id == parent_as(:knowledge).id and
              s.generation == parent_as(:knowledge).source_generation and
              o.updated_at <= ago(^seconds, "second")
          )
      end

    any =
      from(s in KnowledgeSource,
        where:
          s.knowledge_id == parent_as(:knowledge).id and
            s.generation == parent_as(:knowledge).source_generation,
        select: 1
      )

    from(k in ConversationKnowledge,
      as: :knowledge,
      where: exists(subquery(any)) and not exists(subquery(invalid))
    )
  end

  defp changed_source do
    dynamic(
      [s, o],
      is_nil(s.source_note) or is_nil(o.note) or
        o.revision != s.source_revision or o.source_fingerprint != s.source_fingerprint or
        o.note != s.source_note
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

  defp select_items(query, scope, {:related, text}, limit) when is_binary(text) do
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
      select_items(query, scope, "", limit)
    else
      matched =
        Repo.all(
          from(k in query,
            where:
              fragment("to_tsvector('simple', ?) @@ to_tsquery('simple', ?)", k.state, ^terms),
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
        )

      ids = Enum.map(matched, & &1.id)
      remaining = limit - length(matched)

      matched ++
        if remaining == 0,
          do: [],
          else: select_items(from(k in query, where: k.id not in ^ids), scope, "", remaining)
    end
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

  defp current_source(entry) do
    identity = Observations.source_identity(entry)

    source =
      Repo.one(
        from(o in ConversationObservation, where: o.identity_key == ^identity, lock: "FOR SHARE")
      )

    cond do
      source && source.revision > entry.revision ->
        :superseded

      entry.event_kind == :delete ->
        :superseded

      source && source.source_input_id == entry.id && source.revision == entry.revision &&
          not is_nil(source.note) ->
        source

      true ->
        nil
    end
  end

  defp apply_update(scope, source, proposal, offered, omissions) do
    scope_key =
      scope
      |> Map.take([:transport, :workspace_ref, :conversation_ref, :repository_ref])
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> CanonicalJSON.digest()

    # The unique index is the final fence; this transaction lock also makes a
    # competing first insert return context_stale instead of aborting the connection.
    <<lock::signed-64, _::binary>> =
      :crypto.hash(:sha256, scope_key <> ":" <> proposal["topic_key"])

    Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock])

    existing =
      Repo.one(
        from(k in ConversationKnowledge,
          where: k.scope_key == ^scope_key and k.topic_key == ^proposal["topic_key"],
          lock: "FOR UPDATE"
        )
      )

    if allowed_update?(existing, proposal, offered, omissions, scope) do
      if existing && DateTime.compare(source.occurred_at, existing.latest_source_at) == :lt do
        :ok
      else
        save_update(existing, scope, scope_key, source, proposal)
      end
    else
      @stale
    end
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

  defp allowed_update?(
         %{id: key} = existing,
         %{"target_ref" => nil, "expected_version" => 0},
         offered,
         omissions,
         scope
       ) do
    # A fresh source can rebuild an invalid topic, but it must not have been
    # briefed with the withdrawn aggregate. Old revisions and dependencies remain.
    not Enum.any?(offered, &(&1["source_ref"] == "knowledge:" <> key)) and
      (not Repo.exists?(from(k in visible_query(scope), where: k.id == ^key)) or
         capacity_omission?(existing, omissions))
  end

  defp allowed_update?(%{id: key, version: version}, proposal, offered, _, _) do
    reference = "knowledge:" <> key

    proposal["target_ref"] == reference and proposal["expected_version"] == version and
      Enum.any?(offered, &(&1["source_ref"] == reference and &1["version"] == version))
  end

  defp allowed_update?(_, _, _, _, _), do: false

  defp capacity_omission?(existing, omissions) do
    expected = %{
      "source_ref" => "knowledge:#{existing.id}",
      "version" => existing.version,
      "topic_key" => existing.topic_key,
      "conversation_ref" => existing.conversation_ref,
      "repository_ref" => existing.repository_ref,
      "reason" => "source_capacity"
    }

    expected in omissions
  end

  defp save_update(existing, scope, scope_key, source, proposal) do
    state = Map.take(proposal, ~w(title summary topics))
    version = if existing, do: existing.version + 1, else: 1
    previous = if existing && proposal["target_ref"], do: existing.source_dependencies, else: []
    dependencies = LearningSources.merge([previous, source.source_dependencies])

    if is_nil(dependencies) do
      :ok
    else
      save_bounded_update(
        existing,
        scope,
        scope_key,
        source,
        proposal,
        state,
        version,
        dependencies
      )
    end
  end

  defp save_bounded_update(
         existing,
         scope,
         scope_key,
         source,
         proposal,
         state,
         version,
         dependencies
       ) do
    generation =
      cond do
        is_nil(existing) -> 1
        is_nil(proposal["target_ref"]) -> existing.source_generation + 1
        true -> existing.source_generation
      end

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
          topic_key: proposal["topic_key"],
          state: state,
          version: version,
          source_generation: generation,
          source_dependencies: dependencies,
          source_input_id: source.source_input_id,
          source_episode_id: source.source_episode_id,
          latest_source_at: source.occurred_at
        }
      )

    item =
      if existing,
        do: existing |> Ecto.Changeset.change(attrs) |> Repo.update!(),
        else:
          Repo.insert!(struct!(ConversationKnowledge, Map.put(attrs, :id, Ecto.UUID.generate())))

    Repo.insert!(
      %KnowledgeSource{
        knowledge_id: item.id,
        generation: generation,
        observation_id: source.id,
        source_revision: source.revision,
        source_fingerprint: source.source_fingerprint,
        source_note: source.note,
        retained_at: source.updated_at,
        introduced_version: version
      },
      on_conflict: :nothing,
      conflict_target: [:knowledge_id, :observation_id, :generation]
    )

    if Repo.exists?(from(k in valid_query(), where: k.id == ^item.id)) do
      Repo.insert!(%KnowledgeRevision{
        knowledge_id: item.id,
        version: version,
        source_generation: generation,
        source_dependencies: dependencies,
        state: state,
        source_input_id: source.source_input_id,
        source_result_ref: source.source_result_ref,
        source_at: source.occurred_at,
        inserted_at: DateTime.utc_now()
      })

      :ok
    else
      @stale
    end
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
          where: s.knowledge_id in ^ids,
          order_by: [asc: o.id],
          lock: "FOR SHARE",
          select: {s.knowledge_id, o.updated_at}
        )
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    # READ COMMITTED can observe an edit while waiting for the source locks.
    # Recheck after acquiring them; a pre-lock eligibility test is not a receipt.
    valid_ids =
      Repo.all(from(k in valid_query(), where: k.id in ^ids, select: k.id)) |> MapSet.new()

    items =
      Enum.filter(
        items,
        &(MapSet.member?(valid_ids, &1.id) and
            LearningSources.valid?(&1.source_dependencies, scope))
      )

    Enum.map(items, fn item ->
      dates = Map.fetch!(sources, item.id)

      expires =
        case retention_seconds() do
          nil ->
            nil

          seconds ->
            dates
            |> Enum.min_by(&DateTime.to_unix(&1, :microsecond))
            |> then(&LearningSources.oldest(item.source_dependencies, &1))
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
        "latest_source_at" => DateTime.to_iso8601(item.latest_source_at),
        "expires_at" => expires
      })
    end)
  end

  defp within_scope(query, _, "workspace"), do: query

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
    settings = Application.get_env(:responder, :retention) || %{}

    value =
      if is_list(settings),
        do: Keyword.get(settings, :conversation_memory_seconds),
        else: Map.get(settings, :conversation_memory_seconds)

    if is_integer(value) and value > 0, do: value
  end
end
