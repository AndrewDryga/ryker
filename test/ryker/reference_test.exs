defmodule Ryker.ReferenceTest do
  use ExUnit.Case, async: true
  alias Ryker.Reference

  test "a reference is valid UTF-8, not blank, with no NUL byte, within its byte bound" do
    assert Reference.valid?("source:abc")
    assert Reference.valid?("Виправити")
    refute Reference.valid?("  ")
    refute Reference.valid?("a" <> <<0>>)
    refute Reference.valid?(<<255>>)
    refute Reference.valid?(String.duplicate("a", 1_025))
    assert Reference.check("x", :field, :invalid_thing) == :ok
    assert Reference.check(nil, :field, :invalid_thing) == {:error, {:invalid_thing, :field}}
  end

  # Twelve modules each held this pattern until 2026-10-08.
  test "a token is an identifier-shaped reference" do
    assert Reference.token?("artifact:input:1")
    assert Reference.token?("record_2.goal-3")
    refute Reference.token?("")
    refute Reference.token?("with space")
    refute Reference.token?("ключ")
    refute Reference.token?(String.duplicate("a", 257))
    refute Reference.token?(nil)
    assert Regex.match?(Reference.token_pattern(), "record:1")
  end

  test "a UUID is what Ecto casts as one" do
    assert Reference.uuid?(Ecto.UUID.generate())
    refute Reference.uuid?("not-a-uuid")
    refute Reference.uuid?(nil)
  end
end
