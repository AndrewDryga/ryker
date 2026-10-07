defmodule Ryker.Crypto do
  @moduledoc """
  Hashing, random values, message authentication and sealing, chosen in one
  place (`Ryker.Checks.ContextCryptoBoundary`). A digest is SHA-256 written
  as lowercase hex, the form every receipt, fingerprint and ref keeps; thirty
  modules each kept a private copy of that one line.

  The Coop body cipher and the streaming hashes of request bodies and
  workspace checkpoints keep their own modules (`Ryker.CoopFleet.BodyCrypto`,
  `Ryker.CoopFleet.Bodies`, `Ryker.CoopFleet.WorkspaceCheckpointBundle`): the
  worker protocol fixes them.
  """

  @nonce_bytes 12
  @tag_bytes 16

  @doc "SHA-256 of `data`, as lowercase hex."
  @spec sha256_hex(iodata()) :: String.t()
  def sha256_hex(data), do: data |> sha256() |> Base.encode16(case: :lower)

  @doc "SHA-256 of `data`, the raw 32 bytes."
  @spec sha256(iodata()) :: binary()
  def sha256(data), do: :crypto.hash(:sha256, data)

  @doc "SHA-512 of `data`, the raw 64 bytes."
  @spec sha512(iodata()) :: binary()
  def sha512(data), do: :crypto.hash(:sha512, data)

  @doc "HMAC-SHA-256 of `data` under `secret`, the raw 32 bytes."
  @spec hmac_sha256(iodata(), iodata()) :: binary()
  def hmac_sha256(secret, data), do: :crypto.mac(:hmac, :sha256, secret, data)

  @doc "`count` bytes from the operating system's secure random source."
  @spec random_bytes(pos_integer()) :: binary()
  def random_bytes(count), do: :crypto.strong_rand_bytes(count)

  @doc "`count` random bytes, as lowercase hex."
  @spec random_hex(pos_integer()) :: String.t()
  def random_hex(count), do: count |> random_bytes() |> Base.encode16(case: :lower)

  @doc "`count` random bytes, URL-safe Base64 without padding: a secret a person pastes."
  @spec random_secret(pos_integer()) :: String.t()
  def random_secret(count), do: count |> random_bytes() |> Base.url_encode64(padding: false)

  @doc "The PostgreSQL advisory lock key for `name`: the first 64 bits of its SHA-256, signed."
  @spec lock_key(iodata()) :: integer()
  def lock_key(name) do
    <<key::signed-64, _rest::binary>> = sha256(name)
    key
  end

  @doc """
  `plaintext` sealed with AES-256-GCM under the 32-byte `key`, bound to
  `associated_data`: its fresh nonce, the ciphertext and the tag.
  """
  @spec seal(<<_::256>>, binary(), iodata()) ::
          %{nonce: binary(), ciphertext: binary(), tag: binary()}
  def seal(key, plaintext, associated_data) when byte_size(key) == 32 do
    nonce = random_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        plaintext,
        associated_data,
        @tag_bytes,
        true
      )

    %{nonce: nonce, ciphertext: ciphertext, tag: tag}
  end

  @doc "The plaintext `seal/3` sealed, or `:error` for a wrong key, data or tag."
  @spec open(<<_::256>>, %{nonce: binary(), ciphertext: binary(), tag: binary()}, iodata()) ::
          {:ok, binary()} | :error
  def open(key, %{nonce: nonce, ciphertext: ciphertext, tag: tag}, associated_data)
      when byte_size(key) == 32 do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           nonce,
           ciphertext,
           associated_data,
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end
end
