defmodule Ryker.Work.Custody.Claims do
  @moduledoc """
  Worker claims and the fenced lease on one turn.

  A worker claims the least recently updated eligible episode under
  `FOR UPDATE SKIP LOCKED`, spends one attempt on its owning turn, and holds an
  opaque lease that it renews while healthy, yields at the end of a polling
  window, or defers after a failed attempt. Leased custody mutations elsewhere
  prove this lease before they write.

  An episode that cannot be claimed (its session cannot be set up, say) is
  logged, its turn when it has one waits a minute with the error on it, and the
  claim goes on to the next episode, so one broken episode never stops all Work.
  """

  import Ryker.Work.Custody.Locks
  require Logger
  alias Ryker.Publication.PublicationQuery
  alias Ryker.Repo
  alias Ryker.UTCDateTime
  alias Ryker.Work.Custody
  alias Ryker.Work.Custody.Sessions
  alias Ryker.Work.{OwningTurnQuery, Turn, TurnChangeset, TurnQuery}

  # How many episodes one claim tries past ones that could not be claimed.
  @claim_candidates 8
  @claim_failure_retry_seconds 60

  @spec claim_next(String.t(), pos_integer()) ::
          {:ok, Custody.claim() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds) do
    claim_next(worker_ref, lease_seconds, :any)
  end

  @spec claim_next(String.t(), pos_integer(), :any | :work | :delivery) ::
          {:ok, Custody.claim() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds, phase) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- positive_integer(lease_seconds, :lease_seconds),
         :ok <- claim_phase(phase) do
      claim_candidate(worker_ref, lease_seconds, phase, [], @claim_candidates)
    end
  end

  defp claim_candidate(_worker_ref, _lease_seconds, _phase, _skipped, 0), do: {:ok, nil}

  defp claim_candidate(worker_ref, lease_seconds, phase, skipped, left) do
    case Repo.transaction(fn -> claim_locked(worker_ref, lease_seconds, phase, skipped) end) do
      {:error, {:work_claim_failed, episode_id, reason}} ->
        claim_failed(episode_id, reason)
        claim_candidate(worker_ref, lease_seconds, phase, [episode_id | skipped], left - 1)

      result ->
        result
    end
  end

  # Nothing of the failed claim was kept, so this says what happened: the log
  # always, and the episode's turn, when it has one, waits a minute with the
  # error on it instead of being tried first again on the next poll.
  defp claim_failed(episode_id, reason) do
    Logger.warning(
      "work episode #{episode_id} could not be claimed: #{inspect(reason, limit: 8)}"
    )

    now = Repo.now!()

    Repo.update_all(TurnQuery.waiting_owner(episode_id),
      set: [
        next_attempt_at: DateTime.add(now, @claim_failure_retry_seconds, :second),
        last_error_code: claim_failure_code(reason),
        last_error_detail: reason |> inspect(limit: 20) |> String.slice(0, 4_000),
        updated_at: now
      ]
    )
  end

  defp claim_failure_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp claim_failure_code(code) when is_atom(code), do: Atom.to_string(code)
  defp claim_failure_code(_reason), do: "work_claim_failed"

  @doc false
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
    end
  end

  @doc false
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
    end
  end

  @doc false
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
    end
  end

  @doc false
  def next_due_at(%DateTime{} = since, phase) when phase in [:work, :delivery] do
    statuses = if phase == :work, do: [:pending, :cancel_pending], else: [:delivery_pending]

    turns = Repo.one(TurnQuery.next_due_after(since, statuses))

    UTCDateTime.earliest(turns ++ reviews_due(since, phase))
  end

  defp reviews_due(since, :work), do: [Repo.one(PublicationQuery.next_review_expiry_after(since))]

  defp reviews_due(_since, :delivery), do: []

  defp claim_locked(worker_ref, lease_seconds, phase, skipped) do
    now = Repo.now!()

    case eligible_episode(now, phase, skipped) do
      nil ->
        nil

      episode ->
        with {:ok, session, turn} <- Sessions.ensure_session_and_turn(episode),
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
          {:error, reason} -> Repo.rollback({:work_claim_failed, episode.id, reason})
        end
    end
  end

  defp eligible_episode(now, phase, skipped),
    do: Repo.one(OwningTurnQuery.next_claimable_episode(now, phase, skipped))

  defp active_publication_review?(session, %Turn{status: status})
       when status in [:pending, :cancel_pending] do
    # Both claimers lock the session. Recheck after that lock as the selection
    # query may have started before the other claimant committed its lease.
    reviewing =
      session.id |> PublicationQuery.by_session_id() |> PublicationQuery.reviewing_at(Repo.now!())

    Repo.exists?(reviewing)
  end

  defp active_publication_review?(_session, _turn), do: false

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

  @doc false
  def renew_locked(episode_id, turn_ref, lease_ref, lease_seconds) do
    case turn_for_lease(episode_id, turn_ref, lease_ref) do
      {:ok, _session, turn} ->
        now = Repo.now!()
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
    now = Repo.now!()

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

  defp yield_progress_locked(episode_id, turn_ref, lease_ref, retry_seconds) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)
    now = Repo.now!()

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

  defp later_datetime(nil, requested), do: requested

  defp later_datetime(current, requested) do
    if DateTime.compare(current, requested) == :lt, do: requested, else: current
  end

  defp claim_phase(phase) when phase in [:any, :work, :delivery], do: :ok
  defp claim_phase(_phase), do: {:error, {:invalid_work_custody, :phase}}
end
