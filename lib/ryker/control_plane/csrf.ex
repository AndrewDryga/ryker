defmodule Ryker.ControlPlane.CSRF do
  @moduledoc false

  @spec token(binary(), String.t(), String.t()) :: String.t()
  def token(secret, action, resource_ref)
      when is_binary(secret) and is_binary(action) and is_binary(resource_ref) do
    :crypto.mac(:hmac, :sha256, secret, action <> "\n" <> resource_ref)
    |> Base.url_encode64(padding: false)
  end

  @spec valid?(binary(), String.t(), String.t(), term()) :: boolean()
  def valid?(secret, action, resource_ref, submitted) when is_binary(submitted) do
    expected = token(secret, action, resource_ref)

    byte_size(expected) == byte_size(submitted) and
      Plug.Crypto.secure_compare(expected, submitted)
  end

  def valid?(_secret, _action, _resource_ref, _submitted), do: false
end
