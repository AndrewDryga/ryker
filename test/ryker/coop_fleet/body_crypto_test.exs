defmodule Ryker.CoopFleet.BodyCryptoTest do
  use ExUnit.Case, async: true

  alias Ryker.CoopFleet.BodyCrypto

  test "key derivation agrees with RFC 5869 test case 1" do
    output =
      BodyCrypto.derive(
        :binary.copy(<<11>>, 22),
        hex("000102030405060708090a0b0c"),
        hex("f0f1f2f3f4f5f6f7f8f9")
      )

    assert binary_part(output, 0, 42) ==
             hex(
               "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
             )
  end

  test "arbitrary chunk boundaries authenticate before returning any decryptor" do
    key = :crypto.strong_rand_bytes(32)

    identity = %{
      "command" => "c",
      "direction" => "response",
      "reference" => %{"sha256" => "hash", "byte_size" => 17}
    }

    plaintext = "seventeen bytes!!"
    assert byte_size(plaintext) == 17
    assert {:ok, state} = BodyCrypto.start(key, identity)
    encrypted = for <<byte <- plaintext>>, into: <<>>, do: BodyCrypto.encrypt(state, <<byte>>)
    metadata = BodyCrypto.finish(state)
    refute encrypted == plaintext
    assert byte_size(encrypted) == byte_size(plaintext)
    assert {:ok, new_cipher} = BodyCrypto.authenticate(key, identity, metadata, [encrypted])
    cipher = new_cipher.()

    assert :crypto.crypto_update(cipher, binary_part(encrypted, 0, 1)) <>
             :crypto.crypto_update(cipher, binary_part(encrypted, 1, 16)) <>
             :crypto.crypto_final(cipher) == plaintext

    for {candidate_key, candidate_identity, candidate_metadata, bytes} <- [
          {:crypto.strong_rand_bytes(32), identity, metadata, encrypted},
          {key, Map.put(identity, "command", "other"), metadata, encrypted},
          {key, Map.put(identity, "direction", "request"), metadata, encrypted},
          {key, identity, Map.put(metadata, "version", 2), encrypted},
          {key, identity, Map.put(metadata, "tag", Base.encode64(<<0::256>>)), encrypted},
          {key, identity, metadata, binary_part(encrypted, 0, 16)},
          {key, identity, metadata, encrypted <> <<0>>},
          {key, identity, metadata,
           <<Bitwise.bxor(:binary.at(encrypted, 0), 1)>> <> binary_part(encrypted, 1, 16)}
        ] do
      assert {:error, :body_authentication_failed} =
               BodyCrypto.authenticate(candidate_key, candidate_identity, candidate_metadata, [
                 bytes
               ])
    end

    assert {:ok, replay} = BodyCrypto.start(key, identity)
    refute BodyCrypto.encrypt(replay, plaintext) == encrypted
    refute BodyCrypto.finish(replay)["salt"] == metadata["salt"]
    assert {:error, :body_encryption_key_invalid} = BodyCrypto.start(nil, identity)
  end

  defp hex(value), do: Base.decode16!(value, case: :lower)
end
