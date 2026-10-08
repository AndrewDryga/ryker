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

  Creating the session was only part of the wait: on 2026-09-27 Coop still
  spent most of a 12–18 s routing turn starting the box and the agent. A
  ready session is therefore also prepared: Coop starts its agent ahead of
  any message and keeps it running until `warm_until`. A message takes a
  prepared session first, and one that is not (still waiting for an idle
  worker, or refused by Coop) only when none is, since it still spares the
  create.
  """
  alias Ryker.CoopFleet
  alias Ryker.Ingress
  alias Ryker.Repo
  alias Ryker.Work

  @external_ref_prefix "ryker-admission-ready:"

  # Nothing in Coop or the fleet ends an open session that was never
  # prompted: its placement lease (60 s) is renewed on every worker poll, and
  # Coop keeps an idle session open until someone closes it. What does run
  # out is the agent Coop started for it, after the routing job's warm idle
  # timeout (`Ryker.CoopFleet.JobTemplates`, 35 minutes). A session is handed
  # out for five minutes less than that: the time a message may take from its
  # claim to its turn reaching Coop. Its agent is then still running for the
  # whole time a message can take it, the maximum age stays half an hour, well
  # inside the worker's 24-hour certificate, and a replacement costs one
  # session start and no model tokens.
  @claim_margin_seconds 5 * 60

  @type policy :: %{name: String.t(), digest: String.t()}

  @doc "The Coop task reference of a session kept ready."
  @spec external_ref(Ecto.UUID.t()) :: String.t()
  def external_ref(id), do: @external_ref_prefix <> id

  # How long Coop keeps a prepared routing agent running.
  @spec warm_seconds() :: pos_integer()
  defp warm_seconds, do: div(CoopFleet.JobTemplates.warm_idle_timeout_ms(:admission), 1_000)

  @doc "How long a session kept ready may wait for a message: its agent outlasts it by the claim margin."
  @spec maximum_age_seconds() :: pos_integer()
  def maximum_age_seconds, do: warm_seconds() - @claim_margin_seconds

  @doc """
  Gives this message's routing generation a session kept ready, exactly once.

  `{:ok, session, :claimed}` takes an open one for this routing policy that is
  younger than the maximum age: the oldest prepared one, or the oldest of the
  rest when none is prepared. `{:ok, session, :resumed}` is the one this
  generation claimed on an earlier run. `:none` leaves routing to create its
  own: nothing usable is ready, or this generation already has a session
  routing created.
  """
  @spec claim(Ingress.Inbox.Entry.t(), policy()) ::
          {:ok, Work.Session.t(), :claimed | :resumed} | :none | {:error, term()}
  def claim(%Ingress.Inbox.Entry{} = entry, %{name: policy, digest: digest})
      when is_binary(policy) and is_binary(digest) do
    fn -> claim_locked(entry, policy, digest) end
    |> Repo.transaction()
    |> case do
      {:ok, :none} -> :none
      {:ok, {%Work.Session{} = session, origin}} -> {:ok, session, origin}
      {:error, reason} -> {:error, reason}
    end
  end

  def claim(_entry, _policy), do: {:error, :invalid_ready_routing_session}

  # The message is locked first, as cleanup locks an owner before its
  # session, so a claim never races the generation it is claiming for.
  defp claim_locked(entry, policy, digest) do
    current =
      entry.id
      |> Ingress.Inbox.Entry.Query.by_id()
      |> Ingress.Inbox.Entry.Query.lock_for_update()
      |> Repo.one()

    if is_nil(current) or current.status != :pending or
         current.execution_generation != entry.execution_generation,
       do: Repo.rollback(:admission_attempt_lease_lost)

    generation =
      entry.id
      |> Work.Session.Query.by_admission_input_id_and_generation(entry.execution_generation)
      |> Work.Session.Query.lock_for_update()

    case Repo.fetch(generation) do
      {:ok,
       %Work.Session{ready_state: :claimed, policy: ^policy, policy_digest: ^digest} = session} ->
        {session, :resumed}

      {:ok, %Work.Session{ready_state: :claimed}} ->
        Repo.rollback(:admission_fleet_authority_conflict)

      {:ok, %Work.Session{}} ->
        :none

      {:error, :not_found} ->
        take_ready(entry, policy, digest)
    end
  end

  defp take_ready(entry, policy, digest) do
    case Repo.fetch(ready_query(policy, digest)) do
      {:error, :not_found} ->
        :none

      {:ok, %Work.Session{} = session} ->
        session
        |> Work.Session.Changeset.claim_ready(entry.id, entry.execution_generation, Repo.now!())
        |> Repo.update()
        |> case do
          {:ok, claimed} ->
            Work.Custody.broadcast_session_updated(claimed)
            {claimed, :claimed}

          {:error, _changeset} ->
            Repo.rollback(:admission_fleet_session_conflict)
        end
    end
  end

  # The oldest open session kept ready for this policy and younger than the
  # maximum age, locked so no other claim can take it at the same moment.
  # Prepared ones come first: those whose agent will still be running when a
  # message claiming it now reaches its turn.
  defp ready_query(policy, digest) do
    now = Repo.now!()
    cutoff = DateTime.add(now, -maximum_age_seconds(), :second)
    running_past = DateTime.add(now, @claim_margin_seconds, :second)
    Work.Session.Query.next_ready(policy, digest, cutoff, running_past)
  end

  @doc """
  Reserves one more session to start for this policy, unless `target` are
  already starting or ready.

  The pool is the only writer of these rows and runs one pass at a time, so
  the count and the insert need no lock of their own; were two pools ever to
  run at once, the next pass retires what they started beyond the target.
  """
  @spec reserve(policy(), non_neg_integer()) :: {:ok, Work.Session.t()} | :full
  def reserve(%{name: policy, digest: digest}, target)
      when is_integer(target) and target >= 0 do
    if kept_count(policy, digest) >= target do
      :full
    else
      id = Repo.generate_id()
      now = Repo.now!()

      {:ok,
       %{
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
       }
       |> Work.Session.Changeset.reserve()
       |> Repo.insert!()
       |> tap(&Work.Custody.broadcast_session_updated/1)}
    end
  end

  defp kept_count(policy, digest) do
    cutoff = DateTime.add(Repo.now!(), -maximum_age_seconds(), :second)

    [:starting, :ready]
    |> Work.Session.Query.by_ready_state()
    |> Work.Session.Query.by_policy(policy, digest)
    |> Work.Session.Query.inserted_after(cutoff)
    |> Repo.aggregate(:count)
  end

  @doc "Records the open Coop session a reserved one became; a message may claim it now."
  @spec mark_ready(Work.Session.t(), String.t()) :: {:ok, Work.Session.t()} | {:error, term()}
  def mark_ready(%Work.Session{id: id}, coop_session_id) when is_binary(coop_session_id) do
    transition(id, fn
      %Work.Session{ready_state: :starting, coop_session_id: bound} = session
      when bound in [nil, coop_session_id] ->
        Work.Session.Changeset.mark_ready(session, coop_session_id, Repo.now!())

      _other ->
        Repo.rollback(:ready_routing_session_conflict)
    end)
  end

  @doc """
  The open sessions kept ready for this policy that Coop has not been asked
  to prepare yet, oldest first: the order messages take them in.
  """
  @spec unprepared(policy()) :: [Work.Session.t()]
  def unprepared(%{name: policy, digest: digest}) do
    cutoff = DateTime.add(Repo.now!(), -maximum_age_seconds(), :second)

    :ready
    |> Work.Session.Query.by_ready_state()
    |> Work.Session.Query.unprepared()
    |> Work.Session.Query.by_policy(policy, digest)
    |> Work.Session.Query.inserted_after(cutoff)
    |> Work.Session.Query.ordered_by_oldest()
    |> Repo.all()
  end

  @doc """
  Records that Coop started this ready session's agent when asked at
  `asked_at`: it keeps it running for the routing job's warm idle timeout
  from then at the latest.
  """
  @spec mark_warm(Work.Session.t(), DateTime.t()) :: {:ok, Work.Session.t()} | {:error, term()}
  def mark_warm(%Work.Session{} = session, %DateTime{} = asked_at),
    do: record_warm(session, DateTime.add(asked_at, warm_seconds(), :second))

  @doc """
  Records that Coop could not start this ready session's agent, so it is not
  asked again. The session stays ready: a message takes it only when no
  prepared one is, and it still spares that message the create.
  """
  @spec mark_cold(Work.Session.t()) :: {:ok, Work.Session.t()} | {:error, term()}
  def mark_cold(%Work.Session{} = session), do: record_warm(session, Repo.now!())

  # Only a session still waiting, unclaimed, on the Coop session that was
  # prepared; one a message took in the meantime is that message's now.
  defp record_warm(%Work.Session{id: id, coop_session_id: coop_session_id}, warm_until) do
    transition(id, fn
      %Work.Session{ready_state: :ready, coop_session_id: ^coop_session_id, warm_until: nil} =
          session ->
        Work.Session.Changeset.warm(session, warm_until, Repo.now!())

      _other ->
        Repo.rollback(:ready_routing_session_conflict)
    end)
  end

  @doc """
  Gives up a session no message claimed. A Coop session it became, if any, is
  recorded first so cleanup closes that exact session on its worker.
  """
  @spec retire(Work.Session.t(), String.t() | nil) :: {:ok, Work.Session.t()} | {:error, term()}
  def retire(%Work.Session{id: id}, coop_session_id \\ nil) do
    transition(id, fn
      %Work.Session{ready_state: state, coop_session_id: bound} = session
      when state in [:starting, :ready] and
             (is_nil(coop_session_id) or bound in [nil, coop_session_id]) ->
        Work.Session.Changeset.retire_ready(session, bound || coop_session_id, Repo.now!())

      %Work.Session{ready_state: :retired} ->
        :unchanged

      _other ->
        Repo.rollback(:ready_routing_session_conflict)
    end)
  end

  # `change` answers the session's changeset, or `:unchanged` for a session
  # already where the transition would leave it, which is saved as it is.
  defp transition(id, change) do
    Repo.transaction(fn ->
      session =
        id |> Work.Session.Query.by_id() |> Work.Session.Query.lock_for_update() |> Repo.one()

      case change.(session) do
        :unchanged -> session
        changeset -> changeset |> Repo.update() |> transitioned()
      end
    end)
  end

  defp transitioned({:ok, session}) do
    Work.Custody.broadcast_session_updated(session)
    session
  end

  defp transitioned({:error, _changeset}), do: Repo.rollback(:ready_routing_session_conflict)

  @doc """
  The open sessions kept ready that can no longer serve a message under this
  policy and target: every one pinned to another routing policy, every one
  past the maximum age, and those beyond the target. Within the target the
  prepared ones stay first, then the newest.
  """
  @spec unusable(policy(), non_neg_integer()) :: [Work.Session.t()]
  def unusable(%{name: policy, digest: digest}, target)
      when is_integer(target) and target >= 0 do
    now = Repo.now!()
    cutoff = DateTime.add(now, -maximum_age_seconds(), :second)
    running_past = DateTime.add(now, @claim_margin_seconds, :second)

    {usable, unusable} =
      :ready
      |> Work.Session.Query.by_ready_state()
      |> Work.Session.Query.ordered_by_recent()
      |> Repo.all()
      |> Enum.split_with(fn session ->
        session.policy == policy and session.policy_digest == digest and
          DateTime.compare(session.inserted_at, cutoff) == :gt
      end)

    kept_first =
      Enum.sort_by(usable, fn session ->
        not (is_struct(session.warm_until, DateTime) and
               DateTime.compare(session.warm_until, running_past) == :gt)
      end)

    unusable ++ Enum.drop(kept_first, target)
  end

  @doc "Sessions left `starting` for longer than `seconds`: a pass stopped while creating them."
  @spec stranded(non_neg_integer()) :: [Work.Session.t()]
  def stranded(seconds) when is_integer(seconds) and seconds >= 0 do
    cutoff = DateTime.add(Repo.now!(), -seconds, :second)

    :starting
    |> Work.Session.Query.by_ready_state()
    |> Work.Session.Query.inserted_by(cutoff)
    |> Work.Session.Query.ordered_by_oldest()
    |> Repo.all()
  end

  @doc """
  The most recent starts that failed in a row, newest first: sessions retired
  before Coop ever created them. The pool waits longer after each one.
  """
  @spec failed_starts() :: [Work.Session.t()]
  def failed_starts do
    Work.Session.Query.in_ready_pool()
    |> Work.Session.Query.ordered_by_recent()
    |> Work.Session.Query.limit_to(16)
    |> Repo.all()
    |> Enum.take_while(&(&1.ready_state == :retired and is_nil(&1.coop_session_id)))
  end
end
