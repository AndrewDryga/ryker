defmodule Ryker.OptionsTest do
  use ExUnit.Case, async: true
  alias Ryker.Options

  @messages [
    list: "demo configuration must use unique known fields",
    map: "demo configuration has missing or unknown fields",
    other: "demo configuration must be a map or keyword list"
  ]

  test "a keyword list or a map with known fields becomes the same map" do
    assert Options.normalize!([port: 1, ip: :any], [:ip, :port], [:port], @messages) ==
             %{ip: :any, port: 1}

    assert Options.normalize!(%{port: 1}, [:ip, :port], [:port], @messages) == %{port: 1}
  end

  test "each refusal speaks in the caller's own words" do
    assert_raise ArgumentError, "demo configuration must use unique known fields", fn ->
      Options.normalize!([port: 1, port: 2], [:port], [:port], @messages)
    end

    assert_raise ArgumentError, "demo configuration must use unique known fields", fn ->
      Options.normalize!([1, 2], [:port], [:port], @messages)
    end

    assert_raise ArgumentError, "demo configuration has missing or unknown fields", fn ->
      Options.normalize!(%{port: 1, secret: "x"}, [:port], [:port], @messages)
    end

    assert_raise ArgumentError, "demo configuration has missing or unknown fields", fn ->
      Options.normalize!([ip: :any], [:ip, :port], [:port], @messages)
    end

    assert_raise ArgumentError, "demo configuration must be a map or keyword list", fn ->
      Options.normalize!(:invalid, [:port], [:port], @messages)
    end
  end

  test "one message can answer every refusal" do
    for invalid <- [[port: 1, port: 2], %{unknown: true}, :invalid] do
      assert_raise ArgumentError, "demo options are invalid", fn ->
        Options.normalize!(invalid, [:port], [], "demo options are invalid")
      end
    end
  end
end
