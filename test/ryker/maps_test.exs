defmodule Ryker.MapsTest do
  use ExUnit.Case, async: true
  alias Ryker.Maps

  # 115 checks in 83 modules sorted a map's keys by hand to compare them with
  # the keys a document may carry, and about twenty more subtracted a list of
  # allowed keys; each module wrote its own version, three of them as private
  # helpers that differed only in how they spelled it.
  test "a map with exactly the required keys, and only the optional ones besides, is exact" do
    assert Maps.exact_keys?(%{"a" => 1, "b" => 2}, ["b", "a"])
    refute Maps.exact_keys?(%{"a" => 1}, ["a", "b"])
    refute Maps.exact_keys?(%{"a" => 1, "b" => 2, "c" => 3}, ["a", "b"])

    assert Maps.exact_keys?(%{"a" => 1}, ["a"], ["b"])
    assert Maps.exact_keys?(%{"a" => 1, "b" => 2}, ["a"], ["b"])
    refute Maps.exact_keys?(%{"b" => 2}, ["a"], ["b"])
    refute Maps.exact_keys?(%{"a" => 1, "c" => 3}, ["a"], ["b"])

    assert Maps.exact_keys?(%{}, [])
    refute Maps.exact_keys?(nil, [])
    refute Maps.exact_keys?([a: 1], [:a])
  end

  test "a map holds only allowed keys when none is outside them, whichever it lacks" do
    assert Maps.only_keys?(%{}, ["a"])
    assert Maps.only_keys?(%{"a" => 1}, ["a", "b"])
    refute Maps.only_keys?(%{"a" => 1, "c" => 3}, ["a", "b"])
    refute Maps.only_keys?("a", ["a"])
  end

  test "a value is put only when there is one, in a map or a keyword list" do
    assert Maps.put_present(%{a: 1}, :b, nil) == %{a: 1}
    assert Maps.put_present(%{a: 1}, :b, 2) == %{a: 1, b: 2}
    assert Maps.put_present([a: 1], :b, 2) == [b: 2, a: 1]
    assert Maps.put_present([a: 1], :b, nil) == [a: 1]
  end
end
