defmodule Ryker.Work.Custody.Sessions do
  @moduledoc """
  Episode pinning and the Coop session generations under an episode.

  Pinning freezes the trusted policy and repository authority before any worker
  can claim the episode. A session binds to exactly one remote Coop session;
  when that remote session is exhausted, lost, or cleaned up, the next
  generation copies the pinned authority verbatim rather than resolving it again.
  """

  import Ecto.Query
  import Ryker.Work.Custody.Locks

  alias Ryker.Emisar.Connections, as: EmisarConnections
  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.Work.Custody.Turns

  alias Ryker.Work.{
    RepositoryContext,
    RepositorySource,
    Session,
    SessionChangeset,
    Turn,
    TurnChangeset
  }

  @doc false
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
        ) :: {:ok, Session.t()} | {:error, term()}
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
    end
  end

  @doc false
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
    end
  end

  @doc false
  @spec release_session_create(Ecto.UUID.t(), String.t(), String.t(), String.t()) ::
          {:ok, Turn.t()} | {:error, term()}
  def release_session_create(episode_id, turn_ref, lease_ref, operation_key) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- reference(operation_key, :operation_key) do
      Repo.transaction(fn ->
        {_session, turn} = leased!(episode_id, turn_ref, lease_ref)
        Turns.clear_remote_operation!(turn, "create_session", operation_key)
      end)
    end
  end

  @doc false
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
        pin_session_locked(episode, %{
          authority_digest: authority_digest,
          policy: policy,
          policy_digest: policy_digest,
          repository_context: repository_context,
          repository_ref: repository_ref,
          repository_source: repository_source
        })
    end
  end

  defp pin_session_locked(episode, authority) do
    case latest_session(episode.id) do
      nil ->
        session_id = Ecto.UUID.generate()
        emisar = emisar_pin(authority.repository_ref, authority.repository_context)

        session_id
        |> SessionChangeset.insert_with_authority(
          episode.id,
          1,
          authority.policy,
          authority.policy_digest,
          authority.repository_ref,
          session_external_ref(episode.id, 1),
          %{
            authority_digest: authority.authority_digest,
            repository_context: authority.repository_context,
            repository_source: authority.repository_source,
            emisar: emisar,
            workspace_task: nil
          }
        )
        |> Repo.insert()
        |> unwrap_or_rollback(:work_session)

      %Session{cleanup_status: :active} = session ->
        session

      %Session{
        cleanup_status: :grace,
        cleanup_lease_ref: nil,
        closed_at: nil,
        discard_after: %DateTime{}
      } = session ->
        reuse_or_replace_grace(episode, session)

      %Session{} = session ->
        insert_session_or_rollback(
          episode.id,
          session.generation + 1,
          session_authority(session)
        )
    end
  end

  defp reuse_or_replace_grace(episode, session) do
    if reusable_grace?(session),
      do: reactivate_grace!(session),
      else:
        insert_session_or_rollback(
          episode.id,
          session.generation + 1,
          session_authority(session)
        )
  end

  @doc false
  def current_session(episode) do
    case latest_session(episode.id) do
      nil ->
        {:error, :work_policy_not_pinned}

      %Session{cleanup_status: :active} = session ->
        {:ok, session}

      %Session{
        cleanup_status: :grace,
        cleanup_lease_ref: nil,
        closed_at: nil,
        discard_after: %DateTime{}
      } = session ->
        if reusable_grace?(session),
          do: {:ok, reactivate_grace!(session)},
          else: insert_session(episode.id, session.generation + 1, session_authority(session))

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

  defp reusable_grace?(%Session{
         cleanup_status: :grace,
         cleanup_lease_ref: nil,
         closed_at: nil,
         discard_after: %DateTime{} = discard_after
       }) do
    DateTime.compare(discard_after, Repo.now!()) == :gt
  end

  defp reusable_grace?(_session), do: false

  defp reactivate_grace!(session) do
    session
    |> Ecto.Changeset.change(%{
      cleanup_attempt_count: 0,
      cleanup_last_error_code: nil,
      cleanup_last_error_detail: nil,
      cleanup_next_attempt_at: nil,
      cleanup_status: :active,
      discard_after: nil
    })
    |> Repo.update!()
  end

  @doc false
  def ensure_session_and_turn(%Episode{owner_kind: :turn} = episode) do
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

  def ensure_session_and_turn(%Episode{owner_kind: :delivery} = episode) do
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

  @doc false
  def insert_turn(episode, session) do
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
  @doc false
  def session_authority(%Session{} = session) do
    %{
      authority_digest: session.authority_digest,
      policy: session.policy,
      policy_digest: session.policy_digest,
      repository_context: session.repository_context,
      repository_ref: session.repository_ref,
      repository_source: session.repository_source,
      emisar: %{
        connection_ref: session.emisar_connection_ref,
        account_ref: session.emisar_account_ref,
        rpc_url: session.emisar_rpc_url
      },
      workspace_task: session.workspace_task
    }
  end

  @doc false
  def insert_session(episode_id, generation, authority) do
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
        emisar: present_emisar(authority.emisar),
        workspace_task: authority.workspace_task
      }
    )
    |> Repo.insert()
    |> persistence_result(:work_session)
  end

  defp emisar_pin(repository_ref, repository_context) do
    with {:ok, settings} <- Ryker.Settings.fetch(),
         {:ok, pin} <- EmisarConnections.resolve(settings, repository_ref, repository_context) do
      pin
    else
      _unconfigured -> nil
    end
  end

  defp present_emisar(%{connection_ref: ref, account_ref: account, rpc_url: url})
       when is_binary(ref) and is_binary(account) and is_binary(url),
       do: %{connection_ref: ref, account_ref: account, rpc_url: url}

  defp present_emisar(_pin), do: nil

  defp insert_session_or_rollback(episode_id, generation, authority) do
    case insert_session(episode_id, generation, authority) do
      {:ok, session} -> session
      {:error, reason} -> Repo.rollback(reason)
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

    _turn =
      Turns.clear_remote_operation!(turn, "create_session", create_operation_key(session))

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
        _turn =
          Turns.clear_remote_operation!(turn, "create_session", create_operation_key(session))

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

  @doc false
  def create_operation_key(session),
    do: "ryker:work:create:#{session.id}:g#{session.create_generation}"

  defp session_external_ref(episode_id, generation),
    do: "ryker-work:#{episode_id}:session:#{generation}"

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
end
