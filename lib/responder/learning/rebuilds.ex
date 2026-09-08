defmodule Responder.Learning.Rebuilds do
  @moduledoc "Explicit, source-only repair of an unavailable topic under the existing learning budget."
  import Ecto.Query
  alias Responder.{CanonicalJSON, Repo}
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Learning.{Batch, Runtime}
  alias Responder.Slack.ChannelMembership

  alias Responder.State.{
    Continuity,
    ConversationKnowledge,
    ConversationObservation,
    Knowledge,
    KnowledgeSource,
    LearningRun,
    LearningSources,
    Observations
  }

  @page_size 20
  @terminal [:no_change, :deferred, :superseded]

  def preview(id, options) do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         %ConversationKnowledge{} = topic <- Repo.get(ConversationKnowledge, id),
         {:ok, scope} <- scope(topic) do
      query = source_query(topic)
      any_sources = Repo.exists?(query)
      q = options |> Map.get(:q, "") |> String.slice(0, 200)
      selected = matching(query, q)
      total = Repo.aggregate(selected, :count)
      pages = max(1, div(total + @page_size - 1, @page_size))
      page = min(max(Map.get(options, :page, 1), 1), pages)
      batch = existing(topic.id, topic.source_generation)
      available = Repo.exists?(Knowledge.availability_query(scope, [topic.id]))
      reason = preview_reason(topic, batch, available, any_sources)

      entries =
        Repo.all(
          from([o, e] in selected,
            order_by: [desc: o.occurred_at, desc: e.id],
            offset: ^((page - 1) * @page_size),
            limit: @page_size,
            select: {o, e}
          )
        )
        |> Enum.map(fn {observation, entry} -> entry_view(topic, observation, entry) end)

      {:ok,
       %{
         topic_id: topic.id,
         version: topic.version,
         generation: topic.source_generation,
         transport: topic.transport,
         conversation_ref: topic.conversation_ref,
         available?: available,
         eligible?: is_nil(reason),
         reason: reason,
         existing_batch: batch_view(batch, reason),
         entries: entries,
         page: page,
         pages: pages,
         total: total,
         q: q
       }}
    else
      _ -> {:error, :knowledge_not_found}
    end
  end

  defp preview_reason(_topic, _batch, true, _any_sources), do: :knowledge_available

  defp preview_reason(topic, batch, false, any_sources) do
    case settings() do
      {:error, reason} -> reason
      {:ok, _settings} -> recovery_reason(topic, batch, any_sources)
    end
  end

  defp recovery_reason(topic, batch, any_sources) do
    cond do
      outstanding?(topic) -> :learning_remote_outstanding
      batch && batch.status not in @terminal -> :learning_batch_busy
      busy?(topic, if(batch, do: batch.id)) -> :learning_scope_busy
      not any_sources -> :learning_source_stale
      true -> nil
    end
  end

  defp batch_view(nil, _reason), do: nil

  defp batch_view(batch, reason),
    do: %{
      id: batch.id,
      status: batch.status,
      start_count: batch.start_count,
      start_limit: batch.start_limit,
      budget_version: batch.budget_version,
      reselect_available?: is_nil(reason) and batch.status in @terminal
    }

  defp entry_view(topic, observation, entry) do
    %{
      input_id: entry.id,
      revision: entry.revision,
      fingerprint: entry.event_fingerprint,
      occurred_at: entry.occurred_at,
      actor_ref: entry.actor_ref,
      execution_mode: entry.execution_mode,
      content: entry.content,
      source_message_ref: observation.source_message_ref,
      suggested?: suggested?(topic, observation)
    }
  end

  defp suggested?(topic, observation) do
    thread =
      if observation.thread_ref,
        do: dynamic([_s, previous], previous.thread_ref == ^observation.thread_ref),
        else: dynamic(false)

    connected = dynamic([_s, previous], previous.id == ^observation.id or ^thread)

    Repo.exists?(
      from(s in KnowledgeSource,
        join: previous in ConversationObservation,
        on: previous.id == s.observation_id,
        where: s.knowledge_id == ^topic.id and not is_nil(s.direct_support_version),
        where: ^connected
      )
    )
  end

  # Current originals have no inherited prose to authorize. Match the exact
  # observation revision before pagination; a deleted/edited source cannot
  # consume a selectable row merely because its old inbox entry remains.
  defp source_query(topic) do
    topic
    |> scoped_originals()
    |> current_originals()
    |> unexpired_originals(LearningSources.retention_seconds())
    |> undeleted_destination(topic)
  end

  defp scoped_originals(topic) do
    from(o in ConversationObservation,
      join: e in Entry,
      on: e.id == o.source_input_id,
      where:
        o.transport == ^topic.transport and o.workspace_ref == ^topic.workspace_ref and
          o.conversation_ref == ^topic.conversation_ref and
          fragment("? IS NOT DISTINCT FROM ?", o.repository_ref, ^topic.repository_ref),
      where:
        e.destination_transport == o.transport and
          e.destination_conversation_ref == o.conversation_ref and
          fragment("? IS NOT DISTINCT FROM ?", e.repository_ref, o.repository_ref)
    )
  end

  defp current_originals(query) do
    from([o, e] in query,
      where:
        e.status == :decided and e.event_kind != :delete and is_nil(e.operational_pruned_at) and
          not is_nil(e.content),
      where: e.revision == o.revision and e.event_fingerprint == o.source_fingerprint,
      where: is_nil(o.source_result_ref) or not like(o.source_result_ref, "source-conflict:%")
    )
  end

  defp unexpired_originals(query, nil), do: query

  defp unexpired_originals(query, seconds),
    do:
      where(
        query,
        [o],
        o.updated_at > fragment("clock_timestamp() - (? * interval '1 second')", ^seconds)
      )

  defp undeleted_destination(query, %{transport: "slack"} = topic) do
    deleted =
      from(m in ChannelMembership,
        where:
          m.status == :deleted and
            fragment("'slack:' || ? || ':' || ?", m.workspace_ref, m.channel_ref) ==
              ^topic.conversation_ref,
        where: not like(m.channel_ref, "D%"),
        select: 1
      )

    where(query, not exists(subquery(deleted)))
  end

  defp undeleted_destination(query, _topic), do: query

  defp matching(query, ""), do: query

  defp matching(query, q),
    do: where(query, [_o, e], fragment("strpos(lower(?::text), lower(?)) > 0", e.content, ^q))

  def selections(value) when is_list(value) and length(value) in 1..16 do
    if Enum.all?(value, &selection?/1) and
         length(Enum.uniq_by(value, & &1["source_input_id"])) == length(value),
       do: {:ok, Enum.sort_by(value, & &1["source_input_id"])},
       else: {:error, :invalid_learning_rebuild}
  end

  def selections(_), do: {:error, :invalid_learning_rebuild}

  defp selection?(
         %{"source_input_id" => id, "revision" => revision, "fingerprint" => fingerprint} = value
       ) do
    map_size(value) == 3 and Ecto.UUID.cast(id) == {:ok, id} and
      is_integer(revision) and revision in 1..9_223_372_036_854_775_807 and is_binary(fingerprint) and
      byte_size(fingerprint) == 64 and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint)
  end

  defp selection?(_), do: false

  @doc false
  def request_in_transaction(id, version, generation, selected) do
    queue_lock!()
    batch = existing(id, generation, "FOR UPDATE")
    topic = target!(id, version, generation)

    if batch do
      {:ok, %{previous: %{}, outcome: outcome(batch)}}
    else
      {:ok, settings} = settings_or_rollback!()
      entries = selected!(topic, selected)
      execution_mode = hd(entries).execution_mode
      ensure_idle!(topic, nil, execution_mode)
      scope = batch_scope(topic, execution_mode)
      now = now!()

      batch =
        Repo.insert!(
          struct!(
            Batch,
            Map.merge(scope, %{
              scope_key: scope_key(scope),
              policy: settings.policy,
              policy_digest: settings.policy_digest,
              status: :queued,
              input_count: length(entries),
              rebuild_target_id: topic.id,
              rebuild_target_version: topic.version,
              rebuild_target_generation: topic.source_generation,
              rebuild_selection: selected,
              inserted_at: now,
              updated_at: now
            })
          )
        )

      {:ok, %{previous: %{}, outcome: outcome(batch)}}
    end
  end

  @doc false
  def reselect_in_transaction(id, expected_budget_version, expected_target, selected) do
    queue_lock!()
    batch = Repo.one(from(b in Batch, where: b.id == ^id, lock: "FOR UPDATE"))

    unless batch && batch.rebuild_target_id && batch.status in @terminal &&
             batch.budget_version == expected_budget_version,
           do: Repo.rollback(:learning_retry_conflict)

    unless expected_target.generation == batch.rebuild_target_generation,
      do: Repo.rollback(:knowledge_rebuild_conflict)

    topic = target!(batch.rebuild_target_id, expected_target.version, expected_target.generation)
    ensure_idle!(topic, batch.id, batch.execution_mode)
    _settings = settings_or_rollback!()
    entries = selected!(topic, selected)
    execution_mode = hd(entries).execution_mode
    ensure_idle!(topic, batch.id, execution_mode)
    scope = batch_scope(topic, execution_mode)

    changed =
      batch
      |> Ecto.Changeset.change(
        rebuild_selection: selected,
        rebuild_target_version: topic.version,
        execution_mode: execution_mode,
        scope_key: scope_key(scope),
        input_count: length(entries),
        status: :queued,
        start_limit: batch.start_count + 1,
        budget_version: batch.budget_version + 1,
        next_attempt_at: nil,
        completed_at: nil,
        error_code: nil,
        updated_at: now!()
      )
      |> Repo.update!()

    {:ok, %{previous: outcome(batch), outcome: outcome(changed)}}
  end

  defp target!(id, version, generation) do
    topic = Repo.get(ConversationKnowledge, id) || Repo.rollback(:knowledge_not_found)
    destination = destination(topic)

    unless Knowledge.lock_scope_in_transaction(destination, topic.repository_ref) == :ok,
      do: Repo.rollback(:learning_source_stale)

    topic = Repo.one!(from(k in ConversationKnowledge, where: k.id == ^id, lock: "FOR UPDATE"))
    {:ok, scope} = scope(topic)

    unless topic.version == version and topic.source_generation == generation and
             not Repo.exists?(Knowledge.availability_query(scope, [id])),
           do: Repo.rollback(:knowledge_rebuild_conflict)

    topic
  end

  defp selected!(topic, selected) do
    ids = Enum.map(selected, & &1["source_input_id"])
    entries = Repo.all(from(e in Entry, where: e.id in ^ids, order_by: e.id, lock: "FOR SHARE"))
    current = Repo.all(from([_o, e] in source_query(topic), where: e.id in ^ids, select: e.id))

    unless Enum.sort(current) == Enum.sort(ids) and length(entries) == length(ids),
      do: Repo.rollback(:learning_source_stale)

    first = hd(entries)

    unless Enum.all?(entries, &(&1.execution_mode == first.execution_mode)),
      do: Repo.rollback(:learning_mixed_execution_modes)

    {:ok, scope} = Observations.locked_scope(first, first.repository_ref)

    valid =
      Enum.all?(entries, fn entry ->
        receipt = %{
          "source_input_id" => entry.id,
          "revision" => entry.revision,
          "fingerprint" => entry.event_fingerprint
        }

        receipt in selected and LearningSources.valid?(LearningSources.for_entry(entry), scope)
      end)

    unless valid, do: Repo.rollback(:learning_source_stale)
    entries
  end

  @doc false
  def inputs(%Batch{} = batch) do
    ids = Enum.map(batch.rebuild_selection, & &1["source_input_id"])

    case Repo.get(ConversationKnowledge, batch.rebuild_target_id) do
      nil ->
        []

      topic ->
        entries =
          Repo.all(
            from([_o, e] in source_query(topic),
              where: e.id in ^ids,
              order_by: [asc: e.inserted_at, asc: e.id],
              select: e
            )
          )

        if length(entries) == length(ids) and Enum.all?(entries, &selected_revision?(&1, batch)),
          do: entries,
          else: []
    end
  end

  defp selected_revision?(entry, batch),
    do:
      entry.execution_mode == batch.execution_mode and
        %{
          "source_input_id" => entry.id,
          "revision" => entry.revision,
          "fingerprint" => entry.event_fingerprint
        } in batch.rebuild_selection

  @doc false
  def validate_selection!(batch) do
    topic =
      target!(
        batch.rebuild_target_id,
        batch.rebuild_target_version,
        batch.rebuild_target_generation
      )

    entries = selected!(topic, batch.rebuild_selection)

    unless Enum.all?(entries, &(&1.execution_mode == batch.execution_mode)),
      do: Repo.rollback(:learning_source_stale)

    entries
  end

  @doc false
  def contract(%{rebuild_target_id: nil}), do: nil

  def contract(batch),
    do: %{
      "kind" => "rebuild",
      "topic_id" => batch.rebuild_target_id,
      "version" => batch.rebuild_target_version,
      "generation" => batch.rebuild_target_generation,
      "selection" => batch.rebuild_selection,
      "budget_version" => batch.budget_version,
      "execution_mode" => Atom.to_string(batch.execution_mode)
    }

  @doc false
  def authorize_run(%{rebuild: nil}), do: :ok

  def authorize_run(run) do
    batch = Repo.get(Batch, run.batch_id)

    if batch && contract(batch) == run.rebuild && batch.budget_version == run.batch_budget_version do
      _topic =
        target!(
          batch.rebuild_target_id,
          batch.rebuild_target_version,
          batch.rebuild_target_generation
        )

      :ok
    else
      {:error, :knowledge_rebuild_conflict}
    end
  end

  defp ensure_idle!(topic, except, execution_mode) do
    if outstanding?(topic, execution_mode), do: Repo.rollback(:learning_remote_outstanding)
    if busy?(topic, except, execution_mode), do: Repo.rollback(:learning_scope_busy)
  end

  defp outstanding?(topic, mode \\ nil) do
    query = matching_batches(topic, mode)

    Repo.exists?(
      from(b in query,
        join: r in LearningRun,
        on: r.batch_id == b.id,
        where: not is_nil(r.started_at) and is_nil(r.remote_stopped_at)
      )
    )
  end

  defp busy?(topic, except, mode \\ nil) do
    query = matching_batches(topic, mode)
    query = if except, do: where(query, [b], b.id != ^except), else: query
    Repo.exists?(where(query, [b], b.status in [:queued, :running]))
  end

  defp matching_batches(topic, mode) do
    query =
      from(b in Batch,
        where:
          b.transport == ^topic.transport and b.conversation_ref == ^topic.conversation_ref and
            fragment("? IS NOT DISTINCT FROM ?", b.repository_ref, ^topic.repository_ref)
      )

    if mode, do: where(query, [b], b.execution_mode == ^mode), else: query
  end

  defp existing(id, generation, lock \\ nil) do
    query =
      from(b in Batch,
        where: b.rebuild_target_id == ^id and b.rebuild_target_generation == ^generation
      )

    query = if lock, do: from(b in query, lock: "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp settings do
    case Application.get_env(:responder, :learning) do
      nil -> {:error, :learning_disabled}
      config -> {:ok, Runtime.options!(config)}
    end
  rescue
    ArgumentError -> {:error, :learning_configuration_invalid}
  end

  defp settings_or_rollback! do
    case settings() do
      {:ok, _} = result -> result
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp destination(topic),
    do: %{
      destination_transport: topic.transport,
      destination_conversation_ref: topic.conversation_ref,
      destination_thread_ref: nil
    }

  defp scope(topic), do: Continuity.destination_context(destination(topic), topic.repository_ref)

  defp batch_scope(topic, mode),
    do: %{
      transport: topic.transport,
      conversation_ref: topic.conversation_ref,
      repository_ref: topic.repository_ref,
      execution_mode: mode
    }

  defp scope_key(scope),
    do:
      scope
      |> Map.update!(:execution_mode, &Atom.to_string/1)
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      |> CanonicalJSON.digest()

  defp outcome(batch),
    do: %{
      "batch_id" => batch.id,
      "status" => Atom.to_string(batch.status),
      "start_count" => batch.start_count,
      "start_limit" => batch.start_limit,
      "budget_version" => batch.budget_version,
      "execution_mode" => Atom.to_string(batch.execution_mode)
    }

  defp queue_lock! do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "operator audit transaction required")
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended('learning-queue', 0))")
  end

  defp now! do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end
end
