defmodule Ryker.StateTools.Binding do
  @moduledoc false

  import Ecto.Query

  alias Ryker.CoopFleet.Placement
  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.State.Records
  alias Ryker.Work.{Session, StateBinding, Turn}

  @spec authorize(binary()) :: :ok | {:error, :state_tools_binding_not_authorized}
  def authorize(token) do
    case resolve(token) do
      {:ok, _binding} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec resolve(binary()) ::
          {:ok,
           %{
             episode: Episode.t(),
             session: Session.t(),
             state_token: String.t(),
             turn: Turn.t()
           }}
          | {:error, :state_tools_binding_not_authorized}
  def resolve(token) when is_binary(token) and byte_size(token) in 32..256 do
    token_sha256 = StateBinding.sha256(token)

    binding =
      token_sha256
      |> binding_query()
      |> active_session()
      |> active_episode()
      |> active_turn()
      |> select([session, episode, turn, _placement], {session, episode, turn})
      |> Repo.one()

    case binding do
      {%Session{} = session, %Episode{} = episode, %Turn{} = turn} ->
        with {:ok, scope} <- StateBinding.current_scope(session),
             true <- StateBinding.scope_matches?(token, scope) do
          {:ok,
           %{
             episode: episode,
             session: session,
             state_token: Records.token(turn),
             turn: turn
           }}
        else
          _invalid -> {:error, :state_tools_binding_not_authorized}
        end

      nil ->
        {:error, :state_tools_binding_not_authorized}
    end
  end

  def resolve(_token), do: {:error, :state_tools_binding_not_authorized}

  @doc "Recheck an already resolved caller under the session lock before local disclosure."
  def lock_current(binding) do
    # Routine Work bookkeeping briefly owns this row while the model is using
    # MCP. Wait within the existing recall lock budget, then recheck authority.
    Repo.query!("SET LOCAL lock_timeout = '1000ms'")

    session =
      Repo.one(
        from(s in Session,
          where: s.id == ^binding.session.id and s.episode_id == ^binding.episode.id,
          lock: "FOR UPDATE"
        )
      )

    with %Session{cleanup_status: :active} <- session,
         true <-
           same_fields?(session, binding.session, [
             :episode_id,
             :generation,
             :repository_ref,
             :coop_session_id,
             :authority_digest,
             :policy_digest
           ]),
         true <- is_binary(binding.turn.lease_ref),
         {episode, turn} <-
           Repo.one(
             from(e in Episode,
               join: t in Turn,
               on: t.episode_id == e.id,
               where:
                 e.id == ^binding.episode.id and t.id == ^binding.turn.id and
                   t.session_id == ^session.id,
               where: e.state == :working and e.owner_kind == :turn and e.owner_ref == t.turn_ref,
               where:
                 t.status == :pending and t.lease_ref == ^binding.turn.lease_ref and
                   t.lease_expires_at > fragment("clock_timestamp()"),
               select: {e, t}
             )
           ),
         true <-
           same_fields?(episode, binding.episode, [
             :destination_transport,
             :destination_conversation_ref,
             :destination_thread_ref,
             :execution_mode
           ]) do
      {:ok, Map.merge(binding, %{episode: episode, session: session, turn: turn})}
    else
      _ -> {:error, :state_tools_binding_not_authorized}
    end
  end

  defp same_fields?(left, right, fields), do: Map.take(left, fields) == Map.take(right, fields)

  defp binding_query(token_sha256) do
    from(session in Session,
      join: episode in Episode,
      on: episode.id == session.episode_id,
      join: turn in Turn,
      on: turn.session_id == session.id and turn.episode_id == episode.id,
      left_join: placement in Placement,
      on: placement.session_id == session.id,
      where: turn.state_tools_token_sha256 == ^token_sha256
    )
  end

  defp active_session(query),
    do:
      from([session, _episode, _turn, placement] in query,
        where:
          session.cleanup_status == :active and
            (is_nil(placement.id) or
               (placement.state == :active and
                  placement.lease_expires_at > fragment("clock_timestamp()")))
      )

  defp active_episode(query) do
    from([_session, episode, turn, _placement] in query,
      where:
        episode.state == :working and episode.owner_kind == :turn and
          turn.turn_ref == episode.owner_ref
    )
  end

  defp active_turn(query) do
    from([_session, _episode, turn, _placement] in query,
      where:
        turn.status == :pending and not is_nil(turn.lease_ref) and
          turn.lease_expires_at > fragment("clock_timestamp()")
    )
  end
end
