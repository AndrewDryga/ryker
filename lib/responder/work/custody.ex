defmodule Responder.Work.Custody do
  @moduledoc """
  Durable ownership for episode-scoped Coop sessions and logical work turns.

  The episode remains the source of truth for user-visible lifecycle state.
  These rows only preserve execution identity, frozen model context, and a
  fenced worker lease across process restarts.
  """

  import Ecto.Query

  alias Responder.Artifacts.References, as: ArtifactReferences
  alias Responder.CanonicalJSON
  alias Responder.CoopFleet.ControlPlane, as: FleetControlPlane
  alias Responder.Defaults
  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode, Origin}
  alias Responder.Publication.Custody, as: PublicationCustody
  alias Responder.Publication.Publication
  alias Responder.Repo
  alias Responder.Settings
  alias Responder.State.{Continuity, EventSubscriptions, KnowledgeSnapshot}

  alias Responder.Work.{
    Cancellation,
    CandidateResponse,
    DeliveryReceipt,
    FinalPreflight,
    Measurement,
    RepositoryContext,
    RepositorySource,
    Result,
    Session,
    SessionChangeset,
    Submission,
    Turn,
    TurnChangeset,
    ValidationIntent
  }

  @maximum_candidate_bytes 256 * 1_024

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
  def pin_episode(episode_id, policy, policy_digest) do
    pin_episode(episode_id, policy, policy_digest, nil, nil, nil)
  end

  @spec pin_episode(Ecto.UUID.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Session.t()} | {:error, term()}
  def pin_episode(episode_id, policy, policy_digest, repository_ref) do
    pin_episode(episode_id, policy, policy_digest, nil, repository_ref, nil)
  end

  @spec pin_episode(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) :: {:ok, Session.t()} | {:error, term()}
  def pin_episode(episode_id, policy, policy_digest, authority_digest, repository_ref) do
    pin_episode(episode_id, policy, policy_digest, authority_digest, repository_ref, nil)
  end

  @spec pin_episode(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          map() | nil
        ) :: {:ok, Session.t()} | {:error, term()}
  def pin_episode(
        episode_id,
        policy,
        policy_digest,
        authority_digest,
        repository_ref,
        repository_context
      ) do
    pin_episode(
      episode_id,
      policy,
      policy_digest,
      authority_digest,
      repository_ref,
      repository_context,
      nil
    )
  end

  @spec pin_episode(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          map() | nil,
          map() | nil
        ) :: {:ok, Session.t()} | {:error, term()}
  def pin_episode(
        episode_id,
        policy,
        policy_digest,
        authority_digest,
        repository_ref,
        repository_context,
        repository_source
      ) do
    Repo.transaction(fn ->
      case pin_episode_in_transaction(
             episode_id,
             policy,
             policy_digest,
             authority_digest,
             repository_ref,
             repository_context,
             repository_source
           ) do
        {:ok, session} -> session
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> transaction_result()
  end

  @doc false
  @spec pin_episode_in_transaction(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def pin_episode_in_transaction(episode_id, policy, policy_digest) do
    pin_episode_in_transaction(episode_id, policy, policy_digest, nil, nil, nil)
  end

  @spec pin_episode_in_transaction(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil
        ) :: {:ok, Turn.t()} | {:error, term()}
  def pin_episode_in_transaction(episode_id, policy, policy_digest, repository_ref) do
    pin_episode_in_transaction(episode_id, policy, policy_digest, nil, repository_ref, nil)
  end

  @spec pin_episode_in_transaction(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) :: {:ok, Session.t()} | {:error, term()}
  def pin_episode_in_transaction(
        episode_id,
        policy,
        policy_digest,
        authority_digest,
        repository_ref
      ) do
    pin_episode_in_transaction(
      episode_id,
      policy,
      policy_digest,
      authority_digest,
      repository_ref,
      nil
    )
  end

  @spec pin_episode_in_transaction(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          map() | nil
        ) :: {:ok, Session.t()} | {:error, term()}
  def pin_episode_in_transaction(
        episode_id,
        policy,
        policy_digest,
        authority_digest,
        repository_ref,
        repository_context
      ) do
    pin_episode_in_transaction(
      episode_id,
      policy,
      policy_digest,
      authority_digest,
      repository_ref,
      repository_context,
      nil
    )
  end

  @spec pin_episode_in_transaction(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          map() | nil,
          map() | nil
        ) :: {:ok, Session.t()} | {:error, term()}
  def pin_episode_in_transaction(
        episode_id,
        policy,
        policy_digest,
        authority_digest,
        repository_ref,
        repository_context,
        repository_source
      ) do
    with :ok <- transaction_open(),
         {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(policy, :policy),
         :ok <- sha256(policy_digest, :policy_digest),
         :ok <- optional_sha256(authority_digest, :authority_digest),
         :ok <- optional_reference(repository_ref, :repository_ref),
         :ok <- repository_context(repository_context, repository_ref),
         {:ok, repository_source} <- repository_source(repository_source, repository_ref) do
      {:ok,
       pin_episode_locked(
         episode_id,
         policy,
         policy_digest,
         authority_digest,
         repository_ref,
         repository_context,
         repository_source
       )}
    end
  end

  @doc false
  @spec pin_task_episode_in_transaction(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: {:ok, Session.t()} | {:error, term()}
  def pin_task_episode_in_transaction(
        episode_id,
        policy,
        policy_digest,
        repository_ref,
        workspace_task
      ) do
    pin_task_episode_in_transaction(
      episode_id,
      policy,
      policy_digest,
      repository_ref,
      nil,
      workspace_task
    )
  end

  @doc false
  @spec pin_task_episode_in_transaction(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          map() | nil,
          map()
        ) :: {:ok, Session.t()} | {:error, term()}
  def pin_task_episode_in_transaction(
        episode_id,
        policy,
        policy_digest,
        repository_ref,
        repository_context,
        workspace_task
      ) do
    pin_task_episode_in_transaction(
      episode_id,
      policy,
      policy_digest,
      repository_ref,
      repository_context,
      workspace_task,
      nil
    )
  end

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
  def pin_task_episode_in_transaction(
        episode_id,
        policy,
        policy_digest,
        repository_ref,
        repository_context,
        workspace_task,
        repository_source
      ) do
    with {:ok, session} <-
           pin_episode_in_transaction(
             episode_id,
             policy,
             policy_digest,
             nil,
             repository_ref,
             repository_context,
             repository_source
           ) do
      case session.workspace_task do
        nil ->
          session
          |> SessionChangeset.bind_workspace_task(workspace_task)
          |> Repo.update()
          |> persistence_result(:work_session_workspace_task)

        ^workspace_task ->
          {:ok, session}

        _different ->
          {:error, :work_session_workspace_task_conflict}
      end
    end
  end

  @spec claim_next(String.t(), pos_integer()) ::
          {:ok, claim() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds) do
    claim_next(worker_ref, lease_seconds, :any)
  end

  @spec claim_next(String.t(), pos_integer(), :any | :work | :delivery) ::
          {:ok, claim() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds, phase) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- positive_integer(lease_seconds, :lease_seconds),
         :ok <- claim_phase(phase) do
      Repo.transaction(fn -> claim_locked(worker_ref, lease_seconds, phase) end)
      |> transaction_result()
    end
  end

  @spec freeze_submission(Ecto.UUID.t(), String.t(), String.t(), Submission.t(), keyword()) ::
          {:ok, Turn.t()} | {:error, term()}
  def freeze_submission(episode_id, turn_ref, lease_ref, submission, options \\ []) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         {:ok, submission} <- Submission.prepare(submission) do
      fingerprint = Submission.fingerprint(submission)
      evidence = Keyword.take(options, [:selected_input_refs, :selection_ledger])

      Repo.transaction(fn ->
        freeze_locked(episode_id, turn_ref, lease_ref, submission, fingerprint, evidence)
      end)
      |> transaction_result()
    end
  end

  @doc false
  @spec record_final_preflight(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: {:ok, Turn.t()} | {:error, term()}
  def record_final_preflight(
        episode_id,
        turn_ref,
        lease_ref,
        candidate_sha256,
        ledger_sha256,
        semantic_version
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- sha256(candidate_sha256, :final_preflight_candidate_sha256),
         :ok <- sha256(ledger_sha256, :final_preflight_ledger_sha256),
         :ok <- non_negative_integer(semantic_version, :final_preflight_semantic_version) do
      Repo.transaction(fn ->
        {_, turn} = leased!(episode_id, turn_ref, lease_ref)
        continuity_sha256 = Continuity.preflight_fingerprint_in_transaction(turn)

        turn
        |> TurnChangeset.record_final_preflight(
          candidate_sha256,
          continuity_sha256,
          ledger_sha256,
          semantic_version
        )
        |> Repo.update()
        |> unwrap_or_rollback(:work_final_preflight)
      end)
      |> transaction_result()
    end
  end

  @doc false
  @spec verify_final_preflight(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          [String.t()]
        ) :: {:ok, Turn.t()} | {:error, term()}
  def verify_final_preflight(
        episode_id,
        turn_ref,
        lease_ref,
        candidate_sha256,
        artifact_refs
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- sha256(candidate_sha256, :final_preflight_candidate_sha256),
         :ok <- artifact_refs(artifact_refs) do
      Repo.transaction(fn ->
        verify_final_preflight_locked(
          episode_id,
          turn_ref,
          lease_ref,
          candidate_sha256,
          artifact_refs
        )
      end)
      |> transaction_result()
    end
  end

  defp verify_final_preflight_locked(
         episode_id,
         turn_ref,
         lease_ref,
         candidate_sha256,
         artifact_refs
       ) do
    {_, turn} = leased!(episode_id, turn_ref, lease_ref)
    episode = Repo.get!(Episode, episode_id)

    ledger_sha256 =
      FinalPreflight.ledger_sha256(
        episode.id,
        episode.semantic_version,
        artifact_refs,
        turn.id
      )

    continuity_sha256 = Continuity.preflight_fingerprint_in_transaction(turn)

    if turn.final_preflight_candidate_sha256 == candidate_sha256 and
         turn.final_preflight_continuity_sha256 == continuity_sha256 and
         turn.final_preflight_ledger_sha256 == ledger_sha256 and
         turn.final_preflight_semantic_version == episode.semantic_version do
      turn
    else
      Repo.rollback(:work_final_preflight_required)
    end
  end

  @doc false
  @spec bind_state_tools(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, Session.t()} | {:error, term()}
  def bind_state_tools(episode_id, turn_ref, lease_ref, endpoint, token_sha256) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- bounded_text(endpoint, 2_048, :state_tools_endpoint),
         :ok <- sha256(token_sha256, :state_tools_token_sha256) do
      Repo.transaction(fn ->
        bind_state_tools_locked(episode_id, turn_ref, lease_ref, endpoint, token_sha256)
      end)
      |> transaction_result()
    end
  end

  @spec bind_session(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          String.t()
        ) ::
          {:ok, Session.t()} | {:error, term()}
  def bind_session(
        episode_id,
        turn_ref,
        lease_ref,
        generation,
        create_generation,
        coop_session_id
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(generation, :session_generation),
         :ok <- positive_integer(create_generation, :create_generation),
         :ok <- reference(coop_session_id, :coop_session_id) do
      Repo.transaction(fn ->
        bind_session_locked(
          episode_id,
          turn_ref,
          lease_ref,
          generation,
          create_generation,
          coop_session_id
        )
      end)
      |> transaction_result()
    end
  end

  @doc """
  Spends one confirmed failed Coop create operation that produced no session.

  Ambiguous or uncertain outcomes must keep the existing generation and
  reconcile the original idempotency key instead.
  """
  @spec advance_session_create(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Session.t()} | {:error, term()}
  def advance_session_create(episode_id, turn_ref, lease_ref, expected_generation) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(expected_generation, :create_generation) do
      Repo.transaction(fn ->
        advance_session_create_locked(episode_id, turn_ref, lease_ref, expected_generation)
      end)
      |> transaction_result()
    end
  end

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
  def release_session_create(episode_id, turn_ref, lease_ref, operation_key) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- reference(operation_key, :operation_key) do
      Repo.transaction(fn ->
        {_session, turn} = leased!(episode_id, turn_ref, lease_ref)
        clear_remote_operation!(turn, "create_session", operation_key)
      end)
      |> transaction_result()
    end
  end

  @doc """
  Moves an unsubmitted logical turn to the next immutable Coop session generation.

  The caller must first prove the currently bound remote session is exhausted or
  unsafe to reuse (for example, its retained knowledge was withdrawn). A frozen submission cannot move because a same-session delta may not
  be self-contained in the replacement provider transcript.
  """
  @spec rotate_session(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, %{session: Session.t(), turn: Turn.t()}} | {:error, term()}
  def rotate_session(episode_id, turn_ref, lease_ref, expected_generation) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(expected_generation, :session_generation) do
      Repo.transaction(fn ->
        rotate_session_locked(episode_id, turn_ref, lease_ref, expected_generation)
      end)
      |> transaction_result()
    end
  end

  @doc false
  @spec replace_session_after_placement_loss(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          pos_integer()
        ) :: {:ok, %{session: Session.t(), turn: Turn.t()}} | {:error, term()}
  def replace_session_after_placement_loss(
        episode_id,
        turn_ref,
        lease_ref,
        expected_generation
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(expected_generation, :session_generation) do
      Repo.transaction(fn ->
        rotate_session_locked(
          episode_id,
          turn_ref,
          lease_ref,
          expected_generation,
          :placement_lost
        )
      end)
      |> transaction_result()
    end
  end

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
  def bind_turn(
        episode_id,
        turn_ref,
        lease_ref,
        session_generation,
        submit_generation,
        coop_turn_id
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(session_generation, :session_generation),
         :ok <- positive_integer(submit_generation, :submit_generation),
         :ok <- reference(coop_turn_id, :coop_turn_id) do
      Repo.transaction(fn ->
        bind_turn_locked(
          episode_id,
          turn_ref,
          lease_ref,
          session_generation,
          submit_generation,
          coop_turn_id
        )
      end)
      |> transaction_result()
    end
  end

  @doc """
  Spends one confirmed failed Coop submit operation that produced no turn.
  """
  @spec advance_turn_submit(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Turn.t()} | {:error, term()}
  def advance_turn_submit(episode_id, turn_ref, lease_ref, expected_generation) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(expected_generation, :submit_generation) do
      Repo.transaction(fn ->
        advance_turn_submit_locked(episode_id, turn_ref, lease_ref, expected_generation)
      end)
      |> transaction_result()
    end
  end

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
  def stage_candidate(
        episode_id,
        turn_ref,
        lease_ref,
        expected_candidate_sha256,
        expected_candidate_attempt,
        candidate,
        candidate_sha256,
        candidate_attempt
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <-
           optional_candidate_identity(
             expected_candidate_sha256,
             expected_candidate_attempt
           ),
         :ok <- candidate(candidate),
         :ok <- sha256(candidate_sha256, :candidate_sha256),
         :ok <- positive_integer(candidate_attempt, :candidate_attempt),
         :ok <- exact_sha256(candidate, candidate_sha256) do
      Repo.transaction(fn ->
        stage_candidate_locked(
          episode_id,
          turn_ref,
          lease_ref,
          expected_candidate_sha256,
          expected_candidate_attempt,
          candidate,
          candidate_sha256,
          candidate_attempt
        )
      end)
      |> transaction_result()
    end
  end

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
  def prepare_validation(
        episode_id,
        turn_ref,
        lease_ref,
        candidate_sha256,
        candidate_attempt,
        verdict,
        result
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- sha256(candidate_sha256, :candidate_sha256),
         :ok <- positive_integer(candidate_attempt, :candidate_attempt),
         {:ok, intent} <- ValidationIntent.new(verdict, result) do
      fingerprint = ValidationIntent.fingerprint(intent)

      Repo.transaction(fn ->
        prepare_validation_locked(
          episode_id,
          turn_ref,
          lease_ref,
          candidate_sha256,
          candidate_attempt,
          intent,
          fingerprint
        )
      end)
      |> transaction_result()
    end
  end

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
  def advance_validation(
        episode_id,
        turn_ref,
        lease_ref,
        candidate_sha256,
        candidate_attempt,
        expected_generation
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- sha256(candidate_sha256, :candidate_sha256),
         :ok <- positive_integer(candidate_attempt, :candidate_attempt),
         :ok <- positive_integer(expected_generation, :validation_generation) do
      Repo.transaction(fn ->
        advance_validation_locked(
          episode_id,
          turn_ref,
          lease_ref,
          candidate_sha256,
          candidate_attempt,
          expected_generation
        )
      end)
      |> transaction_result()
    end
  end

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
  def accept_result(
        episode_id,
        episode_key,
        turn_ref,
        lease_ref,
        candidate_sha256,
        candidate_attempt,
        validation_receipt,
        measurement \\ %{}
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- sha256(candidate_sha256, :candidate_sha256),
         :ok <- positive_integer(candidate_attempt, :candidate_attempt),
         :ok <- reference(validation_receipt, :validation_receipt),
         :ok <- measurement(measurement) do
      Repo.transaction(fn ->
        accept_result_locked(
          episode_id,
          episode_key,
          turn_ref,
          lease_ref,
          candidate_sha256,
          candidate_attempt,
          validation_receipt,
          measurement
        )
      end)
      |> transaction_result()
    end
  end

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
  def confirm_delivery(episode_id, episode_key, turn_ref, lease_ref, external_receipt) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         {:ok, external_receipt} <- DeliveryReceipt.prepare(external_receipt) do
      receipt_fingerprint = DeliveryReceipt.fingerprint(external_receipt)

      Repo.transaction(fn ->
        confirm_delivery_locked(
          episode_id,
          episode_key,
          turn_ref,
          lease_ref,
          external_receipt,
          receipt_fingerprint
        )
      end)
      |> transaction_result()
    end
  end

  @doc """
  Freezes a user cancellation before stopping a bound Coop turn.

  When no remote turn exists, cancellation settles in the same transaction.
  Otherwise the episode keeps its current owner until a leased worker proves the
  exact remote turn is terminal.
  """
  @spec request_cancel(Ecto.UUID.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def request_cancel(episode_id, episode_key, turn_ref, cancel_ref, reason) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         {:ok, intent} <- Cancellation.new_cancel(cancel_ref, reason) do
      request_cancellation(episode_id, episode_key, turn_ref, intent)
    end
  end

  @doc """
  Freezes an owner transfer before stopping the old bound Coop turn.
  """
  @spec request_transfer(Ecto.UUID.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def request_transfer(episode_id, episode_key, turn_ref, new_turn_ref, transfer_ref) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         {:ok, intent} <- Cancellation.new_transfer(new_turn_ref, transfer_ref) do
      request_cancellation(episode_id, episode_key, turn_ref, intent)
    end
  end

  @doc """
  Stops one exact active run while retaining the episode, session lineage, and
  repository workspace for a later human correction.

  This is an operator-authorized form of blocked custody. It still reconciles
  the exact remote Coop turn before becoming non-claimable; it is not the
  internal lease-authorized error path exposed by `request_block/5`.
  """
  @spec request_stop(Ecto.UUID.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def request_stop(episode_id, episode_key, turn_ref, stop_ref, reason) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(stop_ref, :stop_ref),
         {:ok, intent} <- Cancellation.new_block("#{reason} Control: #{stop_ref}.") do
      request_cancellation(episode_id, episode_key, turn_ref, intent)
    end
  end

  @doc false
  @spec request_block(Ecto.UUID.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def request_block(episode_id, episode_key, turn_ref, lease_ref, reason) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         {:ok, intent} <- Cancellation.new_block(reason) do
      request_cancellation(episode_id, episode_key, turn_ref, intent, lease_ref)
    end
  end

  @doc "Freezes remote completion before fallible host finalization, retaining the lease."
  def record_completion(episode_id, turn_ref, lease_ref, receipt) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref) do
      Repo.transaction(fn ->
        record_completion_locked(episode_id, turn_ref, lease_ref, receipt)
      end)
      |> transaction_result()
    end
  end

  defp record_completion_locked(episode_id, turn_ref, lease_ref, receipt) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    if completion_matches?(turn, receipt) and turn.status == :pending and
         is_nil(turn.cancellation_intent) and is_nil(turn.result_ref) do
      turn
      |> TurnChangeset.record_completion(receipt)
      |> Repo.update()
      |> unwrap_or_rollback(:work_completion_record)
    else
      Repo.rollback(:work_completion_receipt_mismatch)
    end
  end

  @doc "Pauses host finalization of an exactly confirmed completed turn, without closing its workspace."
  def block_completion(episode_id, turn_ref, lease_ref, receipt, code, detail) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- bounded_text(code, 128, :error_code),
         :ok <- bounded_text(detail, 4_096, :error_detail) do
      Repo.transaction(fn ->
        block_completion_locked(episode_id, turn_ref, lease_ref, receipt, code, detail)
      end)
      |> transaction_result()
    end
  end

  defp block_completion_locked(episode_id, turn_ref, lease_ref, receipt, code, detail) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    if completion_matches?(turn, receipt) and turn.status == :pending and
         is_nil(turn.cancellation_intent) and is_nil(turn.result_ref) do
      turn
      |> TurnChangeset.block_completion(receipt, code, detail)
      |> Repo.update()
      |> unwrap_or_rollback(:work_completion_block)
    else
      Repo.rollback(:work_completion_receipt_mismatch)
    end
  end

  defp completion_matches?(
         turn,
         %{
           "candidate_sha256" => sha,
           "candidate_attempt" => attempt,
           "remote_turn_id" => remote_id,
           "validation_receipt" => receipt
         } = proof
       ) do
    map_size(proof) == 4 and turn.candidate_sha256 == sha and turn.candidate_attempt == attempt and
      turn.coop_turn_id == remote_id and is_binary(remote_id) and
      (is_nil(turn.completion_receipt) or turn.completion_receipt == proof) and
      get_in(turn.validation_intent, ["verdict"]) == "accept" and
      reference(receipt, :validation_receipt) == :ok
  end

  defp completion_matches?(_turn, _receipt), do: false

  @doc """
  Pauses one episode because its host-owned delivery destination is inactive.

  This is not an operator cancellation. A bound remote turn is stopped through
  the normal cancellation reconciler, while an unsubmitted turn or an idle
  delivery is blocked locally. The opaque pause reference is required again to
  resume, so restoring one destination cannot rearm unrelated failed work.
  """
  @spec pause_destination(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def pause_destination(episode_id, episode_key, pause_ref) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(pause_ref, :pause_ref),
         {:ok, intent} <- Cancellation.new_block(destination_pause_reason(pause_ref)) do
      fingerprint = Cancellation.fingerprint(intent)

      Repo.transaction(fn ->
        pause_destination_locked(episode_id, episode_key, intent, fingerprint)
      end)
      |> transaction_result()
    end
  end

  @doc """
  Resumes only the exact destination pause recorded by `pause_destination/3`.

  Ordinary execution failures and operator cancellations are deliberately left
  untouched. A stopped remote turn transfers to a fresh logical turn; a local
  unsent delivery is rearmed with the exact accepted result and destination.
  """
  @spec resume_destination(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_destination(episode_id, episode_key, pause_ref) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(pause_ref, :pause_ref) do
      reason = destination_pause_reason(pause_ref)

      Repo.transaction(fn -> resume_destination_locked(episode_id, episode_key, reason) end)
      |> transaction_result()
    end
  end

  defp pause_destination_locked(episode_id, episode_key, intent, fingerprint) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         :ok <- exact_episode(episode, episode_id) do
      pause_destination_owner(episode, intent, fingerprint)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_destination_locked(episode_id, episode_key, reason) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         :ok <- exact_episode(episode, episode_id) do
      resume_destination_owner(episode, reason)
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  @doc false
  @spec resume_blocked_in_transaction(Episode.t(), String.t() | nil) ::
          {:ok, Episode.t()} | {:error, term()}
  def resume_blocked_in_transaction(%Episode{} = episode, required_input_ref) do
    with :ok <- transaction_open(),
         :ok <- optional_reference(required_input_ref, :required_input_ref),
         {:ok, current} <- Episodes.lock_current_in_transaction(episode.key),
         :ok <- exact_episode(current, episode.id) do
      resume_blocked_owner(current, required_input_ref)
    end
  end

  @doc """
  Retries one exact remotely settled blocked owner after operator inspection.

  A confirmed completion resumes finalization on the same turn and session.
  Otherwise the old Coop turn remains immutable: a proven stop and recoverable
  workspace are required before transferring ownership to a new logical turn.
  """
  @spec retry_blocked(String.t(), String.t()) :: {:ok, Episode.t()} | {:error, term()}
  def retry_blocked(episode_key, expected_recovery) do
    with :ok <- reference(episode_key, :episode_key),
         :ok <- reference(expected_recovery, :expected_recovery) do
      Repo.transaction(fn -> retry_blocked_locked(episode_key, expected_recovery) end)
      |> transaction_result()
    end
  end

  @doc "Binds operator confirmation to the exact stopped turn and recovery mode."
  def recovery_fingerprint(%Turn{} = turn) do
    turn
    |> Map.take([
      :id,
      :status,
      :completion_receipt,
      :candidate_sha256,
      :candidate_attempt,
      :coop_turn_id,
      :result_ref,
      :delivery_ref,
      :cancellation_intent,
      :cancellation_receipt,
      :work_attempt_count,
      :cancel_attempt_count,
      :updated_at
    ])
    |> Jason.encode!()
    |> Jason.decode!()
    |> CanonicalJSON.digest()
  end

  @doc """
  Spends one confirmed failed Coop cancellation mutation.

  A lost or uncertain response must keep the same generation and reconcile the
  original key instead.
  """
  @spec advance_cancellation(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Turn.t()} | {:error, term()}
  def advance_cancellation(episode_id, turn_ref, lease_ref, expected_generation) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(expected_generation, :cancel_generation) do
      Repo.transaction(fn ->
        advance_cancellation_locked(episode_id, turn_ref, lease_ref, expected_generation)
      end)
      |> transaction_result()
    end
  end

  @doc false
  @spec freeze_cancellation_revision(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          :cancel_turn | :close_session,
          pos_integer()
        ) :: {:ok, Turn.t()} | {:error, term()}
  def freeze_cancellation_revision(episode_id, turn_ref, lease_ref, phase, observed_revision) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- cancellation_revision_phase(phase),
         :ok <- positive_integer(observed_revision, :cancellation_revision) do
      Repo.transaction(fn ->
        freeze_cancellation_revision_locked(
          episode_id,
          turn_ref,
          lease_ref,
          phase,
          observed_revision
        )
      end)
      |> transaction_result()
    end
  end

  defp freeze_cancellation_revision_locked(
         episode_id,
         turn_ref,
         lease_ref,
         phase,
         observed_revision
       ) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)
    field = cancellation_revision_field(phase)

    case Map.fetch!(turn, field) do
      nil ->
        turn
        |> TurnChangeset.freeze_cancellation_revision(phase, observed_revision)
        |> Repo.update()
        |> unwrap_or_rollback(:work_cancellation_revision)

      _frozen_revision ->
        turn
    end
  end

  @doc """
  Atomically records terminal Coop proof, then cancels or transfers the episode.
  """
  @spec settle_cancellation(Ecto.UUID.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def settle_cancellation(episode_id, episode_key, turn_ref, lease_ref, receipt) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         {:ok, receipt} <- Cancellation.prepare_receipt(receipt) do
      fingerprint = Cancellation.fingerprint(receipt)

      Repo.transaction(fn ->
        settle_cancellation_locked(
          episode_id,
          episode_key,
          turn_ref,
          lease_ref,
          receipt,
          fingerprint
        )
      end)
      |> transaction_result()
    end
  end

  @doc """
  Extends the current fenced turn lease without changing its owner or attempt count.

  A healthy long-running Coop turn renews this lease before it can be reclaimed by
  another worker. A stale worker cannot renew after losing its opaque lease.
  """
  @spec renew(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Turn.t()} | {:error, term()}
  def renew(episode_id, turn_ref, lease_ref, lease_seconds) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(lease_seconds, :lease_seconds) do
      Repo.transaction(fn ->
        renew_locked(episode_id, turn_ref, lease_ref, lease_seconds)
      end)
      |> transaction_result()
    end
  end

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
  def with_mutation_fence(
        episode_id,
        turn_ref,
        lease_ref,
        request,
        callback
      ) do
    with {:ok, request} <- mutation_fence_request(request),
         {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- remote_operation_kind(request.kind),
         :ok <- remote_operation_revision(request.kind, request.operation_revision),
         :ok <- reference(request.operation_key, :operation_key),
         :ok <- positive_integer(request.lease_seconds, :lease_seconds),
         :ok <- positive_integer(request.maximum_block_ms, :maximum_block_ms),
         :ok <- callback(callback),
         :ok <-
           prepare_remote_operation(
             episode_id,
             turn_ref,
             lease_ref,
             request.kind,
             request.operation_key,
             request.operation_revision
           ),
         :ok <- authorize_remote_mutation(episode_id, turn_ref, lease_ref, request) do
      callback.()
    end
  end

  defp mutation_fence_request(
         %{
           kind: kind,
           lease_seconds: lease_seconds,
           maximum_block_ms: maximum_block_ms,
           operation_key: operation_key,
           operation_revision: operation_revision
         } = request
       )
       when map_size(request) == 5 do
    {:ok,
     %{
       kind: kind,
       lease_seconds: lease_seconds,
       maximum_block_ms: maximum_block_ms,
       operation_key: operation_key,
       operation_revision: operation_revision
     }}
  end

  defp mutation_fence_request(_request),
    do: {:error, {:invalid_work_mutation_fence, :request}}

  defp authorize_remote_mutation(episode_id, turn_ref, lease_ref, request) do
    Repo.transaction(fn ->
      remote_mutation_turn!(
        episode_id,
        turn_ref,
        lease_ref,
        request.kind,
        request.operation_key,
        request.lease_seconds,
        request.operation_revision
      )
    end)
    |> transaction_result()
    |> mutation_authorization_result()
  end

  defp mutation_authorization_result({:ok, _turn}), do: :ok
  defp mutation_authorization_result({:error, _reason} = error), do: error

  defp prepare_remote_operation(
         _episode_id,
         _turn_ref,
         _lease_ref,
         kind,
         _operation_key,
         _operation_revision
       )
       when kind not in [:create_session, :submit_turn],
       do: :ok

  defp prepare_remote_operation(
         episode_id,
         turn_ref,
         lease_ref,
         kind,
         operation_key,
         operation_revision
       ) do
    case Repo.transaction(fn ->
           prepare_remote_operation_locked(
             episode_id,
             turn_ref,
             lease_ref,
             kind,
             operation_key,
             operation_revision
           )
         end) do
      {:ok, _turn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_remote_operation_locked(
         episode_id,
         turn_ref,
         lease_ref,
         kind,
         operation_key,
         operation_revision
       ) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)
    kind = Atom.to_string(kind)

    cond do
      turn.remote_operation_kind == nil ->
        persist_remote_operation(turn, kind, operation_key, operation_revision)

      turn.remote_operation_kind == kind and turn.remote_operation_key == operation_key and
          turn.remote_operation_revision == operation_revision ->
        persist_remote_operation(turn, kind, operation_key, operation_revision)

      true ->
        Repo.rollback(
          {:work_remote_operation_conflict,
           {turn.remote_operation_kind, turn.remote_operation_key}}
        )
    end
  end

  defp persist_remote_operation(turn, kind, operation_key, operation_revision) do
    turn
    |> TurnChangeset.prepare_remote_operation(kind, operation_key, operation_revision)
    |> Repo.update()
    |> unwrap_or_rollback(:work_remote_operation)
  end

  defp remote_mutation_turn!(
         episode_id,
         turn_ref,
         lease_ref,
         kind,
         operation_key,
         lease_seconds,
         operation_revision
       ) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    if kind in [:create_session, :submit_turn] do
      if frozen_remote_operation?(turn, kind, operation_key, operation_revision),
        do: renew_locked(episode_id, turn_ref, lease_ref, lease_seconds),
        else: Repo.rollback(:work_remote_operation_not_frozen)
    else
      renew_locked(episode_id, turn_ref, lease_ref, lease_seconds)
    end
  end

  defp frozen_remote_operation?(turn, kind, operation_key, operation_revision) do
    turn.remote_operation_kind == Atom.to_string(kind) and
      turn.remote_operation_key == operation_key and
      turn.remote_operation_revision == operation_revision
  end

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
  def defer(episode_id, turn_ref, lease_ref, retry_seconds, error_code, error_detail) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(retry_seconds, :retry_seconds),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail) do
      Repo.transaction(fn ->
        defer_locked(
          episode_id,
          turn_ref,
          lease_ref,
          retry_seconds,
          error_code,
          error_detail
        )
      end)
      |> transaction_result()
    end
  end

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
  def block_delivery(episode_id, turn_ref, lease_ref, error_code, error_detail) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail) do
      Repo.transaction(fn ->
        block_delivery_locked(episode_id, turn_ref, lease_ref, error_code, error_detail)
      end)
      |> transaction_result()
    end
  end

  @doc """
  Rearms one operator-inspected blocked delivery without changing its result or destination.
  """
  @spec retry_delivery(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, Turn.t()} | {:error, term()}
  def retry_delivery(episode_id, turn_ref, delivery_ref) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(delivery_ref, :delivery_ref) do
      Repo.transaction(fn -> retry_delivery_locked(episode_id, turn_ref, delivery_ref) end)
      |> transaction_result()
    end
  end

  @doc """
  Releases healthy remote work at the end of one bounded polling window.

  A polling window is not a failed execution attempt. The claim increment is
  therefore returned before the turn becomes eligible for another worker.
  """
  @spec yield_progress(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Turn.t()} | {:error, term()}
  def yield_progress(episode_id, turn_ref, lease_ref, retry_seconds) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(retry_seconds, :retry_seconds) do
      Repo.transaction(fn ->
        yield_progress_locked(episode_id, turn_ref, lease_ref, retry_seconds)
      end)
      |> transaction_result()
    end
  end

  defp pin_episode_locked(
         episode_id,
         policy,
         policy_digest,
         authority_digest,
         repository_ref,
         repository_context,
         repository_source
       ) do
    case Repo.one(
           from(episode in Episode,
             where: episode.id == ^episode_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        Repo.rollback(:episode_not_found)

      %Episode{} = episode ->
        case latest_session(episode.id) do
          nil ->
            session_id = Ecto.UUID.generate()

            session_id
            |> SessionChangeset.insert_with_authority(
              episode.id,
              1,
              policy,
              policy_digest,
              repository_ref,
              session_external_ref(episode.id, 1),
              %{
                authority_digest: authority_digest,
                repository_context: repository_context,
                repository_source: repository_source,
                workspace_task: nil
              }
            )
            |> Repo.insert()
            |> unwrap_or_rollback(:work_session)

          %Session{cleanup_status: :active} = session ->
            session

          %Session{} = session ->
            insert_session_or_rollback(
              episode.id,
              session.generation + 1,
              session_authority(session)
            )
        end
    end
  end

  defp claim_locked(worker_ref, lease_seconds, phase) do
    now = database_now!()

    case eligible_episode(now, phase) do
      nil ->
        nil

      episode ->
        with {:ok, session, turn} <- ensure_session_and_turn(episode),
             false <- active_publication_review?(session, turn),
             {:ok, turn} <- claim_turn(turn, worker_ref, now, lease_seconds) do
          %{
            episode: episode,
            lease_ref: turn.lease_ref,
            session: session,
            turn: turn
          }
        else
          true -> nil
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp eligible_episode(now, phase) do
    Repo.one(
      from(episode in Episode,
        where: episode.id in subquery(claimable_episode_ids_query(now, phase)),
        order_by: [asc: episode.updated_at, asc: episode.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  @doc false
  def claimable_episode_ids_query(now, phase) do
    pinned_episode_ids = from(session in Session, select: session.episode_id)

    reviewing_episode_ids =
      from(publication in Publication,
        where: publication.status == :review_pending and publication.lease_expires_at > ^now,
        select: publication.episode_id
      )

    phase_filter = claim_phase_filter(phase, now)

    from(episode in Episode,
      left_join: turn in Turn,
      on:
        turn.episode_id == episode.id and
          ((episode.owner_kind == :turn and turn.turn_ref == episode.owner_ref) or
             (episode.owner_kind == :delivery and turn.delivery_ref == episode.owner_ref)),
      where: episode.state == :working and episode.owner_kind in [:turn, :delivery],
      where: episode.id in subquery(pinned_episode_ids),
      where: ^phase_filter,
      where: episode.owner_kind == :delivery or episode.id not in subquery(reviewing_episode_ids),
      select: episode.id
    )
  end

  defp active_publication_review?(session, %Turn{status: status})
       when status in [:pending, :cancel_pending] do
    # Both claimers lock the session. Recheck after that lock as the selection
    # query may have started before the other claimant committed its lease.
    now = database_now!()

    Repo.exists?(
      from(publication in Publication,
        where:
          publication.session_id == ^session.id and publication.status == :review_pending and
            publication.lease_expires_at > ^now
      )
    )
  end

  defp active_publication_review?(_session, _turn), do: false

  defp claim_phase_filter(:work, now) do
    dynamic(
      [episode, turn],
      episode.owner_kind == :turn and
        (is_nil(turn.id) or
           (turn.status in [:pending, :cancel_pending] and
              (is_nil(turn.next_attempt_at) or turn.next_attempt_at <= ^now) and
              (is_nil(turn.lease_ref) or turn.lease_expires_at <= ^now)))
    )
  end

  defp claim_phase_filter(:delivery, now) do
    dynamic(
      [episode, turn],
      episode.owner_kind == :delivery and not is_nil(turn.id) and
        turn.status == :delivery_pending and
        (is_nil(turn.next_attempt_at) or turn.next_attempt_at <= ^now) and
        (is_nil(turn.lease_ref) or turn.lease_expires_at <= ^now)
    )
  end

  defp claim_phase_filter(:any, now) do
    work = claim_phase_filter(:work, now)
    delivery = claim_phase_filter(:delivery, now)
    dynamic([episode, turn], ^work or ^delivery)
  end

  defp current_session(episode) do
    case latest_session(episode.id) do
      nil ->
        {:error, :work_policy_not_pinned}

      %Session{cleanup_status: :active} = session ->
        {:ok, session}

      %Session{} = session ->
        insert_session(episode.id, session.generation + 1, session_authority(session))
    end
  end

  defp latest_session(episode_id) do
    Repo.one(
      from(session in Session,
        where: session.episode_id == ^episode_id,
        order_by: [desc: session.generation],
        limit: 1,
        lock: "FOR UPDATE"
      )
    )
  end

  defp ensure_session_and_turn(%Episode{owner_kind: :turn} = episode) do
    case turn_identity(episode.id, episode.owner_ref) do
      nil ->
        with {:ok, session} <- current_session(episode),
             {:ok, session} <- isolate_transferred_owner(episode, session),
             {:ok, turn} <- insert_turn(episode, session) do
          {:ok, session, turn}
        end

      %Turn{} = identity ->
        with {:ok, session} <- lock_session(episode.id, identity.session_id),
             {:ok, turn} <- lock_turn(episode.id, episode.owner_ref) do
          {:ok, session, turn}
        end
    end
  end

  defp ensure_session_and_turn(%Episode{owner_kind: :delivery} = episode) do
    case Repo.one(
           from(turn in Turn,
             where: turn.episode_id == ^episode.id and turn.delivery_ref == ^episode.owner_ref
           )
         ) do
      nil ->
        {:error, :work_delivery_turn_not_found}

      %Turn{} = identity ->
        with {:ok, session} <- lock_session(episode.id, identity.session_id),
             {:ok, turn} <- lock_turn(episode.id, identity.turn_ref) do
          {:ok, session, turn}
        end
    end
  end

  defp insert_turn(episode, session) do
    Ecto.UUID.generate()
    |> TurnChangeset.insert(episode.id, session.id, episode.owner_ref)
    |> Repo.insert()
    |> persistence_result(:work_turn)
  end

  defp isolate_transferred_owner(episode, session) do
    stale_turns =
      Repo.all(
        from(turn in Turn,
          where:
            turn.episode_id == ^episode.id and turn.session_id == ^session.id and
              turn.turn_ref != ^episode.owner_ref and turn.status in [:pending, :blocked],
          order_by: [asc: turn.inserted_at, asc: turn.id],
          lock: "FOR UPDATE"
        )
      )

    case stale_turns do
      [] ->
        {:ok, session}

      turns ->
        case block_transferred_turns(turns) do
          :ok ->
            insert_session(episode.id, session.generation + 1, session_authority(session))

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp block_transferred_turns(turns) do
    Enum.reduce_while(turns, :ok, fn
      %Turn{status: :blocked}, :ok ->
        {:cont, :ok}

      %Turn{} = turn, :ok ->
        case turn
             |> TurnChangeset.block(%{
               last_error_code: "owner_transferred",
               last_error_detail:
                 "The episode moved to another logical turn before this work settled.",
               lease_expires_at: nil,
               lease_owner: nil,
               lease_ref: nil,
               next_attempt_at: nil,
               status: :blocked
             })
             |> Repo.update()
             |> persistence_result(:work_transferred_turn) do
          {:ok, _turn} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  # Replacement generations copy the predecessor's authority verbatim, including
  # an absent selector. A rotation is the same custody, never a new resolution.
  defp session_authority(%Session{} = session) do
    %{
      authority_digest: session.authority_digest,
      policy: session.policy,
      policy_digest: session.policy_digest,
      repository_context: session.repository_context,
      repository_ref: session.repository_ref,
      repository_source: session.repository_source,
      workspace_task: session.workspace_task
    }
  end

  defp insert_session(episode_id, generation, authority) do
    session_id = Ecto.UUID.generate()

    session_id
    |> SessionChangeset.insert_with_authority(
      episode_id,
      generation,
      authority.policy,
      authority.policy_digest,
      authority.repository_ref,
      session_external_ref(episode_id, generation),
      %{
        authority_digest: authority.authority_digest,
        repository_context: authority.repository_context,
        repository_source: authority.repository_source,
        workspace_task: authority.workspace_task
      }
    )
    |> Repo.insert()
    |> persistence_result(:work_session)
  end

  defp insert_session_or_rollback(episode_id, generation, authority) do
    case insert_session(episode_id, generation, authority) do
      {:ok, session} -> session
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp claim_turn(%Turn{status: status} = turn, worker_ref, now, lease_seconds)
       when status in [:pending, :cancel_pending, :delivery_pending] do
    attributes =
      %{
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: DateTime.add(now, lease_seconds, :second),
        lease_owner: worker_ref,
        lease_ref: "work-lease:#{Ecto.UUID.generate()}",
        next_attempt_at: nil
      }
      |> Map.put(attempt_field(status), attempt_count(turn, status) + 1)

    turn
    |> TurnChangeset.claim(attributes)
    |> Repo.update()
    |> persistence_result(:work_turn_claim)
  end

  defp claim_turn(%Turn{}, _worker_ref, _now, _lease_seconds),
    do: {:error, :work_turn_not_claimable}

  defp attempt_field(:pending), do: :work_attempt_count
  defp attempt_field(:cancel_pending), do: :cancel_attempt_count
  defp attempt_field(:delivery_pending), do: :delivery_attempt_count

  defp attempt_count(turn, :pending), do: turn.work_attempt_count
  defp attempt_count(turn, :cancel_pending), do: turn.cancel_attempt_count
  defp attempt_count(turn, :delivery_pending), do: turn.delivery_attempt_count

  defp freeze_locked(episode_id, turn_ref, lease_ref, submission, fingerprint, evidence) do
    case turn_for_lease(episode_id, turn_ref, lease_ref) do
      {:ok, _session, %Turn{submission: nil} = turn} ->
        frozen =
          turn
          |> TurnChangeset.freeze(submission, fingerprint, evidence)
          |> Repo.update()
          |> unwrap_or_rollback(:work_submission)

        attach_submission_artifacts(frozen, submission)

      {:ok, _session, %Turn{submission_fingerprint: ^fingerprint} = turn} ->
        attach_submission_artifacts(turn, submission)

      {:ok, _session, %Turn{submission_fingerprint: stored}} ->
        Repo.rollback({:work_submission_conflict, stored})

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp attach_submission_artifacts(turn, submission) do
    case ArtifactReferences.attach_turn(turn.id, submission["input_artifact_refs"]) do
      :ok -> turn
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp bind_state_tools_locked(episode_id, turn_ref, lease_ref, endpoint, token_sha256) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      turn.state_tools_endpoint == endpoint and
          turn.state_tools_token_sha256 == token_sha256 ->
        turn

      is_nil(turn.state_tools_endpoint) and is_nil(turn.state_tools_token_sha256) ->
        turn
        |> TurnChangeset.bind_state_tools(endpoint, token_sha256)
        |> Repo.update()
        |> unwrap_or_rollback(:work_state_tools_binding)

      true ->
        Repo.rollback(:work_state_tools_binding_conflict)
    end
  end

  defp bind_session_locked(
         episode_id,
         turn_ref,
         lease_ref,
         generation,
         create_generation,
         coop_session_id
       ) do
    {session, turn} = leased!(episode_id, turn_ref, lease_ref)
    _turn = clear_remote_operation!(turn, "create_session", create_operation_key(session))

    cond do
      session.generation != generation ->
        Repo.rollback({:work_session_generation_conflict, session.generation})

      session.create_generation != create_generation ->
        Repo.rollback({:work_session_create_generation_conflict, session.create_generation})

      session.coop_session_id == nil ->
        session
        |> SessionChangeset.bind(coop_session_id)
        |> Repo.update()
        |> unwrap_or_rollback(:work_session_binding)

      session.coop_session_id == coop_session_id ->
        session

      true ->
        Repo.rollback({:work_session_conflict, session.coop_session_id})
    end
  end

  defp advance_session_create_locked(episode_id, turn_ref, lease_ref, expected_generation) do
    {session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      session.coop_session_id != nil ->
        Repo.rollback(:work_session_already_bound)

      session.create_generation != expected_generation ->
        Repo.rollback({:work_session_create_generation_conflict, session.create_generation})

      true ->
        _turn = clear_remote_operation!(turn, "create_session", create_operation_key(session))

        session
        |> SessionChangeset.advance_create(session.create_generation + 1)
        |> Repo.update()
        |> unwrap_or_rollback(:work_session_create_generation)
    end
  end

  defp rotate_session_locked(episode_id, turn_ref, lease_ref, expected_generation),
    do:
      rotate_session_locked(
        episode_id,
        turn_ref,
        lease_ref,
        expected_generation,
        :remote_terminal
      )

  defp rotate_session_locked(
         episode_id,
         turn_ref,
         lease_ref,
         expected_generation,
         reason
       ) do
    {session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      session.generation != expected_generation ->
        Repo.rollback({:work_session_generation_conflict, session.generation})

      session.coop_session_id == nil and reason != :placement_lost ->
        Repo.rollback(:work_session_not_bound)

      turn.coop_turn_id != nil ->
        Repo.rollback(:work_turn_already_bound)

      turn.submission != nil ->
        Repo.rollback(:work_session_rotation_requires_unfrozen_submission)

      turn.remote_operation_kind != nil ->
        Repo.rollback(:work_remote_operation_in_flight)

      true ->
        with {:ok, replacement} <-
               insert_session(
                 session.episode_id,
                 session.generation + 1,
                 session_authority(session)
               ),
             {:ok, turn} <-
               turn
               |> TurnChangeset.rebind_session(replacement.id)
               |> Repo.update()
               |> persistence_result(:work_turn_session) do
          %{session: replacement, turn: turn}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp bind_turn_locked(
         episode_id,
         turn_ref,
         lease_ref,
         session_generation,
         submit_generation,
         coop_turn_id
       ) do
    {session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      session.generation != session_generation ->
        Repo.rollback({:work_session_generation_conflict, session.generation})

      session.coop_session_id == nil ->
        Repo.rollback(:work_session_not_bound)

      turn.submit_generation != submit_generation ->
        Repo.rollback({:work_turn_submit_generation_conflict, turn.submit_generation})

      turn.submission == nil ->
        Repo.rollback(:work_submission_not_frozen)

      turn.coop_turn_id == nil ->
        turn = clear_remote_operation!(turn, "submit_turn", submit_operation_key(turn))

        turn
        |> TurnChangeset.bind_coop_turn(coop_turn_id)
        |> Repo.update()
        |> unwrap_or_rollback(:work_turn_binding)

      turn.coop_turn_id == coop_turn_id ->
        clear_remote_operation!(turn, "submit_turn", submit_operation_key(turn))

      true ->
        Repo.rollback({:work_turn_conflict, turn.coop_turn_id})
    end
  end

  defp advance_turn_submit_locked(episode_id, turn_ref, lease_ref, expected_generation) do
    {session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      session.coop_session_id == nil ->
        Repo.rollback(:work_session_not_bound)

      turn.submission == nil ->
        Repo.rollback(:work_submission_not_frozen)

      turn.coop_turn_id != nil ->
        Repo.rollback(:work_turn_already_bound)

      turn.submit_generation != expected_generation ->
        Repo.rollback({:work_turn_submit_generation_conflict, turn.submit_generation})

      true ->
        turn = clear_remote_operation!(turn, "submit_turn", submit_operation_key(turn))

        turn
        |> TurnChangeset.advance_submit(turn.submit_generation + 1)
        |> Repo.update()
        |> unwrap_or_rollback(:work_turn_submit_generation)
    end
  end

  defp stage_candidate_locked(
         episode_id,
         turn_ref,
         lease_ref,
         expected_candidate_sha256,
         expected_candidate_attempt,
         candidate,
         candidate_sha256,
         candidate_attempt
       ) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    case candidate_action(
           turn,
           expected_candidate_sha256,
           expected_candidate_attempt,
           candidate,
           candidate_sha256,
           candidate_attempt
         ) do
      %Turn{} = staged ->
        record_candidate_response!(staged)

        case Continuity.candidate_staged_in_transaction(
               staged,
               candidate_sha256,
               candidate_attempt
             ) do
          :ok -> staged
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp record_candidate_response!(%Turn{operational_pruned_at: pruned}) when not is_nil(pruned),
    do: Repo.rollback(:work_candidate_response_pruned)

  defp record_candidate_response!(turn) do
    # The lease check holds the owning turn lock, also used by operational
    # pruning. Record only these supplied bytes, never backfill an older cursor.
    identity = [turn_id: turn.id, candidate_attempt: turn.candidate_attempt]
    bytes = byte_size(turn.candidate)

    case Repo.get_by(CandidateResponse, identity) do
      nil ->
        Repo.insert!(%CandidateResponse{
          turn_id: turn.id,
          candidate_attempt: turn.candidate_attempt,
          body: turn.candidate,
          sha256: turn.candidate_sha256,
          byte_size: bytes,
          recorded_at: database_now!()
        })

      %CandidateResponse{operational_pruned_at: pruned} when not is_nil(pruned) ->
        Repo.rollback(:work_candidate_response_pruned)

      %CandidateResponse{body: body, sha256: sha256, byte_size: ^bytes}
      when body == turn.candidate and sha256 == turn.candidate_sha256 ->
        :ok

      %CandidateResponse{} ->
        Repo.rollback({:work_candidate_response_conflict, turn.candidate_attempt})
    end
  end

  defp candidate_action(
         %Turn{coop_turn_id: nil},
         _expected_sha,
         _expected_attempt,
         _body,
         _sha,
         _attempt
       ),
       do: Repo.rollback(:work_turn_not_bound)

  defp candidate_action(
         %Turn{result_ref: result_ref},
         _expected_sha,
         _expected_attempt,
         _body,
         _sha,
         _attempt
       )
       when not is_nil(result_ref),
       do: Repo.rollback(:work_result_already_accepted)

  defp candidate_action(turn, _expected_sha, _expected_attempt, body, sha, attempt)
       when turn.candidate == body and turn.candidate_sha256 == sha and
              turn.candidate_attempt == attempt,
       do: turn

  defp candidate_action(
         %Turn{candidate_sha256: nil} = turn,
         nil,
         _expected_attempt,
         body,
         sha,
         attempt
       ) do
    turn
    |> TurnChangeset.stage_candidate(body, sha, attempt)
    |> Repo.update()
    |> unwrap_or_rollback(:work_candidate)
  end

  defp candidate_action(turn, expected_sha, expected_attempt, body, sha, attempt)
       when turn.candidate_sha256 == expected_sha and turn.candidate_attempt == expected_attempt and
              attempt > expected_attempt do
    turn
    |> TurnChangeset.replace_candidate(body, sha, attempt)
    |> Repo.update()
    |> unwrap_or_rollback(:work_candidate)
  end

  defp candidate_action(turn, expected_sha, expected_attempt, _body, _sha, _attempt)
       when turn.candidate_sha256 == expected_sha and turn.candidate_attempt == expected_attempt,
       do: Repo.rollback({:work_candidate_attempt_conflict, turn.candidate_attempt})

  defp candidate_action(turn, _expected_sha, _expected_attempt, _body, _sha, _attempt),
    do: Repo.rollback({:work_candidate_conflict, turn.candidate_sha256})

  defp advance_validation_locked(
         episode_id,
         turn_ref,
         lease_ref,
         candidate_sha256,
         candidate_attempt,
         expected_generation
       ) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      turn.result_ref != nil ->
        Repo.rollback(:work_result_already_accepted)

      turn.candidate_sha256 != candidate_sha256 or
          turn.candidate_attempt != candidate_attempt ->
        Repo.rollback({:work_candidate_conflict, turn.candidate_sha256})

      turn.validation_generation != expected_generation ->
        Repo.rollback({:work_validation_generation_conflict, turn.validation_generation})

      turn.validation_intent == nil ->
        Repo.rollback(:work_validation_intent_not_frozen)

      true ->
        turn
        |> TurnChangeset.advance_validation(turn.validation_generation + 1)
        |> Repo.update()
        |> unwrap_or_rollback(:work_validation_generation)
    end
  end

  defp prepare_validation_locked(
         episode_id,
         turn_ref,
         lease_ref,
         candidate_sha256,
         candidate_attempt,
         intent,
         fingerprint
       ) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      turn.result_ref != nil ->
        Repo.rollback(:work_result_already_accepted)

      turn.coop_turn_id == nil ->
        Repo.rollback(:work_turn_not_bound)

      turn.candidate_sha256 != candidate_sha256 or
          turn.candidate_attempt != candidate_attempt ->
        Repo.rollback({:work_candidate_conflict, turn.candidate_sha256})

      turn.validation_intent_fingerprint == fingerprint ->
        turn

      turn.validation_intent != nil ->
        Repo.rollback({:work_validation_intent_conflict, turn.validation_intent_fingerprint})

      true ->
        persist_validation_intent(turn, intent, fingerprint)
    end
  end

  defp persist_validation_intent(turn, intent, fingerprint) do
    case validation_intent_ready(intent) do
      :ok ->
        turn
        |> TurnChangeset.prepare_validation(intent, fingerprint, database_now!())
        |> Repo.update()
        |> unwrap_or_rollback(:work_validation_intent)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp accept_result_locked(
         episode_id,
         episode_key,
         turn_ref,
         lease_ref,
         candidate_sha256,
         candidate_attempt,
         validation_receipt,
         measurement
       ) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         :ok <- exact_episode(episode, episode_id),
         {:ok, session, turn} <- lock_turn_after_episode(episode_id, turn_ref),
         {:ok, result} <- accepted_intent_result(turn),
         {:continue, command, attributes} <-
           prepare_result_acceptance(
             episode,
             turn,
             lease_ref,
             candidate_sha256,
             candidate_attempt,
             validation_receipt,
             result,
             measurement
           ),
         :ok <- KnowledgeSnapshot.authorize_session(episode, session),
         :ok <-
           KnowledgeSnapshot.authorize_submission(
             episode,
             session.repository_ref,
             turn.submission
           ),
         {:ok, [transition]} <- Episodes.apply_batch_in_transaction([command]),
         {:ok, turn} <-
           turn
           |> TurnChangeset.accept_result(attributes)
           |> Repo.update()
           |> persistence_result(:work_result),
         :ok <-
           PublicationCustody.ensure_task_review_in_transaction(
             transition.episode,
             session,
             turn
           ),
         :ok <- Responder.Accounting.accepted_in_transaction(episode, session, turn),
         {:ok, _subscription} <- EventSubscriptions.ensure_in_transaction(transition.episode),
         :ok <- Continuity.accept_staged_in_transaction(episode, session, turn, turn.result_ref) do
      %{episode: transition.episode, turn: turn}
    else
      {:accepted, turn} -> %{episode: episode_for_result!(episode_key), turn: turn}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp confirm_delivery_locked(
         episode_id,
         episode_key,
         turn_ref,
         lease_ref,
         external_receipt,
         receipt_fingerprint
       ) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         :ok <- exact_episode(episode, episode_id),
         {:ok, _session, turn} <- lock_turn_after_episode(episode_id, turn_ref),
         {:continue, command, delivered_at} <-
           prepare_delivery_confirmation(
             episode,
             turn,
             lease_ref,
             external_receipt,
             receipt_fingerprint
           ),
         {:ok, [transition]} <- Episodes.apply_batch_in_transaction([command]),
         {:ok, turn} <-
           turn
           |> TurnChangeset.confirm_delivery(
             external_receipt,
             receipt_fingerprint,
             delivered_at
           )
           |> Repo.update()
           |> persistence_result(:work_delivery),
         {:ok, _subscription} <- EventSubscriptions.ensure_in_transaction(transition.episode) do
      %{episode: transition.episode, turn: turn}
    else
      {:delivered, turn} -> %{episode: episode_for_result!(episode_key), turn: turn}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp request_cancellation(episode_id, episode_key, turn_ref, intent, lease_ref \\ nil) do
    fingerprint = Cancellation.fingerprint(intent)

    Repo.transaction(fn ->
      request_cancellation_locked(
        episode_id,
        episode_key,
        turn_ref,
        intent,
        fingerprint,
        lease_ref
      )
    end)
    |> transaction_result()
  end

  defp request_cancellation_locked(
         episode_id,
         episode_key,
         turn_ref,
         intent,
         fingerprint,
         lease_ref
       ) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         :ok <- exact_episode(episode, episode_id) do
      request_cancellation_for_identity(
        episode,
        turn_identity(episode_id, turn_ref),
        turn_ref,
        intent,
        fingerprint,
        lease_ref
      )
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_blocked_owner(
         %Episode{state: :working, owner_kind: :turn} = episode,
         required_input_ref
       ) do
    case turn_identity(episode.id, episode.owner_ref) do
      %Turn{
        status: status,
        cancellation_intent: %{"action" => "block"}
      } = identity
      when status in [:cancel_pending, :blocked] ->
        resume_blocked_identity(episode, identity, required_input_ref)

      _other ->
        {:ok, episode}
    end
  end

  defp resume_blocked_owner(%Episode{} = episode, _required_input_ref), do: {:ok, episode}

  defp retry_blocked_locked(episode_key, expected_recovery) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         {:ok, _session, turn} <- lock_turn_after_episode(episode.id, episode.owner_ref) do
      if recovery_fingerprint(turn) != expected_recovery,
        do: Repo.rollback(:work_recovery_changed)

      retry_blocked_episode(episode)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp retry_blocked_episode(%Episode{state: :working, owner_kind: :turn} = episode) do
    case turn_identity(episode.id, episode.owner_ref) do
      %Turn{
        status: :blocked,
        completion_receipt: %{},
        cancellation_intent: nil,
        result_ref: nil,
        delivery_ref: nil
      } ->
        with {:ok, _session, turn} <- lock_turn_after_episode(episode.id, episode.owner_ref),
             true <-
               is_nil(turn.operational_pruned_at) and
                 completion_matches?(turn, turn.completion_receipt),
             {:ok, _turn} <- turn |> TurnChangeset.retry_completion() |> Repo.update() do
          episode
        else
          _invalid -> Repo.rollback(:work_completion_not_retryable)
        end

      %Turn{status: :blocked, cancellation_intent: %{"action" => "block"}} = identity ->
        case resume_blocked_identity(episode, identity, nil) do
          {:ok, resumed} -> resumed
          {:error, reason} -> Repo.rollback(reason)
        end

      _not_blocked ->
        Repo.rollback(:work_not_blocked)
    end
  end

  defp retry_blocked_episode(%Episode{}), do: Repo.rollback(:work_not_blocked)

  defp pause_destination_owner(
         %Episode{state: :working, owner_kind: :turn} = episode,
         intent,
         fingerprint
       ) do
    case turn_identity(episode.id, episode.owner_ref) do
      nil ->
        block_unsubmitted_destination_turn(episode, intent, fingerprint)

      %Turn{} = identity ->
        request_cancellation_for_identity(
          episode,
          identity,
          episode.owner_ref,
          intent,
          fingerprint,
          nil
        )
    end
  end

  defp pause_destination_owner(
         %Episode{state: :working, owner_kind: :delivery} = episode,
         intent,
         _fingerprint
       ) do
    pause_destination_delivery(episode, intent)
  end

  defp pause_destination_owner(%Episode{} = episode, _intent, _fingerprint),
    do: %{episode: episode, status: :settled, turn: nil}

  defp block_unsubmitted_destination_turn(episode, intent, fingerprint) do
    with {:ok, session} <- current_session(episode),
         {:ok, turn} <- insert_turn(episode, session),
         {:ok, turn} <-
           turn
           |> TurnChangeset.prepare_cancellation(intent, fingerprint, nil)
           |> Repo.update()
           |> persistence_result(:work_destination_pause),
         {:ok, turn} <-
           turn
           |> TurnChangeset.block(%{
             last_error_code: "destination_paused",
             last_error_detail: intent["reason"],
             lease_expires_at: nil,
             lease_owner: nil,
             lease_ref: nil,
             next_attempt_at: nil,
             status: :blocked
           })
           |> Repo.update()
           |> persistence_result(:work_destination_pause) do
      %{episode: episode, status: :settled, turn: turn}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp pause_destination_delivery(episode, intent) do
    now = database_now!()

    case lock_delivery_turn(episode.id, episode.owner_ref) do
      {:ok, %Turn{status: :delivery_pending} = turn} ->
        pause_pending_delivery(episode, turn, intent, now)

      {:ok, %Turn{status: :blocked} = turn} ->
        pause_blocked_delivery(episode, turn, intent)

      {:ok, %Turn{}} ->
        Repo.rollback(:work_delivery_not_pending)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp pause_pending_delivery(episode, turn, intent, now) do
    if current_lease?(turn, turn.lease_ref, now),
      do: %{episode: episode, status: :pending, turn: turn},
      else: block_destination_delivery(episode, turn, intent)
  end

  defp pause_blocked_delivery(episode, turn, intent) do
    cond do
      turn.last_error_code == "destination_paused" and
          turn.last_error_detail == intent["reason"] ->
        %{episode: episode, status: :settled, turn: turn}

      turn.last_error_code == "slack_incident_room_inactive" ->
        block_destination_delivery(episode, turn, intent)

      true ->
        %{episode: episode, status: :settled, turn: turn}
    end
  end

  defp block_destination_delivery(episode, turn, intent) do
    result =
      turn
      |> TurnChangeset.block(%{
        last_error_code: "destination_paused",
        last_error_detail: intent["reason"],
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        status: :blocked
      })
      |> Repo.update()
      |> persistence_result(:work_destination_pause)

    case result do
      {:ok, turn} -> %{episode: episode, status: :settled, turn: turn}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_destination_owner(
         %Episode{state: :working, owner_kind: :turn} = episode,
         reason
       ) do
    case turn_identity(episode.id, episode.owner_ref) do
      %Turn{cancellation_intent: %{"action" => "block", "reason" => ^reason}} = turn ->
        resume_destination_turn(episode, turn)

      _not_this_pause ->
        %{episode: episode, status: :settled, turn: nil}
    end
  end

  defp resume_destination_owner(
         %Episode{state: :working, owner_kind: :delivery} = episode,
         reason
       ) do
    case lock_delivery_turn(episode.id, episode.owner_ref) do
      {:ok,
       %Turn{
         last_error_code: "destination_paused",
         last_error_detail: ^reason,
         status: :blocked
       } = turn} ->
        case turn |> TurnChangeset.retry_delivery() |> Repo.update() do
          {:ok, turn} ->
            %{episode: episode, status: :settled, turn: turn}

          {:error, changeset} ->
            Repo.rollback({:work_destination_resume_persistence_failed, changeset.errors})
        end

      {:ok, %Turn{} = turn} ->
        %{episode: episode, status: :settled, turn: turn}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp resume_destination_owner(%Episode{} = episode, _reason),
    do: %{episode: episode, status: :settled, turn: nil}

  defp resume_destination_turn(
         episode,
         %Turn{
           cancellation_receipt: nil,
           coop_turn_id: nil,
           status: :blocked,
           submission: nil
         } = turn
       ) do
    transfer_local_destination_block(episode, turn)
  end

  defp resume_destination_turn(episode, %Turn{status: status} = turn)
       when status in [:cancel_pending, :blocked] do
    new_turn_ref = "turn:resume-destination:#{turn.id}:v#{episode.semantic_version}"
    transfer_ref = "transfer:resume-destination:#{turn.id}:v#{episode.semantic_version}"

    case Cancellation.new_transfer(new_turn_ref, transfer_ref) do
      {:ok, intent} ->
        request_cancellation_for_identity(
          episode,
          turn,
          episode.owner_ref,
          intent,
          Cancellation.fingerprint(intent),
          nil
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp resume_destination_turn(episode, turn),
    do: %{episode: episode, status: :settled, turn: turn}

  defp transfer_local_destination_block(episode, turn) do
    new_turn_ref = "turn:resume-destination:#{turn.id}:v#{episode.semantic_version}"
    transfer_ref = "transfer:resume-destination:#{turn.id}:v#{episode.semantic_version}"

    with {:ok, intent} <- Cancellation.new_transfer(new_turn_ref, transfer_ref),
         {:ok, [transition]} <-
           Episodes.apply_batch_in_transaction(
             [Cancellation.command(intent, episode, database_now!())],
             settled_work_turn_id: turn.id
           ),
         {:ok, turn} <-
           turn
           |> TurnChangeset.replace_cancellation_disposition(
             turn.cancellation_intent,
             turn.cancellation_intent_fingerprint,
             "destination_resumed",
             "The destination became active before remote work was submitted.",
             :superseded
           )
           |> Repo.update()
           |> persistence_result(:work_destination_resume) do
      %{episode: transition.episode, status: :settled, turn: turn}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_blocked_identity(episode, identity, required_input_ref) do
    new_turn_ref = "turn:resume-blocked:#{identity.id}:v#{episode.semantic_version}"
    transfer_ref = "transfer:resume-blocked:#{identity.id}:v#{episode.semantic_version}"

    with :ok <- completed_workspace_recoverable(identity),
         {:ok, intent} <-
           Cancellation.new_transfer(new_turn_ref, transfer_ref, required_input_ref) do
      fingerprint = Cancellation.fingerprint(intent)

      episode
      |> request_cancellation_for_identity(
        identity,
        episode.owner_ref,
        intent,
        fingerprint,
        nil
      )
      |> resumed_episode()
    end
  end

  @doc "Read-only recovery eligibility; retry rechecks this under custody locks."
  def completed_workspace_recoverable(
        %Turn{cancellation_receipt: %{"remote_state" => "completed", "session_state" => state}} =
          turn
      )
      when state in ["closed", "discarded"] do
    session = Repo.get!(Session, turn.session_id)

    key =
      "responder:work:checkpoint:#{turn.id}:a#{turn.candidate_attempt}:#{turn.candidate_sha256}"

    saved =
      Repo.exists?(
        from(t in Responder.CoopFleet.WorkspaceCheckpointTransfer,
          join: c in Responder.CoopFleet.Command,
          on: c.id == t.command_id,
          where:
            c.session_id == ^session.id and c.idempotency_key == ^key and c.status == :succeeded
        )
      )

    if is_map(session.workspace_task) and not saved,
      do: {:error, :work_completed_workspace_recovery_required},
      else: :ok
  end

  def completed_workspace_recoverable(_turn), do: :ok

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
  def portable_workspace(%Turn{session_id: session_id}) when is_binary(session_id) do
    with %Session{} = session <- Repo.get(Session, session_id),
         {:ok, %{work: %{workspace_ref: workspace_ref}}} when is_binary(workspace_ref) <-
           Settings.fetch() do
      FleetControlPlane.portable_workspace(session, %{
        capability_names: Defaults.fetch!(:work).capability_names,
        capability_versions: %{},
        repository_ref: session.repository_ref,
        workspace_ref: workspace_ref
      })
    else
      _unavailable -> nil
    end
  end

  def portable_workspace(_turn), do: nil

  defp resumed_episode(%{episode: episode}), do: {:ok, episode}

  defp request_cancellation_for_identity(
         episode,
         nil,
         _turn_ref,
         intent,
         fingerprint,
         _lease_ref
       ),
       do: settle_local_cancellation(episode, nil, intent, fingerprint)

  defp request_cancellation_for_identity(
         episode,
         identity,
         turn_ref,
         intent,
         fingerprint,
         lease_ref
       ) do
    with {:ok, session} <- lock_session(episode.id, identity.session_id),
         {:ok, turn} <- lock_turn(episode.id, turn_ref) do
      request_cancellation_for_turn(episode, session, turn, intent, fingerprint, lease_ref)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp request_cancellation_for_turn(episode, session, turn, intent, fingerprint, lease_ref) do
    if exact_cancellation_intent?(turn, fingerprint) do
      retry_cancellation_request(episode, turn, lease_ref)
    else
      prepare_new_cancellation(episode, session, turn, intent, fingerprint, lease_ref)
    end
  end

  defp retry_cancellation_request(episode, turn, lease_ref) do
    case exact_internal_lease(turn, lease_ref) do
      :ok ->
        status =
          if turn.cancellation_receipt != nil or locally_settled_cancellation?(turn),
            do: :settled,
            else: :pending

        %{episode: episode, status: status, turn: turn}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp locally_settled_cancellation?(%Turn{
         status: :blocked,
         coop_turn_id: nil,
         submission: nil,
         remote_operation_kind: nil
       }),
       do: true

  defp locally_settled_cancellation?(%Turn{}), do: false

  defp prepare_new_cancellation(episode, session, turn, intent, fingerprint, lease_ref) do
    with :ok <- valid_cancellation_target(episode, turn, intent),
         :ok <- exact_internal_lease(turn, lease_ref) do
      cond do
        not turn_owner?(episode, turn) ->
          Repo.rollback(:work_episode_owner_lost)

        operator_supersedes_pending_block?(turn, intent) ->
          prepare_cancellation(turn, episode, intent, fingerprint)

        operator_supersedes_settled_block?(turn, intent) ->
          replace_settled_block(episode, session, turn, intent, fingerprint)

        block_follows_operator_intent?(turn, intent) ->
          %{episode: episode, status: :pending, turn: turn}

        conflicting_cancellation?(turn, fingerprint) ->
          Repo.rollback({:work_cancellation_conflict, turn.cancellation_intent_fingerprint})

        true ->
          prepare_cancellation(turn, episode, intent, fingerprint)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp prepare_cancellation(turn, episode, intent, fingerprint) do
    turn =
      turn
      |> TurnChangeset.prepare_cancellation(intent, fingerprint, nil)
      |> Repo.update()
      |> unwrap_or_rollback(:work_cancellation_intent)

    %{episode: episode, status: :pending, turn: turn}
  end

  defp exact_cancellation_intent?(turn, fingerprint),
    do: turn.cancellation_intent_fingerprint == fingerprint

  defp valid_cancellation_target(_episode, _turn, %{"action" => action})
       when action in ~w(cancel block),
       do: :ok

  defp valid_cancellation_target(episode, turn, %{
         "action" => "transfer",
         "new_turn_ref" => new_turn_ref
       }) do
    cond do
      new_turn_ref == turn.turn_ref ->
        {:error, :work_transfer_target_conflict}

      Repo.exists?(
        from(existing in Turn,
          where: existing.episode_id == ^episode.id and existing.turn_ref == ^new_turn_ref
        )
      ) ->
        {:error, :work_transfer_target_conflict}

      true ->
        :ok
    end
  end

  defp operator_supersedes_pending_block?(
         %Turn{status: :cancel_pending, cancellation_intent: %{"action" => "block"}},
         %{"action" => action}
       )
       when action in ~w(cancel transfer),
       do: true

  defp operator_supersedes_pending_block?(_turn, _intent), do: false

  defp operator_supersedes_settled_block?(
         %Turn{
           status: :blocked,
           cancellation_intent: %{"action" => "block"},
           cancellation_receipt: receipt
         },
         %{"action" => action}
       )
       when is_map(receipt) and action in ~w(cancel transfer),
       do: true

  defp operator_supersedes_settled_block?(_turn, _intent), do: false

  defp block_follows_operator_intent?(
         %Turn{cancellation_intent: %{"action" => action}},
         %{"action" => "block"}
       )
       when action in ~w(cancel transfer),
       do: true

  defp block_follows_operator_intent?(_turn, _intent), do: false

  defp exact_internal_lease(_turn, nil), do: :ok

  defp exact_internal_lease(turn, lease_ref),
    do: current_turn_lease(turn, lease_ref, database_now!())

  defp replace_settled_block(episode, session, turn, intent, fingerprint) do
    now = database_now!()

    with :ok <- exact_cancellation_proof(turn.cancellation_receipt, session, turn),
         {:ok, settled_episode} <-
           settle_episode_after_cancellation(
             Cancellation.command(intent, episode, now),
             episode,
             turn
           ),
         {:ok, turn} <-
           turn
           |> TurnChangeset.replace_cancellation_disposition(
             intent,
             fingerprint,
             cancellation_error_code(intent),
             cancellation_error_detail(intent),
             :superseded
           )
           |> Repo.update()
           |> persistence_result(:work_cancellation_disposition),
         :ok <- maybe_rotate_cancelled_session(intent, turn.cancellation_receipt, session) do
      %{episode: settled_episode, status: :settled, turn: turn}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp turn_owner?(episode, turn),
    do:
      episode.state == :working and episode.owner_kind == :turn and
        episode.owner_ref == turn.turn_ref

  defp lock_delivery_turn(episode_id, delivery_ref) do
    case Repo.one(
           from(turn in Turn,
             where: turn.episode_id == ^episode_id and turn.delivery_ref == ^delivery_ref,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :work_delivery_turn_not_found}
      %Turn{} = turn -> {:ok, turn}
    end
  end

  defp conflicting_cancellation?(turn, fingerprint),
    do: turn.cancellation_intent != nil and turn.cancellation_intent_fingerprint != fingerprint

  defp settle_local_cancellation(episode, nil, intent, _fingerprint) do
    command = Cancellation.command(intent, episode, database_now!())

    case Episodes.apply_batch_in_transaction([command]) do
      {:ok, [transition]} -> %{episode: transition.episode, status: :settled, turn: nil}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp advance_cancellation_locked(episode_id, turn_ref, lease_ref, expected_generation) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      turn.status != :cancel_pending ->
        Repo.rollback(:work_cancellation_not_pending)

      turn.cancellation_intent == nil ->
        Repo.rollback(:work_cancellation_intent_not_frozen)

      turn.cancellation_receipt != nil ->
        Repo.rollback(:work_cancellation_already_settled)

      turn.cancel_generation != expected_generation ->
        Repo.rollback({:work_cancel_generation_conflict, turn.cancel_generation})

      true ->
        turn
        |> TurnChangeset.advance_cancel(turn.cancel_generation + 1)
        |> Repo.update()
        |> unwrap_or_rollback(:work_cancel_generation)
    end
  end

  defp settle_cancellation_locked(
         episode_id,
         episode_key,
         turn_ref,
         lease_ref,
         receipt,
         receipt_fingerprint
       ) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         :ok <- exact_episode(episode, episode_id),
         {:ok, session, turn} <- lock_turn_after_episode(episode_id, turn_ref) do
      settle_cancellation_turn(
        episode,
        session,
        turn,
        lease_ref,
        receipt,
        receipt_fingerprint
      )
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp settle_cancellation_turn(
         episode,
         session,
         turn,
         lease_ref,
         receipt,
         receipt_fingerprint
       ) do
    now = database_now!()

    if cancellation_already_settled?(turn, receipt_fingerprint) do
      %{episode: episode, turn: turn}
    else
      with :ok <- cancellation_pending(turn),
           :ok <- cancellation_intent_frozen(turn),
           :ok <- exact_cancellation_proof(receipt, session, turn),
           :ok <- current_turn_owner(episode, turn),
           :ok <- current_turn_lease(turn, lease_ref, now) do
        persist_cancellation_settlement(
          episode,
          session,
          turn,
          receipt,
          receipt_fingerprint,
          now
        )
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp cancellation_already_settled?(turn, receipt_fingerprint),
    do:
      turn.status in [:blocked, :superseded] and
        turn.cancellation_receipt_fingerprint == receipt_fingerprint

  defp cancellation_pending(%Turn{status: :cancel_pending}), do: :ok
  defp cancellation_pending(_turn), do: {:error, :work_cancellation_not_pending}

  defp cancellation_intent_frozen(%Turn{cancellation_intent: intent})
       when not is_nil(intent),
       do: :ok

  defp cancellation_intent_frozen(_turn),
    do: {:error, :work_cancellation_intent_not_frozen}

  defp exact_cancellation_proof(%{"kind" => "terminal_turn"} = receipt, session, turn) do
    expected_cancel_ref = Cancellation.operation_key(turn.id, turn.cancel_generation)

    with :ok <- exact_bound_remote_identity(receipt, session, turn),
         :ok <- optional_exact_reference(receipt["cancel_operation_ref"], expected_cancel_ref),
         do: exact_session_disposition(receipt, session, turn)
  end

  defp exact_cancellation_proof(%{"kind" => "absent_turn"} = receipt, session, turn) do
    expected_submit_ref = if turn.submission == nil, do: nil, else: submit_operation_key(turn)

    with :ok <- exact_reference(receipt["create_operation_ref"], create_operation_key(session)),
         :ok <- exact_optional_reference(receipt["submit_operation_ref"], expected_submit_ref),
         :ok <- absent_remote_identity(receipt, session, turn),
         do: exact_session_disposition(receipt, session, turn)
  end

  defp exact_cancellation_proof(_receipt, _session, _turn),
    do: {:error, :work_cancellation_receipt_mismatch}

  defp exact_bound_remote_identity(receipt, session, turn) do
    if is_binary(session.coop_session_id) and is_binary(turn.coop_turn_id) and
         receipt["remote_session_id"] == session.coop_session_id and
         receipt["remote_turn_id"] == turn.coop_turn_id,
       do: :ok,
       else: {:error, :work_cancellation_receipt_mismatch}
  end

  defp absent_remote_identity(receipt, %Session{coop_session_id: nil}, %Turn{coop_turn_id: nil}) do
    if receipt["remote_session_id"] == nil and receipt["session_state"] == nil and
         receipt["close_operation_ref"] == nil,
       do: :ok,
       else: {:error, :work_cancellation_receipt_mismatch}
  end

  defp absent_remote_identity(receipt, session, %Turn{coop_turn_id: nil}) do
    if is_binary(session.coop_session_id) and
         receipt["remote_session_id"] == session.coop_session_id,
       do: :ok,
       else: {:error, :work_cancellation_receipt_mismatch}
  end

  defp absent_remote_identity(_receipt, _session, _turn),
    do: {:error, :work_cancellation_receipt_mismatch}

  defp exact_session_disposition(%{"remote_session_id" => nil}, %Session{}, %Turn{}),
    do: :ok

  defp exact_session_disposition(receipt, session, turn) do
    state = receipt["session_state"]
    close_ref = receipt["close_operation_ref"]

    case {turn.cancellation_intent["action"], state} do
      {"transfer", "open"} ->
        exact_optional_reference(close_ref, nil)

      {_action, state} when state in ~w(closed discarded) ->
        optional_exact_reference(close_ref, cancellation_close_key(turn))

      _other ->
        {:error, :work_cancellation_receipt_mismatch}
    end
    |> case do
      :ok -> exact_reference(receipt["remote_session_id"], session.coop_session_id)
      {:error, _reason} = error -> error
    end
  end

  defp exact_reference(expected, expected), do: :ok
  defp exact_reference(_actual, _expected), do: {:error, :work_cancellation_receipt_mismatch}

  defp exact_optional_reference(nil, nil), do: :ok
  defp exact_optional_reference(actual, expected), do: exact_reference(actual, expected)

  defp optional_exact_reference(nil, _expected), do: :ok
  defp optional_exact_reference(actual, expected), do: exact_reference(actual, expected)

  defp current_turn_owner(episode, turn) do
    if turn_owner?(episode, turn),
      do: :ok,
      else: {:error, :work_episode_owner_lost}
  end

  defp current_turn_lease(turn, lease_ref, now) do
    if current_lease?(turn, lease_ref, now), do: :ok, else: {:error, :work_lease_lost}
  end

  defp persist_cancellation_settlement(episode, session, turn, receipt, fingerprint, now) do
    command = Cancellation.command(turn.cancellation_intent, episode, now)

    with {:ok, settled_episode} <- settle_episode_after_cancellation(command, episode, turn),
         {:ok, turn} <-
           turn
           |> TurnChangeset.settle_cancellation(
             receipt,
             fingerprint,
             now,
             cancellation_error_code(turn.cancellation_intent),
             cancellation_error_detail(turn.cancellation_intent),
             cancellation_status(turn.cancellation_intent)
           )
           |> Repo.update()
           |> persistence_result(:work_cancellation),
         :ok <- maybe_rotate_cancelled_session(turn.cancellation_intent, receipt, session) do
      %{episode: settled_episode, turn: turn}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp maybe_rotate_cancelled_session(
         %{"action" => "transfer"},
         %{"session_state" => state},
         session
       )
       when state in ~w(closed discarded) do
    case insert_session(
           session.episode_id,
           session.generation + 1,
           session_authority(session)
         ) do
      {:ok, _session} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp maybe_rotate_cancelled_session(_intent, _receipt, _session), do: :ok

  defp settle_episode_after_cancellation(nil, episode, _turn), do: {:ok, episode}

  defp settle_episode_after_cancellation(command, _episode, turn) do
    case Episodes.apply_batch_in_transaction([command], settled_work_turn_id: turn.id) do
      {:ok, [transition]} -> {:ok, transition.episode}
      {:error, _reason} = error -> error
    end
  end

  defp cancellation_error_code(%{"action" => "cancel"}), do: "operator_cancelled"
  defp cancellation_error_code(%{"action" => "transfer"}), do: "owner_transferred"
  defp cancellation_error_code(%{"action" => "block"}), do: "work_execution_blocked"

  defp cancellation_error_detail(%{"action" => "block", "reason" => reason}), do: reason

  defp cancellation_error_detail(_intent),
    do: "The bound Coop turn stopped before episode ownership changed."

  defp cancellation_status(%{"action" => "block"}), do: :blocked
  defp cancellation_status(_intent), do: :superseded

  defp renew_locked(episode_id, turn_ref, lease_ref, lease_seconds) do
    case turn_for_lease(episode_id, turn_ref, lease_ref) do
      {:ok, _session, turn} ->
        now = database_now!()
        requested_expiry = DateTime.add(now, lease_seconds, :second)
        lease_expires_at = later_datetime(turn.lease_expires_at, requested_expiry)

        turn
        |> TurnChangeset.renew(lease_expires_at)
        |> Repo.update()
        |> unwrap_or_rollback(:work_lease_renewal)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp defer_locked(
         episode_id,
         turn_ref,
         lease_ref,
         retry_seconds,
         error_code,
         error_detail
       ) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)
    now = database_now!()

    turn
    |> TurnChangeset.defer(%{
      last_error_code: error_code,
      last_error_detail: error_detail,
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      next_attempt_at: DateTime.add(now, retry_seconds, :second),
      status: turn.status
    })
    |> Repo.update()
    |> unwrap_or_rollback(:work_defer)
  end

  defp block_delivery_locked(episode_id, turn_ref, lease_ref, error_code, error_detail) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    if turn.status == :delivery_pending do
      turn
      |> TurnChangeset.block(%{
        last_error_code: error_code,
        last_error_detail: error_detail,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        status: :blocked
      })
      |> Repo.update()
      |> unwrap_or_rollback(:work_delivery_block)
    else
      Repo.rollback(:work_delivery_not_pending)
    end
  end

  defp retry_delivery_locked(episode_id, turn_ref, delivery_ref) do
    case turn_identity(episode_id, turn_ref) do
      %Turn{delivery_ref: ^delivery_ref} ->
        retry_delivery_owner_locked(episode_id, turn_ref, delivery_ref)

      %Turn{} ->
        Repo.rollback(:work_delivery_ref_mismatch)

      nil ->
        Repo.rollback(:work_turn_not_found)
    end
  end

  defp retry_delivery_owner_locked(episode_id, turn_ref, delivery_ref) do
    with {:ok, _episode} <- lock_episode_owner(episode_id, :delivery, delivery_ref),
         {:ok, turn} <- lock_turn(episode_id, turn_ref) do
      retry_delivery_turn_locked(turn, delivery_ref)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp retry_delivery_turn_locked(
         %Turn{status: :blocked, delivery_ref: delivery_ref} = turn,
         delivery_ref
       ) do
    turn
    |> TurnChangeset.retry_delivery()
    |> Repo.update()
    |> unwrap_or_rollback(:work_delivery_retry)
  end

  defp retry_delivery_turn_locked(
         %Turn{status: :delivery_pending, delivery_ref: delivery_ref} = turn,
         delivery_ref
       ),
       do: turn

  defp retry_delivery_turn_locked(%Turn{}, _delivery_ref),
    do: Repo.rollback(:work_delivery_not_retryable)

  defp yield_progress_locked(episode_id, turn_ref, lease_ref, retry_seconds) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)
    now = database_now!()

    case progress_attempt(turn) do
      {field, count} when count > 0 ->
        turn
        |> TurnChangeset.yield_progress(
          DateTime.add(now, retry_seconds, :second),
          field,
          count - 1
        )
        |> Repo.update()
        |> unwrap_or_rollback(:work_progress_yield)

      _not_yieldable ->
        Repo.rollback(:work_progress_not_yieldable)
    end
  end

  defp progress_attempt(%Turn{status: :pending, work_attempt_count: count}),
    do: {:work_attempt_count, count}

  defp progress_attempt(%Turn{status: :cancel_pending, cancel_attempt_count: count}),
    do: {:cancel_attempt_count, count}

  defp progress_attempt(%Turn{}), do: nil

  defp leased!(episode_id, turn_ref, lease_ref) do
    case turn_for_lease(episode_id, turn_ref, lease_ref) do
      {:ok, session, turn} -> {session, turn}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp turn_for_lease(episode_id, turn_ref, lease_ref) do
    with %Turn{} = identity <- turn_identity(episode_id, turn_ref),
         {:ok, _episode} <- lock_current_episode_owner(episode_id, identity),
         {:ok, session} <- lock_session(episode_id, identity.session_id),
         {:ok, turn} <- leased_turn(episode_id, turn_ref, lease_ref) do
      {:ok, session, turn}
    else
      nil -> {:error, :work_turn_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp turn_identity(episode_id, turn_ref) do
    Repo.one(
      from(turn in Turn,
        where: turn.episode_id == ^episode_id and turn.turn_ref == ^turn_ref
      )
    )
  end

  defp lock_turn(episode_id, turn_ref) do
    case Repo.one(
           from(turn in Turn,
             where: turn.episode_id == ^episode_id and turn.turn_ref == ^turn_ref,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :work_turn_not_found}
      %Turn{} = turn -> {:ok, turn}
    end
  end

  defp leased_turn(episode_id, turn_ref, lease_ref) do
    case Repo.one(
           from(turn in Turn,
             where:
               turn.episode_id == ^episode_id and turn.turn_ref == ^turn_ref and
                 turn.lease_expires_at > fragment("clock_timestamp()"),
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        {:error, :work_turn_not_found}

      %Turn{status: status, lease_ref: ^lease_ref} = turn
      when status in [:pending, :cancel_pending, :delivery_pending] ->
        {:ok, turn}

      %Turn{} ->
        {:error, :work_lease_lost}
    end
  end

  defp lock_current_episode_owner(episode_id, %Turn{status: :pending, turn_ref: owner_ref}) do
    lock_episode_owner(episode_id, :turn, owner_ref)
  end

  defp lock_current_episode_owner(
         episode_id,
         %Turn{status: :cancel_pending, turn_ref: owner_ref}
       ) do
    lock_episode_owner(episode_id, :turn, owner_ref)
  end

  defp lock_current_episode_owner(
         episode_id,
         %Turn{status: :delivery_pending, delivery_ref: owner_ref}
       )
       when is_binary(owner_ref) do
    lock_episode_owner(episode_id, :delivery, owner_ref)
  end

  defp lock_current_episode_owner(_episode_id, %Turn{}),
    do: {:error, :work_turn_not_claimable}

  defp lock_episode_owner(episode_id, owner_kind, owner_ref) do
    case Repo.one(
           from(episode in Episode,
             where:
               episode.id == ^episode_id and episode.state == :working and
                 episode.owner_kind == ^owner_kind and episode.owner_ref == ^owner_ref,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :work_episode_owner_lost}
      %Episode{} = episode -> {:ok, episode}
    end
  end

  defp lock_session(episode_id, session_id) do
    case Repo.one(
           from(session in Session,
             where: session.episode_id == ^episode_id and session.id == ^session_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :work_session_not_found}
      %Session{} = session -> {:ok, session}
    end
  end

  defp lock_turn_after_episode(episode_id, turn_ref) do
    with %Turn{} = identity <- turn_identity(episode_id, turn_ref),
         {:ok, session} <- lock_session(episode_id, identity.session_id),
         {:ok, turn} <- lock_turn(episode_id, turn_ref) do
      {:ok, session, turn}
    else
      nil -> {:error, :work_turn_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_result_acceptance(
         episode,
         turn,
         lease_ref,
         candidate_sha256,
         candidate_attempt,
         validation_receipt,
         result,
         measurement
       ) do
    now = database_now!()
    result_ref = "result:#{turn.id}"
    delivery_ref = if result.delivery == :reply, do: "delivery:#{turn.id}"
    delivery_target = if result.delivery == :reply, do: reply_target(episode, turn)

    delivery_fingerprint =
      if result.delivery_document,
        do: CanonicalJSON.digest(result.delivery_document)

    attributes =
      measurement
      |> Measurement.acceptance_attributes(now)
      |> Map.merge(%{
        accepted_at: now,
        continuation: result.continuation,
        delivery_document: result.delivery_document,
        delivery_fingerprint: delivery_fingerprint,
        delivery_ref: delivery_ref,
        delivery_target: delivery_target,
        result_ref: result_ref,
        status: acceptance_status(result.delivery),
        validation_receipt: validation_receipt
      })

    if result_already_accepted?(
         turn,
         candidate_sha256,
         candidate_attempt,
         validation_receipt,
         attributes
       ) do
      {:accepted, turn}
    else
      with :ok <- result_not_accepted(turn),
           :ok <- current_turn_owner(episode, turn),
           :ok <- current_turn_lease(turn, lease_ref, now),
           :ok <- pending_turn(turn),
           :ok <- bound_turn(turn),
           :ok <- exact_candidate(turn, candidate_sha256, candidate_attempt) do
        build_result_acceptance(episode, turn, result, attributes, result_ref, delivery_ref, now)
      end
    end
  end

  defp result_not_accepted(%Turn{result_ref: nil}), do: :ok

  defp result_not_accepted(%Turn{result_ref: result_ref}),
    do: {:error, {:work_result_conflict, result_ref}}

  defp pending_turn(%Turn{status: :pending}), do: :ok
  defp pending_turn(_turn), do: {:error, :work_turn_not_pending}

  defp bound_turn(%Turn{coop_turn_id: turn_id}) when is_binary(turn_id), do: :ok
  defp bound_turn(_turn), do: {:error, :work_turn_not_bound}

  defp exact_candidate(turn, sha256, attempt) do
    if turn.candidate_sha256 == sha256 and turn.candidate_attempt == attempt,
      do: :ok,
      else: {:error, {:work_candidate_conflict, turn.candidate_sha256}}
  end

  defp build_result_acceptance(episode, turn, result, attributes, result_ref, delivery_ref, now) do
    {next_turn, next_wait} =
      if result.delivery == :none,
        do: delivery_continuation(episode, %{turn | continuation: result.continuation}, now),
        else: {next_turn_ref(episode, result.delivery, turn.id), nil}

    command = %Command.AcceptResult{
      decision_reason: result.decision_reason,
      delivery: result.delivery,
      delivery_ref: delivery_ref,
      episode_key: episode.key,
      expected_turn_ref: turn.turn_ref,
      next_turn_ref: next_turn,
      next_wait: next_wait,
      occurred_at: now,
      result_ref: result_ref
    }

    {:continue, command, release_lease(attributes)}
  end

  defp prepare_delivery_confirmation(
         episode,
         turn,
         lease_ref,
         external_receipt,
         receipt_fingerprint
       ) do
    now = database_now!()

    with :ok <- exact_delivery_ref(turn, external_receipt),
         :ok <- exact_delivery_destination(episode, turn, external_receipt) do
      prepare_identified_delivery(
        episode,
        turn,
        lease_ref,
        external_receipt,
        receipt_fingerprint,
        now
      )
    end
  end

  defp prepare_identified_delivery(episode, turn, lease_ref, receipt, fingerprint, now) do
    if delivery_already_settled?(turn, receipt, fingerprint) do
      {:delivered, turn}
    else
      validate_pending_delivery(episode, turn, lease_ref, now)
    end
  end

  defp validate_pending_delivery(episode, turn, lease_ref, now) do
    with :ok <- delivery_receipt_unset(turn),
         :ok <- current_delivery_owner(episode, turn),
         :ok <- delivery_pending(turn),
         :ok <- current_turn_lease(turn, lease_ref, now) do
      build_delivery_confirmation(episode, turn, now)
    end
  end

  defp exact_delivery_ref(turn, %{"delivery_ref" => delivery_ref})
       when delivery_ref == turn.delivery_ref,
       do: :ok

  defp exact_delivery_ref(_turn, _receipt), do: {:error, :work_delivery_receipt_mismatch}

  defp exact_delivery_destination(episode, turn, receipt) do
    target = delivery_target(episode, turn)

    if receipt["transport"] == target["transport"] and
         receipt["conversation_ref"] == target["conversation_ref"] and
         receipt["thread_ref"] == target["thread_ref"],
       do: :ok,
       else: {:error, :work_delivery_destination_mismatch}
  end

  @doc """
  Where this turn's accepted answer belongs.

  A reply answers the inputs that instructed it, so it returns to the newest
  one's own origin — a question asked in a new thread is answered there even
  when the episode's home is elsewhere. An accepted answer keeps the target it
  was accepted with; later context can never move or erase it.
  """
  @spec delivery_target(Episode.t(), Turn.t()) :: map()
  def delivery_target(%Episode{} = episode, %Turn{delivery_target: %{} = target}) do
    Map.merge(home_target(episode), target)
  end

  def delivery_target(%Episode{} = episode, _turn), do: home_target(episode)

  defp home_target(%Episode{} = episode) do
    %{
      "conversation_ref" => episode.destination_conversation_ref,
      "thread_ref" => episode.destination_thread_ref,
      "transport" => episode.destination_transport
    }
  end

  @doc """
  The origin a reply from this turn answers, or nil when there is nothing to answer.

  This is computed once, when the result is accepted, and then frozen on the
  turn. Later inputs cannot move an answer that has already been accepted.
  """
  @spec reply_target(Episode.t(), Turn.t()) :: map() | nil
  def reply_target(%Episode{} = episode, %Turn{} = turn) do
    episode
    |> answering_origin(turn)
    |> case do
      nil ->
        nil

      origin ->
        %{
          "conversation_ref" => origin.conversation_ref,
          "thread_ref" => origin.thread_ref,
          "transport" => origin.transport
        }
    end
  end

  defp answering_origin(%Episode{} = episode, %Turn{selected_input_refs: refs})
       when is_list(refs) and refs != [] do
    newest_origin(episode, refs)
  end

  defp answering_origin(%Episode{} = episode, %Turn{selected_input_refs: nil} = turn),
    do: active_origin(episode, turn)

  defp answering_origin(%Episode{} = episode, %Turn{selected_input_refs: []} = turn),
    do: active_origin(episode, turn)

  defp answering_origin(_episode, _turn), do: nil

  defp active_origin(%Episode{active_input_refs: [_ | _] = refs} = episode, _turn),
    do: newest_origin(episode, refs)

  defp active_origin(_episode, _turn), do: nil

  # An episode may hold evidence from several conversations, so the input a
  # reply answers is the newest by occurrence, not by this episode's own
  # event sequence.
  defp newest_origin(%Episode{} = episode, refs) do
    Repo.one(
      from(origin in Origin,
        where:
          origin.episode_id == ^episode.id and origin.input_ref in ^refs and origin.effective,
        order_by: [desc: origin.occurred_at, desc: origin.sequence],
        limit: 1
      )
    )
  end

  defp delivery_already_settled?(turn, receipt, fingerprint),
    do:
      turn.status == :settled and turn.external_receipt == receipt and
        turn.external_receipt_fingerprint == fingerprint

  defp delivery_receipt_unset(%Turn{external_receipt: nil}), do: :ok
  defp delivery_receipt_unset(_turn), do: {:error, :work_delivery_receipt_conflict}

  defp current_delivery_owner(episode, turn) do
    if episode.state == :working and episode.owner_kind == :delivery and
         episode.owner_ref == turn.delivery_ref,
       do: :ok,
       else: {:error, :work_delivery_owner_lost}
  end

  defp delivery_pending(%Turn{status: :delivery_pending}), do: :ok
  defp delivery_pending(_turn), do: {:error, :work_delivery_not_pending}

  defp build_delivery_confirmation(episode, turn, now) do
    {next_turn_ref, next_wait} = delivery_continuation(episode, turn, now)

    command = %Command.ConfirmDelivery{
      episode_key: episode.key,
      expected_delivery_ref: turn.delivery_ref,
      next_turn_ref: next_turn_ref,
      next_wait: next_wait,
      occurred_at: now
    }

    {:continue, command, now}
  end

  defp result_already_accepted?(
         turn,
         candidate_sha256,
         candidate_attempt,
         validation_receipt,
         attributes
       ) do
    turn.result_ref == attributes.result_ref and
      turn.candidate_sha256 == candidate_sha256 and
      turn.candidate_attempt == candidate_attempt and
      turn.validation_receipt == validation_receipt and
      turn.delivery_ref == attributes.delivery_ref and
      turn.delivery_fingerprint == attributes.delivery_fingerprint and
      turn.delivery_document == attributes.delivery_document and
      turn.continuation == attributes.continuation and
      turn.status in [:delivery_pending, :settled, :superseded]
  end

  defp acceptance_status(:reply), do: :delivery_pending
  defp acceptance_status(:none), do: :settled

  defp release_lease(attributes) do
    Map.merge(attributes, %{
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      next_attempt_at: nil
    })
  end

  defp next_turn_ref(%Episode{queued_input_refs: []}, _phase, _turn_id), do: nil
  defp next_turn_ref(_episode, :reply, _turn_id), do: nil
  defp next_turn_ref(_episode, _phase, turn_id), do: "turn:after:#{turn_id}"

  defp validation_intent_ready(intent) do
    case ValidationIntent.result(intent) do
      {:ok, nil} -> :ok
      {:ok, result} -> Result.validate_at(result, database_now!())
      {:error, _reason} -> {:error, :work_validation_intent_invalid}
    end
  end

  defp accepted_intent_result(%Turn{validation_intent: intent}) when is_map(intent) do
    case ValidationIntent.result(intent) do
      {:ok, %Result{} = result} -> {:ok, result}
      {:ok, nil} -> {:error, :work_validation_intent_not_accept}
      {:error, _reason} -> {:error, :work_validation_intent_invalid}
    end
  end

  defp accepted_intent_result(%Turn{}), do: {:error, :work_validation_intent_not_frozen}

  defp delivery_continuation(%Episode{queued_input_refs: [_first | _rest]}, turn, _now),
    do: {"turn:after:#{turn.id}", nil}

  defp delivery_continuation(_episode, %{continuation: %{"kind" => "complete"}}, _now),
    do: {nil, nil}

  defp delivery_continuation(
         _episode,
         %{
           continuation: %{
             "deadline_at" => nil,
             "kind" => "wait",
             "wait_kind" => "event",
             "wait_ref" => ref
           }
         },
         _now
       ),
       do: {nil, %{deadline_at: nil, kind: :event, ref: ref}}

  defp delivery_continuation(
         _episode,
         %{
           continuation: %{
             "deadline_at" => nil,
             "kind" => "wait",
             "wait_kind" => "input",
             "wait_ref" => wait_ref
           }
         },
         _now
       ),
       do: {nil, %{deadline_at: nil, kind: :input, ref: wait_ref}}

  defp delivery_continuation(
         _episode,
         %{
           continuation: %{
             "deadline_at" => deadline_at,
             "kind" => "wait",
             "wait_kind" => "event",
             "wait_ref" => wait_ref
           }
         } = turn,
         now
       ) do
    case DateTime.from_iso8601(deadline_at) do
      {:ok, deadline, 0} ->
        if DateTime.compare(deadline, now) == :gt,
          do: {nil, %{deadline_at: deadline, kind: :event, ref: wait_ref}},
          else: {"turn:after:#{turn.id}", nil}

      _elapsed_or_invalid ->
        {"turn:after:#{turn.id}", nil}
    end
  end

  defp current_lease?(turn, lease_ref, now) do
    turn.lease_ref == lease_ref and match?(%DateTime{}, turn.lease_expires_at) and
      DateTime.compare(turn.lease_expires_at, now) == :gt
  end

  defp exact_episode(%Episode{id: episode_id}, episode_id), do: :ok

  defp exact_episode(%Episode{id: actual}, expected),
    do: {:error, {:work_episode_identity_conflict, actual, expected}}

  defp episode_for_result!(episode_key) do
    Repo.one!(from(episode in Episode, where: episode.key == ^episode_key))
  end

  defp unwrap_or_rollback({:ok, record}, _kind), do: record

  defp unwrap_or_rollback({:error, changeset}, kind) do
    Repo.rollback({:persistence_failed, kind, changeset.errors})
  end

  defp persistence_result({:ok, record}, _kind), do: {:ok, record}

  defp persistence_result({:error, changeset}, kind) do
    {:error, {:persistence_failed, kind, changeset.errors}}
  end

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp later_datetime(nil, requested), do: requested

  defp later_datetime(current, requested) do
    if DateTime.compare(current, requested) == :lt, do: requested, else: current
  end

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_work_custody, field}}
  end

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp repository_context(value, repository_ref) do
    case RepositoryContext.restore(value, repository_ref) do
      {:ok, _context} -> :ok
      {:error, :invalid} -> {:error, {:invalid_work_custody, :repository_context}}
    end
  end

  # Repository-backed work always carries a source; the host supplies `default`
  # when nobody chose. Workspace-free work never carries one.
  defp repository_source(nil, nil), do: {:ok, nil}
  defp repository_source(nil, _repository_ref), do: {:ok, RepositorySource.default()}

  defp repository_source(_value, nil),
    do: {:error, {:invalid_work_custody, :repository_source}}

  defp repository_source(value, _repository_ref) do
    case RepositorySource.parse(value) do
      {:ok, source} -> {:ok, source}
      {:error, _reason} -> {:error, {:invalid_work_custody, :repository_source}}
    end
  end

  defp optional_sha256(nil, _field), do: :ok
  defp optional_sha256(value, field), do: sha256(value, field)

  defp artifact_refs(refs) when is_list(refs) and length(refs) <= 5 do
    if Enum.uniq(refs) == refs and Enum.all?(refs, &valid_reference?/1),
      do: :ok,
      else: {:error, {:invalid_work_custody, :artifact_refs}}
  end

  defp artifact_refs(_refs), do: {:error, {:invalid_work_custody, :artifact_refs}}

  defp valid_reference?(value) when is_binary(value),
    do:
      byte_size(value) in 1..256 and String.valid?(value) and
        :binary.match(value, <<0>>) == :nomatch

  defp valid_reference?(_value), do: false

  defp bounded_text(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_work_custody, field}}
  end

  defp candidate(value) do
    if is_binary(value) and String.valid?(value) and
         byte_size(value) in 1..@maximum_candidate_bytes and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_work_custody, :candidate}}
  end

  defp sha256(value, field) do
    if is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: :ok,
      else: {:error, {:invalid_work_custody, field}}
  end

  defp optional_candidate_identity(nil, nil), do: :ok

  defp optional_candidate_identity(candidate_sha256, candidate_attempt)
       when is_binary(candidate_sha256) and is_integer(candidate_attempt) do
    case sha256(candidate_sha256, :expected_candidate_sha256) do
      :ok -> positive_integer(candidate_attempt, :expected_candidate_attempt)
      {:error, _reason} = error -> error
    end
  end

  defp optional_candidate_identity(_candidate_sha256, _candidate_attempt),
    do: {:error, {:invalid_work_custody, :expected_candidate_identity}}

  defp claim_phase(phase) when phase in [:any, :work, :delivery], do: :ok
  defp claim_phase(_phase), do: {:error, {:invalid_work_custody, :phase}}

  defp callback(value) when is_function(value, 0), do: :ok
  defp callback(_value), do: {:error, {:invalid_work_custody, :callback}}

  defp remote_operation_kind(kind)
       when kind in [
              :create_session,
              :submit_turn,
              :validate_candidate,
              :cancel_turn,
              :close_session
            ],
       do: :ok

  defp remote_operation_kind(_kind),
    do: {:error, {:invalid_work_custody, :remote_operation_kind}}

  defp remote_operation_revision(:submit_turn, revision),
    do: positive_integer(revision, :remote_operation_revision)

  defp remote_operation_revision(_kind, nil), do: :ok

  defp remote_operation_revision(_kind, _revision),
    do: {:error, {:invalid_work_custody, :remote_operation_revision}}

  defp cancellation_revision_phase(phase) when phase in [:cancel_turn, :close_session], do: :ok

  defp cancellation_revision_phase(_phase),
    do: {:error, {:invalid_work_custody, :cancellation_revision_phase}}

  defp cancellation_revision_field(:cancel_turn), do: :cancel_expected_revision
  defp cancellation_revision_field(:close_session), do: :close_expected_revision

  defp clear_remote_operation!(%Turn{remote_operation_kind: nil} = turn, _kind, _key), do: turn

  defp clear_remote_operation!(
         %Turn{remote_operation_kind: kind, remote_operation_key: key} = turn,
         kind,
         key
       ) do
    turn
    |> TurnChangeset.clear_remote_operation()
    |> Repo.update()
    |> unwrap_or_rollback(:work_remote_operation)
  end

  defp clear_remote_operation!(turn, _kind, _key) do
    Repo.rollback(
      {:work_remote_operation_conflict, {turn.remote_operation_kind, turn.remote_operation_key}}
    )
  end

  defp create_operation_key(session),
    do: "responder:work:create:#{session.id}:g#{session.create_generation}"

  defp submit_operation_key(turn),
    do: "responder:work:turn:#{turn.id}:g#{turn.submit_generation}:#{turn.submission_fingerprint}"

  defp cancellation_close_key(turn),
    do: "responder:work:cancel-close:#{turn.id}:g#{turn.cancel_generation}"

  defp destination_pause_reason(pause_ref), do: "destination_paused:#{pause_ref}"

  defp exact_sha256(value, digest) do
    if digest == digest(value),
      do: :ok,
      else: {:error, {:invalid_work_custody, :candidate_sha256}}
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp session_external_ref(episode_id, generation),
    do: "responder-work:#{episode_id}:session:#{generation}"

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_work_custody, field}}
    end
  end

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    DateTime.truncate(now, :microsecond)
  end

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, field), do: {:error, {:invalid_work_custody, field}}

  defp non_negative_integer(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp non_negative_integer(_value, field),
    do: {:error, {:invalid_work_custody, field}}

  defp measurement(value) when is_map(value), do: :ok
  defp measurement(_value), do: {:error, {:invalid_work_custody, :measurement}}

  defp transaction_open do
    if Repo.in_transaction?(),
      do: :ok,
      else: {:error, :work_transaction_required}
  end
end
