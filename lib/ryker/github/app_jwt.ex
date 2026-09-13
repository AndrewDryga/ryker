defmodule Ryker.GitHub.AppJWT do
  @moduledoc """
  Mints the short-lived RS256 bearer JWT used to authenticate as a GitHub App.

  The decoded private key stays in host runtime memory. It is never written to
  ingress, delivery, publication, or Work custody.
  """

  @derive {Inspect, only: [:app_id]}
  @enforce_keys [:app_id, :private_key]
  defstruct [:app_id, :private_key]

  @type t :: %__MODULE__{app_id: String.t(), private_key: tuple()}

  @spec new(pos_integer() | String.t(), binary()) :: {:ok, t()} | {:error, term()}
  def new(app_id, pem) do
    with {:ok, app_id} <- normalize_app_id(app_id),
         {:ok, private_key} <- decode_private_key(pem) do
      {:ok, %__MODULE__{app_id: app_id, private_key: private_key}}
    end
  end

  @spec token(t(), DateTime.t()) :: {:ok, String.t()} | {:error, term()}
  def token(signer, now \\ DateTime.utc_now())

  def token(%__MODULE__{} = signer, %DateTime{} = now) do
    unix = DateTime.to_unix(now)
    header = encode(%{"alg" => "RS256", "typ" => "JWT"})

    claims =
      encode(%{
        "exp" => unix + 540,
        "iat" => unix - 60,
        "iss" => signer.app_id
      })

    signed = header <> "." <> claims
    signature = :public_key.sign(signed, :sha256, signer.private_key)
    {:ok, signed <> "." <> Base.url_encode64(signature, padding: false)}
  rescue
    _error -> {:error, {:invalid_github_app_jwt, :private_key}}
  end

  def token(%__MODULE__{}, _now), do: {:error, {:invalid_github_app_jwt, :clock}}
  def token(_signer, _now), do: {:error, {:invalid_github_app_jwt, :signer}}

  defp normalize_app_id(value) when is_integer(value) and value > 0,
    do: {:ok, Integer.to_string(value)}

  defp normalize_app_id(value) when is_binary(value) do
    if byte_size(value) in 1..128 and String.valid?(value) and
         Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, value),
       do: {:ok, value},
       else: {:error, {:invalid_github_app_jwt, :app_id}}
  end

  defp normalize_app_id(_value), do: {:error, {:invalid_github_app_jwt, :app_id}}

  defp decode_private_key(pem) when is_binary(pem) and byte_size(pem) in 128..16_384 do
    with [entry] <- :public_key.pem_decode(pem),
         private_key <- :public_key.pem_entry_decode(entry),
         true <- is_tuple(private_key) and elem(private_key, 0) == :RSAPrivateKey do
      {:ok, private_key}
    else
      _invalid -> {:error, {:invalid_github_app_jwt, :private_key}}
    end
  rescue
    _error -> {:error, {:invalid_github_app_jwt, :private_key}}
  end

  defp decode_private_key(_pem), do: {:error, {:invalid_github_app_jwt, :private_key}}

  defp encode(document) do
    document
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end
end
