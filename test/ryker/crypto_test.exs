defmodule Ryker.CryptoTest do
  use ExUnit.Case, async: true
  alias Ryker.Crypto

  # Sixty places checked a digest with a pattern of their own until
  # 2026-10-08; one used ^ and $, which in Elixir accept a trailing newline.
  test "a digest is exactly what sha256_hex/1 writes" do
    digest = Crypto.sha256_hex("ryker")

    assert Crypto.sha256_hex?(digest)
    refute Crypto.sha256_hex?(digest <> "\n")
    refute Crypto.sha256_hex?(String.upcase(digest))
    refute Crypto.sha256_hex?(binary_part(digest, 0, 63))
    refute Crypto.sha256_hex?(nil)
    assert Regex.match?(Crypto.sha256_hex_pattern(), digest)
  end
end
