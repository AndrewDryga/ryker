defmodule Ryker.StateTools.Binding do
  @moduledoc false
  alias Ryker.Crypto
  alias Ryker.Episodes
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Work

  @spec resolve(binary()) ::
          {:ok,
           %{
             episode: Episodes.Episode.t(),
             session: Work.Session.t(),
             state_token: String.t(),
             turn: Work.Turn.t()
           }}
          | {:error, :state_tools_binding_not_authorized}
  def resolve(token) when is_binary(token) and byte_size(token) in 32..256 do
    token_sha256 = Crypto.sha256_hex(token)

    binding = token_sha256 |> Work.Session.Query.state_tools_binding() |> Repo.one()

    with {%Work.Session{} = session, %Episodes.Episode{} = episode, %Work.Turn{} = turn} <-
           binding,
         {:ok, scope} <- Work.StateBinding.current_scope(session),
         true <- Work.StateBinding.scope_matches?(token, scope) do
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
  end

  def resolve(_token), do: {:error, :state_tools_binding_not_authorized}

  @doc "Recheck an already resolved caller under the session lock before local disclosure."
  def lock_current(binding) do
    # Routine Work bookkeeping briefly owns this row while the model is using
    # MCP. Wait within the existing recall lock budget, then recheck authority.
    Repo.lock_timeout!(1_000)

    session =
      binding.session.id
      |> Work.Session.Query.by_id()
      |> Work.Session.Query.by_episode_id(binding.episode.id)
      |> Work.Session.Query.lock_for_update()
      |> Repo.one()

    with %Work.Session{cleanup_status: :active} <- session,
         true <-
           same_fields?(session, binding.session, [
             :episode_id,
             :generation,
             :repository_ref,
             :coop_session_id,
             :authority_digest,
             :policy_digest,
             :emisar_connection_ref,
             :emisar_account_ref,
             :emisar_rpc_url
           ]),
         true <- is_binary(binding.turn.lease_ref),
         {:ok, {episode, turn}} <- Repo.fetch(working_on_turn(binding, session)),
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

  defp working_on_turn(binding, session) do
    Episodes.Episode.Query.working_on_turn(
      binding.episode.id,
      binding.turn.id,
      session.id,
      binding.turn.lease_ref
    )
  end

  defp same_fields?(left, right, fields), do: Map.take(left, fields) == Map.take(right, fields)
end
