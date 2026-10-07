defmodule Ryker.ControlPlane.CSRF do
  @moduledoc """
  The token a console form carries: the action it confirms, and an HMAC over
  that action and the resource it is for. The action travels with the token,
  so a confirmation of an earlier revision can be told from a forged one.
  """
  alias Ryker.Crypto

  @spec token(binary(), String.t(), String.t()) :: String.t()
  def token(secret, action, resource_ref)
      when is_binary(secret) and is_binary(action) and is_binary(resource_ref) do
    Base.url_encode64(action, padding: false) <> "." <> mac(secret, action, resource_ref)
  end

  @spec valid?(binary(), String.t(), String.t(), term()) :: boolean()
  def valid?(secret, action, resource_ref, submitted),
    do: signed_action(secret, resource_ref, submitted) == {:ok, action}

  @doc "The action a token for `resource_ref` was minted for, when Ryker minted it."
  @spec signed_action(binary(), String.t(), term()) :: {:ok, String.t()} | :error
  def signed_action(secret, resource_ref, submitted) when is_binary(submitted) do
    with [encoded, signature] <- String.split(submitted, ".", parts: 2),
         {:ok, action} <- Base.url_decode64(encoded, padding: false),
         expected = mac(secret, action, resource_ref),
         true <-
           byte_size(expected) == byte_size(signature) and
             Plug.Crypto.secure_compare(expected, signature) do
      {:ok, action}
    else
      _invalid -> :error
    end
  end

  def signed_action(_secret, _resource_ref, _submitted), do: :error

  defp mac(secret, action, resource_ref) do
    Crypto.hmac_sha256(secret, action <> "\n" <> resource_ref)
    |> Base.url_encode64(padding: false)
  end
end
