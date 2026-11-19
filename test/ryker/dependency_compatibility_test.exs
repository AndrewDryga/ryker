defmodule Ryker.DependencyCompatibilityTest do
  use ExUnit.Case, async: true

  # CVE-2026-117678: the public advisory's xn-- + repeated a + 99 input
  # spent seconds to minutes in Punycode before rejecting an overlong label.
  # Assert the early length refusal, without a load-dependent timing threshold.
  test "overlong Punycode labels are rejected before decoding" do
    hostname = String.to_charlist("xn--" <> String.duplicate("a", 128) <> "99.example")

    for convert <- [&:idna.decode/1, &:idna.to_ascii/1] do
      assert {:bad_label, {:too_long, _}} = catch_exit(convert.(hostname))
    end
  end

  test "JSV hostname validation accepts valid names with the patched IDNA dependency" do
    schema = JSV.build!(%{"type" => "string", "format" => "hostname"}, formats: true)

    for hostname <- ["example.com", "xn--bcher-kva.example"] do
      assert {:ok, ^hostname} = JSV.validate(hostname, schema)
    end

    for hostname <- [
          "a..example",
          "-bad.example",
          "bücher.example",
          String.duplicate("a", 64) <> ".example",
          "xn--" <> String.duplicate("a", 128) <> "99.example"
        ] do
      assert {:error, _} = JSV.validate(hostname, schema)
    end
  end
end
