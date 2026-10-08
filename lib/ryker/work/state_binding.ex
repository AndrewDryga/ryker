defmodule Ryker.Work.StateBinding do
  @moduledoc false
  alias Ryker.CoopFleet
  alias Ryker.Crypto
  alias Ryker.{Repo, Secret}
  alias Ryker.Work.{Session, Turn}

  @context "ryker-state-binding:v1:"
  @maximum_endpoint_bytes 2_048
  @maximum_scope_bytes 2_048

  @type t :: %{
          endpoint: String.t(),
          token: String.t(),
          token_sha256: String.t()
        }

  @spec derive(Session.t(), Turn.t(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, term()}
  # The state-tools root arrives sealed (`Ryker.Secret`) and is opened only to
  # derive this turn's token.
  def derive(%Session{id: session_id}, %Turn{id: turn_id}, scope, endpoint, %Secret{value: secret})
      when is_binary(session_id) and is_binary(turn_id) and is_binary(endpoint) and
             is_binary(scope) and is_binary(secret) do
    with :ok <- endpoint(endpoint),
         :ok <- scope(scope),
         :ok <- secret(secret) do
      scope_sha256 = Crypto.sha256_hex(scope)

      token =
        (@context <> session_id <> ":" <> turn_id <> ":" <> scope_sha256)
        |> then(&Crypto.hmac_sha256(secret, &1))
        |> Base.url_encode64(padding: false)
        |> then(&(scope_sha256 <> &1))

      {:ok,
       %{
         endpoint: endpoint,
         token: token,
         token_sha256: Crypto.sha256_hex(token)
       }}
    end
  end

  def derive(_session, _turn, _scope, _endpoint, _secret),
    do: {:error, {:invalid_work_state_tools_binding, :fields}}

  @spec current_scope(Session.t()) :: {:ok, String.t()} | {:error, term()}
  def current_scope(%Session{id: session_id}) when is_binary(session_id) do
    placement =
      session_id
      |> CoopFleet.Placement.Query.by_session_id()
      |> CoopFleet.Placement.Query.current()
      |> CoopFleet.Placement.Query.limit_to(1)
      |> Repo.fetch()

    case placement do
      {:ok, %CoopFleet.Placement{state: :active} = current} ->
        if DateTime.compare(current.lease_expires_at, Repo.now!()) == :gt,
          do: {:ok, placement_scope(current)},
          else: {:error, {:work_state_tools_placement_not_current, session_id}}

      {:ok, %CoopFleet.Placement{}} ->
        {:error, {:work_state_tools_placement_not_current, session_id}}

      {:error, :not_found} ->
        if Repo.exists?(CoopFleet.Placement.Query.by_session_id(session_id)) do
          {:error, {:work_state_tools_placement_not_current, session_id}}
        else
          {:ok, local_scope(session_id)}
        end
    end
  end

  def current_scope(%Session{}),
    do: {:error, {:invalid_work_state_tools_binding, :session}}

  # Tests derive the local scope name to address a session's state tools.
  @doc false
  @spec local_scope(Session.t() | String.t()) :: String.t()
  def local_scope(%Session{id: session_id}), do: local_scope(session_id)
  def local_scope(session_id) when is_binary(session_id), do: "local:" <> session_id

  @spec placement_scope(CoopFleet.Placement.t()) :: String.t()
  def placement_scope(%CoopFleet.Placement{} = placement) do
    Enum.join(
      [
        "placement",
        placement.id,
        Integer.to_string(placement.generation),
        placement.lease_ref,
        placement.worker_id
      ],
      ":"
    )
  end

  @spec scope_matches?(String.t(), String.t()) :: boolean()
  def scope_matches?(<<scope_sha256::binary-size(64), _mac::binary-size(43)>>, scope)
      when is_binary(scope),
      do: scope_sha256 == Crypto.sha256_hex(scope)

  def scope_matches?(_token, _scope), do: false

  @spec document(t()) :: map()
  def document(%{endpoint: endpoint, token: token}) do
    %{"endpoint" => endpoint, "token" => token}
  end

  @spec binding_digest(Turn.t()) :: String.t() | nil
  def binding_digest(%Turn{
        state_tools_endpoint: endpoint,
        state_tools_token_sha256: token_sha256
      })
      when is_binary(endpoint) and is_binary(token_sha256) do
    Crypto.sha256_hex(endpoint <> <<0>> <> token_sha256)
  end

  def binding_digest(%Turn{}), do: nil

  defp endpoint(value)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @maximum_endpoint_bytes do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        path: "/v1/state-tools/mcp",
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when is_binary(host) and host != "" ->
        :ok

      _invalid ->
        {:error, {:invalid_work_state_tools_binding, :endpoint}}
    end
  end

  defp endpoint(_value), do: {:error, {:invalid_work_state_tools_binding, :endpoint}}

  defp scope(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @maximum_scope_bytes do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch,
      do: :ok,
      else: {:error, {:invalid_work_state_tools_binding, :scope}}
  end

  defp scope(_value), do: {:error, {:invalid_work_state_tools_binding, :scope}}

  defp secret(value)
       when is_binary(value) and byte_size(value) >= 16 and byte_size(value) <= 4_096 do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch,
      do: :ok,
      else: {:error, {:invalid_work_state_tools_binding, :secret}}
  end

  defp secret(_value), do: {:error, {:invalid_work_state_tools_binding, :secret}}
end
