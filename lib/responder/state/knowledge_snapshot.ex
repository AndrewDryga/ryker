defmodule Responder.State.KnowledgeSnapshot do
  @moduledoc "Reauthorize the sources of an exact retained knowledge revision used by Work."
  import Ecto.Query
  alias Responder.Repo

  alias Responder.State.{
    ConversationKnowledge,
    ConversationObservation,
    DerivedContext,
    KnowledgeExposure,
    KnowledgeRevision,
    KnowledgeSource,
    LearningSources,
    Observations,
    SourceExposure
  }

  @stale {:error, :work_knowledge_context_stale}

  def authorize_session(destination, session) do
    case Repo.transaction(fn -> session_valid?(destination, session) end) do
      {:ok, true} -> :ok
      _ -> @stale
    end
  end

  @doc "Record every knowledge revision disclosed to this exact native session, without copying its text."
  def expose(%{episode: destination, session: session, turn: turn}, documents) do
    case Repo.transaction(fn -> expose_locked(destination, session, turn, documents) end) do
      {:ok, :ok} -> :ok
      {:error, :work_derived_context_busy} = error -> error
      {:error, :work_memory_source_capacity_exceeded} = error -> error
      {:error, _} -> @stale
    end
  end

  defp expose_locked(destination, session, turn, documents) do
    # Serialize tool disclosure with result acceptance and session replacement.
    current =
      Repo.one!(from(s in Responder.Work.Session, where: s.id == ^session.id, lock: "FOR UPDATE"))

    unless exposure_counts_valid?(current, false),
      do: Repo.rollback(:work_knowledge_context_stale)

    {knowledge, sources, inherited} =
      document_context!(destination, session.repository_ref, documents)

    # Each search page is bounded, but all pages share one retained transcript.
    # Check its union under the same session lock before disclosing new text.
    # Re-reading an existing root costs no extra capacity or retained lifetime.
    if is_list(sources) and is_nil(LearningSources.merge([session_sources(session.id), sources])),
      do: Repo.rollback(:work_memory_source_capacity_exceeded)

    with true <- turn.session_id == session.id,
         true <- session_valid?(destination, session),
         :ok <- reauthorize(destination, session.repository_ref, knowledge),
         references <- lock_dependency_heads!(sources),
         true <- sources_valid?(destination, session.repository_ref, sources) do
      Enum.each(references, &record_knowledge(&1, session, turn))
      record_inherited_knowledge(inherited, session, turn)
      record_sources(LearningSources.expand(sources), session)
      attest_exposure_counts(current)
      :ok
    else
      _ -> Repo.rollback(:work_knowledge_context_stale)
    end
  end

  @doc "Within the owning transaction, resolve proven Responder-accounted disclosure custody."
  def producer_sources(destination, session) do
    if Repo.in_transaction?(), do: locked_producer_sources(destination, session)
  end

  defp locked_producer_sources(destination, session) do
    # The receiver may already hold its UPDATE lock. Never wait on another
    # producer here: reciprocal historical reads must yield, not deadlock.
    current =
      Repo.one(
        from(s in Responder.Work.Session,
          where: s.id == ^session.id,
          lock: "FOR SHARE SKIP LOCKED"
        )
      )

    case current do
      nil ->
        if Repo.exists?(from(s in Responder.Work.Session, where: s.id == ^session.id)),
          do: {:error, :work_derived_context_busy}

      current ->
        receiving_scope = %{current | repository_ref: session.repository_ref}

        if exposure_counts_valid?(current, true) and
             authorize_session(destination, receiving_scope) == :ok,
           do: session_sources(current.id)
    end
  end

  defp exposure_counts_valid?(
         %{source_exposure_count: nil, knowledge_exposure_count: nil},
         required
       ),
       do: not required

  defp exposure_counts_valid?(session, _required) do
    exposure_counts(session.id) ==
      {session.source_exposure_count, session.knowledge_exposure_count}
  end

  defp exposure_counts(id) do
    {
      Repo.aggregate(from(e in SourceExposure, where: e.session_id == ^id), :count),
      Repo.aggregate(from(e in KnowledgeExposure, where: e.session_id == ^id), :count)
    }
  end

  defp attest_exposure_counts(session) do
    if not is_nil(session.source_exposure_count) or fresh_disclosure_custody?(session.id) do
      {sources, knowledge} = exposure_counts(session.id)

      session
      |> Ecto.Changeset.change(
        source_exposure_count: sources,
        knowledge_exposure_count: knowledge
      )
      |> Repo.update!()
    end
  end

  defp fresh_disclosure_custody?(session_id) do
    # A new read cannot retrospectively attest a pre-custody native transcript.
    # Fresh Work initializes this before submit; old sessions remain unproven.
    not Repo.exists?(
      from(t in Responder.Work.Turn,
        where: t.session_id == ^session_id,
        where: not is_nil(t.coop_turn_id) or not is_nil(t.candidate) or not is_nil(t.result_ref)
      )
    ) and
      not Repo.exists?(
        from(r in Responder.State.Record,
          join: t in Responder.Work.Turn,
          on: t.id == r.turn_id,
          where: t.session_id == ^session_id
        )
      )
  end

  defp document_context!(destination, repository, documents) do
    {derived, ordinary} = Enum.split_with(documents, &DerivedContext.derived?/1)

    case DerivedContext.resolve(derived, destination, repository) do
      {:ok, inherited} ->
        sources =
          LearningSources.merge([
            inherited.sources | Enum.map(ordinary, &LearningSources.document_sources/1)
          ])

        knowledge =
          Enum.filter(
            ordinary,
            &(&1["kind"] == "conversation_knowledge" or
                match?(%{"source_ref" => "knowledge:" <> _}, &1))
          )

        {knowledge, sources, inherited.session_ids}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp record_inherited_knowledge([], _session, _turn), do: :ok

  defp record_inherited_knowledge(ids, session, turn) do
    query =
      from(e in KnowledgeExposure,
        where: e.session_id in ^ids and e.session_id != ^session.id,
        distinct: [e.knowledge_id, e.version],
        select: %{
          session_id: type(^session.id, :binary_id),
          turn_id: type(^turn.id, :binary_id),
          knowledge_id: e.knowledge_id,
          version: e.version,
          inserted_at: fragment("clock_timestamp()")
        }
      )

    Repo.insert_all(KnowledgeExposure, query, on_conflict: :nothing)
  end

  defp lock_dependency_heads!(sources) when is_list(sources) do
    references = Enum.filter(sources, &Map.has_key?(&1, "knowledge_id"))
    ids = references |> Enum.map(& &1["knowledge_id"]) |> Enum.uniq() |> Enum.sort()
    heads = lock_dependency_heads(ids)

    unless Enum.all?(references, &(heads[&1["knowledge_id"]] == &1["generation"])),
      do: Repo.rollback(:work_knowledge_context_stale)

    references
  end

  defp lock_dependency_heads!(_), do: Repo.rollback(:work_knowledge_context_stale)

  defp lock_dependency_heads([]), do: %{}

  defp lock_dependency_heads(ids) do
    # Summaries and rollups can inherit a topic without showing its document.
    # Retain that generation boundary as well as the expanded raw roots. Do not
    # wait while holding earlier session/topic locks: a concurrent rebuild yields.
    heads =
      Repo.all(
        from(k in ConversationKnowledge,
          where: k.id in ^ids,
          order_by: [asc: k.id],
          select: {k.id, k.source_generation},
          lock: "FOR SHARE SKIP LOCKED"
        )
      )
      |> Map.new()

    missing = Enum.reject(ids, &Map.has_key?(heads, &1))

    if missing != [] do
      reason =
        if Repo.exists?(from(k in ConversationKnowledge, where: k.id in ^missing)),
          do: :work_derived_context_busy,
          else: :work_knowledge_context_stale

      Repo.rollback(reason)
    end

    heads
  end

  defp record_knowledge(reference, session, turn) do
    Repo.insert!(
      %KnowledgeExposure{
        session_id: session.id,
        turn_id: turn.id,
        knowledge_id: reference["knowledge_id"],
        version: reference["through_version"],
        inserted_at: DateTime.utc_now()
      },
      on_conflict: :nothing
    )
  end

  defp record_sources([], _session), do: :ok

  defp record_sources(receipts, session) do
    ids = receipts |> Enum.map(& &1["observation_id"]) |> Enum.uniq()

    existing =
      Repo.all(
        from(e in SourceExposure,
          where: e.session_id == ^session.id and e.observation_id in ^ids
        )
      )
      |> Map.new(&{{&1.observation_id, &1.source_input_id}, &1.receipt})

    # The parent session is locked. Preserve earliest custody, skip unchanged
    # rows, and batch writes instead of making two network round trips per root.
    rows =
      Enum.flat_map(receipts, fn receipt ->
        identity = {receipt["observation_id"], receipt["source_input_id"]}
        previous = existing[identity]

        earliest = earliest_receipt!(previous, receipt)

        if earliest == previous,
          do: [],
          else: [
            %{
              session_id: session.id,
              observation_id: elem(identity, 0),
              source_input_id: elem(identity, 1),
              receipt: earliest
            }
          ]
      end)

    rows
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      Repo.insert_all(SourceExposure, chunk,
        on_conflict: {:replace, [:receipt]},
        conflict_target: [:session_id, :observation_id, :source_input_id]
      )
    end)
  end

  defp earliest_receipt!(nil, receipt), do: receipt

  defp earliest_receipt!(previous, receipt) do
    case LearningSources.merge([[previous], [receipt]]) do
      [value] -> value
      _ -> Repo.rollback(:work_knowledge_context_stale)
    end
  end

  def session_sources(session_id) do
    sources =
      Repo.all(
        from(e in SourceExposure,
          where: e.session_id == ^session_id,
          select: e.receipt,
          limit: 10_001
        )
      )

    LearningSources.merge([sources])
  end

  @doc "Retain a handover's exact raw and topic-generation custody within result acceptance."
  def summary_sources(session_id) do
    session = Repo.get(Responder.Work.Session, session_id)

    if (Repo.in_transaction?() and session) && exposure_counts_valid?(session, true),
      do: retained_summary_sources(session_id),
      else: {:error, "source_unavailable"}
  end

  defp retained_summary_sources(session_id) do
    with {:ok, references} <- summary_knowledge_references(session_id),
         raw when is_list(raw) <- session_sources(session_id),
         covered when is_list(covered) <- LearningSources.expand(references),
         # Keep compact generations without charging identical raw roots twice.
         # An earlier raw lifetime is not identical and must remain explicit.
         covered = MapSet.new(covered),
         remaining = Enum.reject(raw, &MapSet.member?(covered, &1)),
         sources when is_list(sources) <- LearningSources.merge([references, remaining]) do
      {:ok, sources}
    else
      {:error, _} = error -> error
      _ -> {:error, "source_capacity"}
    end
  end

  defp summary_knowledge_references(session_id) do
    rows =
      Repo.all(
        from(e in KnowledgeExposure,
          left_join: r in KnowledgeRevision,
          on: r.knowledge_id == e.knowledge_id and r.version == e.version,
          where: e.session_id == ^session_id,
          order_by: [asc: e.knowledge_id, asc: e.version],
          select: {e.knowledge_id, r.source_generation, e.version},
          limit: 10_001
        )
      )

    cond do
      length(rows) > 10_000 ->
        {:error, "source_capacity"}

      Enum.any?(rows, fn {_id, generation, _version} -> is_nil(generation) end) ->
        {:error, "source_unavailable"}

      true ->
        {:ok,
         Enum.map(rows, fn {id, generation, version} ->
           LearningSources.knowledge_reference(id, generation, version)
         end)}
    end
  end

  def expose_submission(claim) do
    with :ok <-
           authorize_submission(
             claim.episode,
             claim.session.repository_ref,
             claim.turn.submission
           ) do
      expose(claim, submission_documents(claim.turn.submission))
    end
  end

  defp session_valid?(destination, session) do
    current = Repo.get(Responder.Work.Session, session.id)

    if current && exposure_counts_valid?(current, false),
      do: retained_session_valid?(destination, session),
      else: false
  end

  defp retained_session_valid?(destination, session) do
    query =
      from(e in KnowledgeExposure,
        where: e.session_id == ^session.id,
        order_by: [asc: e.knowledge_id, asc: e.version]
      )

    empty? =
      not Repo.exists?(query) and
        not Repo.exists?(from(e in SourceExposure, where: e.session_id == ^session.id))

    if empty?, do: true, else: session_sources_valid?(destination, session, query)
  end

  defp session_sources_valid?(destination, session, query) do
    case Observations.locked_scope(destination, session.repository_ref) do
      {:ok, scope} ->
        Enum.all?(Repo.stream(query, max_rows: 100), &valid_exposure?(&1, scope)) and
          source_exposures_valid?(session.id, scope)

      _ ->
        false
    end
  end

  defp source_exposures_valid?(session_id, scope) do
    from(e in SourceExposure,
      where: e.session_id == ^session_id,
      order_by: [asc: e.observation_id],
      select: e.receipt
    )
    |> Repo.stream(max_rows: 500)
    # Even maximum-size receipts fit the 8 MiB validation budget in these batches.
    # Check the whole transcript without reverting to per-root round trips.
    |> Stream.chunk_every(500)
    |> Enum.all?(fn receipts ->
      LearningSources.valid?(LearningSources.merge([receipts]), scope)
    end)
  end

  def authorize_submission(destination, repository, submission) do
    documents = submission_documents(submission)

    case Repo.transaction(fn ->
           {knowledge, sources, _inherited} =
             document_context!(destination, repository, documents)

           reauthorize(destination, repository, knowledge) == :ok and
             sources_valid?(destination, repository, sources)
         end) do
      {:ok, true} -> :ok
      {:error, :work_derived_context_busy} = error -> error
      _ -> @stale
    end
  end

  defp sources_valid?(_destination, _repository, []), do: true

  defp sources_valid?(destination, repository, sources) do
    case Observations.locked_scope(destination, repository) do
      {:ok, scope} -> LearningSources.valid?(sources, scope)
      _ -> false
    end
  end

  defp submission_documents(submission) do
    briefing = (submission || %{})["context"] || %{}
    context = get_in(briefing, ["operator_context", "continuity"]) || %{}

    memory =
      [context["current"]] ++
        Enum.flat_map(~w(related rollups knowledge observations), &(context[&1] || []))

    (work_input_documents(briefing) ++ memory ++ DerivedContext.submission_documents(briefing))
    |> Enum.reject(&is_nil/1)
  end

  defp work_input_documents(briefing) do
    ((get_in(briefing, ["inputs", "items"]) || []) ++
       (get_in(briefing, ["current_inputs", "items"]) || []) ++
       [get_in(briefing, ["continuity", "first_input"])])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&%{"kind" => "work_input", "input" => &1})
  end

  defp valid_exposure?(exposure, scope) do
    with %{} = head <- Repo.get(ConversationKnowledge, exposure.knowledge_id),
         %{} = revision <-
           Repo.get_by(KnowledgeRevision,
             knowledge_id: exposure.knowledge_id,
             version: exposure.version
           ) do
      count =
        Repo.one(
          from(s in KnowledgeSource,
            where:
              s.knowledge_id == ^head.id and s.generation == ^revision.source_generation and
                s.introduced_version <= ^revision.version and
                s.direct_support_version <= ^revision.version,
            select: count(s.observation_id, :distinct)
          )
        )

      document =
        Map.merge(revision.state, %{
          "source_ref" => "knowledge:#{head.id}",
          "version" => revision.version,
          "topic_key" => head.topic_key,
          "conversation_ref" => head.conversation_ref,
          "repository_ref" => head.repository_ref,
          "source_count" => count
        })

      valid_document?(document, scope)
    else
      _ -> false
    end
  end

  def reauthorize(_destination, _repository, []), do: :ok

  def reauthorize(destination, repository, documents)
      when is_list(documents) and length(documents) <= 32 do
    case Repo.transaction(fn -> reauthorize_locked(destination, repository, documents) end) do
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

  defp reauthorize_locked(destination, repository, documents) do
    case Observations.locked_scope(destination, repository) do
      {:ok, scope} -> Enum.all?(documents, &valid_document?(&1, scope))
      _ -> false
    end
  end

  defp valid_document?(
         %{"source_ref" => "knowledge:" <> id, "version" => version} = document,
         scope
       )
       when is_integer(version) and version > 0 do
    allowed = Observations.visible_conversations(scope)

    with {:ok, ^id} <- Ecto.UUID.cast(id),
         %{} = head <-
           Repo.one(
             from(k in ConversationKnowledge,
               where: k.id == ^id and k.workspace_ref == ^scope.workspace_ref,
               where: ^allowed,
               lock: "FOR SHARE"
             )
           ),
         [_] <- Observations.authorized_notes([head], scope),
         %{} = revision <-
           Repo.one(
             from(r in KnowledgeRevision,
               where: r.knowledge_id == ^id and r.version == ^version,
               lock: "FOR SHARE"
             )
           ),
         true <- revision.source_generation == head.source_generation,
         true <- revision.state["retention"] != "pruned",
         true <- revision.state == Map.take(document, ~w(title summary topics anchors)),
         true <- LearningSources.valid?(revision.source_dependencies, scope) do
      sources =
        Repo.all(
          from(s in KnowledgeSource,
            where:
              s.knowledge_id == ^id and s.generation == ^revision.source_generation and
                s.introduced_version <= ^version and s.direct_support_version <= ^version,
            order_by: [asc: s.observation_id],
            lock: "FOR SHARE"
          )
        )
        |> Enum.uniq_by(& &1.observation_id)

      valid_sources?(sources, document, head)
    else
      _ -> false
    end
  end

  defp valid_document?(_, _), do: false

  defp valid_sources?([], _, _), do: false

  defp valid_sources?(sources, document, head) do
    ids = Enum.map(sources, & &1.observation_id)

    observations =
      Repo.all(
        from(o in ConversationObservation,
          where: o.id in ^ids,
          order_by: [asc: o.id],
          lock: "FOR SHARE"
        )
      )
      |> Map.new(&{&1.id, &1})

    document["topic_key"] == head.topic_key and
      document["conversation_ref"] == head.conversation_ref and
      document["repository_ref"] == head.repository_ref and
      document["source_count"] == length(sources) and
      Enum.all?(sources, &source_valid?(&1, observations[&1.observation_id], head))
  end

  defp source_valid?(_source, nil, _head), do: false

  defp source_valid?(source, observation, head) do
    source.source_revision == observation.revision and
      source.source_fingerprint == observation.source_fingerprint and
      observation.conversation_ref == head.conversation_ref and
      observation.workspace_ref == head.workspace_ref and
      observation.repository_ref == head.repository_ref and
      unexpired?(source.retained_at)
  end

  defp unexpired?(at) do
    settings = Application.get_env(:responder, :retention) || %{}

    seconds =
      if is_list(settings),
        do: Keyword.get(settings, :conversation_memory_seconds),
        else: Map.get(settings, :conversation_memory_seconds)

    case seconds do
      seconds when is_integer(seconds) and seconds > 0 ->
        %{rows: [[valid]]} =
          Repo.query!("SELECT $1::timestamptz > clock_timestamp() - ($2 * interval '1 second')", [
            at,
            seconds
          ])

        valid

      _ ->
        true
    end
  end
end
