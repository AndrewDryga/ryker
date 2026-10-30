defmodule Ryker.Knowledge.KnowledgeSnapshot do
  @moduledoc "Reauthorize the sources of an exact retained knowledge revision used by Work."
  alias Ryker.Behaviors
  alias Ryker.Episodes
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Knowledge.KnowledgeExposure
  alias Ryker.Knowledge.KnowledgeRevision
  alias Ryker.Knowledge.KnowledgeSource
  alias Ryker.Learning
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Work

  @stale {:error, :work_knowledge_context_stale}

  def authorize_session(%Episodes.Episode{} = destination, %Work.Session{} = session) do
    case Repo.transaction(fn -> authorize_retained_session(destination, session) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, :work_derived_context_busy}} -> {:error, :work_derived_context_busy}
      {:error, :work_derived_context_busy} -> {:error, :work_derived_context_busy}
      _ -> @stale
    end
  end

  def authorize_session(_destination, _session), do: @stale

  @doc "A source edit may annotate an existing reply; it never makes old context reusable."
  def edited_sources_visible?(%Episodes.Episode{} = destination, %Work.Session{} = session) do
    with true <- Repo.in_transaction?(),
         true <- exposure_counts_attested?(session),
         true <- session.environment_ref == Work.EnvironmentContext.ref(destination),
         :ok <- Behaviors.GuidanceSnapshot.authorize_session(destination, session),
         :ok <- Work.PersonalizationSnapshot.authorize_session(destination, session),
         {:ok, scope} <-
           Learning.Observations.fetch_and_lock_scope(destination, session.repository_ref) do
      sources = session_sources(session.id)
      Learning.LearningSources.edited_sources_visible?(sources, scope)
    else
      _ -> false
    end
  end

  def edited_sources_visible?(_destination, _session), do: false

  @doc "Record an explicit read's source custody for this exact native session, without copying its text."
  def expose(claim, documents), do: expose_documents(claim, documents, :explicit)

  defp expose_documents(
         %{
           episode: %Episodes.Episode{} = destination,
           session: %Work.Session{} = session,
           turn: %Work.Turn{} = turn
         },
         documents,
         kind
       ) do
    case Repo.transaction(fn -> expose_locked(destination, session, turn, documents, kind) end) do
      {:ok, :ok} ->
        :ok

      {:error, :work_derived_context_busy} ->
        {:error, :work_derived_context_busy}

      {:error, :work_memory_source_capacity_exceeded} ->
        {:error, :work_memory_source_capacity_exceeded}

      {:error, _} ->
        @stale
    end
  end

  defp expose_documents(_claim, _documents, _kind), do: @stale

  defp expose_locked(
         %Episodes.Episode{} = destination,
         %Work.Session{} = session,
         %Work.Turn{} = turn,
         documents,
         kind
       ) do
    # Serialize tool disclosure with result acceptance and session replacement.
    current =
      session.id
      |> Work.Session.Query.by_id()
      |> Work.Session.Query.lock_for_update()
      |> Repo.fetch!()

    unless exposure_counts_consistent?(current),
      do: Repo.rollback(:work_knowledge_context_stale)

    context = document_context!(destination, current, documents)

    # Each search page is bounded, but all pages share one retained transcript.
    # Check its union under the same session lock before disclosing new text.
    # Re-reading an existing root costs no extra capacity or retained lifetime.
    if is_list(context.sources) and
         is_nil(Learning.LearningSources.merge([session_sources(session.id), context.sources])),
       do: Repo.rollback(:work_memory_source_capacity_exceeded)

    with true <- turn.session_id == session.id,
         :ok <- authorize_retained_session(destination, session),
         :ok <- still_valid(destination, session.repository_ref, context.knowledge),
         references <- fetch_and_lock_dependency_heads!(context.sources),
         {:ok, custody} <-
           validated_disclosures(destination, session.repository_ref, context),
         {:ok, automatic} <- automatic_sources(context, current, kind),
         {:ok, guidance} <-
           Behaviors.GuidanceSnapshot.authorize(context.guidance, destination, current, kind),
         {:ok, personalization} <-
           Work.PersonalizationSnapshot.authorize(turn.submission, destination, current, kind) do
      Enum.each(references, &record_knowledge(&1, session, turn))
      record_inherited_knowledge(context.inherited, session, turn)
      record_sources(custody.roots, session, custody.input_only, automatic)
      inherit_automatic_sources(context.inherited, current)
      Behaviors.GuidanceSnapshot.retain!(current, guidance, context.inherited)
      Work.PersonalizationSnapshot.retain!(current, personalization, context.inherited)
      attest_exposure_counts(current)
      # What a run was shown is part of its request's record.
      Ryker.Episodes.broadcast_episode_updated(session.episode_id)
      Enum.each(references, &Ryker.Knowledge.broadcast_knowledge_updated(&1["knowledge_id"]))
    else
      {:error, :work_derived_context_busy} -> Repo.rollback(:work_derived_context_busy)
      _ -> Repo.rollback(:work_knowledge_context_stale)
    end
  end

  defp expose_locked(_destination, _session, _turn, _documents, _kind),
    do: Repo.rollback(:work_knowledge_context_stale)

  @doc """
  Within the owning transaction, resolve proven disclosure custody for an
  exact receiver. Own-session records use its already authorized transcript;
  another receiver, including nil for a historical read, requires unforgotten roots.
  """
  def producer_sources(%Episodes.Episode{} = destination, %Work.Session{} = session, receiver)
      when is_struct(receiver, Work.Session) or is_nil(receiver) do
    if Repo.in_transaction?(), do: fetch_and_lock_producer_sources(destination, session, receiver)
  end

  def producer_sources(_destination, _session, _receiver), do: nil

  defp fetch_and_lock_producer_sources(
         %Episodes.Episode{} = destination,
         %Work.Session{} = session,
         receiver
       )
       when is_struct(receiver, Work.Session) or is_nil(receiver) do
    # The receiver may already hold its UPDATE lock. Never wait on another
    # producer here: reciprocal historical reads must yield, not deadlock.
    current =
      session.id
      |> Work.Session.Query.by_id()
      |> Work.Session.Query.lock_for_share_skip_locked()
      |> Repo.fetch()

    case current do
      {:error, :not_found} ->
        if Repo.exists?(Work.Session.Query.by_id(session.id)),
          do: {:error, :work_derived_context_busy}

      {:ok, current} ->
        authorized_producer_sources(destination, current, session.repository_ref, receiver)
    end
  end

  defp fetch_and_lock_producer_sources(_destination, _session, _receiver), do: nil

  defp authorized_producer_sources(
         %Episodes.Episode{} = destination,
         %Work.Session{} = session,
         repository,
         receiver
       )
       when is_struct(receiver, Work.Session) or is_nil(receiver) do
    receiving_scope = %{session | repository_ref: repository}
    sources = session_sources(session.id)

    receiving =
      session.episode_id == destination.id and Work.Session.same_identity?(session, receiver)

    with true <- exposure_counts_attested?(session),
         :ok <- authorize_retained_session(destination, receiving_scope),
         true <- receiving or sources_valid?(destination, repository, sources) do
      sources
    else
      {:error, :work_derived_context_busy} -> {:error, :work_derived_context_busy}
      _ -> nil
    end
  end

  defp authorized_producer_sources(_destination, _session, _repository, _receiver), do: nil

  # A session created before exposure counts were attested carries none; a
  # disclosure or a validity check tolerates that, a handover or a source read
  # does not.
  defp exposure_counts_consistent?(%{source_exposure_count: nil, knowledge_exposure_count: nil}),
    do: true

  defp exposure_counts_consistent?(session), do: exposure_counts_attested?(session)

  defp exposure_counts_attested?(%{source_exposure_count: nil, knowledge_exposure_count: nil}),
    do: false

  defp exposure_counts_attested?(session) do
    exposure_counts(session.id) ==
      {session.source_exposure_count, session.knowledge_exposure_count}
  end

  defp exposure_counts(id) do
    {
      Repo.aggregate(Learning.SourceExposure.Query.by_session_id(id), :count),
      Repo.aggregate(KnowledgeExposure.Query.by_session_id(id), :count)
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
    begun = session_id |> Work.Turn.Query.by_session_id() |> Work.Turn.Query.begun()
    not Repo.exists?(begun) and not Repo.exists?(Records.Record.Query.by_session_id(session_id))
  end

  defp document_context!(%Episodes.Episode{} = destination, %Work.Session{} = session, documents) do
    {derived, ordinary} = Enum.split_with(documents, &Records.DerivedContext.derived?/1)
    {guidance, ordinary} = Enum.split_with(ordinary, &(&1["kind"] == "guidance"))
    {inputs, memory_documents} = Enum.split_with(ordinary, &(&1["kind"] == "work_input"))

    case Records.DerivedContext.resolve(derived, destination, session.repository_ref, session) do
      {:ok, inherited} ->
        inputs =
          inputs
          |> Enum.map(&Learning.LearningSources.document_sources/1)
          |> Learning.LearningSources.merge()

        direct_memories =
          memory_documents
          |> Enum.map(&Learning.LearningSources.document_sources/1)
          |> Learning.LearningSources.merge()

        memories = Learning.LearningSources.merge([inherited.sources, direct_memories])

        sources = Learning.LearningSources.merge([inputs, memories])

        knowledge =
          Enum.filter(
            ordinary,
            &(&1["kind"] == "conversation_knowledge" or
                match?(%{"source_ref" => "knowledge:" <> _}, &1))
          )

        %{
          guidance: guidance,
          knowledge: knowledge,
          sources: sources,
          inherited: inherited.session_ids,
          inputs: inputs,
          memories: memories,
          memory_documents: memory_documents,
          direct_memories: direct_memories
        }

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp document_context!(_destination, _session, _documents),
    do: Repo.rollback(:work_knowledge_context_stale)

  defp record_inherited_knowledge([], _session, _turn), do: :ok

  defp record_inherited_knowledge(ids, session, turn) do
    query = KnowledgeExposure.Query.inherited_by(ids, session.id, turn.id)
    Repo.insert_all(KnowledgeExposure, query, on_conflict: :nothing)
  end

  defp inherit_automatic_sources([], %Work.Session{}), do: :ok

  defp inherit_automatic_sources(ids, %Work.Session{} = session) do
    # The receiver holds UPDATE and its producers SHARE. Copy only the role
    # onto roots already validated and retained, never renew their receipts.
    query =
      session.id
      |> Learning.SourceExposure.Query.by_session_id()
      |> Learning.SourceExposure.Query.with_joined_automatic_sources(ids)

    Repo.update_all(query, set: [automatic_context: true, input_only: false])
    :ok
  end

  defp inherit_automatic_sources(_ids, _session),
    do: Repo.rollback(:work_knowledge_context_stale)

  defp fetch_and_lock_dependency_heads!(sources) when is_list(sources) do
    references = Enum.filter(sources, &Map.has_key?(&1, "knowledge_id"))
    ids = references |> Enum.map(& &1["knowledge_id"]) |> Enum.uniq() |> Enum.sort()
    heads = fetch_and_lock_dependency_heads(ids)

    unless Enum.all?(references, &(heads[&1["knowledge_id"]] == &1["generation"])),
      do: Repo.rollback(:work_knowledge_context_stale)

    references
  end

  defp fetch_and_lock_dependency_heads!(_), do: Repo.rollback(:work_knowledge_context_stale)

  defp fetch_and_lock_dependency_heads([]), do: %{}

  defp fetch_and_lock_dependency_heads(ids) do
    # Summaries and rollups can inherit a topic without showing its document.
    # Retain that generation boundary as well as the expanded raw roots. Do not
    # wait while holding earlier session/topic locks: a concurrent rebuild yields.
    heads =
      ids
      |> ConversationKnowledge.Query.by_ids()
      |> ConversationKnowledge.Query.ordered_by_id()
      |> ConversationKnowledge.Query.select_id_generations()
      |> ConversationKnowledge.Query.lock_for_share_skip_locked()
      |> Repo.all()
      |> Map.new(&{&1.id, &1.source_generation})

    missing = Enum.reject(ids, &Map.has_key?(heads, &1))

    if missing != [] do
      reason =
        if Repo.exists?(ConversationKnowledge.Query.by_ids(missing)),
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
        inserted_at: Repo.now!()
      },
      on_conflict: :nothing
    )
  end

  defp record_sources([], %Work.Session{}, %MapSet{}, %MapSet{}), do: :ok

  defp record_sources(
         receipts,
         %Work.Session{} = session,
         %MapSet{} = input_only,
         %MapSet{} = automatic
       ) do
    ids = receipts |> Enum.map(& &1["observation_id"]) |> Enum.uniq()

    existing =
      session.id
      |> Learning.SourceExposure.Query.by_session_id()
      |> Learning.SourceExposure.Query.by_observation_ids(ids)
      |> Repo.all()
      |> Map.new(&{{&1.observation_id, &1.source_input_id}, &1})

    # The parent session is locked. Preserve earliest custody, skip unchanged
    # rows, and batch writes instead of making two network round trips per root.
    rows =
      Enum.flat_map(receipts, fn receipt ->
        identity = {receipt["observation_id"], receipt["source_input_id"]}
        previous = existing[identity]
        previous_receipt = if previous, do: previous.receipt
        earliest = earliest_receipt!(previous_receipt, receipt)

        input_source = MapSet.member?(input_only, identity)
        automatic_source = MapSet.member?(automatic, identity)
        {only_input, automatic_context} = exposure_roles(previous, input_source, automatic_source)

        if not is_nil(previous) and earliest == previous.receipt and
             only_input == previous.input_only and automatic_context == previous.automatic_context,
           do: [],
           else: [
             %{
               session_id: session.id,
               observation_id: elem(identity, 0),
               source_input_id: elem(identity, 1),
               receipt: earliest,
               input_only: only_input,
               automatic_context: automatic_context
             }
           ]
      end)

    rows
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      Repo.insert_all(Learning.SourceExposure, chunk,
        on_conflict: {:replace, [:receipt, :input_only, :automatic_context]},
        conflict_target: [:session_id, :observation_id, :source_input_id]
      )
    end)
  end

  defp record_sources(_receipts, _session, _input_only, _automatic),
    do: Repo.rollback(:work_knowledge_context_stale)

  defp exposure_roles(nil, input_source, automatic_source),
    do: {input_source and not automatic_source, automatic_source}

  defp exposure_roles(%Learning.SourceExposure{} = exposure, input_source, automatic_source) do
    automatic_context = automatic_source or exposure.automatic_context
    {input_source and exposure.input_only and not automatic_context, automatic_context}
  end

  defp exposure_roles(_exposure, _input_source, _automatic_source), do: {false, true}

  defp earliest_receipt!(nil, receipt), do: receipt

  defp earliest_receipt!(previous, receipt) do
    case Learning.LearningSources.merge([[previous], [receipt]]) do
      [value] -> value
      _ -> Repo.rollback(:work_knowledge_context_stale)
    end
  end

  @doc """
  The sources work in session `session_id` was shown, merged, or nil when
  they are more than one context may carry.
  """
  def session_sources(session_id) do
    sources =
      session_id
      |> Learning.SourceExposure.Query.by_session_id()
      |> Learning.SourceExposure.Query.select_receipts()
      |> Learning.SourceExposure.Query.limit_to(10_001)
      |> Repo.all()

    Learning.LearningSources.merge([sources])
  end

  @doc "Retain a handover's exact raw and topic-generation custody within result acceptance."
  def summary_sources(session_id) do
    session = Repo.peek(Work.Session.Query.by_id(session_id))

    if (Repo.in_transaction?() and session) && exposure_counts_attested?(session),
      do: retained_summary_sources(session_id),
      else: {:error, "source_unavailable"}
  end

  defp retained_summary_sources(session_id) do
    with {:ok, references} <- summary_knowledge_references(session_id),
         raw when is_list(raw) <- session_sources(session_id),
         covered when is_list(covered) <- Learning.LearningSources.expand(references),
         # Keep compact generations without charging identical raw roots twice.
         # An earlier raw lifetime is not identical and must remain explicit.
         covered = MapSet.new(covered),
         remaining = Enum.reject(raw, &MapSet.member?(covered, &1)),
         sources when is_list(sources) <- Learning.LearningSources.merge([references, remaining]) do
      {:ok, sources}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "source_capacity"}
    end
  end

  defp summary_knowledge_references(session_id) do
    rows =
      session_id
      |> KnowledgeExposure.Query.generations_by_session_id()
      |> KnowledgeExposure.Query.limit_to(10_001)
      |> Repo.all()

    cond do
      length(rows) > 10_000 ->
        {:error, "source_capacity"}

      Enum.any?(rows, fn {_id, generation, _version} -> is_nil(generation) end) ->
        {:error, "source_unavailable"}

      true ->
        {:ok,
         Enum.map(rows, fn {id, generation, version} ->
           Learning.LearningSources.knowledge_reference(id, generation, version)
         end)}
    end
  end

  @doc "Authorize and retain automatic frozen context before disclosing it to a native session."
  def expose_submission(claim) do
    with :ok <-
           authorize_submission(
             claim.episode,
             claim.session,
             claim.turn.submission
           ) do
      documents = submission_documents(claim.turn.submission)
      expose_documents(claim, documents, :submission)
    end
  end

  defp authorize_retained_session(%Episodes.Episode{} = destination, %Work.Session{} = session) do
    query = Work.Session.Query.by_id(session.id)

    with {:ok, %Work.Session{} = current} <- Repo.fetch(query),
         true <- exposure_counts_consistent?(current),
         receiving_session <- %{current | repository_ref: session.repository_ref},
         :ok <- Behaviors.GuidanceSnapshot.authorize_session(destination, receiving_session),
         :ok <- Work.PersonalizationSnapshot.authorize_session(destination, receiving_session),
         true <- retained_session_valid?(destination, receiving_session) do
      :ok
    else
      {:error, :work_derived_context_busy} -> {:error, :work_derived_context_busy}
      _ -> @stale
    end
  end

  defp authorize_retained_session(_destination, _session), do: @stale

  defp retained_session_valid?(destination, session) do
    query =
      session.id
      |> KnowledgeExposure.Query.by_session_id()
      |> KnowledgeExposure.Query.ordered_by_knowledge_and_version()

    empty? =
      not Repo.exists?(query) and
        not Repo.exists?(Learning.SourceExposure.Query.by_session_id(session.id))

    if empty?, do: true, else: session_sources_valid?(destination, session, query)
  end

  defp session_sources_valid?(destination, session, query) do
    case Learning.Observations.fetch_and_lock_scope(destination, session.repository_ref) do
      {:ok, scope} ->
        Enum.all?(Repo.stream(query, max_rows: 100), &valid_exposure?(&1, scope)) and
          source_exposures_valid?(session.id, scope, session.environment_ref)

      _ ->
        false
    end
  end

  defp source_exposures_valid?(session_id, scope, environment_ref) do
    session_id
    |> Learning.SourceExposure.Query.by_session_id()
    |> Learning.SourceExposure.Query.ordered_by_observation()
    |> Repo.stream(max_rows: 500)
    # Even maximum-size receipts fit the 8 MiB validation budget in these batches.
    # Check the whole transcript without reverting to per-root round trips.
    |> Stream.chunk_every(500)
    |> Enum.all?(&exposure_batch_valid?(&1, scope, environment_ref))
  end

  defp exposure_batch_valid?(exposures, scope, environment_ref) do
    {inputs, memories} =
      Enum.split_with(exposures, &(&1.input_only and not &1.automatic_context))

    inputs = Enum.map(inputs, & &1.receipt)
    memories = Enum.map(memories, & &1.receipt)

    automatic =
      exposures
      |> Enum.filter(& &1.automatic_context)
      |> Enum.map(& &1.receipt)

    match?({:ok, _}, Learning.LearningSources.validated_disclosures(inputs, memories, scope)) and
      automatic_environment?(automatic, environment_ref)
  end

  defp automatic_environment?([], _environment_ref), do: true

  defp automatic_environment?(sources, environment_ref),
    do: Learning.LearningSources.in_environment?(sources, environment_ref)

  defp automatic_sources(_context, %Work.Session{}, :explicit),
    do: {:ok, MapSet.new()}

  defp automatic_sources(%{memory_documents: []}, %Work.Session{}, :submission),
    do: {:ok, MapSet.new()}

  defp automatic_sources(context, %Work.Session{} = session, :submission) do
    with true <-
           Enum.all?(context.memory_documents, &automatic_document?(&1, session.environment_ref)),
         true <-
           Learning.LearningSources.in_environment?(
             context.direct_memories,
             session.environment_ref
           ),
         roots when is_list(roots) <- Learning.LearningSources.expand(context.direct_memories) do
      {:ok, MapSet.new(roots, &{&1["observation_id"], &1["source_input_id"]})}
    else
      _ -> :error
    end
  end

  defp automatic_sources(_context, _session, _kind), do: :error

  defp automatic_document?(%{"environment_known" => true, "environment_ref" => ref}, ref),
    do: true

  defp automatic_document?(_document, _environment_ref), do: false

  def authorize_submission(
        %Episodes.Episode{id: episode_id} = destination,
        %Work.Session{episode_id: episode_id} = session,
        submission
      ) do
    documents = submission_documents(submission)

    case Repo.transaction(fn ->
           submission_valid?(destination, session, documents, submission)
         end) do
      {:ok, true} -> :ok
      {:error, :work_derived_context_busy} -> {:error, :work_derived_context_busy}
      _ -> @stale
    end
  end

  def authorize_submission(_destination, _session, _submission), do: @stale

  defp submission_valid?(
         %Episodes.Episode{id: episode_id} = destination,
         %Work.Session{} = session,
         documents,
         submission
       ) do
    query = Work.Session.Query.by_id(session.id)

    with {:ok, %Work.Session{episode_id: ^episode_id} = current} <- Repo.fetch(query),
         context <- document_context!(destination, current, documents),
         :ok <- still_valid(destination, current.repository_ref, context.knowledge),
         {:ok, _custody} <- validated_disclosures(destination, current.repository_ref, context),
         {:ok, _automatic} <- automatic_sources(context, current, :submission),
         {:ok, _guidance} <-
           Behaviors.GuidanceSnapshot.authorize(
             context.guidance,
             destination,
             current,
             :submission
           ),
         {:ok, _personalization} <-
           Work.PersonalizationSnapshot.authorize(submission, destination, current, :submission) do
      true
    else
      {:error, :work_derived_context_busy} -> Repo.rollback(:work_derived_context_busy)
      _ -> false
    end
  end

  defp submission_valid?(_destination, _session, _documents, _submission), do: false

  # Kernel-only work with no source body still accepts its host transition
  # after its channel is deleted; the write fence separately drops its draft.
  defp validated_disclosures(_destination, _repository, %{inputs: [], memories: []}),
    do: {:ok, %{roots: [], input_only: MapSet.new()}}

  defp validated_disclosures(destination, repository, context) do
    case Learning.Observations.fetch_and_lock_scope(destination, repository) do
      {:ok, scope} ->
        Learning.LearningSources.validated_disclosures(context.inputs, context.memories, scope)

      _ ->
        :error
    end
  end

  defp sources_valid?(_destination, _repository, []), do: true

  defp sources_valid?(destination, repository, sources) do
    case Learning.Observations.fetch_and_lock_scope(destination, repository) do
      {:ok, scope} -> Learning.LearningSources.valid?(sources, scope)
      _ -> false
    end
  end

  defp submission_documents(submission) do
    briefing = (submission || %{})["context"] || %{}
    context = get_in(briefing, ["operator_context", "continuity"]) || %{}

    memory =
      [context["current"]] ++
        Enum.flat_map(~w(related rollups knowledge observations), &(context[&1] || []))

    guidance = get_in(briefing, ["operator_context", "guidance"]) || []

    (work_input_documents(briefing) ++
       guidance ++ memory ++ Records.DerivedContext.submission_documents(briefing))
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
    revision_query =
      exposure.knowledge_id
      |> KnowledgeRevision.Query.by_knowledge_id()
      |> KnowledgeRevision.Query.by_version(exposure.version)

    with {:ok, head} <- Repo.fetch(ConversationKnowledge.Query.by_id(exposure.knowledge_id)),
         {:ok, revision} <- Repo.fetch(revision_query) do
      count =
        head.id
        |> KnowledgeSource.Query.by_generation(revision.source_generation)
        |> KnowledgeSource.Query.direct_through(revision.version)
        |> KnowledgeSource.Query.select_observation_count()
        |> Repo.one()

      document =
        Map.merge(revision.state, %{
          "source_ref" => "knowledge:#{head.id}",
          "version" => revision.version,
          "topic_key" => head.topic_key,
          "conversation_ref" => head.conversation_ref,
          "repository_ref" => head.repository_ref,
          "environment_ref" => head.environment_ref,
          "environment_known" => head.environment_known,
          "source_count" => count
        })

      valid_document?(document, scope)
    else
      _ -> false
    end
  end

  @doc """
  Whether each topic version in `documents` is still valid for `destination`:
  visible, of the generation it was learned in, not pruned, and resting on
  sources nobody forgot or edited. A Work session keeps a version it saw while
  that holds, even after a newer one; routing and learning need the current
  one (`Knowledge.still_current/3`).
  """
  def still_valid(_destination, _repository, []), do: :ok

  def still_valid(destination, repository, documents)
      when is_list(documents) and length(documents) <= 32 do
    case Repo.transaction(fn -> valid_locked?(destination, repository, documents) end) do
      {:ok, true} -> :ok
      _ -> @stale
    end
  rescue
    error in Postgrex.Error ->
      if Repo.conflict?(error), do: @stale, else: reraise(error, __STACKTRACE__)
  end

  def still_valid(_, _, _), do: @stale

  defp valid_locked?(destination, repository, documents) do
    case Learning.Observations.fetch_and_lock_scope(destination, repository) do
      {:ok, scope} -> Enum.all?(documents, &valid_document?(&1, scope))
      _ -> false
    end
  end

  defp valid_document?(
         %{"source_ref" => "knowledge:" <> id, "version" => version} = document,
         scope
       )
       when is_integer(version) and version > 0 do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, head} <- Repo.fetch(visible_head(id, scope)),
         [_] <- Learning.Observations.authorized_notes([head], scope),
         {:ok, revision} <- Repo.fetch(shared_revision(id, version)),
         true <- revision.source_generation == head.source_generation,
         true <- revision.state["retention"] != "pruned",
         true <- revision.state == Map.take(document, ~w(title summary topics anchors)),
         true <- Learning.LearningSources.valid?(revision.source_dependencies, scope) do
      sources =
        id
        |> KnowledgeSource.Query.by_generation(revision.source_generation)
        |> KnowledgeSource.Query.direct_through(version)
        |> KnowledgeSource.Query.ordered_by_observation()
        |> KnowledgeSource.Query.lock_for_share()
        |> Repo.all()
        |> Enum.uniq_by(& &1.observation_id)

      valid_sources?(sources, document, head)
    else
      _ -> false
    end
  end

  defp valid_document?(_, _), do: false

  defp visible_head(id, scope) do
    id
    |> ConversationKnowledge.Query.by_id()
    |> ConversationKnowledge.Query.by_workspace_ref(scope.workspace_ref)
    |> Learning.Visibility.Query.visible_from(scope)
    |> ConversationKnowledge.Query.lock_for_share()
  end

  defp shared_revision(id, version) do
    id
    |> KnowledgeRevision.Query.by_knowledge_id()
    |> KnowledgeRevision.Query.by_version(version)
    |> KnowledgeRevision.Query.lock_for_share()
  end

  defp valid_sources?([], _, _), do: false

  defp valid_sources?(sources, document, head) do
    ids = Enum.map(sources, & &1.observation_id)

    observations =
      ids
      |> Learning.ConversationObservation.Query.by_ids()
      |> Learning.ConversationObservation.Query.ordered_by_id()
      |> Learning.ConversationObservation.Query.lock_for_share()
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    cutoff = Learning.LearningSources.horizon_cutoff()

    document["topic_key"] == head.topic_key and
      document["conversation_ref"] == head.conversation_ref and
      document["repository_ref"] == head.repository_ref and
      document["environment_ref"] == head.environment_ref and
      document["environment_known"] == head.environment_known and
      document["source_count"] == length(sources) and
      Enum.all?(sources, &source_valid?(&1, observations[&1.observation_id], head, cutoff))
  end

  defp source_valid?(_source, nil, _head, _cutoff), do: false

  # Forgetting keeps a message's revision and fingerprint, so the message stays a
  # valid input Ryker answers; what learning took from it does not. A topic
  # resting on a forgotten message passed this check and an open session kept
  # using it (2026-10-04 review).
  # Each source is judged against one horizon (`LearningSources.horizon_cutoff/0`):
  # every source asked the database on its own, ten queries a topic on every
  # turn (2026-10-04 review).
  defp source_valid?(source, observation, head, cutoff) do
    is_nil(observation.forgotten_at) and source.source_revision == observation.revision and
      source.source_fingerprint == observation.source_fingerprint and
      observation.conversation_ref == head.conversation_ref and
      observation.workspace_ref == head.workspace_ref and
      (is_nil(cutoff) or DateTime.after?(source.retained_at, cutoff))
  end
end
