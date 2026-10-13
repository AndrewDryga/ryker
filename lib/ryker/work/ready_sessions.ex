defmodule Ryker.Work.ReadySessions do
  @moduledoc """
  Durable custody for Work sessions started ahead of any conversation.

  A new conversation's first answer waited for Coop to create its Work
  session: 20-55 s of every first answer measured on 2026-10-11 (create
  command 8-20 s, create operation 10-35 s). A session kept ready is created
  with exactly the pin a conversation would freeze for itself
  (`Ryker.Work.Custody.Sessions.pin_episode_in_transaction/4`): the policy and
  its digests, the environment and its Emisar pin, the working copy with the
  repositories mounted beside it, and its source. A conversation takes one
  only on an exact match, so nothing is resolved twice or widened, and one
  never prompted carries no other conversation's knowledge or transcript.
  The repository a conversation is about is not part of its pin: it may be
  any one the session mounts (`Ryker.Work.RepositoryContext`), and the
  session takes it when the conversation claims it.

  Each is a Work session on the shared session table with no episode:
  `starting` while Coop creates it, `ready` once it is open, `claimed` by
  exactly one conversation's episode, or `retired` when it is given up unused.
  A claimed session is that episode's first session from then on, exactly
  like one the episode created. Nothing moves a session back to `ready`.
  Cleanup closes and removes a retired one (`Ryker.Retention.Custody`).

  Only a new conversation (`Ryker.Admission`) takes one. A task binds a
  workspace at create, an incident room and a schedule pin their own
  authority, so none of them is kept ready.
  """
  alias Ryker.Repo
  alias Ryker.Work

  @external_ref_prefix "ryker-work-ready:"

  # A ready session's repository is frozen at the commit its default branch
  # had when the pool started it, and nothing refreshes it once Coop created
  # it. An hour bounds how far behind a first answer can read, and how often
  # a pin nobody uses is started again.
  @maximum_age_seconds 60 * 60

  # The pins worth keeping are the ones conversations used in the last week. A day was too short
  # for an install people use now and then: the first conversation after a quiet day found
  # nothing ready and waited minutes for its first answer (2026-10-13).
  @window_seconds 7 * 24 * 60 * 60

  @pin_fields [
    :policy,
    :policy_digest,
    :authority_digest,
    :environment_ref,
    :repository_ref,
    :repository_context,
    :repository_source,
    :emisar_connection_ref,
    :emisar_account_ref,
    :emisar_rpc_url
  ]

  @typedoc """
  Every field a conversation's first session freezes, as `@pin_fields` lists
  them, with its working copy as `repository_ref`.
  """
  @type pin :: %{required(atom()) => term()}

  @doc "The Coop task reference of a Work session kept ready."
  @spec external_ref(Ecto.UUID.t()) :: String.t()
  def external_ref(id), do: @external_ref_prefix <> id

  @doc """
  The pin a conversation's first session freezes, from the authority
  `pin_episode_in_transaction/4` resolved and the Emisar pin of its
  environment, `emisar`, or nil without one.
  """
  @spec pin(map(), map() | nil) :: pin()
  def pin(authority, emisar) do
    authority
    |> Map.take(@pin_fields -- [:emisar_connection_ref, :emisar_account_ref, :emisar_rpc_url])
    |> Map.merge(%{
      emisar_connection_ref: emisar && emisar.connection_ref,
      emisar_account_ref: emisar && emisar.account_ref,
      emisar_rpc_url: emisar && emisar.rpc_url,
      repository_ref: Work.RepositoryContext.working_copy(authority)
    })
  end

  # The pin a session was started or created with. One kept ready is about
  # its working copy until a conversation claims it.
  defp pin_of(%Work.Session{} = session) do
    session
    |> Map.take(@pin_fields)
    |> Map.put(:repository_ref, Work.RepositoryContext.working_copy(session))
  end

  @doc """
  Whether a conversation's pin may be served by a session kept ready: one
  that reads the default branch, or no repository at all. A pull request, a
  commit or a branch a request names is pinned for that request alone.
  """
  @spec pooled_source?(map() | nil) :: boolean()
  def pooled_source?(nil), do: true
  def pooled_source?(source), do: source == Work.RepositorySource.default()

  @doc """
  Gives `episode_id` the oldest open session kept ready for exactly `pin`,
  younger than the maximum age, inside the caller's transaction, as the
  session of its work about `repository_ref`. The episode is already locked
  by the caller, so a claim never races the episode it is for; a session
  another claim holds is passed over. `:none` leaves the episode to create
  its own.
  """
  @spec claim_in_transaction(Ecto.UUID.t(), pin(), String.t() | nil) ::
          {:ok, Work.Session.t()} | :none
  def claim_in_transaction(episode_id, pin, repository_ref),
    do: claim(episode_id, pin, repository_ref, 1)

  @doc """
  Gives `episode_id` a session kept ready for exactly the pin of `previous`, its
  session that closed, as its next one, inside the caller's transaction. A
  conversation picked up again after its session's grace starts on it instead
  of waiting for Coop to create one: a follow-up on the tenant install waited
  four minutes for Coop to fetch 17 repositories again (2026-10-13). A task's
  workspace and a pinned branch, commit or pull request are never served so.
  """
  @spec claim_successor_in_transaction(Ecto.UUID.t(), Work.Session.t()) ::
          {:ok, Work.Session.t()} | :none
  def claim_successor_in_transaction(episode_id, %Work.Session{} = previous) do
    if is_nil(previous.workspace_task) and pooled_source?(previous.repository_source),
      do: claim(episode_id, pin_of(previous), previous.repository_ref, previous.generation + 1),
      else: :none
  end

  defp claim(episode_id, pin, repository_ref, generation) do
    cutoff = DateTime.add(Repo.now!(), -@maximum_age_seconds, :second)

    case Repo.fetch(Work.Session.Query.next_work_ready(pin, cutoff)) do
      {:error, :not_found} ->
        :none

      {:ok, %Work.Session{} = session} ->
        session
        |> Work.Session.Changeset.claim_work_ready(
          episode_id,
          repository_ref,
          generation,
          Repo.now!()
        )
        |> Repo.update()
        |> case do
          {:ok, claimed} ->
            Work.Custody.broadcast_session_updated(claimed)
            {:ok, claimed}

          {:error, _changeset} ->
            Repo.rollback(:work_ready_session_conflict)
        end
    end
  end

  @doc """
  Reserves a session to start for `pin` unless one is already starting or
  ready for it. The pool is the only writer of these rows and runs one pass
  at a time, so the count and the insert need no lock of their own; were two
  pools ever to run at once, the next pass retires what they started beyond
  one a pin.
  """
  @spec reserve(pin()) :: {:ok, Work.Session.t()} | :kept
  def reserve(pin) do
    if kept?(pin) do
      :kept
    else
      id = Repo.generate_id()
      now = Repo.now!()

      pin
      |> Map.merge(%{
        cleanup_status: :active,
        create_generation: 1,
        execution_kind: :work,
        external_ref: external_ref(id),
        generation: 1,
        id: id,
        inserted_at: now,
        ready_state: :starting,
        updated_at: now
      })
      |> Work.Session.Changeset.reserve_work_ready()
      |> Repo.insert!()
      |> tap(&Work.Custody.broadcast_session_updated/1)
      |> then(&{:ok, &1})
    end
  end

  defp kept?(pin) do
    cutoff = DateTime.add(Repo.now!(), -@maximum_age_seconds, :second)

    [:starting, :ready]
    |> Work.Session.Query.work_ready()
    |> Work.Session.Query.with_pin(pin)
    |> Work.Session.Query.inserted_after(cutoff)
    |> Repo.exists?()
  end

  @doc "Records the open Coop session a reserved one became; a conversation may claim it now."
  @spec mark_ready(Work.Session.t(), String.t()) :: {:ok, Work.Session.t()} | {:error, term()}
  def mark_ready(%Work.Session{id: id}, coop_session_id) when is_binary(coop_session_id) do
    transition(id, fn
      %Work.Session{ready_state: :starting, episode_id: nil, coop_session_id: bound} = session
      when bound in [nil, coop_session_id] ->
        Work.Session.Changeset.mark_ready(session, coop_session_id, Repo.now!())

      _other ->
        Repo.rollback(:work_ready_session_conflict)
    end)
  end

  @doc """
  Gives up a session no conversation claimed. A Coop session it became, if
  any, is recorded first so cleanup closes that exact session on its worker.
  """
  @spec retire(Work.Session.t(), String.t() | nil) :: {:ok, Work.Session.t()} | {:error, term()}
  def retire(%Work.Session{id: id}, coop_session_id \\ nil) do
    transition(id, fn
      %Work.Session{ready_state: state, episode_id: nil, coop_session_id: bound} = session
      when state in [:starting, :ready] and
             (is_nil(coop_session_id) or bound in [nil, coop_session_id]) ->
        Work.Session.Changeset.retire_ready(session, bound || coop_session_id, Repo.now!())

      %Work.Session{ready_state: :retired} ->
        :unchanged

      _other ->
        Repo.rollback(:work_ready_session_conflict)
    end)
  end

  # `change` answers the session's changeset, or `:unchanged` for a session
  # already where the transition would leave it, which is saved as it is.
  defp transition(id, change) do
    Repo.transaction(fn ->
      session =
        id |> Work.Session.Query.by_id() |> Work.Session.Query.lock_for_update() |> Repo.peek()

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

  defp transitioned({:error, _changeset}), do: Repo.rollback(:work_ready_session_conflict)

  @doc """
  The open sessions kept ready that can no longer serve a conversation: every
  one whose pin is not among `pins`, every one past the maximum age, and every
  one beyond the newest for its pin.
  """
  @spec unusable([pin()]) :: [Work.Session.t()]
  def unusable(pins) do
    cutoff = DateTime.add(Repo.now!(), -@maximum_age_seconds, :second)

    {usable, unusable} =
      :ready
      |> Work.Session.Query.work_ready()
      |> Work.Session.Query.ordered_by_recent()
      |> Repo.all()
      |> Enum.split_with(fn session ->
        pin_of(session) in pins and DateTime.compare(session.inserted_at, cutoff) == :gt
      end)

    {_newest, extra} =
      Enum.reduce(usable, {MapSet.new(), []}, fn session, {seen, extra} ->
        pin = pin_of(session)

        if MapSet.member?(seen, pin),
          do: {seen, [session | extra]},
          else: {MapSet.put(seen, pin), extra}
      end)

    unusable ++ Enum.reverse(extra)
  end

  @doc "Sessions left `starting` for longer than `seconds`: a pass stopped while creating them."
  @spec stranded(non_neg_integer()) :: [Work.Session.t()]
  def stranded(seconds) when is_integer(seconds) and seconds >= 0 do
    cutoff = DateTime.add(Repo.now!(), -seconds, :second)

    :starting
    |> Work.Session.Query.work_ready()
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
    [:starting, :ready, :claimed, :retired]
    |> Work.Session.Query.work_ready()
    |> Work.Session.Query.ordered_by_recent()
    |> Work.Session.Query.limit_to(16)
    |> Repo.all()
    |> Enum.take_while(&(&1.ready_state == :retired and is_nil(&1.coop_session_id)))
  end

  @doc """
  The pins new conversations froze since `since`, most used first and the
  most recent of equals first: each first session of an episode a message
  started, with no workspace task and a source a session kept ready may serve.
  """
  @spec recent_pins() :: [pin()]
  def recent_pins, do: recent_pins(DateTime.add(Repo.now!(), -@window_seconds, :second))

  @spec recent_pins(DateTime.t()) :: [pin()]
  def recent_pins(%DateTime{} = since) do
    since
    |> Work.Session.Query.conversation_first_sessions()
    |> Repo.all()
    |> Enum.filter(&pooled_source?(&1.repository_source))
    |> Enum.group_by(&pin_of/1)
    |> Enum.sort_by(fn {_pin, sessions} -> {-length(sessions), -latest(sessions)} end)
    |> Enum.map(fn {pin, _sessions} -> pin end)
  end

  defp latest(sessions) do
    sessions
    |> Enum.map(&DateTime.to_unix(&1.inserted_at, :microsecond))
    |> Enum.max()
  end
end
