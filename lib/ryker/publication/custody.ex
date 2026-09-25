defmodule Ryker.Publication.Custody do
  @moduledoc """
  Durable review, approval, publication, and notification custody.

  A model-created publication offer is inert. This module binds it to the
  delivered episode, its immutable Coop session generation, and one trusted
  repository before any review or GitHub mutation can run.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Ryker.Delivery.Request
  alias Ryker.Episodes.Episode

  alias Ryker.Publication.{
    Card,
    Changeset,
    ConflictReceipt,
    Followups,
    Publication,
    Receipt,
    Review
  }

  alias Ryker.Repo
  alias Ryker.State.{CardDelivery, Record, Records}
  alias Ryker.Work.{DeliveryReceipt, Session, Turn}

  @claimable [:review_pending, :review_ready, :publish_pending, :published_ready]
  @publication_conflicts ~w(publication_branch_already_exists publication_branch_changed publication_existing_pull_request_changed publication_pull_request_mismatch)
  @request_fields [:actor_ref, :occurred_at, :record_ref, :request_ref, :target]
  @approval_fields [:actor_ref, :approval_ref, :occurred_at, :publication_ref, :target]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]

  @spec request_review(keyword() | map()) ::
          {:ok, %{publication: Publication.t(), status: :requested | :duplicate}}
          | {:error, term()}
  def request_review(attributes) do
    with {:ok, attributes} <- attributes(attributes, @request_fields, :review),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- reference(attributes.record_ref, :record_ref),
         :ok <- reference(attributes.request_ref, :request_ref),
         {:ok, occurred_at} <- utc_datetime(attributes.occurred_at),
         {:ok, target} <- target(attributes.target) do
      Repo.transaction(fn ->
        request_review_locked(%{attributes | occurred_at: occurred_at, target: target})
      end)
      |> transaction_result()
    end
  end

  @doc "Queue a confirmed task's ordinary checks inside accepted Work-result custody."
  def ensure_task_review_in_transaction(
        %Episode{} = episode,
        %Session{workspace_task: %{"offer_ref" => task_ref}, repository_ref: repository} = session,
        %Turn{continuation: %{"kind" => "complete"}} = turn
      )
      when is_binary(repository) and is_binary(session.coop_session_id) do
    case confirmed_task_readiness(episode, turn, task_ref) do
      {%Record{} = offer, %Record{} = task,
       %Turn{external_receipt: %{"message_ref" => message} = receipt}} ->
        # The original task confirmation authorizes its checks, not publication.
        # Retain that actor, source message and source thread; no new button
        # receipt is invented, and the checks report where the task was started.
        attributes = %{
          actor_ref: task.confirmed_by_actor_ref,
          occurred_at: turn.accepted_at,
          request_ref: "task-readiness:#{turn.id}",
          target: %{message_ref: message, thread_ref: receipt["thread_ref"]}
        }

        # Later completed turns belong to the task's existing publication,
        # including its pull request and recovery history. Re-arm that one for a
        # fresh review; never open a second draft workflow for the same task.
        case episode_publication(episode.id) do
          nil ->
            _request = insert_review_request(offer, episode, session, repository, attributes)
            :ok

          %Publication{} = publication ->
            rearm_task_review(publication, session, repository, attributes)
        end

      nil ->
        :ok
    end
  end

  def ensure_task_review_in_transaction(_episode, _session, _turn), do: :ok

  defp confirmed_task_readiness(episode, turn, task_ref) do
    Repo.one(
      from(offer in Record,
        join: task in Record,
        on: task.ref == ^task_ref and task.confirmed_episode_id == ^episode.id,
        join: source_turn in Turn,
        on: source_turn.id == task.turn_id and source_turn.episode_id == task.episode_id,
        where:
          offer.episode_id == ^episode.id and offer.turn_id == ^turn.id and
            offer.kind == "publication_offer" and offer.status == :open and
            offer.operation_id == "host:publication:ready",
        where: task.kind == "task_offer" and task.status == :confirmed,
        where: source_turn.status == :settled,
        select: {offer, task, source_turn}
      )
    )
  end

  defp episode_publication(episode_id) do
    Repo.one(
      from(publication in Publication,
        where: publication.episode_id == ^episode_id,
        order_by: [desc: publication.inserted_at, desc: publication.id],
        limit: 1,
        lock: "FOR UPDATE"
      )
    )
  end

  # A corrected candidate is the same task's work, so it belongs on the pull
  # request that task already opened. Before this the second review was refused
  # outright: the correction's checks never ran, the open draft never moved, and
  # the operator's only routes back were "Review latest state" or retyping the
  # whole task. The review generation, not the row, is what is superseded — the
  # pull request, the branch and the review history all stay.
  defp rearm_task_review(publication, session, repository, attributes) do
    cond do
      # Accepting one result twice is ordinary Work custody; the turn that armed
      # the current generation is named on the publication, so a replay is inert.
      publication.review_request_ref == attributes.request_ref ->
        :ok

      rearmable?(publication, repository) ->
        now = database_now!()

        _rearmed =
          update!(
            publication,
            publication
            |> fresh_review_attributes(now)
            |> Map.merge(%{
              approval_ref: nil,
              approved_at: nil,
              approved_by_actor_ref: nil,
              publication_receipt: nil,
              publication_receipt_fingerprint: nil,
              published_at: nil,
              published_delivery_receipt: nil,
              published_delivery_receipt_fingerprint: nil,
              discarded_reason: nil,
              recovery_generation: publication.recovery_generation + 1,
              review_request_ref: attributes.request_ref,
              review_requested_at: attributes.occurred_at,
              review_requested_by_actor_ref: attributes.actor_ref,
              session_id: session.id
            }),
            now
          )

        :ok

      true ->
        :ok
    end
  end

  # Only a settled generation of this task's own repository is re-armable. A
  # review, approval or publish phase still in flight keeps the publication it
  # holds; a discarded candidate is never resurrected; and a head that moved
  # outside this publication is not the agent's to reconcile, which is why the
  # operator's "Review latest state" recovery stays the route through it.
  defp rearmable?(
         %Publication{status: :published, expected_remote_head_sha: nil, repository: repository},
         repository
       ),
       do: true

  defp rearmable?(
         %Publication{status: status, approval_ref: nil, repository: repository},
         repository
       )
       when status in [:reviewed, :blocked],
       do: true

  # Ryker ended this one because its worker session closed, not because anyone
  # decided against publishing. A later completed turn runs in a new session,
  # so its candidate can be reviewed; without this the task's publication
  # stayed discarded and every later candidate went unreviewed.
  defp rearmable?(
         %Publication{
           status: :discarded,
           discarded_reason: :review_session_closed,
           approval_ref: nil,
           repository: repository
         },
         repository
       ),
       do: true

  defp rearmable?(_publication, _repository), do: false

  @spec claim_next(String.t(), pos_integer()) ::
          {:ok,
           nil | %{lease_ref: String.t(), publication: Publication.t(), session: Session.t()}}
          | {:error, term()}
  def claim_next(worker_ref, lease_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> claim_next_locked(worker_ref, lease_seconds) end)
      |> transaction_result()
    end
  end

  def freeze_review_revision(publication_ref, lease_ref, revision) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(revision, :review_expected_revision) do
      Repo.transaction(fn ->
        freeze_review_revision_locked(publication_ref, lease_ref, revision)
      end)
      |> transaction_result()
    end
  end

  def advance_review_generation(publication_ref, lease_ref, generation) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(generation, :review_generation) do
      Repo.transaction(fn ->
        advance_review_generation_locked(publication_ref, lease_ref, generation)
      end)
      |> transaction_result()
    end
  end

  def store_review(publication_ref, lease_ref, generation, review, patch) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(generation, :review_generation) do
      Repo.transaction(fn ->
        store_review_locked(publication_ref, lease_ref, generation, review, patch)
      end)
      |> transaction_result()
    end
  end

  @spec delivery_request(Publication.t()) :: {:ok, Request.t()} | {:error, term()}
  def delivery_request(%Publication{status: :review_ready} = publication) do
    authorized? =
      Review.publishable?(publication.review_document) and
        is_binary(draft_grant(publication))

    message = review_delivery_message(publication, authorized?)

    delivery_request(
      publication,
      review_delivery_ref(publication),
      message,
      Card.review(publication, authorized?)
    )
  end

  def delivery_request(%Publication{status: :published_ready} = publication) do
    receipt = publication.publication_receipt
    message = "Published draft pull request: #{receipt["pull_request_url"]}"

    delivery_request(
      publication,
      result_delivery_ref(publication),
      message,
      Card.published(publication)
    )
  end

  def delivery_request(_publication), do: {:error, :publication_delivery_not_pending}

  defp review_delivery_message(_publication, true),
    do:
      "The committed change passed the trusted review. I'm opening the draft pull request for it now; merging and deploying stay with you."

  defp review_delivery_message(publication, false) do
    if Review.publishable?(publication.review_document) do
      "The committed change passed the trusted review. An operator may publish this exact candidate as a draft pull request."
    else
      "The committed change is not publishable. The trusted review details are below."
    end
  end

  def confirm_delivery(publication_ref, lease_ref, external_receipt) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         {:ok, receipt} <- DeliveryReceipt.prepare(external_receipt) do
      Repo.transaction(fn -> confirm_delivery_locked(publication_ref, lease_ref, receipt) end)
      |> transaction_result()
    end
  end

  def approve(attributes) do
    with {:ok, attributes} <- attributes(attributes, @approval_fields, :approval),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- reference(attributes.approval_ref, :approval_ref),
         :ok <- reference(attributes.publication_ref, :publication_ref),
         {:ok, occurred_at} <- utc_datetime(attributes.occurred_at),
         {:ok, target} <- target(attributes.target) do
      Repo.transaction(fn ->
        approve_locked(%{attributes | occurred_at: occurred_at, target: target})
      end)
      |> transaction_result()
    end
  end

  def store_publication(publication_ref, lease_ref, receipt) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref) do
      Repo.transaction(fn -> store_publication_locked(publication_ref, lease_ref, receipt) end)
      |> transaction_result()
    end
  end

  def store_conflict(publication_ref, lease_ref, code, receipt) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         {:ok, code} <- publication_conflict(code) do
      Repo.transaction(fn -> store_conflict_locked(publication_ref, lease_ref, code, receipt) end)
      |> transaction_result()
    end
  end

  def renew(publication_ref, lease_ref, lease_seconds) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> renew_locked(publication_ref, lease_ref, lease_seconds) end)
      |> transaction_result()
    end
  end

  def defer(publication_ref, lease_ref, retry_seconds, code, detail) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(retry_seconds, :retry_seconds),
         :ok <- bounded_error(code, :last_error_code),
         :ok <- bounded_error(detail, :last_error_detail) do
      Repo.transaction(fn ->
        defer_locked(publication_ref, lease_ref, retry_seconds, code, detail)
      end)
      |> transaction_result()
    end
  end

  @doc """
  Ends a review whose worker session closed for good.

  The change exists only in the session that made it, and a closed Coop
  session never reopens, so no retry can run this review. The publication is
  discarded with that reason instead of being deferred to ask the same session
  again. Its request, attempts and review generations stay as history, and the
  recovery generation advances so a stale operator action cannot act on it.
  """
  @spec discard_unreviewable(String.t(), String.t(), :review_session_closed) ::
          {:ok, Publication.t()} | {:error, term()}
  def discard_unreviewable(publication_ref, lease_ref, :review_session_closed = reason) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- reference(lease_ref, :lease_ref) do
      Repo.transaction(fn -> discard_unreviewable_locked(publication_ref, lease_ref, reason) end)
      |> transaction_result()
    end
  end

  defp discard_unreviewable_locked(publication_ref, lease_ref, reason) do
    with {:ok, publication, now} <- lock_leased(publication_ref, lease_ref),
         :ok <- status(publication, :review_pending) do
      attributes =
        publication.recovery_generation
        |> discard_attributes()
        |> Map.put(:discarded_reason, reason)

      update!(publication, attributes, now)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  Recovers one exact publication generation.

  Retry rearms a deferred executable phase without changing its frozen review
  state. Update invalidates the prior review and queues a fresh one, including a
  review_pending phase whose own failure no retry can clear. Discard is terminal
  and preserves the prior review as operator evidence. Every action is fenced by
  `recovery_generation`, and an active executor lease always wins.
  """
  @spec recover(String.t(), :retry | :update | :discard, pos_integer()) ::
          {:ok, %{previous: map(), publication: Publication.t()}} | {:error, term()}
  def recover(publication_ref, action, expected_generation) do
    with :ok <- reference(publication_ref, :publication_ref),
         :ok <- recovery_action(action),
         :ok <- positive(expected_generation, :recovery_generation) do
      Repo.transaction(fn -> recover_locked(publication_ref, action, expected_generation) end)
      |> transaction_result()
    end
  end

  defp recover_locked(publication_ref, action, expected_generation) do
    case lock_publication(publication_ref) do
      nil ->
        Repo.rollback(:publication_not_found)

      publication ->
        now = database_now!()

        with :ok <- recovery_generation(publication, expected_generation),
             :ok <- no_live_recovery_lease(publication, now),
             {:ok, attributes} <- recovery_attributes(publication, action, now) do
          previous = recovery_snapshot(publication)
          recovered = update!(publication, attributes, now)
          %{previous: previous, publication: recovered}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp recovery_generation(%Publication{recovery_generation: expected}, expected), do: :ok

  defp recovery_generation(_publication, _expected),
    do: {:error, :publication_recovery_generation_stale}

  defp no_live_recovery_lease(%Publication{lease_ref: nil}, _now), do: :ok

  defp no_live_recovery_lease(%Publication{lease_expires_at: %DateTime{} = expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt,
      do: {:error, :publication_recovery_lease_active},
      else: :ok
  end

  defp no_live_recovery_lease(_publication, _now),
    do: {:error, :publication_recovery_lease_active}

  defp recovery_attributes(
         %Publication{status: status, last_error_code: code, recovery_generation: generation},
         :retry,
         now
       )
       when status in @claimable and is_binary(code) and code not in @publication_conflicts do
    {:ok,
     %{
       last_error_code: nil,
       last_error_detail: nil,
       lease_expires_at: nil,
       lease_owner: nil,
       lease_ref: nil,
       next_attempt_at: now,
       recovery_generation: generation + 1
     }}
  end

  defp recovery_attributes(
         %Publication{
           status: :published,
           expected_remote_head_sha: head_sha,
           recovery_generation: generation
         } = publication,
         :update,
         now
       )
       when is_binary(head_sha) do
    with :ok <- Followups.rearm_stale_in_transaction(publication, now) do
      {:ok,
       publication
       |> fresh_review_attributes(now)
       |> Map.merge(%{
         approval_ref: nil,
         approved_at: nil,
         approved_by_actor_ref: nil,
         publication_receipt: nil,
         publication_receipt_fingerprint: nil,
         published_at: nil,
         published_delivery_receipt: nil,
         published_delivery_receipt_fingerprint: nil,
         recovery_generation: generation + 1
       })}
    end
  end

  defp recovery_attributes(
         %Publication{
           status: :publish_pending,
           expected_remote_head_sha: head_sha,
           last_error_code: code,
           recovery_generation: generation
         } = publication,
         :update,
         now
       )
       when is_binary(head_sha) and code in @publication_conflicts do
    with :ok <- Followups.rearm_conflict_in_transaction(publication, now) do
      {:ok,
       publication
       |> fresh_review_attributes(now)
       |> Map.merge(%{
         approval_ref: nil,
         approved_at: nil,
         approved_by_actor_ref: nil,
         recovery_generation: generation + 1
       })}
    end
  end

  # A review phase can fail in a way no retry can clear: the operation it is reconciling belongs to
  # a placement that has been replaced, and reconciliation never re-places that lookup. Retry only
  # rearms the same doomed call, and before this clause nothing else applied to review_pending — so
  # the publication deferred once a minute forever with no operator exit. Update queues a FRESH
  # review generation, which asks a new question instead of re-asking the unanswerable one. It
  # requires a recorded failure: a review that is merely slow is not stuck.
  defp recovery_attributes(
         %Publication{
           status: :review_pending,
           approval_ref: nil,
           last_error_code: code,
           recovery_generation: generation
         } = publication,
         :update,
         now
       )
       when is_binary(code) do
    {:ok,
     publication
     |> fresh_review_attributes(now)
     |> Map.put(:recovery_generation, generation + 1)}
  end

  defp recovery_attributes(
         %Publication{status: status, approval_ref: nil, recovery_generation: generation} =
           publication,
         :update,
         now
       )
       when status in [:reviewed, :blocked] do
    {:ok,
     publication
     |> fresh_review_attributes(now)
     |> Map.put(:recovery_generation, generation + 1)}
  end

  defp recovery_attributes(
         %Publication{
           status: :published,
           expected_remote_head_sha: head_sha,
           recovery_generation: generation
         },
         :discard,
         _now
       )
       when is_binary(head_sha) do
    {:ok, discard_attributes(generation)}
  end

  defp recovery_attributes(
         %Publication{
           status: :publish_pending,
           last_error_code: code,
           recovery_generation: generation
         },
         :discard,
         _now
       )
       when code in @publication_conflicts do
    {:ok, discard_attributes(generation)}
  end

  defp recovery_attributes(
         %Publication{status: status, approval_ref: nil, recovery_generation: generation},
         :discard,
         _now
       )
       when status in [:reviewed, :blocked] do
    {:ok, discard_attributes(generation)}
  end

  defp recovery_attributes(_publication, _action, _now),
    do: {:error, :publication_recovery_not_allowed}

  defp discard_attributes(generation) do
    %{
      last_error_code: nil,
      last_error_detail: nil,
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      next_attempt_at: nil,
      recovery_generation: generation + 1,
      status: :discarded
    }
  end

  defp recovery_snapshot(publication) do
    snapshot = %{
      "last_error_code" => publication.last_error_code,
      "recovery_generation" => publication.recovery_generation,
      "status" => Atom.to_string(publication.status)
    }

    if is_binary(publication.expected_remote_head_sha),
      do: Map.put(snapshot, "expected_remote_head_sha", publication.expected_remote_head_sha),
      else: snapshot
  end

  defp fresh_review_attributes(publication, now) do
    %{
      last_error_code: nil,
      last_error_detail: nil,
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      next_attempt_at: now,
      review_delivery_receipt: nil,
      review_delivery_receipt_fingerprint: nil,
      review_document: nil,
      review_expected_revision: nil,
      review_fingerprint: nil,
      review_generation: publication.review_generation + 1,
      review_patch: nil,
      reviewed_at: nil,
      status: :review_pending
    }
  end

  defp freeze_review_revision_locked(publication_ref, lease_ref, revision) do
    with {:ok, publication, now} <- lock_leased(publication_ref, lease_ref),
         :ok <- status(publication, :review_pending) do
      case publication.review_expected_revision do
        nil -> update!(publication, %{review_expected_revision: revision}, now)
        ^revision -> publication
        _other -> Repo.rollback(:publication_review_revision_conflict)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp advance_review_generation_locked(publication_ref, lease_ref, generation) do
    with {:ok, publication, now} <- lock_leased(publication_ref, lease_ref),
         :ok <- status(publication, :review_pending),
         true <- publication.review_generation == generation do
      update!(
        publication,
        %{review_expected_revision: nil, review_generation: generation + 1},
        now
      )
    else
      false -> Repo.rollback(:publication_review_generation_stale)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp store_review_locked(publication_ref, lease_ref, generation, review, patch) do
    with {:ok, publication, now} <- lock_leased(publication_ref, lease_ref),
         :ok <- status(publication, :review_pending),
         true <- publication.review_generation == generation,
         {:ok, session} <- session(publication.session_id),
         {:ok, prepared} <-
           Review.prepare(review, %{
             revision: publication.review_expected_revision,
             session_id: session.coop_session_id
           }),
         :ok <- exact_review_policy(prepared, session),
         {:ok, patch} <- exact_patch(prepared, patch) do
      persist_review(publication, prepared, patch, now)
    else
      false -> Repo.rollback(:publication_review_generation_stale)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A phase that completes clears the failure an earlier attempt recorded. The
  # stale code used to ride along into every later phase, so a publication that
  # had recovered on its own stayed on the Failures page as broken.
  defp persist_review(publication, prepared, patch, now) do
    update!(
      publication,
      %{
        review_document: prepared,
        review_fingerprint: Review.fingerprint(prepared),
        review_patch: patch,
        reviewed_at: now,
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        status: :review_ready
      },
      now
    )
  end

  defp store_publication_locked(publication_ref, lease_ref, receipt) do
    with {:ok, publication, now} <- lock_leased(publication_ref, lease_ref),
         :ok <- status(publication, :publish_pending),
         {:ok, receipt} <-
           Receipt.prepare(receipt, publication.review_document, publication.repository) do
      persist_publication(publication, receipt, now)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp store_conflict_locked(publication_ref, lease_ref, code, receipt) do
    with {:ok, publication, now} <- lock_leased(publication_ref, lease_ref),
         :ok <- status(publication, :publish_pending),
         {:ok, receipt} <- ConflictReceipt.prepare(receipt, publication.repository) do
      update!(
        publication,
        %{
          branch_ref: receipt["branch_ref"],
          commit_sha: receipt["candidate_commit_sha"],
          expected_remote_head_sha: receipt["observed_head_sha"],
          github_repository: receipt["github_repository"],
          last_error_code: code,
          pull_request_number: receipt["pull_request_number"],
          pull_request_url: receipt["pull_request_url"]
        },
        now
      )
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist_publication(publication, receipt, now) do
    update!(
      publication,
      %{
        branch_ref: receipt["branch_ref"],
        commit_sha: receipt["commit_sha"],
        expected_remote_head_sha: nil,
        github_repository: github_repository!(receipt["pull_request_url"]),
        last_error_code: nil,
        last_error_detail: nil,
        publication_receipt: receipt,
        publication_receipt_fingerprint: Receipt.fingerprint(receipt),
        pull_request_number: receipt["pull_request_number"],
        pull_request_url: receipt["pull_request_url"],
        published_at: now,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        status: :published_ready
      },
      now
    )
  end

  defp renew_locked(publication_ref, lease_ref, lease_seconds) do
    case lock_leased(publication_ref, lease_ref) do
      {:ok, publication, now} ->
        update!(
          publication,
          %{lease_expires_at: DateTime.add(now, lease_seconds, :second)},
          now
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp defer_locked(publication_ref, lease_ref, retry_seconds, code, detail) do
    case lock_leased(publication_ref, lease_ref) do
      {:ok, publication, now} ->
        update!(
          publication,
          %{
            last_error_code: code,
            last_error_detail: detail,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: DateTime.add(now, retry_seconds, :second)
          },
          now
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp request_review_locked(attributes) do
    case publication_for_record(attributes.record_ref) do
      %Publication{} = publication ->
        if publication.review_request_ref == attributes.request_ref and
             publication.review_requested_by_actor_ref == attributes.actor_ref do
          %{publication: publication, status: :duplicate}
        else
          Repo.rollback(:publication_offer_already_requested)
        end

      nil ->
        create_review_request(attributes)
    end
  end

  defp create_review_request(attributes) do
    with {:ok, record, episode, turn, session} <- delivered_offer(attributes.record_ref),
         :ok <- delivered_offer_proof(record, episode, turn, attributes.target),
         {:ok, repository} <- repository(session, episode.id),
         true <- is_binary(session.coop_session_id) do
      insert_review_request(record, episode, session, repository, attributes)
    else
      false -> Repo.rollback(:publication_session_not_bound)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_review_request(record, episode, session, repository, attributes) do
    id = Ecto.UUID.generate()

    publication =
      Changeset.insert(%{
        body: record.payload["body"],
        destination_conversation_ref: episode.destination_conversation_ref,
        destination_thread_ref: attributes.target.thread_ref || attributes.target.message_ref,
        destination_transport: episode.destination_transport,
        episode_id: episode.id,
        id: id,
        offer_message_ref: attributes.target.message_ref,
        record_id: record.id,
        ref: "publication:#{id}",
        repository: repository,
        review_request_ref: attributes.request_ref,
        review_requested_at: attributes.occurred_at,
        review_requested_by_actor_ref: attributes.actor_ref,
        session_id: session.id,
        status: :review_pending,
        title: record.payload["title"]
      })
      |> Repo.insert()

    case publication do
      {:ok, publication} -> %{publication: publication, status: :requested}
      {:error, changeset} -> Repo.rollback({:publication_persistence_failed, changeset.errors})
    end
  end

  defp publication_for_record(record_ref) do
    Repo.one(
      from(publication in Publication,
        join: record in Record,
        on: record.id == publication.record_id,
        where: record.ref == ^record_ref,
        select: publication,
        lock: "FOR UPDATE"
      )
    )
  end

  defp delivered_offer(record_ref) do
    query =
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        join: session in Session,
        on: session.id == turn.session_id and session.episode_id == record.episode_id,
        where:
          record.ref == ^record_ref and record.kind == "publication_offer" and
            record.status == :open,
        select: {record, episode, turn, session}
      )

    case Repo.one(query) do
      {%Record{} = record, %Episode{} = episode, %Turn{status: :settled} = turn,
       %Session{} = session} ->
        {:ok, record, episode, turn, session}

      nil ->
        {:error, :publication_offer_not_found}

      _not_delivered ->
        {:error, :publication_offer_not_delivered}
    end
  end

  defp delivered_target(episode, turn, target) do
    case CardDelivery.delivered_from?(episode, turn, target) do
      :ok -> :ok
      {:error, :mismatch} -> {:error, :publication_offer_delivery_mismatch}
      {:error, :not_delivered} -> {:error, :publication_offer_not_delivered}
    end
  end

  defp delivered_offer_proof(record, episode, turn, target) do
    with :ok <- delivered_target(episode, turn, target),
         do: record_was_delivered(turn, record.ref)
  end

  defp record_was_delivered(%Turn{delivery_document: document}, record_ref) do
    if record_ref in get_in(document || %{}, ["outcome", "record_refs"]),
      do: :ok,
      else: {:error, :publication_offer_not_delivered}
  rescue
    Protocol.UndefinedError -> {:error, :publication_offer_not_delivered}
  end

  defp repository(%Session{repository_ref: repository, workspace_task: task}, _episode_id)
       when is_binary(repository) and is_map(task),
       do: {:ok, repository}

  defp repository(_session, episode_id) do
    case Records.repository_write_goals(episode_id) do
      [%{"writable_repository" => repository} | rest] ->
        if Enum.all?(rest, &(&1["writable_repository"] == repository)),
          do: {:ok, repository},
          else: {:error, :publication_repository_conflict}

      [] ->
        {:error, :publication_repository_not_bound}
    end
  end

  defp claim_next_locked(worker_ref, lease_seconds) do
    now = database_now!()

    case Repo.one(next_claimable_query(now)) do
      nil ->
        nil

      {publication, session} ->
        # The joined session is locked by next_claimable_query. Recheck Work
        # custody after acquiring it, before starting Coop's exclusive review.
        if publication.status != :review_pending or
             not Repo.exists?(
               from(e in active_work_episodes(), where: e.id == ^session.episode_id)
             ) do
          lease_publication(publication, session, worker_ref, lease_seconds, now)
        end
    end
  end

  defp next_claimable_query(now) do
    from([publication, session] in claimable_query(now),
      order_by: [asc: publication.inserted_at, asc: publication.id],
      limit: 1,
      select: {publication, session},
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  @doc false
  def claimable_query(now) do
    from(publication in Publication,
      join: session in Session,
      on: session.id == publication.session_id and session.episode_id == publication.episode_id,
      where:
        publication.status != :review_pending or
          publication.episode_id not in subquery(active_work_episodes()),
      where:
        publication.status in ^@claimable and
          (is_nil(publication.last_error_code) or
             publication.last_error_code not in ^@publication_conflicts) and
          (is_nil(publication.next_attempt_at) or publication.next_attempt_at <= ^now) and
          (is_nil(publication.lease_expires_at) or publication.lease_expires_at <= ^now)
    )
  end

  defp active_work_episodes do
    from(episode in Episode,
      where: episode.state == :working and episode.owner_kind == :turn,
      select: episode.id
    )
  end

  defp lease_publication(publication, session, worker_ref, lease_seconds, now) do
    lease_ref = "publication-lease:#{Ecto.UUID.generate()}"

    publication =
      update!(
        publication,
        %{
          attempt_count: publication.attempt_count + 1,
          lease_expires_at: DateTime.add(now, lease_seconds, :second),
          lease_owner: worker_ref,
          lease_ref: lease_ref,
          next_attempt_at: nil
        },
        now
      )

    %{lease_ref: lease_ref, publication: publication, session: session}
  end

  defp confirm_delivery_locked(publication_ref, lease_ref, receipt) do
    publication = lock_publication(publication_ref)
    fingerprint = DeliveryReceipt.fingerprint(receipt)

    cond do
      publication == nil ->
        Repo.rollback(:publication_not_found)

      publication.review_delivery_receipt_fingerprint == fingerprint and
          publication.status in [:reviewed, :blocked] ->
        publication

      publication.published_delivery_receipt_fingerprint == fingerprint and
          publication.status == :published ->
        publication

      true ->
        now = database_now!()

        with :ok <- live_lease(publication, lease_ref, now),
             :ok <- exact_delivery_receipt(publication, receipt) do
          confirm_phase_delivery(publication, receipt, fingerprint, now)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp confirm_phase_delivery(%Publication{status: :review_ready} = publication, receipt, fp, now) do
    delivered = %{
      last_error_code: nil,
      last_error_detail: nil,
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      review_delivery_receipt: receipt,
      review_delivery_receipt_fingerprint: fp
    }

    attributes =
      if Review.publishable?(publication.review_document),
        do: reviewed_or_authorized_draft(publication, delivered, now),
        else: Map.put(delivered, :status, :blocked)

    update!(publication, attributes, now)
  end

  defp confirm_phase_delivery(
         %Publication{status: :published_ready} = publication,
         receipt,
         fp,
         now
       ) do
    published =
      update!(
        publication,
        %{
          last_error_code: nil,
          last_error_detail: nil,
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          published_delivery_receipt: receipt,
          published_delivery_receipt_fingerprint: fp,
          status: :published
        },
        now
      )

    _followup = Followups.ensure_published_in_transaction(published, now)
    published
  end

  defp confirm_phase_delivery(_publication, _receipt, _fp, _now),
    do: Repo.rollback(:publication_delivery_not_pending)

  # The person who confirmed the task already authorized this work in the
  # repository they named, so opening a draft pull request from the exact
  # candidate that work produced asks them for nothing new. Merge, deployment
  # and any other repository remain separate decisions, and a candidate the
  # gate did not clear never reaches here.
  defp reviewed_or_authorized_draft(publication, delivered, now) do
    case draft_grant(publication) do
      actor_ref when is_binary(actor_ref) ->
        Map.merge(delivered, %{
          approval_ref: "host:publication:draft:#{publication.id}",
          approved_at: now,
          approved_by_actor_ref: actor_ref,
          status: :publish_pending
        })

      nil ->
        Map.put(delivered, :status, :reviewed)
    end
  end

  # The grant is the confirmed task record itself: revoke the confirmation or
  # name a different repository and there is no authority left to carry.
  defp draft_grant(%Publication{episode_id: episode_id, repository: repository})
       when is_binary(episode_id) and is_binary(repository) do
    Repo.one(
      from(task in Record,
        where:
          task.kind == "task_offer" and task.status == :confirmed and
            task.confirmed_episode_id == ^episode_id and
            fragment("(?::jsonb) ->> 'repository' = ?", task.payload, ^repository),
        order_by: [asc: task.sequence],
        limit: 1,
        select: task.confirmed_by_actor_ref
      )
    )
  end

  defp draft_grant(_publication), do: nil

  defp approve_locked(attributes) do
    case lock_publication(attributes.publication_ref) do
      nil ->
        Repo.rollback(:publication_not_found)

      %Publication{approval_ref: approval_ref} = publication when is_binary(approval_ref) ->
        if exact_approval?(publication, attributes),
          do: %{publication: publication, status: :duplicate},
          else: Repo.rollback(:publication_approval_conflict)

      %Publication{status: status} = publication when status in [:reviewed, :blocked] ->
        with true <- approvable?(publication),
             :ok <- exact_approval_target(publication, attributes.target) do
          approved =
            update!(
              publication,
              %{
                approval_ref: attributes.approval_ref,
                approved_at: attributes.occurred_at,
                approved_by_actor_ref: attributes.actor_ref,
                status: :publish_pending
              },
              database_now!()
            )

          %{publication: approved, status: :approved}
        else
          false -> Repo.rollback(:publication_not_publishable)
          {:error, reason} -> Repo.rollback(reason)
        end

      _not_reviewed ->
        Repo.rollback(:publication_not_reviewed)
    end
  end

  # Merge readiness releases the ordinary publish path. A blocked candidate is
  # releasable only on the separate draft-shareability verdict, and only by an
  # explicit operator approval: the host never opens an unverified draft itself.
  defp approvable?(%Publication{status: :reviewed, review_document: review}),
    do: Review.publishable?(review)

  defp approvable?(%Publication{status: :blocked, review_document: review}),
    do: Review.draft_shareable?(review)

  defp exact_approval?(publication, attributes) do
    publication.approval_ref == attributes.approval_ref and
      publication.approved_by_actor_ref == attributes.actor_ref and
      publication.approved_at == attributes.occurred_at and
      exact_approval_target(publication, attributes.target) == :ok
  end

  defp exact_approval_target(publication, target) do
    receipt = publication.review_delivery_receipt

    expected = %{
      conversation_ref: publication.destination_conversation_ref,
      message_ref: receipt && receipt["message_ref"],
      thread_ref: publication.destination_thread_ref,
      transport: publication.destination_transport
    }

    if expected == target,
      do: :ok,
      else: {:error, :publication_review_delivery_mismatch}
  end

  defp lock_leased(publication_ref, lease_ref) do
    case lock_publication(publication_ref) do
      nil ->
        {:error, :publication_not_found}

      publication ->
        now = database_now!()

        case live_lease(publication, lease_ref, now) do
          :ok -> {:ok, publication, now}
          {:error, _reason} = error -> error
        end
    end
  end

  defp lock_publication(publication_ref) do
    Repo.one(
      from(publication in Publication,
        where: publication.ref == ^publication_ref,
        lock: "FOR UPDATE"
      )
    )
  end

  defp live_lease(publication, lease_ref, now) do
    if publication.status in @claimable and publication.lease_ref == lease_ref and
         is_struct(publication.lease_expires_at, DateTime) and
         DateTime.compare(publication.lease_expires_at, now) == :gt,
       do: :ok,
       else: {:error, :publication_lease_lost}
  end

  defp exact_delivery_receipt(publication, receipt) do
    expected_ref =
      case publication.status do
        :review_ready -> review_delivery_ref(publication)
        :published_ready -> result_delivery_ref(publication)
        _other -> nil
      end

    if is_binary(expected_ref) and receipt["delivery_ref"] == expected_ref and
         receipt["transport"] == publication.destination_transport and
         receipt["conversation_ref"] == publication.destination_conversation_ref and
         receipt["thread_ref"] == publication.destination_thread_ref do
      :ok
    else
      {:error, :publication_delivery_receipt_mismatch}
    end
  end

  # Two review generations of one publication are two facts, not one message.
  # Slack reconciles a repeat delivery ref onto the message that already carries
  # it, so a ref naming only the publication landed a re-armed review silently
  # on the card its superseded generation had posted.
  defp review_delivery_ref(publication),
    do: "publication-review:#{publication.id}:g#{publication.review_generation}"

  defp result_delivery_ref(publication),
    do: "publication-result:#{publication.id}:g#{publication.review_generation}"

  defp delivery_request(publication, ref, message, record) do
    Request.new(%{
      conversation_ref: publication.destination_conversation_ref,
      document: %{"message" => message, "records" => [record]},
      kind: :message,
      ref: ref,
      source_item_ref: nil,
      thread_ref: publication.destination_thread_ref,
      transport: publication.destination_transport
    })
  end

  defp exact_review_policy(%{"policy_digest" => digest}, %{policy_digest: digest}), do: :ok

  defp exact_review_policy(_review, _session),
    do: {:error, :publication_review_policy_mismatch}

  # A snapshot that only a person may share still has to be exactly the change
  # the review described. Retaining it is preservation, not a claim that any
  # check passed.
  defp exact_patch(review, patch) do
    cond do
      Review.draft_shareable?(review) and is_binary(patch) and patch != "" and
        byte_size(patch) == review["patch_bytes"] and digest(patch) == review["patch_digest"] ->
        {:ok, patch}

      not Review.draft_shareable?(review) and is_nil(patch) ->
        {:ok, nil}

      true ->
        {:error, :publication_review_patch_mismatch}
    end
  end

  defp session(session_id) do
    case Repo.get(Session, session_id) do
      %Session{coop_session_id: coop_session_id} = session when is_binary(coop_session_id) ->
        {:ok, session}

      _missing ->
        {:error, :publication_session_not_bound}
    end
  end

  defp status(%Publication{status: expected}, expected), do: :ok
  defp status(_publication, _expected), do: {:error, :publication_status_changed}

  defp update!(publication, attributes, now) do
    publication
    |> Changeset.update(Map.put(attributes, :updated_at, now))
    |> Repo.update!()
  end

  defp attributes(attributes, fields, namespace) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> attributes(fields, namespace),
       else: {:error, {String.to_atom("invalid_publication_#{namespace}"), :fields}}
  end

  defp attributes(attributes, fields, namespace) when is_map(attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(fields),
      do: {:ok, attributes},
      else: {:error, {String.to_atom("invalid_publication_#{namespace}"), :fields}}
  end

  defp attributes(_attributes, _fields, namespace),
    do: {:error, {String.to_atom("invalid_publication_#{namespace}"), :fields}}

  defp target(target) when is_map(target) do
    if Map.keys(target) |> Enum.sort() == Enum.sort(@target_fields) do
      with :ok <- reference(target.transport, :transport),
           :ok <- reference(target.conversation_ref, :conversation_ref),
           :ok <- optional_reference(target.thread_ref, :thread_ref),
           :ok <- reference(target.message_ref, :message_ref) do
        {:ok, target}
      end
    else
      {:error, {:invalid_publication_target, :fields}}
    end
  end

  defp target(_target), do: {:error, {:invalid_publication_target, :fields}}

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_publication, field}}
  end

  defp bounded_error(value, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..4_096,
      do: :ok,
      else: {:error, {:invalid_publication, field}}
  end

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_publication, field}}

  defp recovery_action(action) when action in [:retry, :update, :discard], do: :ok

  defp recovery_action(_action),
    do: {:error, {:invalid_publication, :recovery_action}}

  defp publication_conflict(code) when is_atom(code) do
    code = Atom.to_string(code)

    if code in @publication_conflicts,
      do: {:ok, code},
      else: {:error, {:invalid_publication, :conflict_code}}
  end

  defp publication_conflict(_code),
    do: {:error, {:invalid_publication, :conflict_code}}

  defp utc_datetime(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0 do
      {microsecond, _precision} = value.microsecond
      {:ok, %{value | microsecond: {microsecond, 6}}}
    else
      {:error, {:invalid_publication, :occurred_at}}
    end
  end

  defp utc_datetime(_value), do: {:error, {:invalid_publication, :occurred_at}}

  defp database_now! do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp github_repository!(url) do
    %URI{host: "github.com", path: path} = URI.parse(url)
    [owner, repository, "pull", _number] = String.split(String.trim_leading(path, "/"), "/")
    "#{owner}/#{repository}"
  end
end
