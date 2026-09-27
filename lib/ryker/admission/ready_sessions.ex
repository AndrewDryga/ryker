defmodule Ryker.Admission.ReadySessions do
  @moduledoc """
  Durable custody for routing sessions started ahead of time.

  Routing creates a Coop session for every message, and creating one is the
  longest wait before the model starts: 5.6 s of the 28.6 s a plain "hi"
  took on the live install on 2026-09-26. A session kept ready is started
  with the installation's routing policy before any message needs it and is
  never prompted until one does, so it spends no model tokens while it waits.
  Every channel and conversation shares the same few.

  Each is a routing session on the shared session table with no message:
  `starting` while Coop creates it, `ready` once it is open, `claimed` by
  exactly one message's routing generation, or `retired` when it is given up
  unused. A claimed session belongs to that generation from then on, exactly
  like one routing created for itself: routing closes it after its one turn,
  and cleanup closes it if the generation ends without doing so. Nothing moves
  a session back to `ready`, so no session ever carries two messages. Cleanup
  closes and removes a retired one (`Ryker.Retention.Custody`).
  """

  import Ecto.Query

  alias Ryker.Admission.FleetSession
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Work.{Custody, Session}

  @external_ref_prefix "ryker-admission-ready:"

  # Nothing in Coop or the fleet ends an open session that was never
  # prompted: its placement lease (60 s) is renewed on every worker poll, and
  # Coop keeps an idle session open until someone closes it. The nearest
  # clocks are Coop's warm-runtime idle limit (`warm_idle_timeout`, at most an
  # hour, and unset for routing) and the worker's 24-hour certificate. Half an
  # hour stays well inside both; a replacement costs one session start and no
  # model tokens.
  @maximum_age_seconds 30 * 60

  @type policy :: %{name: String.t(), digest: String.t()}

  @doc "The Coop task reference of a session kept ready."
  @spec external_ref(Ecto.UUID.t()) :: String.t()
  def external_ref(id), do: @external_ref_prefix <> id

  @spec maximum_age_seconds() :: pos_integer()
  def maximum_age_seconds, do: @maximum_age_seconds

  @doc """
  Gives this message's routing generation a session kept ready, exactly once.

  `{:ok, session, :claimed}` takes the oldest open one for this routing policy
  that is younger than the maximum age. `{:ok, session, :resumed}` is the one
  this generation claimed on an earlier run. `:none` leaves routing to create
  its own: nothing usable is ready, or this generation already has a session
  routing created.
  """
  @spec claim(Entry.t(), policy()) ::
          {:ok, Session.t(), :claimed | :resumed} | :none | {:error, term()}
  def claim(%Entry{} = entry, %{name: policy, digest: digest})
      when is_binary(policy) and is_binary(digest) do
    fn -> claim_locked(entry, policy, digest) end
    |> Repo.transaction()
    |> case do
      {:ok, :none} -> :none
      {:ok, {%Session{} = session, origin}} -> {:ok, session, origin}
      {:error, _reason} = error -> error
    end
  end

  def claim(_entry, _policy), do: {:error, :invalid_ready_routing_session}

  # The message is locked first, as cleanup locks an owner before its
  # session, so a claim never races the generation it is claiming for.
  defp claim_locked(entry, policy, digest) do
    current = Repo.one(from(input in Entry, where: input.id == ^entry.id, lock: "FOR UPDATE"))

    if is_nil(current) or current.status != :pending or
         current.execution_generation != entry.execution_generation,
       do: Repo.rollback(:admission_attempt_lease_lost)

    case Repo.one(from(session in FleetSession.generation_query(entry), lock: "FOR UPDATE")) do
      %Session{ready_state: :claimed, policy: ^policy, policy_digest: ^digest} = session ->
        {session, :resumed}

      %Session{ready_state: :claimed} ->
        Repo.rollback(:admission_fleet_authority_conflict)

      %Session{} ->
        :none

      nil ->
        take_ready(entry, policy, digest)
    end
  end

  defp take_ready(entry, policy, digest) do
    case Repo.one(ready_query(policy, digest)) do
      nil ->
        :none

      %Session{} = session ->
        session
        |> Ecto.Changeset.change(%{
          admission_input_id: entry.id,
          generation: entry.execution_generation,
          ready_state: :claimed,
          updated_at: Repo.now!()
        })
        |> Ecto.Changeset.unique_constraint([:admission_input_id, :generation],
          name: :episode_work_sessions_admission_generation_index
        )
        |> Repo.update()
        |> case do
          {:ok, claimed} ->
            Custody.broadcast_session_updated(claimed)
            {claimed, :claimed}

          {:error, _changeset} ->
            Repo.rollback(:admission_fleet_session_conflict)
        end
    end
  end

  # The oldest open session kept ready for this policy and younger than the
  # maximum age, locked so no other claim can take it at the same moment.
  defp ready_query(policy, digest) do
    cutoff = DateTime.add(Repo.now!(), -@maximum_age_seconds, :second)

    from(session in Session,
      where: session.execution_kind == :admission and session.ready_state == :ready,
      where: is_nil(session.admission_input_id) and session.cleanup_status == :active,
      where: session.policy == ^policy and session.policy_digest == ^digest,
      where: session.inserted_at > ^cutoff,
      order_by: [asc: session.inserted_at, asc: session.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  @doc """
  Reserves one more session to start for this policy, unless `target` are
  already starting or ready.

  The pool is the only writer of these rows and runs one pass at a time, so
  the count and the insert need no lock of their own; were two pools ever to
  run at once, the next pass retires what they started beyond the target.
  """
  @spec reserve(policy(), non_neg_integer()) :: {:ok, Session.t()} | :full
  def reserve(%{name: policy, digest: digest}, target)
      when is_integer(target) and target >= 0 do
    if kept_count(policy, digest) >= target do
      :full
    else
      id = Ecto.UUID.generate()
      now = Repo.now!()

      {:ok,
       %Session{}
       |> Ecto.Changeset.change(%{
         cleanup_status: :active,
         create_generation: 1,
         execution_kind: :admission,
         external_ref: external_ref(id),
         generation: 1,
         id: id,
         inserted_at: now,
         policy: policy,
         policy_digest: digest,
         ready_state: :starting,
         updated_at: now
       })
       |> Ecto.Changeset.check_constraint(:ready_state,
         name: :episode_work_session_ready_state_valid
       )
       |> Repo.insert!()
       |> tap(&Custody.broadcast_session_updated/1)}
    end
  end

  defp kept_count(policy, digest) do
    cutoff = DateTime.add(Repo.now!(), -@maximum_age_seconds, :second)

    Repo.aggregate(
      from(session in Session,
        where:
          session.ready_state in [:starting, :ready] and session.policy == ^policy and
            session.policy_digest == ^digest and session.inserted_at > ^cutoff
      ),
      :count
    )
  end

  @doc "Records the open Coop session a reserved one became; a message may claim it now."
  @spec mark_ready(Session.t(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def mark_ready(%Session{id: id}, coop_session_id) when is_binary(coop_session_id) do
    transition(id, fn
      %Session{ready_state: :starting, coop_session_id: bound} = session
      when bound in [nil, coop_session_id] ->
        Ecto.Changeset.change(session, %{
          coop_session_id: coop_session_id,
          ready_state: :ready,
          updated_at: Repo.now!()
        })

      _other ->
        Repo.rollback(:ready_routing_session_conflict)
    end)
  end

  @doc """
  Gives up a session no message claimed. A Coop session it became, if any, is
  recorded first so cleanup closes that exact session on its worker.
  """
  @spec retire(Session.t(), String.t() | nil) :: {:ok, Session.t()} | {:error, term()}
  def retire(%Session{id: id}, coop_session_id \\ nil) do
    transition(id, fn
      %Session{ready_state: state, coop_session_id: bound} = session
      when state in [:starting, :ready] and
             (is_nil(coop_session_id) or bound in [nil, coop_session_id]) ->
        Ecto.Changeset.change(session, %{
          coop_session_id: bound || coop_session_id,
          ready_state: :retired,
          updated_at: Repo.now!()
        })

      %Session{ready_state: :retired} = session ->
        Ecto.Changeset.change(session)

      _other ->
        Repo.rollback(:ready_routing_session_conflict)
    end)
  end

  defp transition(id, change) do
    Repo.transaction(fn ->
      Repo.one(from(session in Session, where: session.id == ^id, lock: "FOR UPDATE"))
      |> change.()
      |> Ecto.Changeset.unique_constraint(:coop_session_id,
        name: :episode_work_sessions_coop_session_id_index
      )
      |> Ecto.Changeset.check_constraint(:ready_state,
        name: :episode_work_session_ready_state_valid
      )
      |> Repo.update()
      |> case do
        {:ok, session} ->
          Custody.broadcast_session_updated(session)
          session

        {:error, _changeset} ->
          Repo.rollback(:ready_routing_session_conflict)
      end
    end)
  end

  @doc """
  The open sessions kept ready that can no longer serve a message under this
  policy and target: every one pinned to another routing policy, every one
  past the maximum age, and the oldest of those beyond the target.
  """
  @spec unusable(policy(), non_neg_integer()) :: [Session.t()]
  def unusable(%{name: policy, digest: digest}, target)
      when is_integer(target) and target >= 0 do
    cutoff = DateTime.add(Repo.now!(), -@maximum_age_seconds, :second)

    {usable, unusable} =
      from(session in Session,
        where: session.ready_state == :ready,
        order_by: [desc: session.inserted_at, desc: session.id]
      )
      |> Repo.all()
      |> Enum.split_with(fn session ->
        session.policy == policy and session.policy_digest == digest and
          DateTime.compare(session.inserted_at, cutoff) == :gt
      end)

    unusable ++ Enum.drop(usable, target)
  end

  @doc "Sessions left `starting` for longer than `seconds`: a pass stopped while creating them."
  @spec stranded(non_neg_integer()) :: [Session.t()]
  def stranded(seconds) when is_integer(seconds) and seconds >= 0 do
    cutoff = DateTime.add(Repo.now!(), -seconds, :second)

    Repo.all(
      from(session in Session,
        where: session.ready_state == :starting and session.inserted_at <= ^cutoff,
        order_by: [asc: session.inserted_at, asc: session.id]
      )
    )
  end

  @doc """
  The most recent starts that failed in a row, newest first: sessions retired
  before Coop ever created them. The pool waits longer after each one.
  """
  @spec failed_starts() :: [Session.t()]
  def failed_starts do
    from(session in Session,
      where: not is_nil(session.ready_state),
      order_by: [desc: session.inserted_at, desc: session.id],
      limit: 16
    )
    |> Repo.all()
    |> Enum.take_while(&(&1.ready_state == :retired and is_nil(&1.coop_session_id)))
  end
end
