defmodule Ryker.CanonicalJSON.TypeTest do
  use ExUnit.Case, async: true

  alias Ryker.CanonicalJSON.Type

  test "casts, dumps, and loads only valid canonical JSON" do
    value = %{"nested" => [1, true, nil]}

    assert {:ok, ^value} = Type.cast(value)
    assert {:ok, encoded} = Type.dump(value)
    assert encoded == ~s({"nested":[1,true,null]})
    assert {:ok, ^value} = Type.load(encoded)

    assert :error = Type.cast(%{"bad" => {:tuple, 1}})
    assert :error = Type.dump(%{"bad" => <<0>>})
    assert :error = Type.load("{")
    assert :error = Type.load(123)
  end
end
