defmodule Ryker.CanonicalJSONTest do
  use ExUnit.Case, async: true
  alias Ryker.CanonicalJSON
  alias Ryker.Crypto

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

  # Go's encoding/json writes 1.0 as 1 and Jason writes 1.0, so the worker digest refused
  # every float rather than give one the worker cannot reproduce (2026-10-04 review). A
  # webhook's JSON holds what its sender sends, and an error rate of 0.24 in one stopped
  # every Work turn of its task with an ArgumentError, once a minute (2026-10-09). The
  # digest writes each float as Go does; the texts are Go 1.27's json.Marshal of each.
  test "a worker digest writes a float as Go's encoding/json does" do
    for {float, go} <- [
          {0.24, "0.24"},
          {1.0, "1"},
          {-1.0, "-1"},
          {0.0, "0"},
          {-0.0, "-0"},
          {-0.001, "-0.001"},
          {1.0e-6, "0.000001"},
          {9.99e-7, "9.99e-7"},
          {1.25e-7, "1.25e-7"},
          {123_456.0, "123456"},
          {1.0e16, "10000000000000000"},
          {1.0000000000000002, "1.0000000000000002"},
          {9.99e20, "999000000000000000000"},
          {1.0e21, "1e+21"},
          {1.5e21, "1.5e+21"},
          {-2.5e-300, "-2.5e-300"},
          {5.0e-324, "5e-324"},
          {12_345_678_901_234_567_890.0, "12345678901234567000"}
        ] do
      assert CanonicalJSON.worker_digest(%{"value" => float}) ==
               Crypto.sha256_hex(~s({"value":#{go}})),
             "#{float} is #{go} in Go"
    end

    payload = %{"items" => [%{"error_rate" => 0.24, "count" => 3}]}

    assert CanonicalJSON.worker_digest(payload) ==
             Crypto.sha256_hex(~s({"items":[{"count":3,"error_rate":0.24}]}))
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
