defmodule Ryker.StateTools.SchemaCheckTest do
  use ExUnit.Case, async: true
  alias Ryker.StateTools.SchemaCheck

  @catalog [
    %{
      "name" => "probe",
      "inputSchema" => %{
        "additionalProperties" => false,
        "properties" => %{"note" => %{"maxLength" => 4, "minLength" => 1, "type" => "string"}},
        "required" => ["note"],
        "type" => "object"
      }
    }
  ]

  # The catalog tells the model each string's maxLength, which JSON Schema
  # counts in code points, and the host counted what a reader sees as one
  # character: a value the model was told was too long passed, and its row's
  # char_length check then raised (2026-10-08).
  test "a string's length counts code points, as the schema the model reads does" do
    assert SchemaCheck.exact_schema("probe", %{"note" => "abcd"}, @catalog) == :ok
    assert SchemaCheck.exact_schema("probe", %{"note" => "🇺🇦🇺🇦"}, @catalog) == :ok

    assert {:error, _reason} =
             SchemaCheck.exact_schema("probe", %{"note" => "abc🇺🇦"}, @catalog)

    assert {:error, _reason} =
             SchemaCheck.exact_schema("probe", %{"note" => "éée"}, @catalog)
  end
end
