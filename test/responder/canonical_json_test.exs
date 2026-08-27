defmodule Responder.CanonicalJSONTest do
  use ExUnit.Case, async: true
  alias Responder.CanonicalJSON

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

  test "rejects object keys that collapse to the same JSON field" do
    assert {:error, {:duplicate_key, "$", "same"}} =
             CanonicalJSON.validate(%{"same" => 1, same: 2})

    assert_raise ArgumentError, ~r/duplicate JSON key "same" at \$/, fn ->
      CanonicalJSON.encode!(%{"same" => 1, same: 2})
    end
  end

  test "rejects values that JSON cannot preserve" do
    assert {:error, {:invalid_json_value, "$.nested", {:tuple, 1}}} =
             CanonicalJSON.validate(%{"nested" => {:tuple, 1}})
  end

  test "rejects non-string object keys even without a collision" do
    assert {:error, {:invalid_json_key, "$", :atom_key}} =
             CanonicalJSON.validate(%{atom_key: 1})

    assert_raise ArgumentError, ~r/invalid JSON key :atom_key at \$/, fn ->
      CanonicalJSON.encode!(%{atom_key: 1})
    end
  end

  test "rejects a key with no string representation instead of crashing" do
    assert {:error, {:invalid_json_key, "$", {:bad, 1}}} =
             CanonicalJSON.validate(%{{:bad, 1} => "value"})

    assert_raise ArgumentError, ~r/invalid JSON key \{:bad, 1\} at \$/, fn ->
      CanonicalJSON.encode!(%{{:bad, 1} => "value"})
    end
  end

  test "rejects strings that Postgres JSONB cannot preserve" do
    assert {:error, {:invalid_json_value, "$.text", <<0>>}} =
             CanonicalJSON.validate(%{"text" => <<0>>})

    assert {:error, {:invalid_json_value, "$.text", <<255>>}} =
             CanonicalJSON.validate(%{"text" => <<255>>})

    assert {:error, {:invalid_json_key, "$", <<0>>}} =
             CanonicalJSON.validate(%{<<0>> => "value"})
  end
end
