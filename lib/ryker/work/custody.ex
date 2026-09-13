defmodule Ryker.Work.Custody do
  @moduledoc """
  Durable ownership for episode-scoped Coop sessions and logical work turns.

  The episode remains the source of truth for user-visible lifecycle state.
  These rows only preserve execution identity, frozen model context, and a
  fenced worker lease across process restarts.

  This module is the public entry point; each function delegates to the seam
  that owns it. `Ryker.Work.Custody.Sessions` pins episodes and rotates session
  generations, `Ryker.Work.Custody.Claims` claims work and holds the lease,
  `Ryker.Work.Custody.Turns` carries one turn from frozen submission to accepted
  result and fences remote mutations, `Ryker.Work.Custody.Delivery` confirms,
  blocks, and pauses delivery, `Ryker.Work.Custody.Cancellation` stops turns and
  recovers blocked episodes, and `Ryker.Work.Custody.Locks` holds the row
  locking and argument validation they all share.
  """

  alias Ryker.Episodes.Episode
  alias Ryker.Work.Custody.{Cancellation, Claims, Delivery, Sessions, Turns}
  alias Ryker.Work.{Result, Session, Submission, Turn}

  @type claim :: %{
          episode: Episode.t(),
          lease_ref: String.t(),
          session: Session.t(),
          turn: Turn.t()
        }

  @doc """
  Pins the trusted Coop policy before an episode can enter execution custody.

  Workers never supply or replace this authority. The argument is the default
  for a new episode; an existing episode keeps its stored policy across config
  deploys. Authority changes require an explicit owner-fenced migration.
  """
  @spec pin_episode(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  defdelegate pin_episode(episode_id, policy, policy_digest), to: Sessions

  @spec pin_episode(Ecto.UUID.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Session.t()} | {:error, term()}
  defdelegate pin_episode(episode_id, policy, policy_digest, repository_ref), to: Sessions

  @spec pin_episode(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) :: {:ok, Session.t()} | {:error, term()}
  defdelegate pin_episode(episode_id, policy, policy_digest, authority_digest, repository_ref),
    to: Sessions

  @spec pin_episode(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          map() | nil
        ) :: {:ok, Session.t()} | {:error, term()}
  defdelegate pin_episode(
                episode_id,
                policy,
                policy_digest,
                authority_digest,
                repository_ref,
                repository_context
              ),
              to: Sessions

  @spec pin_episode(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          map() | nil,
          map() | nil
        ) :: {:ok, Session.t()} | {:error, term()}
  defdelegate pin_episode(
                episode_id,
                policy,
                policy_digest,
                authority_digest,
                repository_ref,
                repository_context,
                repository_source
              ),
              to: Sessions

  @doc false
  @spec pin_episode_in_transaction(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  defdelegate pin_episode_in_transaction(episode_id, policy, policy_digest), to: Sessions

  @spec pin_episode_in_transaction(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil
        ) :: {:ok, Turn.t()} | {:error, term()}
  defdelegate pin_episode_in_transaction(episode_id, policy, policy_digest, repository_ref),
    to: Sessions

  @spec pin_episode_in_transaction(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) :: {:ok, Session.t()} | {:error, term()}
  defdelegate pin_episode_in_transaction(
                episode_id,
                policy,
                policy_digest,
                authority_digest,
                repository_ref
              ),
              to: Sessions

  @spec pin_episode_in_transaction(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          map() | nil
        ) :: {:ok, Session.t()} | {:error, term()}
  defdelegate pin_episode_in_transaction(
                episode_id,
                policy,
                policy_digest,
                authority_digest,
                repository_ref,
                repository_context
              ),
              to: Sessions

  @spec pin_episode_in_transaction(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          map() | nil,
          map() | nil
        ) :: {:ok, Session.t()} | {:error, term()}
  defdelegate pin_episode_in_transaction(
                episode_id,
                policy,
                policy_digest,
                authority_digest,
                repository_ref,
                repository_context,
                repository_source
              ),
              to: Sessions

  @doc false
  @spec pin_task_episode_in_transaction(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: {:ok, Session.t()} | {:error, term()}
  defdelegate pin_task_episode_in_transaction(
                episode_id,
                policy,
                policy_digest,
                repository_ref,
                workspace_task
              ),
              to: Sessions

  @doc false
  @spec pin_task_episode_in_transaction(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          map() | nil,
          map()
        ) :: {:ok, Session.t()} | {:error, term()}
  defdelegate pin_task_episode_in_transaction(
                episode_id,
                policy,
                policy_digest,
                repository_ref,
                repository_context,
                workspace_task
              ),
              to: Sessions

  @doc false
  @spec pin_task_episode_in_transaction(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          map() | nil,
          map(),
          map() | nil
        ) :: {:ok, Session.t()} | {:error, term()}
  defdelegate pin_task_episode_in_transaction(
                episode_id,
                policy,
                policy_digest,
                repository_ref,
                repository_context,
                workspace_task,
                repository_source
              ),
              to: Sessions

  @spec claim_next(String.t(), pos_integer()) ::
          {:ok, claim() | nil} | {:error, term()}
  defdelegate claim_next(worker_ref, lease_seconds), to: Claims

  @spec claim_next(String.t(), pos_integer(), :any | :work | :delivery) ::
          {:ok, claim() | nil} | {:error, term()}
  defdelegate claim_next(worker_ref, lease_seconds, phase), to: Claims

  @spec freeze_submission(Ecto.UUID.t(), String.t(), String.t(), Submission.t(), keyword()) ::
          {:ok, Turn.t()} | {:error, term()}
  defdelegate freeze_submission(episode_id, turn_ref, lease_ref, submission, options \\ []),
    to: Turns

  @doc false
  @spec record_final_preflight(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: {:ok, Turn.t()} | {:error, term()}
  defdelegate record_final_preflight(
                episode_id,
                turn_ref,
                lease_ref,
                candidate_sha256,
                ledger_sha256,
                semantic_version
              ),
              to: Turns

  @doc false
  @spec verify_final_preflight(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          [String.t()]
        ) :: {:ok, Turn.t()} | {:error, term()}
  defdelegate verify_final_preflight(
                episode_id,
                turn_ref,
                lease_ref,
                candidate_sha256,
                artifact_refs
              ),
              to: Turns

  @doc false
  @spec bind_state_tools(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, Session.t()} | {:error, term()}
  defdelegate bind_state_tools(episode_id, turn_ref, lease_ref, endpoint, token_sha256),
    to: Turns

  @spec bind_session(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          String.t()
        ) ::
          {:ok, Session.t()} | {:error, term()}
  defdelegate bind_session(
                episode_id,
                turn_ref,
                lease_ref,
                generation,
                create_generation,
                coop_session_id
              ),
              to: Sessions

  @doc """
  Spends one confirmed failed Coop create operation that produced no session.

  Ambiguous or uncertain outcomes must keep the existing generation and
  reconcile the original idempotency key instead.
  """
  @spec advance_session_create(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Session.t()} | {:error, term()}
  defdelegate advance_session_create(episode_id, turn_ref, lease_ref, expected_generation),
    to: Sessions

  @doc """
  Releases the fence of a create that provably never reached Coop.

  A create is fenced on its turn before it is attempted, so a response the host
  never saw can never become a blind second remote session. `operation_by_key`
  answering `:not_found` is the proof there is nothing to be blind about: no
  operation exists under the key, so nothing crossed the boundary and no session
  was made. The generation is not spent, because nothing spent it — the key is
  free to be attempted again. An unresolved or uncertain outcome never reaches
  here and keeps the fence.
  """
  @spec release_session_create(Ecto.UUID.t(), String.t(), String.t(), String.t()) ::
          {:ok, Turn.t()} | {:error, term()}
  defdelegate release_session_create(episode_id, turn_ref, lease_ref, operation_key),
    to: Sessions

  @doc """
  Moves an unsubmitted logical turn to the next immutable Coop session generation.

  The caller must first prove the currently bound remote session is exhausted or
  unsafe to reuse (for example, its retained knowledge was withdrawn). A frozen submission cannot move because a same-session delta may not
  be self-contained in the replacement provider transcript.
  """
  @spec rotate_session(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, %{session: Session.t(), turn: Turn.t()}} | {:error, term()}
  defdelegate rotate_session(episode_id, turn_ref, lease_ref, expected_generation), to: Sessions

  @doc false
  @spec replace_session_after_placement_loss(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          pos_integer()
        ) :: {:ok, %{session: Session.t(), turn: Turn.t()}} | {:error, term()}
  defdelegate replace_session_after_placement_loss(
                episode_id,
                turn_ref,
                lease_ref,
                expected_generation
              ),
              to: Sessions

  @doc """
  Binds the immutable Coop turn resource created from the frozen submission.
  """
  @spec bind_turn(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          String.t()
        ) :: {:ok, Turn.t()} | {:error, term()}
  defdelegate bind_turn(
                episode_id,
                turn_ref,
                lease_ref,
                session_generation,
                submit_generation,
                coop_turn_id
              ),
              to: Turns

  @doc """
  Spends one confirmed failed Coop submit operation that produced no turn.
  """
  @spec advance_turn_submit(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Turn.t()} | {:error, term()}
  defdelegate advance_turn_submit(episode_id, turn_ref, lease_ref, expected_generation),
    to: Turns

  @doc """
  Durably records the exact candidate before any semantic validation mutation.

  Replacing a rejected candidate requires the exact stored candidate digest.
  An accepted result can never be replaced.
  """
  @spec stage_candidate(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          pos_integer() | nil,
          String.t(),
          String.t(),
          pos_integer()
        ) :: {:ok, Turn.t()} | {:error, term()}
  defdelegate stage_candidate(
                episode_id,
                turn_ref,
                lease_ref,
                expected_candidate_sha256,
                expected_candidate_attempt,
                candidate,
                candidate_sha256,
                candidate_attempt
              ),
              to: Turns

  @doc """
  Freezes the exact semantic verdict before any Coop validation mutation.

  An accepted intent includes the exact host result that may become a delivery
  intent. A retry cannot recompute or replace either the verdict or result.
  """
  @spec prepare_validation(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          :accept | {:reject, [String.t()]},
          Result.t() | nil
        ) :: {:ok, Turn.t()} | {:error, term()}
  defdelegate prepare_validation(
                episode_id,
                turn_ref,
                lease_ref,
                candidate_sha256,
                candidate_attempt,
                verdict,
                result
              ),
              to: Turns

  @doc """
  Spends one confirmed failed validation mutation for the same frozen candidate.
  """
  @spec advance_validation(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer()
        ) :: {:ok, Turn.t()} | {:error, term()}
  defdelegate advance_validation(
                episode_id,
                turn_ref,
                lease_ref,
                candidate_sha256,
                candidate_attempt,
                expected_generation
              ),
              to: Turns

  @doc """
  Atomically accepts one Coop-validated candidate and advances its episode.

  A visible result creates the single durable delivery intent. A deliberate
  no-delivery result settles immediately and advances any already queued input.
  """
  @spec accept_result(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          String.t(),
          map()
        ) :: {:ok, %{episode: Episode.t(), turn: Turn.t()}} | {:error, term()}
  defdelegate accept_result(
                episode_id,
                episode_key,
                turn_ref,
                lease_ref,
                candidate_sha256,
                candidate_attempt,
                validation_receipt,
                measurement \\ %{}
              ),
              to: Turns

  @doc """
  Atomically records one reconciled external delivery and advances the episode.
  """
  @spec confirm_delivery(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: {:ok, %{episode: Episode.t(), turn: Turn.t()}} | {:error, term()}
  defdelegate confirm_delivery(episode_id, episode_key, turn_ref, lease_ref, external_receipt),
    to: Delivery

  @doc """
  Freezes a user cancellation before stopping a bound Coop turn.

  When no remote turn exists, cancellation settles in the same transaction.
  Otherwise the episode keeps its current owner until a leased worker proves the
  exact remote turn is terminal.
  """
  @spec request_cancel(Ecto.UUID.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate request_cancel(episode_id, episode_key, turn_ref, cancel_ref, reason),
    to: Cancellation

  @doc """
  Freezes an owner transfer before stopping the old bound Coop turn.
  """
  @spec request_transfer(Ecto.UUID.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate request_transfer(episode_id, episode_key, turn_ref, new_turn_ref, transfer_ref),
    to: Cancellation

  @doc """
  Stops one exact active run while retaining the episode, session lineage, and
  repository workspace for a later human correction.

  This is an operator-authorized form of blocked custody. It still reconciles
  the exact remote Coop turn before becoming non-claimable; it is not the
  internal lease-authorized error path exposed by `request_block/5`.
  """
  @spec request_stop(Ecto.UUID.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate request_stop(episode_id, episode_key, turn_ref, stop_ref, reason),
    to: Cancellation

  @doc false
  @spec request_block(Ecto.UUID.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate request_block(episode_id, episode_key, turn_ref, lease_ref, reason),
    to: Cancellation

  @doc "Freezes remote completion before fallible host finalization, retaining the lease."
  defdelegate record_completion(episode_id, turn_ref, lease_ref, receipt), to: Turns

  @doc "Pauses host finalization of an exactly confirmed completed turn, without closing its workspace."
  defdelegate block_completion(episode_id, turn_ref, lease_ref, receipt, code, detail),
    to: Turns

  @doc """
  Pauses one episode because its host-owned delivery destination is inactive.

  This is not an operator cancellation. A bound remote turn is stopped through
  the normal cancellation reconciler, while an unsubmitted turn or an idle
  delivery is blocked locally. The opaque pause reference is required again to
  resume, so restoring one destination cannot rearm unrelated failed work.
  """
  @spec pause_destination(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate pause_destination(episode_id, episode_key, pause_ref), to: Delivery

  @doc """
  Resumes only the exact destination pause recorded by `pause_destination/3`.

  Ordinary execution failures and operator cancellations are deliberately left
  untouched. A stopped remote turn transfers to a fresh logical turn; a local
  unsent delivery is rearmed with the exact accepted result and destination.
  """
  @spec resume_destination(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate resume_destination(episode_id, episode_key, pause_ref), to: Delivery

  @doc false
  @spec resume_blocked_in_transaction(Episode.t(), String.t() | nil) ::
          {:ok, Episode.t()} | {:error, term()}
  defdelegate resume_blocked_in_transaction(episode, required_input_ref), to: Cancellation

  @doc """
  Retries one exact remotely settled blocked owner after operator inspection.

  A confirmed completion resumes finalization on the same turn and session.
  Otherwise the old Coop turn remains immutable: a proven stop and recoverable
  workspace are required before transferring ownership to a new logical turn.
  """
  @spec retry_blocked(String.t(), String.t()) :: {:ok, Episode.t()} | {:error, term()}
  defdelegate retry_blocked(episode_key, expected_recovery), to: Cancellation

  @doc "Binds operator confirmation to the exact stopped turn and recovery mode."
  defdelegate recovery_fingerprint(turn), to: Cancellation

  @doc """
  Spends one confirmed failed Coop cancellation mutation.

  A lost or uncertain response must keep the same generation and reconcile the
  original key instead.
  """
  @spec advance_cancellation(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Turn.t()} | {:error, term()}
  defdelegate advance_cancellation(episode_id, turn_ref, lease_ref, expected_generation),
    to: Cancellation

  @doc false
  @spec freeze_cancellation_revision(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          :cancel_turn | :close_session,
          pos_integer()
        ) :: {:ok, Turn.t()} | {:error, term()}
  defdelegate freeze_cancellation_revision(
                episode_id,
                turn_ref,
                lease_ref,
                phase,
                observed_revision
              ),
              to: Cancellation

  @doc """
  Atomically records terminal Coop proof, then cancels or transfers the episode.
  """
  @spec settle_cancellation(Ecto.UUID.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  defdelegate settle_cancellation(episode_id, episode_key, turn_ref, lease_ref, receipt),
    to: Cancellation

  @doc """
  Extends the current fenced turn lease without changing its owner or attempt count.

  A healthy long-running Coop turn renews this lease before it can be reclaimed by
  another worker. A stale worker cannot renew after losing its opaque lease.
  """
  @spec renew(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Turn.t()} | {:error, term()}
  defdelegate renew(episode_id, turn_ref, lease_ref, lease_seconds), to: Claims

  @doc """
  Fences one outbound Coop mutation with exact durable request identity.

  Create and submit identity is committed before the callback. The callback
  runs after the database transaction, so a slow local Coop socket never holds
  episode row locks. Stop may revoke the lease concurrently; exact replay of
  the same key and body then proves and cleans up whatever crossed the boundary.
  """
  @spec with_mutation_fence(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          map(),
          (-> result)
        ) :: result | {:error, term()}
        when result: term()
  defdelegate with_mutation_fence(episode_id, turn_ref, lease_ref, request, callback),
    to: Turns

  @doc """
  Releases one failed attempt for a bounded automatic retry.

  The retry time is computed by PostgreSQL so process clock skew cannot steal or
  indefinitely extend custody.
  """
  @spec defer(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          pos_integer(),
          String.t(),
          String.t()
        ) :: {:ok, Turn.t()} | {:error, term()}
  defdelegate defer(episode_id, turn_ref, lease_ref, retry_seconds, error_code, error_detail),
    to: Claims

  @doc """
  Moves one permanently failing delivery out of automatic retries.

  The accepted result and delivery owner remain durable so an operator can
  correct platform configuration and rearm the exact same intent.
  """
  @spec block_delivery(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, Turn.t()} | {:error, term()}
  defdelegate block_delivery(episode_id, turn_ref, lease_ref, error_code, error_detail),
    to: Delivery

  @doc """
  Rearms one operator-inspected blocked delivery without changing its result or destination.
  """
  @spec retry_delivery(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, Turn.t()} | {:error, term()}
  defdelegate retry_delivery(episode_id, turn_ref, delivery_ref), to: Delivery

  @doc """
  Releases healthy remote work at the end of one bounded polling window.

  A polling window is not a failed execution attempt. The claim increment is
  therefore returned before the turn becomes eligible for another worker.
  """
  @spec yield_progress(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Turn.t()} | {:error, term()}
  defdelegate yield_progress(episode_id, turn_ref, lease_ref, retry_seconds), to: Claims

  @doc false
  defdelegate claimable_episode_ids_query(now, phase), to: Claims

  @doc "Read-only recovery eligibility; retry rechecks this under custody locks."
  defdelegate completed_workspace_recoverable(turn), to: Cancellation

  @doc """
  The snapshot a blocked turn could be resumed from on another worker.

  `blocked-task-recovery.md` state 2 allows the offer only when a suitable
  worker and a verified portable snapshot both exist, so the fleet answers both
  halves at once. An uninitialized or non-fleet installation has nowhere to
  resume, which is not a failure — the surfaces simply keep their plain retry.
  """
  @spec portable_workspace(Turn.t()) ::
          %{byte_size: pos_integer(), checkpoint_ref: String.t(), repository_ref: String.t()}
          | nil
  defdelegate portable_workspace(turn), to: Cancellation

  @doc """
  Where this turn's accepted answer belongs.

  A reply answers the inputs that instructed it, so it returns to the newest
  one's own origin — a question asked in a new thread is answered there even
  when the episode's home is elsewhere. An accepted answer keeps the target it
  was accepted with; later context can never move or erase it.
  """
  @spec delivery_target(Episode.t(), Turn.t()) :: map()
  defdelegate delivery_target(episode, turn), to: Delivery

  @doc """
  The origin a reply from this turn answers, or nil when there is nothing to answer.

  This is computed once, when the result is accepted, and then frozen on the
  turn. Later inputs cannot move an answer that has already been accepted.
  """
  @spec reply_target(Episode.t(), Turn.t()) :: map() | nil
  defdelegate reply_target(episode, turn), to: Delivery
end
