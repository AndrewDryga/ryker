defmodule Ryker.CoopFleet.CheckpointCrypto do
  @moduledoc false

  @nonce_bytes 12
  @tag_bytes 16

  @spec open(binary(), map(), binary(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def open(key, checkpoint, ciphertext, nonce, tag, key_sha256)
      when is_binary(key) and byte_size(key) == 32 and is_map(checkpoint) and
             is_binary(ciphertext) and is_binary(nonce) and byte_size(nonce) == @nonce_bytes and
             is_binary(tag) and byte_size(tag) == @tag_bytes and is_binary(key_sha256) do
    with true <- secure_equal?(digest(key), key_sha256),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             associated_data(checkpoint),
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _invalid -> {:error, :workspace_checkpoint_decryption_failed}
    end
  rescue
    _error -> {:error, :workspace_checkpoint_decryption_failed}
  end

  def open(_key, _checkpoint, _ciphertext, _nonce, _tag, _key_sha256),
    do: {:error, :workspace_checkpoint_decryption_failed}

  defp associated_data(checkpoint) do
    [
      "ryker-workspace-checkpoint-v1",
      checkpoint["checkpoint_ref"],
      checkpoint["session_ref"],
      Integer.to_string(checkpoint["placement_generation"]),
      checkpoint["repository_ref"],
      checkpoint["bundle"]["sha256"],
      Integer.to_string(checkpoint["bundle"]["byte_size"])
    ]
    |> Enum.join(<<0>>)
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
