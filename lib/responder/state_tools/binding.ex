defmodule Responder.StateTools.Binding do
  @moduledoc false

  import Ecto.Query

  alias Responder.CoopFleet.Placement
  alias Responder.Episodes.Episode
  alias Responder.Repo
  alias Responder.State.Records
  alias Responder.Work.{Session, StateBinding, Turn}

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
