defmodule Responder.State.KnowledgeSnapshot do
  @moduledoc "Reauthorize the sources of an exact retained knowledge revision used by Work."
  import Ecto.Query
  alias Responder.Repo

  alias Responder.State.{
    ConversationKnowledge,
    ConversationObservation,
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
      {:error, _} -> @stale
    end
  end

  defp expose_locked(destination, session, turn, documents) do
    # Serialize tool disclosure with result acceptance and session replacement.
    Repo.one!(from(s in Responder.Work.Session, where: s.id == ^session.id, lock: "FOR UPDATE"))
    knowledge = Enum.filter(documents, &(&1["kind"] == "conversation_knowledge"))

    sources =
      documents |> Enum.map(&LearningSources.document_sources/1) |> LearningSources.merge()

    with true <- turn.session_id == session.id,
         true <- session_valid?(destination, session),
         :ok <- reauthorize(destination, session.repository_ref, knowledge),
         true <- sources_valid?(destination, session.repository_ref, sources) do
      Enum.each(knowledge, &record_knowledge(&1, session, turn))
      Enum.each(sources, &record_source(&1, session))
      :ok
    else
      _ -> Repo.rollback(:work_knowledge_context_stale)
    end
  end

  defp record_knowledge(document, session, turn) do
    "knowledge:" <> id = document["source_ref"]

    Repo.insert!(
      %KnowledgeExposure{
        session_id: session.id,
        turn_id: turn.id,
        knowledge_id: id,
        version: document["version"],
        inserted_at: DateTime.utc_now()
      },
      on_conflict: :nothing
    )
  end

  defp record_source(receipt, session) do
    identity = [
      session_id: session.id,
      observation_id: receipt["observation_id"],
      source_input_id: receipt["source_input_id"]
    ]

    # The parent session is already locked. Repeated disclosure can shorten, never
    # refresh, the lifetime inherited by this transcript and its later summaries.
    case Repo.get_by(SourceExposure, identity) do
      nil ->
        Repo.insert!(struct!(SourceExposure, [{:receipt, receipt} | identity]))

      existing ->
        case LearningSources.merge([[existing.receipt], [receipt]]) do
          [earliest] -> Repo.update!(Ecto.Changeset.change(existing, receipt: earliest))
          _ -> Repo.rollback(:work_knowledge_context_stale)
        end
    end
  end

  def session_sources(session_id) do
    sources =
      Repo.all(
        from(e in SourceExposure,
          where: e.session_id == ^session_id,
          select: e.receipt,
          limit: 129
        )
      )

    LearningSources.merge([sources])
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
    |> Repo.stream(max_rows: 128)
    # Eight maximum-size scope receipts still fit the per-validation byte budget.
    # This checks the whole transcript; the separate summary budget may skip learning.
    |> Stream.chunk_every(8)
    |> Enum.all?(fn receipts ->
      LearningSources.valid?(LearningSources.merge([receipts]), scope)
    end)
  end

  def authorize_submission(destination, repository, submission) do
    documents = submission_documents(submission)
    knowledge = Enum.filter(documents, &match?(%{"source_ref" => "knowledge:" <> _}, &1))

    sources =
      documents |> Enum.map(&LearningSources.document_sources/1) |> LearningSources.merge()

    with :ok <- reauthorize(destination, repository, knowledge),
         {:ok, true} <-
           Repo.transaction(fn -> sources_valid?(destination, repository, sources) end) do
      :ok
    else
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
    context = get_in(submission || %{}, ["context", "operator_context", "continuity"]) || %{}

    ([context["current"]] ++
       (context["related"] || []) ++
       (context["rollups"] || []) ++
       (context["knowledge"] || []) ++ (context["observations"] || []))
    |> Enum.reject(&is_nil/1)
  end

  defp valid_exposure?(exposure, scope) do
    with %{} = head <- Repo.get(ConversationKnowledge, exposure.knowledge_id),
         %{} = revision <-
           Repo.get_by(KnowledgeRevision,
             knowledge_id: exposure.knowledge_id,
             version: exposure.version
           ) do
      count =
        Repo.aggregate(
          from(s in KnowledgeSource,
            where:
              s.knowledge_id == ^head.id and s.generation == ^revision.source_generation and
                s.introduced_version <= ^revision.version
          ),
          :count
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
         true <- revision.state == Map.take(document, ~w(title summary topics)),
         true <- LearningSources.valid?(revision.source_dependencies, scope) do
      sources =
        Repo.all(
          from(s in KnowledgeSource,
            where:
              s.knowledge_id == ^id and s.generation == ^revision.source_generation and
                s.introduced_version <= ^version,
            order_by: [asc: s.observation_id],
            lock: "FOR SHARE"
          )
        )

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
    not is_nil(source.source_note) and not is_nil(observation.note) and
      source.source_revision == observation.revision and
      source.source_fingerprint == observation.source_fingerprint and
      source.source_note == observation.note and
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
