defmodule Ryker.Work.Custody.Claims do
  @moduledoc """
  Worker claims and the fenced lease on one turn.

  A worker claims the least recently updated eligible episode under
  `FOR UPDATE SKIP LOCKED`, spends one attempt on its owning turn, and holds an
  opaque lease that it renews while healthy, yields at the end of a polling
  window, or defers after a failed attempt. Leased custody mutations elsewhere
  prove this lease before they write.
  """

  import Ecto.Query
  import Ryker.Work.Custody.Locks

  alias Ryker.Episodes.Episode
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.Work.Custody
  alias Ryker.Work.Custody.Sessions
  alias Ryker.Work.{Session, Turn, TurnChangeset}

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
      Repo.transaction(fn -> claim_locked(worker_ref, lease_seconds, phase) end)
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
    end
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
    end
  end

  defp claim_locked(worker_ref, lease_seconds, phase) do
    now = Repo.now!()

    case eligible_episode(now, phase) do
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
    now = Repo.now!()

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
