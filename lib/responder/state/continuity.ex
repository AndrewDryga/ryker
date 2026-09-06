defmodule Responder.State.Continuity do
  @moduledoc """
  Durable, derived conversation continuity.

  A model may stage a typed summary only while it owns an active Work turn. The
  summary becomes recallable in the same transaction that accepts the validated
  result. Summaries and rollups are bounded hints, never evidence or authority.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Responder.CanonicalJSON
  alias Responder.Episodes.Episode
  alias Responder.Repo
  alias Responder.Slack.{ChannelFence, ChannelMembership}

  alias Responder.State.{
    ConversationRollup,
    ConversationSummary,
    ConversationSummaryDraft,
    ConversationSummaryState,
    Knowledge,
    KnowledgeSnapshot,
    LearningSources,
    Observations
  }

  alias Responder.Work.{Session, Turn}

  @maximum_related 8
  @maximum_rollups 4
  @maximum_candidates 64
  @maximum_compaction 100
  @maximum_rollup_source_refs 500
  @maximum_rollup_source_scopes 10_000
  @maximum_rollup_source_ref_bytes 32 * 1_024
  @maximum_rollup_source_scope_bytes 8 * 1_024 * 1_024
  @maximum_state_bytes 32 * 1_024

  @spec stage(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def stage("state:" <> turn_id, state) do
    with {:ok, state} <- ConversationSummaryState.prepare(state),
         {:ok, turn_id} <- Ecto.UUID.cast(turn_id) do
      Repo.transaction(fn -> stage_locked(turn_id, state) end)
      |> transaction_result()
    else
      :error -> {:error, :conversation_summary_unauthorized}
      {:error, _reason} = error -> error
    end
  end

  def stage(_state_token, _state), do: {:error, :conversation_summary_unauthorized}

  @doc false
  @spec accept_staged_in_transaction(Episode.t(), Session.t(), Turn.t(), String.t()) ::
          :ok | {:error, term()}
  def accept_staged_in_transaction(
        %Episode{} = episode,
        %Session{} = session,
        %Turn{} = turn,
        result_ref
      )
      when is_binary(result_ref) do
    if Repo.in_transaction?() do
      case ChannelFence.authorize_in_transaction(
             episode.destination_transport,
             episode.destination_conversation_ref
           ) do
        :ok ->
          accept_staged_locked(episode, session, turn, result_ref)

        {:error, :slack_channel_deleted} ->
          Repo.delete_all(
            from(draft in ConversationSummaryDraft,
              where: draft.turn_id == ^turn.id and draft.episode_id == ^episode.id
            )
          )

          :ok

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :conversation_summary_transaction_required}
    end
  end

  def accept_staged_in_transaction(_episode, _session, _turn, _result_ref),
    do: {:error, :conversation_summary_invalid_acceptance}

  defp accept_staged_locked(episode, session, turn, result_ref) do
    case Repo.one(
           from(draft in ConversationSummaryDraft,
             where: draft.turn_id == ^turn.id and draft.episode_id == ^episode.id,
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        :ok

      %ConversationSummaryDraft{} = draft ->
        with :ok <- exact_candidate(draft, turn),
             {:ok, state} <- ConversationSummaryState.prepare(draft.state),
             true <- CanonicalJSON.digest(state) == draft.state_fingerprint,
             {:ok, context} <- destination_context(episode, session.repository_ref),
             :ok <- upsert_summary(draft, episode, turn, result_ref, context),
             {:ok, _draft} <- Repo.delete(draft) do
          :ok
        else
          {:error, :conversation_summary_candidate_mismatch} ->
            {:ok, _draft} = Repo.delete(draft)
            :ok

          false ->
            {:error, :conversation_summary_fingerprint_mismatch}

          {:error, _reason} = error ->
            error
        end
    end
  end

  @doc false
  @spec candidate_staged_in_transaction(Turn.t(), String.t(), pos_integer()) ::
          :ok | {:error, term()}
  def candidate_staged_in_transaction(%Turn{} = turn, candidate_sha256, candidate_attempt)
      when is_binary(candidate_sha256) and is_integer(candidate_attempt) and candidate_attempt > 0 do
    if Repo.in_transaction?() do
      bind_candidate_draft(locked_draft(turn), candidate_sha256, candidate_attempt)
    else
      {:error, :conversation_summary_transaction_required}
    end
  end

  defp bind_candidate_draft(nil, _candidate_sha256, _candidate_attempt), do: :ok

  defp bind_candidate_draft(
         %ConversationSummaryDraft{candidate_sha256: nil} = draft,
         candidate_sha256,
         candidate_attempt
       ),
       do: bind_draft(draft, candidate_sha256, candidate_attempt)

  defp bind_candidate_draft(
         %ConversationSummaryDraft{
           candidate_sha256: candidate_sha256,
           candidate_attempt: candidate_attempt
         },
         candidate_sha256,
         candidate_attempt
       ),
       do: :ok

  defp bind_candidate_draft(%ConversationSummaryDraft{} = draft, _sha256, _attempt) do
    case Repo.delete(draft) do
      {:ok, _draft} -> :ok
      {:error, changeset} -> {:error, {:conversation_summary_persistence, changeset.errors}}
    end
  end

  @doc false
  @spec preflight_fingerprint_in_transaction(Turn.t()) :: String.t() | no_return()
  def preflight_fingerprint_in_transaction(%Turn{} = turn) do
    if Repo.in_transaction?() do
      CanonicalJSON.digest(preflight_document(locked_draft(turn)))
    else
      Repo.rollback(:conversation_summary_transaction_required)
    end
  end

  @spec model_context(Episode.t(), String.t() | nil) :: map()
  def model_context(%Episode{} = episode, repository_ref)
      when is_binary(repository_ref) or is_nil(repository_ref) do
    case destination_context(episode, repository_ref) do
      {:ok, context} ->
        result = recall_context(context)
        knowledge = Knowledge.context(episode, repository_ref)
        result = if knowledge == [], do: result, else: Map.put(result, "knowledge", knowledge)

        case Observations.context(episode, repository_ref) do
          [] -> result
          notes -> Map.put(result, "observations", notes)
        end

      {:error, _reason} ->
        empty_context()
    end
  end

  def model_context(_episode, _repository_ref), do: empty_context()

  @spec search_context(Episode.t(), String.t() | nil, String.t(), String.t(), pos_integer()) ::
          [map()]
  def search_context(%Episode{} = episode, repository_ref, query, scope, limit)
      when (is_binary(repository_ref) or is_nil(repository_ref)) and is_binary(query) and
             is_binary(scope) and is_integer(limit) and limit in 1..50 do
    case destination_context(episode, repository_ref) do
      {:ok, context} ->
        (Knowledge.context(episode, repository_ref, query, limit, scope) ++
           Observations.context(episode, repository_ref, query, limit, scope) ++
           search_context(context, query, scope, limit))
        |> Enum.take(limit)

      {:error, _reason} ->
        []
    end
  end

  def search_context(_episode, _repository_ref, _query, _scope, _limit), do: []

  @doc false
  @spec compact_in_transaction(pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def compact_in_transaction(summary_age_seconds, rollup_retention_seconds)
      when is_integer(summary_age_seconds) and summary_age_seconds > 0 and
             is_integer(rollup_retention_seconds) and rollup_retention_seconds > 0 do
    if Repo.in_transaction?() do
      compact_locked(summary_age_seconds, rollup_retention_seconds)
    else
      {:error, :conversation_summary_transaction_required}
    end
  end

  def compact_in_transaction(_summary_age_seconds, _rollup_retention_seconds),
    do: {:error, :invalid_conversation_summary_retention}

  @doc false
  @spec delete_slack_channel_in_transaction(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_slack_channel_in_transaction(workspace_ref, channel_ref)
      when is_binary(workspace_ref) and is_binary(channel_ref) do
    if Repo.in_transaction?() do
      delete_slack_channel_locked(workspace_ref, channel_ref)
    else
      {:error, :conversation_summary_transaction_required}
    end
  end

  def delete_slack_channel_in_transaction(_workspace_ref, _channel_ref),
    do: {:error, :conversation_summary_destination}

  defp recall_context(context) do
    case Repo.transaction(fn -> recall_locked(context) end) do
      {:ok, result} -> result
      {:error, _reason} -> empty_context()
    end
  end

  defp search_context(context, query, scope, limit) do
    case Repo.transaction(fn -> search_locked(context, query, scope, limit) end) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  defp compact_locked(summary_age_seconds, rollup_retention_seconds) do
    before = DateTime.add(database_now!(), -summary_age_seconds, :second)

    Repo.all(
      from(summary in ConversationSummary,
        where: summary.updated_at < ^before and summary.state != ^%{"retention" => "pruned"},
        order_by: [asc: summary.updated_at, asc: summary.id],
        limit: @maximum_compaction,
        lock: "FOR UPDATE"
      )
    )
    |> Enum.group_by(&rollup_identity/1)
    |> Enum.sort_by(fn {identity, _items} -> identity end)
    |> compact_groups(rollup_retention_seconds)
  end

  defp compact_groups(groups, rollup_retention_seconds) do
    Enum.reduce_while(groups, {:ok, 0}, fn {_identity, sources}, {:ok, count} ->
      case compact_group(sources, rollup_retention_seconds) do
        :ok -> {:cont, {:ok, count + length(sources)}}
        :skipped -> {:cont, {:ok, count}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp delete_slack_channel_locked(workspace_ref, channel_ref) do
    conversation_ref = "slack:#{workspace_ref}:#{channel_ref}"
    scoped_workspace_ref = "slack:#{workspace_ref}"

    delete_channel_summaries(scoped_workspace_ref, conversation_ref)
    delete_channel_drafts(conversation_ref)
    delete_channel_rollups(scoped_workspace_ref, conversation_ref, workspace_ref, channel_ref)

    Repo.delete_all(
      from(item in Responder.State.ConversationKnowledge,
        where:
          item.workspace_ref == ^scoped_workspace_ref and
            item.conversation_ref == ^conversation_ref
      )
    )

    Repo.delete_all(
      from(note in Responder.State.ConversationObservation,
        where:
          note.workspace_ref == ^scoped_workspace_ref and
            note.conversation_ref == ^conversation_ref
      )
    )

    :ok
  end

  defp delete_channel_summaries(workspace_ref, conversation_ref) do
    Repo.delete_all(
      from(summary in ConversationSummary,
        where:
          summary.workspace_ref == ^workspace_ref and
            summary.conversation_ref == ^conversation_ref
      )
    )
  end

  defp delete_channel_drafts(conversation_ref) do
    Repo.all(
      from(draft in ConversationSummaryDraft,
        join: episode in Episode,
        on: episode.id == draft.episode_id,
        where:
          episode.destination_transport == "slack" and
            episode.destination_conversation_ref == ^conversation_ref,
        select: draft.id
      )
    )
    |> delete_drafts()
  end

  defp delete_drafts([]), do: :ok

  defp delete_drafts(draft_ids) do
    Repo.delete_all(from(draft in ConversationSummaryDraft, where: draft.id in ^draft_ids))
  end

  defp delete_channel_rollups(workspace_ref, conversation_ref, slack_workspace_ref, channel_ref) do
    Repo.all(
      from(rollup in ConversationRollup,
        where: rollup.workspace_ref == ^workspace_ref,
        lock: "FOR UPDATE"
      )
    )
    |> Enum.filter(&rollup_uses_channel?(&1, conversation_ref, slack_workspace_ref, channel_ref))
    |> Enum.map(& &1.id)
    |> delete_rollups()
  end

  defp rollup_uses_channel?(rollup, conversation_ref, workspace_ref, channel_ref) do
    rollup.scope_ref == conversation_ref or
      Enum.any?(rollup.source_scopes, &slack_source?(&1, workspace_ref, channel_ref))
  end

  defp slack_source?(source, workspace_ref, channel_ref) do
    source["transport"] == "slack" and source["workspace_ref"] == workspace_ref and
      source["channel_ref"] == channel_ref
  end

  defp delete_rollups([]), do: :ok

  defp delete_rollups(rollup_ids) do
    Repo.delete_all(from(rollup in ConversationRollup, where: rollup.id in ^rollup_ids))
  end

  defp stage_locked(turn_id, state) do
    with %Turn{} = identity <- Repo.get(Turn, turn_id),
         %Episode{} = episode <-
           Repo.one(
             from(item in Episode, where: item.id == ^identity.episode_id, lock: "FOR UPDATE")
           ),
         %Turn{} = turn <-
           Repo.one(from(item in Turn, where: item.id == ^turn_id, lock: "FOR UPDATE")),
         :ok <-
           ChannelFence.authorize_in_transaction(
             episode.destination_transport,
             episode.destination_conversation_ref
           ),
         :ok <- stage_authorized(episode, turn) do
      fingerprint = CanonicalJSON.digest(state)

      case Repo.one(
             from(draft in ConversationSummaryDraft,
               where: draft.turn_id == ^turn.id,
               lock: "FOR UPDATE"
             )
           ) do
        nil ->
          insert_draft(episode, turn, state, fingerprint)

        %ConversationSummaryDraft{
          state_fingerprint: ^fingerprint,
          candidate_sha256: nil
        } = draft ->
          draft_result(draft)

        %ConversationSummaryDraft{} = draft ->
          update_draft(draft, state, fingerprint)
      end
    else
      nil -> Repo.rollback(:conversation_summary_unauthorized)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp stage_authorized(
         %Episode{
           owner_kind: :turn,
           owner_ref: owner_ref,
           state: :working
         },
         %Turn{cancellation_intent: nil, status: :pending, turn_ref: owner_ref}
       ),
       do: :ok

  defp stage_authorized(_episode, _turn), do: {:error, :conversation_summary_unauthorized}

  defp insert_draft(episode, turn, state, fingerprint) do
    id = Ecto.UUID.generate()

    %ConversationSummaryDraft{}
    |> Changeset.cast(
      %{
        episode_id: episode.id,
        id: id,
        revision: 1,
        state: state,
        state_fingerprint: fingerprint,
        turn_id: turn.id
      },
      [:episode_id, :id, :revision, :state, :state_fingerprint, :turn_id]
    )
    |> Changeset.validate_required([
      :episode_id,
      :id,
      :revision,
      :state,
      :state_fingerprint,
      :turn_id
    ])
    |> Changeset.unique_constraint(:turn_id)
    |> Changeset.foreign_key_constraint(:episode_id)
    |> Changeset.foreign_key_constraint(:turn_id)
    |> Changeset.check_constraint(:revision, name: :conversation_summary_draft_valid)
    |> Repo.insert()
    |> case do
      {:ok, draft} -> draft_result(draft)
      {:error, changeset} -> Repo.rollback({:conversation_summary_persistence, changeset.errors})
    end
  end

  defp update_draft(draft, state, fingerprint) do
    draft
    |> Changeset.change(%{
      revision: draft.revision + 1,
      state: state,
      state_fingerprint: fingerprint,
      candidate_sha256: nil,
      candidate_attempt: nil
    })
    |> Changeset.check_constraint(:revision, name: :conversation_summary_draft_valid)
    |> Repo.update()
    |> case do
      {:ok, updated} -> draft_result(updated)
      {:error, changeset} -> Repo.rollback({:conversation_summary_persistence, changeset.errors})
    end
  end

  defp draft_result(draft) do
    %{
      revision: draft.revision,
      state_fingerprint: draft.state_fingerprint,
      summary_ref: "continuity-draft:#{draft.turn_id}"
    }
  end

  defp locked_draft(turn) do
    Repo.one(
      from(draft in ConversationSummaryDraft,
        where: draft.turn_id == ^turn.id and draft.episode_id == ^turn.episode_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp bind_draft(draft, candidate_sha256, candidate_attempt) do
    draft
    |> Changeset.change(%{
      candidate_sha256: candidate_sha256,
      candidate_attempt: candidate_attempt
    })
    |> Changeset.check_constraint(:candidate_sha256, name: :conversation_summary_draft_valid)
    |> Repo.update()
    |> case do
      {:ok, _draft} -> :ok
      {:error, changeset} -> {:error, {:conversation_summary_persistence, changeset.errors}}
    end
  end

  defp preflight_document(nil), do: %{"summary" => nil}

  defp preflight_document(draft) do
    %{
      "revision" => draft.revision,
      "state_fingerprint" => draft.state_fingerprint,
      "summary_ref" => "continuity-draft:#{draft.turn_id}"
    }
  end

  defp exact_candidate(
         %ConversationSummaryDraft{
           candidate_sha256: sha256,
           candidate_attempt: attempt
         },
         %Turn{candidate_sha256: sha256, candidate_attempt: attempt}
       )
       when is_binary(sha256) and is_integer(attempt),
       do: :ok

  defp exact_candidate(_draft, _turn), do: {:error, :conversation_summary_candidate_mismatch}

  defp upsert_summary(draft, episode, turn, result_ref, context) do
    attributes = %{
      conversation_ref: context.conversation_ref,
      identity_key: context.identity_key,
      repository_ref: context.repository_ref,
      source_episode_id: episode.id,
      source_message_ref: List.last(episode.active_input_refs),
      source_result_ref: result_ref,
      source_turn_id: turn.id,
      source_dependencies: KnowledgeSnapshot.session_sources(turn.session_id),
      state: draft.state,
      state_fingerprint: draft.state_fingerprint,
      thread_ref: context.thread_ref,
      transport: context.transport,
      visibility: context.visibility,
      workspace_ref: context.workspace_ref
    }

    if is_nil(attributes.source_dependencies) do
      # Optional learning must not preserve prose after dropping its source fences.
      :ok
    else
      persist_summary(attributes, context.identity_key)
    end
  end

  defp persist_summary(attributes, identity_key) do
    case Repo.one(
           from(summary in ConversationSummary,
             where: summary.identity_key == ^identity_key,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> insert_summary(attributes)
      %ConversationSummary{} = summary -> update_summary(summary, attributes)
    end
  end

  defp insert_summary(attributes) do
    id = Ecto.UUID.generate()

    attributes
    |> Map.merge(%{id: id, ref: "continuity:#{id}"})
    |> summary_changeset(%ConversationSummary{})
    |> Repo.insert()
    |> persistence_result()
  end

  defp update_summary(summary, attributes) do
    attributes
    |> summary_changeset(summary)
    |> Repo.update()
    |> persistence_result()
  end

  defp summary_changeset(attributes, summary) do
    summary
    |> Changeset.cast(attributes, [
      :conversation_ref,
      :id,
      :identity_key,
      :ref,
      :repository_ref,
      :source_episode_id,
      :source_message_ref,
      :source_result_ref,
      :source_turn_id,
      :source_dependencies,
      :state,
      :state_fingerprint,
      :thread_ref,
      :transport,
      :visibility,
      :workspace_ref
    ])
    |> Changeset.validate_required([
      :conversation_ref,
      :identity_key,
      :source_result_ref,
      :state,
      :state_fingerprint,
      :transport,
      :visibility,
      :workspace_ref
    ])
    |> Changeset.unique_constraint(:ref)
    |> Changeset.unique_constraint(:identity_key)
    |> Changeset.foreign_key_constraint(:source_episode_id)
    |> Changeset.foreign_key_constraint(:source_turn_id)
    |> Changeset.check_constraint(:identity_key, name: :conversation_summary_valid)
  end

  defp persistence_result({:ok, _record}), do: :ok

  defp persistence_result({:error, changeset}),
    do: {:error, {:conversation_summary_persistence, changeset.errors}}

  defp recall_locked(context) do
    current =
      Repo.one(
        from(summary in ConversationSummary, where: summary.identity_key == ^context.identity_key)
      )
      |> learning_visible(context)

    related = related_summaries(context)
    rollups = related_rollups(context)
    now = database_now!()

    mark_summaries_recalled(Enum.reject([current | related], &is_nil/1), now)
    mark_rollups_recalled(rollups, now)

    %{
      "current" => if(current, do: summary_document(current)),
      "related" => Enum.map(related, &summary_document/1),
      "rollups" => Enum.map(rollups, &rollup_document/1)
    }
  end

  defp search_locked(context, query, scope, limit) do
    current =
      Repo.one(
        from(summary in ConversationSummary, where: summary.identity_key == ^context.identity_key)
      )
      |> learning_visible(context)

    candidates =
      ([current] |> Enum.reject(&is_nil/1) |> Enum.map(&{:summary, &1})) ++
        Enum.map(related_summaries(context), &{:summary, &1}) ++
        Enum.map(related_rollups(context), &{:rollup, &1})

    selected =
      candidates
      |> Enum.filter(fn candidate ->
        continuity_search_scope?(candidate, scope, context) and
          candidate
          |> continuity_search_document()
          |> CanonicalJSON.encode!()
          |> String.downcase()
          |> String.contains?(String.downcase(query))
      end)
      |> Enum.take(limit)

    summaries = for {:summary, summary} <- selected, do: summary
    rollups = for {:rollup, rollup} <- selected, do: rollup
    now = database_now!()
    mark_summaries_recalled(summaries, now)
    mark_rollups_recalled(rollups, now)

    Enum.map(selected, &continuity_search_document/1)
  end

  defp continuity_search_scope?({:summary, summary}, "current_channel", context),
    do: summary.conversation_ref == context.conversation_ref

  defp continuity_search_scope?({:rollup, rollup}, "current_channel", context),
    do: rollup.scope_kind == :conversation and rollup.scope_ref == context.conversation_ref

  defp continuity_search_scope?({_kind, item}, "repository", context),
    do: is_binary(context.repository_ref) and item.repository_ref == context.repository_ref

  defp continuity_search_scope?({_kind, _item}, "workspace", _context), do: true
  defp continuity_search_scope?(_candidate, _scope, _context), do: false

  defp continuity_search_document({:summary, summary}),
    do: summary |> summary_document() |> Map.put("kind", "continuity")

  defp continuity_search_document({:rollup, rollup}),
    do: rollup |> rollup_document() |> Map.put("kind", "continuity")

  defp related_summaries(context) do
    Repo.all(
      from(summary in ConversationSummary,
        where:
          summary.workspace_ref == ^context.workspace_ref and
            summary.identity_key != ^context.identity_key,
        order_by: [desc: summary.updated_at, desc: summary.id],
        limit: @maximum_candidates
      )
    )
    |> Enum.filter(fn summary ->
      (summary.conversation_ref == context.conversation_ref or
         (context.visibility == :public and summary.visibility == :public and
            public_source_visible?(summary))) and
        LearningSources.valid?(summary.source_dependencies, context)
    end)
    |> Enum.sort_by(&summary_rank(&1, context))
    |> Enum.take(@maximum_related)
  end

  defp related_rollups(context) do
    context
    |> related_rollups_query()
    |> Repo.all()
    |> Enum.filter(
      &(rollup_visible?(&1, context) and LearningSources.valid?(&1.source_dependencies, context))
    )
    |> Enum.take(@maximum_rollups)
  end

  defp related_rollups_query(%{repository_ref: repository_ref} = context)
       when is_binary(repository_ref) do
    from(rollup in ConversationRollup,
      where:
        rollup.workspace_ref == ^context.workspace_ref and
          rollup.expires_at > fragment("clock_timestamp()") and
          ((rollup.scope_kind == :conversation and
              rollup.scope_ref == ^context.conversation_ref) or
             (rollup.scope_kind == :repository and rollup.repository_ref == ^repository_ref)),
      order_by: [desc: rollup.period_end, desc: rollup.id],
      limit: @maximum_candidates
    )
  end

  defp related_rollups_query(context) do
    from(rollup in ConversationRollup,
      where:
        rollup.workspace_ref == ^context.workspace_ref and
          rollup.expires_at > fragment("clock_timestamp()") and
          rollup.scope_kind == :conversation and
          rollup.scope_ref == ^context.conversation_ref,
      order_by: [desc: rollup.period_end, desc: rollup.id],
      limit: @maximum_candidates
    )
  end

  defp learning_visible(nil, _context), do: nil

  defp learning_visible(item, context),
    do: if(LearningSources.valid?(item.source_dependencies, context), do: item)

  defp public_source_visible?(%ConversationSummary{
         transport: "slack",
         workspace_ref: "slack:" <> workspace_ref,
         conversation_ref: conversation_ref
       }) do
    case String.split(conversation_ref, ":", parts: 3) do
      ["slack", ^workspace_ref, channel_ref] ->
        Repo.exists?(
          from(membership in ChannelMembership,
            where:
              membership.workspace_ref == ^workspace_ref and
                membership.channel_ref == ^channel_ref and membership.status == :joined and
                membership.private == false and membership.external_shared == false
          )
        )

      _invalid ->
        false
    end
  end

  defp public_source_visible?(_non_slack), do: false

  defp rollup_visible?(
         %ConversationRollup{scope_kind: :conversation, scope_ref: scope_ref},
         context
       ),
       do: scope_ref == context.conversation_ref

  defp rollup_visible?(%ConversationRollup{scope_kind: :repository} = rollup, context) do
    context.visibility == :public and is_binary(context.repository_ref) and
      rollup.repository_ref == context.repository_ref and rollup.visibility == :public and
      Enum.all?(rollup.source_scopes, &public_rollup_source_visible?/1)
  end

  defp public_rollup_source_visible?(%{
         "channel_ref" => channel_ref,
         "transport" => "slack",
         "workspace_ref" => workspace_ref
       }) do
    public_source_visible?(%ConversationSummary{
      conversation_ref: "slack:#{workspace_ref}:#{channel_ref}",
      transport: "slack",
      workspace_ref: "slack:#{workspace_ref}"
    })
  end

  defp public_rollup_source_visible?(_scope), do: false

  defp summary_rank(summary, context) do
    conversation_rank = if summary.conversation_ref == context.conversation_ref, do: 0, else: 1
    repository_rank = if summary.repository_ref == context.repository_ref, do: 0, else: 1
    recent = -DateTime.to_unix(summary.updated_at, :microsecond)
    {conversation_rank, repository_rank, recent, summary.ref}
  end

  defp summary_document(summary) do
    %{
      "repository_ref" => summary.repository_ref,
      "source_ref" => summary.ref,
      "state" => summary.state,
      "updated_at" => DateTime.to_iso8601(summary.updated_at)
    }
  end

  defp rollup_document(rollup) do
    %{
      "period_end" => DateTime.to_iso8601(rollup.period_end),
      "period_start" => DateTime.to_iso8601(rollup.period_start),
      "repository_ref" => rollup.repository_ref,
      "source_count" => rollup.source_count,
      "source_ref" => rollup.ref,
      "source_refs" => rollup.source_refs,
      "state" => rollup.state
    }
  end

  defp mark_summaries_recalled([], _now), do: :ok

  defp mark_summaries_recalled(summaries, now) do
    ids = Enum.map(summaries, & &1.id)

    Repo.update_all(from(summary in ConversationSummary, where: summary.id in ^ids),
      inc: [recall_count: 1],
      set: [last_recalled_at: now]
    )

    :ok
  end

  defp mark_rollups_recalled([], _now), do: :ok

  defp mark_rollups_recalled(rollups, now) do
    ids = Enum.map(rollups, & &1.id)

    Repo.update_all(from(rollup in ConversationRollup, where: rollup.id in ^ids),
      inc: [recall_count: 1],
      set: [last_recalled_at: now]
    )

    :ok
  end

  defp rollup_identity(summary) do
    period_start = beginning_of_week(summary.updated_at)

    if summary.visibility == :public and is_binary(summary.repository_ref) and
         public_source_visible?(summary) do
      {summary.workspace_ref, :repository, summary.repository_ref, period_start}
    else
      {summary.workspace_ref, :conversation, summary.conversation_ref, period_start}
    end
  end

  defp compact_group([first | _rest] = sources, retention_seconds) do
    {workspace_ref, scope_kind, scope_ref, period_start} = rollup_identity(first)

    existing = locked_rollup(workspace_ref, scope_kind, scope_ref, period_start)
    retained = if existing && existing.state != %{"retention" => "pruned"}, do: existing

    attributes =
      rollup_attributes(
        first,
        sources,
        retained,
        retention_seconds,
        {workspace_ref, scope_kind, scope_ref, period_start}
      )

    complete_compaction(existing, sources, attributes)
  end

  defp locked_rollup(workspace_ref, scope_kind, scope_ref, period_start) do
    Repo.one(
      from(rollup in ConversationRollup,
        where:
          rollup.workspace_ref == ^workspace_ref and rollup.scope_kind == ^scope_kind and
            rollup.scope_ref == ^scope_ref and rollup.period_start == ^period_start,
        lock: "FOR UPDATE"
      )
    )
  end

  defp rollup_attributes(
         first,
         sources,
         existing,
         retention_seconds,
         {workspace_ref, scope_kind, scope_ref, period_start}
       ) do
    states = Enum.map(sources, &{&1.updated_at, &1.state}) ++ existing_states(existing)
    period_end = sources |> Enum.map(& &1.updated_at) |> latest_period_end(existing)
    state = merge_states(states)
    existing_refs = existing_source_refs(existing)
    new_refs = Enum.map(sources, & &1.ref)

    %{
      expires_at: DateTime.add(period_end, retention_seconds, :second),
      period_end: period_end,
      period_start: period_start,
      repository_ref: rollup_repository_ref(scope_kind, scope_ref, first),
      scope_kind: scope_kind,
      scope_ref: scope_ref,
      source_count:
        existing_source_count(existing) + Enum.count(new_refs, &(&1 not in existing_refs)),
      source_refs: bounded_source_refs(existing_refs, new_refs),
      source_scopes: merged_source_scopes(existing, sources),
      source_dependencies:
        LearningSources.merge([
          if(existing, do: existing.source_dependencies, else: [])
          | Enum.map(sources, & &1.source_dependencies)
        ]),
      state: state,
      state_fingerprint: CanonicalJSON.digest(state),
      visibility: rollup_visibility(scope_kind, first),
      workspace_ref: workspace_ref
    }
  end

  defp existing_states(nil), do: []
  defp existing_states(existing), do: [{existing.period_end, existing.state}]

  defp latest_period_end(updated_at_values, nil), do: latest_datetime(updated_at_values)

  defp latest_period_end(updated_at_values, existing),
    do: latest_datetime([latest_datetime(updated_at_values), existing.period_end])

  defp existing_source_refs(nil), do: []
  defp existing_source_refs(existing), do: existing.source_refs

  defp existing_source_count(nil), do: 0
  defp existing_source_count(existing), do: existing.source_count

  defp bounded_source_refs(existing_refs, new_refs) do
    existing_refs
    |> Kernel.++(new_refs)
    |> Enum.uniq()
    |> Enum.sort()
    |> bounded_json_items(@maximum_rollup_source_refs, @maximum_rollup_source_ref_bytes)
  end

  defp merged_source_scopes(existing, sources) do
    existing_source_scopes(existing)
    |> Kernel.++(Enum.map(sources, &summary_source_scope/1))
    |> Enum.uniq()
    |> Enum.sort_by(&CanonicalJSON.encode!/1)
    |> exact_source_scopes!()
  end

  defp existing_source_scopes(nil), do: []
  defp existing_source_scopes(existing), do: existing.source_scopes

  defp rollup_repository_ref(:repository, scope_ref, _first), do: scope_ref
  defp rollup_repository_ref(_scope_kind, _scope_ref, first), do: first.repository_ref

  defp complete_compaction(_existing, _sources, %{source_dependencies: nil}), do: :skipped

  defp complete_compaction(existing, sources, attributes) do
    if DateTime.after?(attributes.expires_at, database_now!()) do
      persist_and_delete_compacted(existing, sources, attributes)
    else
      delete_expired_rollup(existing)
      {_count, nil} = delete_compacted_summaries(sources)
      :ok
    end
  end

  defp persist_and_delete_compacted(existing, sources, attributes) do
    with :ok <- persist_rollup(existing, attributes),
         {_count, nil} <- delete_compacted_summaries(sources) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp delete_expired_rollup(nil), do: :ok
  defp delete_expired_rollup(existing), do: Repo.delete!(existing)

  defp delete_compacted_summaries(sources) do
    Repo.delete_all(
      from(summary in ConversationSummary,
        where: summary.id in ^Enum.map(sources, & &1.id)
      )
    )
  end

  defp persist_rollup(nil, attributes) do
    id = Ecto.UUID.generate()

    attributes
    |> Map.merge(%{id: id, ref: "continuity-rollup:#{id}"})
    |> rollup_changeset(%ConversationRollup{})
    |> Repo.insert()
    |> rollup_result()
  end

  defp persist_rollup(rollup, attributes) do
    attributes
    |> rollup_changeset(rollup)
    |> Repo.update()
    |> rollup_result()
  end

  defp rollup_changeset(attributes, rollup) do
    rollup
    |> Changeset.cast(attributes, [
      :expires_at,
      :id,
      :period_end,
      :period_start,
      :ref,
      :repository_ref,
      :scope_kind,
      :scope_ref,
      :source_count,
      :source_refs,
      :source_scopes,
      :source_dependencies,
      :state,
      :state_fingerprint,
      :visibility,
      :workspace_ref
    ])
    |> Changeset.validate_required([
      :expires_at,
      :period_end,
      :period_start,
      :scope_kind,
      :scope_ref,
      :source_count,
      :source_refs,
      :source_scopes,
      :state,
      :state_fingerprint,
      :visibility,
      :workspace_ref
    ])
    |> Changeset.unique_constraint(:ref)
    |> Changeset.unique_constraint([:workspace_ref, :scope_kind, :scope_ref, :period_start],
      name: :conversation_rollups_identity
    )
    |> Changeset.check_constraint(:scope_kind, name: :conversation_rollup_valid)
  end

  defp rollup_result({:ok, _rollup}), do: :ok

  defp rollup_result({:error, changeset}),
    do: {:error, {:conversation_rollup_persistence, changeset.errors}}

  defp merge_states(states) do
    states = Enum.sort_by(states, fn {updated_at, _state} -> updated_at end, {:desc, DateTime})
    list_fields = ConversationSummaryState.list_fields()

    base =
      Map.new(
        ConversationSummaryState.fields(),
        &{&1, initial_merged_value(&1, list_fields, states)}
      )

    Enum.reduce(list_fields, base, &merge_list_field(states, &1, &2))
  end

  defp initial_merged_value(field, list_fields, states) do
    if field in list_fields,
      do: [],
      else: Enum.find_value(states, fn {_updated_at, state} -> state[field] end)
  end

  defp merge_list_field(states, field, merged) do
    states
    |> Enum.flat_map(fn {_updated_at, state} -> state[field] end)
    |> Enum.uniq()
    |> Enum.take(20)
    |> Enum.reduce_while(merged, &append_bounded_value(&1, &2, field))
  end

  defp append_bounded_value(value, current, field) do
    candidate = Map.update!(current, field, &(&1 ++ [value]))

    if byte_size(CanonicalJSON.encode!(candidate)) <= @maximum_state_bytes,
      do: {:cont, candidate},
      else: {:halt, current}
  end

  defp summary_source_scope(summary) do
    case summary do
      %ConversationSummary{
        transport: "slack",
        workspace_ref: "slack:" <> workspace_ref,
        conversation_ref: conversation_ref
      } ->
        case String.split(conversation_ref, ":", parts: 3) do
          ["slack", ^workspace_ref, channel_ref] ->
            %{
              "channel_ref" => channel_ref,
              "transport" => "slack",
              "workspace_ref" => workspace_ref
            }

          _invalid ->
            %{"conversation_ref" => conversation_ref, "transport" => summary.transport}
        end

      _other ->
        %{"conversation_ref" => summary.conversation_ref, "transport" => summary.transport}
    end
  end

  defp exact_source_scopes!(scopes) do
    if length(scopes) <= @maximum_rollup_source_scopes and
         byte_size(CanonicalJSON.encode!(scopes)) <= @maximum_rollup_source_scope_bytes,
       do: scopes,
       else: Repo.rollback(:conversation_rollup_scope_capacity)
  end

  defp rollup_visibility(:repository, _summary), do: :public

  defp rollup_visibility(:conversation, summary) do
    case summary do
      %ConversationSummary{
        transport: "slack",
        workspace_ref: "slack:" <> workspace_ref,
        conversation_ref: conversation_ref
      } ->
        case String.split(conversation_ref, ":", parts: 3) do
          ["slack", ^workspace_ref, channel_ref] -> slack_visibility(workspace_ref, channel_ref)
          _invalid -> :conversation
        end

      _other ->
        :conversation
    end
  end

  defp bounded_json_items(items, maximum_items, maximum_bytes) do
    items
    |> Enum.take(maximum_items)
    |> Enum.reduce_while([], fn item, kept ->
      candidate = kept ++ [item]

      if byte_size(CanonicalJSON.encode!(candidate)) <= maximum_bytes,
        do: {:cont, candidate},
        else: {:halt, kept}
    end)
  end

  defp beginning_of_week(datetime) do
    date = datetime |> DateTime.to_date() |> Date.beginning_of_week(:monday)
    DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")
  end

  defp latest_datetime(values), do: Enum.max_by(values, &DateTime.to_unix(&1, :microsecond))

  @doc false
  def destination_context(episode, repository_ref) do
    with {:ok, workspace_ref, visibility} <-
           destination_scope(episode.destination_transport, episode.destination_conversation_ref) do
      identity_key =
        CanonicalJSON.digest(%{
          "conversation_ref" => episode.destination_conversation_ref,
          "thread_ref" => episode.destination_thread_ref,
          "transport" => episode.destination_transport
        })

      {:ok,
       %{
         conversation_ref: episode.destination_conversation_ref,
         identity_key: identity_key,
         repository_ref: repository_ref,
         thread_ref: episode.destination_thread_ref,
         transport: episode.destination_transport,
         visibility: visibility,
         workspace_ref: workspace_ref
       }}
    end
  end

  defp destination_scope("slack", "slack:" <> rest = conversation_ref) do
    case String.split(rest, ":", parts: 2) do
      [workspace_ref, "D" <> _channel] ->
        {:ok, "slack:#{workspace_ref}", :direct}

      [workspace_ref, channel_ref] ->
        {:ok, "slack:#{workspace_ref}", slack_visibility(workspace_ref, channel_ref)}

      _invalid ->
        {:ok, conversation_ref, :conversation}
    end
  end

  defp destination_scope("github", "github:" <> rest = conversation_ref) do
    case String.split(rest, ":", parts: 2) do
      [binding_ref, _conversation] when binding_ref != "" ->
        {:ok, "github:#{binding_ref}", :conversation}

      _invalid ->
        {:ok, conversation_ref, :conversation}
    end
  end

  defp destination_scope("control_plane", "control-plane:" <> _rest = conversation_ref),
    do: {:ok, conversation_ref, :conversation}

  defp destination_scope(transport, conversation_ref)
       when is_binary(transport) and byte_size(transport) in 1..64 and
              is_binary(conversation_ref) and byte_size(conversation_ref) in 1..1_024,
       do: {:ok, conversation_ref, :conversation}

  defp destination_scope(_transport, _conversation_ref),
    do: {:error, :conversation_summary_destination}

  defp slack_visibility(workspace_ref, channel_ref) do
    case Repo.one(
           from(membership in ChannelMembership,
             where:
               membership.workspace_ref == ^workspace_ref and
                 membership.channel_ref == ^channel_ref and membership.status == :joined,
             select: {membership.private, membership.external_shared}
           )
         ) do
      {false, false} ->
        :public

      {private, external_shared}
      when is_boolean(private) and is_boolean(external_shared) ->
        :private

      _unknown ->
        :conversation
    end
  end

  defp empty_context, do: %{"current" => nil, "related" => [], "rollups" => []}

  defp database_now! do
    {:ok, %{rows: [[%DateTime{} = now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
