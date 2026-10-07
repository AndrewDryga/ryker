defmodule Ryker.Learning.Rebuilds do
  @moduledoc "Explicit, source-only repair of an unavailable topic under the existing learning budget."
  alias Ryker.Continuity
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Knowledge
  alias Ryker.Knowledge.{ConversationKnowledge, KnowledgeSource}
  alias Ryker.Learning
  alias Ryker.Learning.{Batch, Batches, LearningSources, Observations}
  alias Ryker.Learning.{RebuildSource, Runtime}
  alias Ryker.Repo

  @page_size 20
  @terminal [:no_change, :deferred, :superseded, :dropped]

  def preview(id, options) do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, topic} <- Repo.fetch(ConversationKnowledge.Query.by_id(id)),
         {:ok, scope} <- scope(topic) do
      query = source_query(topic)
      any_sources = Repo.exists?(query)
      search = options |> Map.get(:q, "") |> String.slice(0, 200)
      selected = RebuildSource.Query.mentioning(query, search)
      total = Repo.aggregate(selected, :count)
      pages = max(1, div(total + @page_size - 1, @page_size))
      page = min(max(Map.get(options, :page, 1), 1), pages)
      batch = existing(topic.id, topic.source_generation)
      available = Repo.exists?(Knowledge.availability_query(scope, [topic.id]))
      reason = preview_reason(topic, batch, available, any_sources)

      entries =
        selected
        |> RebuildSource.Query.latest_said_first()
        |> RebuildSource.Query.page(page, @page_size)
        |> RebuildSource.Query.select_observations_and_entries()
        |> Repo.all()
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
         q: search
       }}
    else
      _ -> {:error, :knowledge_not_found}
    end
  end

  defp preview_reason(_topic, _batch, true, _any_sources), do: :knowledge_available

  defp preview_reason(topic, batch, false, any_sources) do
    case Runtime.configured_options() do
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

  defp suggested?(topic, observation),
    do: Repo.exists?(KnowledgeSource.Query.direct_near(topic.id, observation))

  defp source_query(topic),
    do: RebuildSource.Query.of_topic(topic, LearningSources.retention_seconds())

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
    Batches.lock_queue!()
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
      now = Repo.now!()

      batch =
        Repo.insert!(
          struct!(
            Batch,
            Map.merge(scope, %{
              scope_key: Batches.scope_key(scope),
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

      Learning.broadcast_learning_updated(batch.id)
      {:ok, %{previous: %{}, outcome: outcome(batch)}}
    end
  end

  @doc false
  def reselect_in_transaction(id, expected_budget_version, expected_target, selected) do
    Batches.lock_queue!()
    batch = id |> Batch.Query.by_id() |> Batch.Query.lock_for_update() |> Repo.one()

    unless batch && batch.rebuild_target_id && batch.status in @terminal &&
             batch.budget_version == expected_budget_version,
           do: Repo.rollback(:learning_retry_conflict)

    unless expected_target.generation == batch.rebuild_target_generation,
      do: Repo.rollback(:knowledge_rebuild_conflict)

    topic = target!(batch.rebuild_target_id, expected_target.version, expected_target.generation)
    ensure_idle!(topic, batch.id, batch.execution_mode)
    {:ok, settings} = settings_or_rollback!()
    entries = selected!(topic, selected)
    execution_mode = hd(entries).execution_mode
    ensure_idle!(topic, batch.id, execution_mode)
    scope = batch_scope(topic, execution_mode)

    changed =
      batch
      |> Ecto.Changeset.change(
        policy: settings.policy,
        policy_digest: settings.policy_digest,
        rebuild_selection: selected,
        rebuild_target_version: topic.version,
        execution_mode: execution_mode,
        scope_key: Batches.scope_key(scope),
        input_count: length(entries),
        status: :queued,
        start_limit: batch.start_count + 1,
        budget_version: batch.budget_version + 1,
        next_attempt_at: nil,
        completed_at: nil,
        error_code: nil,
        updated_at: Repo.now!()
      )
      |> Repo.update!()

    Learning.broadcast_learning_updated(changed.id)
    {:ok, %{previous: outcome(batch), outcome: outcome(changed)}}
  end

  defp target!(id, version, generation) do
    topic = Repo.one(ConversationKnowledge.Query.by_id(id)) || Repo.rollback(:knowledge_not_found)
    destination = destination(topic)

    unless Knowledge.lock_scope_in_transaction(destination, topic.repository_ref) == :ok,
      do: Repo.rollback(:learning_source_stale)

    topic =
      id
      |> ConversationKnowledge.Query.by_id()
      |> ConversationKnowledge.Query.lock_for_update()
      |> Repo.one!()

    {:ok, scope} = scope(topic)

    # Forgetting leaves version and generation alone, so a rebuild queued
    # before it brought the topic back (2026-10-04 review).
    unless is_nil(topic.forgotten_at) and topic.version == version and
             topic.source_generation == generation and
             not Repo.exists?(Knowledge.availability_query(scope, [id])),
           do: Repo.rollback(:knowledge_rebuild_conflict)

    topic
  end

  defp selected!(topic, selected) do
    ids = Enum.map(selected, & &1["source_input_id"])

    entries =
      ids
      |> Entry.Query.by_ids()
      |> Entry.Query.ordered_by_id()
      |> Entry.Query.lock_for_share()
      |> Repo.all()

    current =
      topic
      |> source_query()
      |> RebuildSource.Query.by_entry_ids(ids)
      |> RebuildSource.Query.select_entry_ids()
      |> Repo.all()

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

    case Repo.one(ConversationKnowledge.Query.by_id(batch.rebuild_target_id)) do
      nil ->
        []

      topic ->
        entries =
          topic
          |> source_query()
          |> RebuildSource.Query.by_entry_ids(ids)
          |> RebuildSource.Query.oldest_received_first()
          |> RebuildSource.Query.select_entries()
          |> Repo.all()

        if length(entries) == length(ids) and Enum.all?(entries, &selected_revision?(&1, batch)),
          do: entries,
          else: []
    end
  end

  defp selected_revision?(entry, batch) do
    entry.execution_mode == batch.execution_mode and
      %{
        "source_input_id" => entry.id,
        "revision" => entry.revision,
        "fingerprint" => entry.event_fingerprint
      } in batch.rebuild_selection
  end

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
    batch = Repo.one(Batch.Query.by_id(run.batch_id))

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

  defp outstanding?(topic, mode \\ nil),
    do: topic |> matching_batches(mode) |> Batch.Query.with_unstopped_run() |> Repo.exists?()

  defp busy?(topic, except, mode \\ nil) do
    query = matching_batches(topic, mode)
    query = if except, do: Batch.Query.excluding_id(query, except), else: query
    Repo.exists?(Batch.Query.active(query))
  end

  defp matching_batches(topic, mode) do
    query = Batch.Query.in_conversation(topic.transport, topic.conversation_ref)
    if mode, do: Batch.Query.with_execution_mode(query, mode), else: query
  end

  defp existing(id, generation, lock \\ nil) do
    query = Batch.Query.rebuilding(id, generation)
    query = if lock, do: Batch.Query.lock_for_update(query), else: query
    Repo.one(query)
  end

  defp settings_or_rollback! do
    case Runtime.configured_options() do
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

  defp outcome(batch),
    do: %{
      "batch_id" => batch.id,
      "policy" => batch.policy,
      "policy_digest" => batch.policy_digest,
      "status" => Atom.to_string(batch.status),
      "start_count" => batch.start_count,
      "start_limit" => batch.start_limit,
      "budget_version" => batch.budget_version,
      "execution_mode" => Atom.to_string(batch.execution_mode)
    }
end
