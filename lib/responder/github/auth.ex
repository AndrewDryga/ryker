defmodule Responder.GitHub.Auth do
  @moduledoc """
  GitHub App webhook authentication over the exact raw request body.
  """

  import Plug.Conn, only: [get_req_header: 2]

  alias Responder.GitHub.Binding

  @spec authorize(Plug.Conn.t(), Binding.t(), binary()) :: :ok | {:error, :unauthorized}
  def authorize(conn, %Binding{} = binding, body) when is_binary(body) do
    authorize(conn, binding.secret, body)
  end

  @spec authorize(Plug.Conn.t(), binary(), binary()) :: :ok | {:error, :unauthorized}
  def authorize(conn, secret, body) when is_binary(secret) and is_binary(body) do
    expected = signature(secret, body)

    case get_req_header(conn, "x-hub-signature-256") do
      [submitted] when byte_size(submitted) == byte_size(expected) ->
        if Plug.Crypto.secure_compare(submitted, expected),
          do: :ok,
          else: {:error, :unauthorized}

      _other ->
        {:error, :unauthorized}
    end
  end

  def authorize(_conn, _secret, _body), do: {:error, :unauthorized}

  @doc false
  @spec signature(binary(), binary()) :: String.t()
  def signature(secret, body) when is_binary(secret) and is_binary(body) do
    digest = :crypto.mac(:hmac, :sha256, secret, body)
    "sha256=" <> Base.encode16(digest, case: :lower)
  end
end
