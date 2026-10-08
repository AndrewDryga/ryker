defmodule Ryker.Continuity.Handover do
  @moduledoc """
  Staging a conversation summary during a Work turn and publishing it with the
  turn's accepted result.

  A model may stage a typed summary only while it owns an active Work turn. The
  draft is bound to the exact candidate the host validates, and the summary
  becomes recallable in the same transaction that accepts that result.
  """
  alias Ecto.Changeset
  alias Ryker.CanonicalJSON
  alias Ryker.Continuity
  alias Ryker.Continuity.ConversationSummary
  alias Ryker.Continuity.ConversationSummaryDraft
  alias Ryker.Continuity.ConversationSummaryState
  alias Ryker.Continuity.Scope
  alias Ryker.Episodes
  alias Ryker.Knowledge
  alias Ryker.Learning
  alias Ryker.Repo
  alias Ryker.Slack
  alias Ryker.Work

  @doc """
  Stage a typed summary for the Work turn a state token names. Restaging the
  same state is idempotent; a changed state replaces the draft and unbinds it
  from any candidate the host already validated.
  """
  @spec stage(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def stage("state:" <> turn_id, state) do
    with {:ok, state} <- ConversationSummaryState.prepare(state),
         {:ok, turn_id} <- Ecto.UUID.cast(turn_id) do
      Repo.transaction(fn -> stage_locked(turn_id, state) end)
    else
      :error -> {:error, :conversation_summary_unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def stage(_state_token, _state), do: {:error, :conversation_summary_unauthorized}

  @doc """
  Publish the draft bound to the candidate an accepted result came from, inside
  the transaction that accepts it. A draft for another candidate, a deleted
  channel or an unsourced session is discarded without failing the acceptance.
  """
  @spec accept_staged_in_transaction(
          Episodes.Episode.t(),
          Work.Session.t(),
          Work.Turn.t(),
          String.t()
        ) ::
          :ok | {:error, term()}
  def accept_staged_in_transaction(
        %Episodes.Episode{} = episode,
        %Work.Session{} = session,
        %Work.Turn{} = turn,
        result_ref
      )
      when is_binary(result_ref) do
    if Repo.in_transaction?() do
      case Slack.ChannelFence.authorize_in_transaction(
             episode.destination_transport,
             episode.destination_conversation_ref
           ) do
        :ok ->
          accept_staged_locked(episode, session, turn, result_ref)

        {:error, :slack_channel_deleted} ->
          turn.id
          |> ConversationSummaryDraft.Query.by_turn_id()
          |> ConversationSummaryDraft.Query.by_episode_id(episode.id)
          |> Repo.delete_all()

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :conversation_summary_transaction_required}
    end
  end

  def accept_staged_in_transaction(_episode, _session, _turn, _result_ref),
    do: {:error, :conversation_summary_invalid_acceptance}

  defp accept_staged_locked(episode, session, turn, result_ref) do
    draft =
      turn.id
      |> ConversationSummaryDraft.Query.by_turn_id()
      |> ConversationSummaryDraft.Query.by_episode_id(episode.id)
      |> ConversationSummaryDraft.Query.lock_for_update()
      |> Repo.fetch()

    case draft do
      {:error, :not_found} ->
        :ok

      {:ok, %ConversationSummaryDraft{} = draft} ->
        with :ok <- exact_candidate(draft, turn),
             {:ok, state} <- ConversationSummaryState.prepare(draft.state),
             true <- CanonicalJSON.digest(state) == draft.state_fingerprint,
             {:ok, context} <- Scope.destination_context(episode, session.repository_ref),
             :ok <- upsert_summary(draft, episode, turn, result_ref, context),
             {:ok, _draft} <- Repo.delete(draft) do
          :ok
        else
          {:error, :conversation_summary_candidate_mismatch} ->
            {:ok, _draft} = Repo.delete(draft)
            :ok

          {:error, {:conversation_summary_unavailable, reason}} ->
            # Optional memory maintenance must not roll back an accepted reply.
            # Retain a visible failure on the exact turn, not unsourced prose.
            Repo.update_all(Work.Turn.Query.by_id(turn.id), set: [summary_error_code: reason])

            Episodes.broadcast_episode_updated(turn.episode_id)

            Repo.delete!(draft)
            :ok

          false ->
            {:error, :conversation_summary_fingerprint_mismatch}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Bind the turn's draft to the candidate the host is validating. A draft bound
  to an earlier candidate is dropped so a replaced attempt cannot publish it.
  """
  @spec candidate_staged_in_transaction(Work.Turn.t(), String.t(), pos_integer()) ::
          :ok | {:error, term()}
  def candidate_staged_in_transaction(%Work.Turn{} = turn, candidate_sha256, candidate_attempt)
      when is_binary(candidate_sha256) and is_integer(candidate_attempt) and candidate_attempt > 0 do
    if Repo.in_transaction?() do
      bind_candidate_draft(fetch_and_lock_draft(turn), candidate_sha256, candidate_attempt)
    else
      {:error, :conversation_summary_transaction_required}
    end
  end

  defp bind_candidate_draft({:error, :not_found}, _candidate_sha256, _candidate_attempt), do: :ok

  defp bind_candidate_draft(
         {:ok, %ConversationSummaryDraft{candidate_sha256: nil} = draft},
         candidate_sha256,
         candidate_attempt
       ),
       do: bind_draft(draft, candidate_sha256, candidate_attempt)

  defp bind_candidate_draft(
         {:ok,
          %ConversationSummaryDraft{
            candidate_sha256: candidate_sha256,
            candidate_attempt: candidate_attempt
          }},
         candidate_sha256,
         candidate_attempt
       ),
       do: :ok

  defp bind_candidate_draft({:ok, %ConversationSummaryDraft{} = draft}, _sha256, _attempt) do
    case Repo.delete(draft) do
      {:ok, _draft} -> :ok
      {:error, changeset} -> {:error, {:conversation_summary_persistence, changeset.errors}}
    end
  end

  @doc """
  The fingerprint of the turn's staged draft, taken while the final preflight
  holds the turn locked so a summary changed after validation is detected.
  """
  @spec preflight_fingerprint_in_transaction(Work.Turn.t()) :: String.t() | no_return()
  def preflight_fingerprint_in_transaction(%Work.Turn{} = turn) do
    if Repo.in_transaction?() do
      CanonicalJSON.digest(preflight_document(fetch_and_lock_draft(turn)))
    else
      raise ArgumentError, "preflight fingerprint requires a transaction"
    end
  end

  defp fetch_and_lock_episode(id) do
    id
    |> Episodes.Episode.Query.by_id()
    |> Episodes.Episode.Query.lock_for_update()
    |> staged()
  end

  defp fetch_and_lock_turn(id),
    do: id |> Work.Turn.Query.by_id() |> Work.Turn.Query.lock_for_update() |> staged()

  # A turn or request gone before its summary is staged leaves nothing it may
  # write for.
  defp staged(query) do
    with {:error, :not_found} <- Repo.fetch(query),
         do: {:error, :conversation_summary_unauthorized}
  end

  defp stage_locked(turn_id, state) do
    with {:ok, identity} <- staged(Work.Turn.Query.by_id(turn_id)),
         {:ok, episode} <- fetch_and_lock_episode(identity.episode_id),
         {:ok, turn} <- fetch_and_lock_turn(turn_id),
         :ok <-
           Slack.ChannelFence.authorize_in_transaction(
             episode.destination_transport,
             episode.destination_conversation_ref
           ),
         :ok <- stage_authorized(episode, turn) do
      fingerprint = CanonicalJSON.digest(state)

      existing =
        turn.id
        |> ConversationSummaryDraft.Query.by_turn_id()
        |> ConversationSummaryDraft.Query.lock_for_update()
        |> Repo.fetch()

      case existing do
        {:error, :not_found} ->
          insert_draft(episode, turn, state, fingerprint)

        {:ok,
         %ConversationSummaryDraft{
           state_fingerprint: ^fingerprint,
           candidate_sha256: nil
         } = draft} ->
          draft_result(draft)

        {:ok, %ConversationSummaryDraft{} = draft} ->
          update_draft(draft, state, fingerprint)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp stage_authorized(
         %Episodes.Episode{
           owner_kind: :turn,
           owner_ref: owner_ref,
           state: :working
         },
         %Work.Turn{cancellation_intent: nil, status: :pending, turn_ref: owner_ref}
       ),
       do: :ok

  defp stage_authorized(_episode, _turn), do: {:error, :conversation_summary_unauthorized}

  defp insert_draft(episode, turn, state, fingerprint) do
    id = Repo.generate_id()

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
      {:ok, draft} ->
        Episodes.broadcast_episode_updated(draft.episode_id)
        draft_result(draft)

      {:error, changeset} ->
        Repo.rollback({:conversation_summary_persistence, changeset.errors})
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
      {:ok, updated} ->
        Episodes.broadcast_episode_updated(updated.episode_id)
        draft_result(updated)

      {:error, changeset} ->
        Repo.rollback({:conversation_summary_persistence, changeset.errors})
    end
  end

  defp draft_result(draft) do
    %{
      revision: draft.revision,
      state_fingerprint: draft.state_fingerprint,
      summary_ref: "continuity-draft:#{draft.turn_id}"
    }
  end

  defp fetch_and_lock_draft(turn) do
    turn.id
    |> ConversationSummaryDraft.Query.by_turn_id()
    |> ConversationSummaryDraft.Query.by_episode_id(turn.episode_id)
    |> ConversationSummaryDraft.Query.lock_for_update()
    |> Repo.fetch()
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

  defp preflight_document({:error, :not_found}), do: %{"summary" => nil}

  defp preflight_document({:ok, draft}) do
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
         %Work.Turn{candidate_sha256: sha256, candidate_attempt: attempt}
       )
       when is_binary(sha256) and is_integer(attempt),
       do: :ok

  defp exact_candidate(_draft, _turn), do: {:error, :conversation_summary_candidate_mismatch}

  defp upsert_summary(draft, episode, turn, result_ref, context) do
    case Knowledge.KnowledgeSnapshot.summary_sources(turn.session_id) do
      {:ok, dependencies} ->
        persist_staged_summary(draft, episode, turn, result_ref, context, dependencies)

      {:error, reason} ->
        {:error, {:conversation_summary_unavailable, reason}}
    end
  end

  defp persist_staged_summary(draft, episode, turn, result_ref, context, dependencies) do
    attributes = %{
      compaction_error_code: nil,
      compaction_retry_at: nil,
      conversation_ref: context.conversation_ref,
      identity_key: context.identity_key,
      repository_ref: context.repository_ref,
      source_episode_id: episode.id,
      source_message_ref: List.last(episode.active_input_refs),
      source_result_ref: result_ref,
      source_turn_id: turn.id,
      source_dependencies: dependencies,
      state: draft.state,
      state_fingerprint: draft.state_fingerprint,
      thread_ref: context.thread_ref,
      transport: context.transport,
      visibility: context.visibility,
      workspace_ref: context.workspace_ref
    }

    if Learning.LearningSources.sourced?(attributes.source_dependencies) do
      persist_summary(attributes)
    else
      {:error, {:conversation_summary_unavailable, "no_sources"}}
    end
  end

  # One upsert on the identity key. A read-then-write let two episodes on the
  # same destination — a pull request, a lab, a direct message; anything the
  # channel fence does not serialize — both find no summary, and the second
  # insert failed on the unique index, which rolled the accepted reply back
  # with it. The unique index is the fence: the later writer waits for the
  # earlier one to commit and then replaces its state, and the row keeps its
  # first identity.
  defp persist_summary(attributes) do
    id = Repo.generate_id()
    now = Repo.now!()

    attributes
    |> Map.merge(%{id: id, ref: "continuity:#{id}"})
    |> summary_changeset(%ConversationSummary{})
    |> Changeset.change(inserted_at: now, updated_at: now)
    |> Repo.insert(
      conflict_target: :identity_key,
      on_conflict: {:replace_all_except, [:id, :ref, :inserted_at]}
    )
    |> tap(fn _result ->
      Episodes.broadcast_episode_updated(attributes.source_episode_id)
      Continuity.broadcast_continuity_updated(attributes.conversation_ref)
    end)
    |> persistence_result()
  end

  defp summary_changeset(attributes, summary) do
    summary
    |> Changeset.cast(attributes, [
      :compaction_error_code,
      :compaction_retry_at,
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
end
