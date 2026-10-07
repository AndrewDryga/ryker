defmodule Ryker.CoopFleet.BodyCrypto do
  @moduledoc false
  alias Ryker.{CanonicalJSON, Secret}

  @domain "ryker-worker-body-v1"
  @iv <<0::128>>

  # Each write has fresh 256-bit salt and independent encryption/MAC keys.
  # A zero CTR counter is therefore never reused with the same encryption key.
  # The key arrives sealed (`Ryker.Secret`) and is opened only here.
  def start(%Secret{value: key}, identity) when is_binary(key) and byte_size(key) == 32 do
    salt = :crypto.strong_rand_bytes(32)
    {encryption, authentication, header} = keys(key, identity, salt)

    {:ok,
     %{
       cipher: :crypto.crypto_init(:aes_256_ctr, encryption, @iv, true),
       mac: :crypto.mac_init(:hmac, :sha256, authentication) |> :crypto.mac_update(header),
       salt: Base.encode64(salt)
     }}
  end

  def start(_key, _identity), do: {:error, :body_encryption_key_invalid}

  # OTP cipher/MAC contexts are mutable and belong to one serialized writer.
  def encrypt(state, plaintext) do
    ciphertext = :crypto.crypto_update(state.cipher, plaintext)
    :crypto.mac_update(state.mac, ciphertext)
    ciphertext
  end

  def finish(state) do
    <<>> = :crypto.crypto_final(state.cipher)
    %{"version" => 1, "salt" => state.salt, "tag" => Base.encode64(:crypto.mac_final(state.mac))}
  end

  # No decryptor escapes until the complete ciphertext has authenticated. The
  # caller keeps the same immutable open file for verification and every pass.
  def authenticate(
        %Secret{value: key},
        identity,
        %{"version" => 1, "salt" => encoded, "tag" => tag} = metadata,
        chunks
      )
      when is_binary(key) and byte_size(key) == 32 and map_size(metadata) == 3 do
    with {:ok, salt} when byte_size(salt) == 32 <- Base.decode64(encoded),
         {:ok, expected} when byte_size(expected) == 32 <- Base.decode64(tag) do
      {encryption, authentication, header} = keys(key, identity, salt)
      initial = :crypto.mac_init(:hmac, :sha256, authentication) |> :crypto.mac_update(header)
      actual = chunks |> Enum.reduce(initial, &:crypto.mac_update(&2, &1)) |> :crypto.mac_final()

      if Plug.Crypto.secure_compare(expected, actual),
        do: {:ok, fn -> :crypto.crypto_init(:aes_256_ctr, encryption, @iv, false) end},
        else: {:error, :body_authentication_failed}
    else
      _ -> {:error, :body_authentication_failed}
    end
  rescue
    _ -> {:error, :body_authentication_failed}
  end

  def authenticate(_key, _identity, _metadata, _chunks),
    do: {:error, :body_authentication_failed}

  defp keys(key, identity, salt) do
    header =
      CanonicalJSON.encode!(%{
        "domain" => @domain,
        "identity" => identity,
        "salt" => Base.encode64(salt)
      })

    <<encryption::binary-size(32), authentication::binary-size(32)>> = derive(key, salt, header)
    {encryption, authentication, header}
  end

  # RFC 5869 HKDF-SHA256, fixed at the two 32-byte keys used by this format.
  @doc false
  def derive(key, salt, info) do
    extracted = :crypto.mac(:hmac, :sha256, salt, key)
    first = :crypto.mac(:hmac, :sha256, extracted, [info, <<1>>])
    first <> :crypto.mac(:hmac, :sha256, extracted, [first, info, <<2>>])
  end
end
