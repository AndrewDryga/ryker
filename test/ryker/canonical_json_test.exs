defmodule Ryker.CanonicalJSONTest do
  use ExUnit.Case, async: true
  alias Ryker.CanonicalJSON

  describe "encode!/1" do
    test "orders every object while preserving list order" do
      value = %{"z" => %{"b" => 1, "a" => 2}, "list" => [%{"d" => 4, "c" => 3}, 1]}

      assert CanonicalJSON.encode!(value) ==
               ~s({"list":[{"c":3,"d":4},1],"z":{"a":2,"b":1}})
    end
  end

  describe "digest/1" do
    test "gives equivalent maps one stable identity" do
      assert CanonicalJSON.digest(%{"a" => 1, "b" => 2}) ==
               CanonicalJSON.digest(%{"b" => 2, "a" => 1})

      refute CanonicalJSON.digest(%{"a" => 1}) == CanonicalJSON.digest(%{"a" => 2})
    end
  end

  # A briefing keeps a long record this way and the record's check rebuilds
  # the preview to compare, so these bytes are pinned: a briefing frozen
  # before a change to them would read as stale (2026-10-04 review).
  test "a value too long for its bound keeps its head, tail, size and digest" do
    long = %{"text" => String.duplicate("a", 60) <> "é" <> String.duplicate("b", 60)}

    assert CanonicalJSON.bounded(long, 64) == %{
             "json_preview" =>
               ~s({"text":"aaaaaaaaaaaaaa...<truncated>...bbbbbbbbbbbbbbbbbbbbbb"}),
             "original_bytes" => 133,
             "sha256" => CanonicalJSON.digest(long),
             "truncated" => true
           }

    assert CanonicalJSON.bounded(%{"x" => 1}, 64) == %{"x" => 1}
    assert CanonicalJSON.bounded(nil, 64) == nil
  end

  test "rejects object keys that collapse to the same JSON field" do
    assert CanonicalJSON.validate(%{"same" => 1, same: 2}) ==
             {:error, {:duplicate_key, "$", "same"}}

    assert_raise ArgumentError, ~r/duplicate JSON key "same" at \$/, fn ->
      CanonicalJSON.encode!(%{"same" => 1, same: 2})
    end
  end

  test "rejects values that JSON cannot preserve" do
    assert CanonicalJSON.validate(%{"nested" => {:tuple, 1}}) ==
             {:error, {:invalid_json_value, "$.nested", :tuple}}
  end

  # 2026-10-04 review: an error carried the value it refused, and the raised message printed
  # it, so a secret with a NUL byte or invalid UTF-8 in it reached the logs whole. An error
  # says where the value is and what kind it is.
  test "an error names where and what kind, never the value" do
    secret = "xoxb-secret-token-" <> <<0>>

    assert CanonicalJSON.validate(%{"token" => secret}) ==
             {:error, {:invalid_json_value, "$.token", :string_with_nul}}

    error = assert_raise ArgumentError, fn -> CanonicalJSON.encode!(%{"token" => secret}) end
    refute error.message =~ "xoxb-secret-token"
    assert error.message =~ "$.token"

    key_error =
      assert_raise ArgumentError, fn -> CanonicalJSON.encode!(%{("key-" <> <<255>>) => 1}) end

    refute key_error.message =~ "key-"
  end

  # Go's encoding/json writes 1.0 as 1 and Jason writes 1.0, so a float in what Coop
  # digests would give a digest the worker cannot reproduce (2026-10-04 review). Nothing
  # Ryker sends a worker holds one; a worker digest refuses one rather than mismatch.
  test "a worker digest refuses a float it would encode unlike Go" do
    assert_raise ArgumentError, ~r/float at \$\.limit/, fn ->
      CanonicalJSON.worker_digest(%{"limit" => 1.0})
    end

    assert CanonicalJSON.worker_digest(%{"limit" => 1}) =~ ~r/\A[0-9a-f]{64}\z/
    assert CanonicalJSON.digest(%{"score" => 0.5}) =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "rejects non-string object keys even without a collision" do
    assert CanonicalJSON.validate(%{atom_key: 1}) == {:error, {:invalid_json_key, "$", :atom}}

    assert_raise ArgumentError, ~r/invalid JSON key \(an atom\) at \$/, fn ->
      CanonicalJSON.encode!(%{atom_key: 1})
    end
  end

  test "rejects a key with no string representation instead of crashing" do
    assert CanonicalJSON.validate(%{{:bad, 1} => "value"}) ==
             {:error, {:invalid_json_key, "$", :tuple}}

    assert_raise ArgumentError, ~r/invalid JSON key \(a tuple\) at \$/, fn ->
      CanonicalJSON.encode!(%{{:bad, 1} => "value"})
    end
  end

  test "rejects strings that Postgres JSONB cannot preserve" do
    assert CanonicalJSON.validate(%{"text" => <<0>>}) ==
             {:error, {:invalid_json_value, "$.text", :string_with_nul}}

    assert CanonicalJSON.validate(%{"text" => <<255>>}) ==
             {:error, {:invalid_json_value, "$.text", :invalid_utf8}}

    assert CanonicalJSON.validate(%{<<0>> => "value"}) ==
             {:error, {:invalid_json_key, "$", :string_with_nul}}
  end
end
