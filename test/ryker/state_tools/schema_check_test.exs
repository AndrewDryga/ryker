defmodule Ryker.StateTools.SchemaCheckTest do
  use ExUnit.Case, async: true
  alias Ryker.StateTools.{ErrorCode, SchemaCheck}

  @nested %{
    "name" => "nested",
    "inputSchema" => %{
      "additionalProperties" => false,
      "properties" => %{
        "title" => %{"maxLength" => 10, "type" => "string"},
        "steps" => %{
          "items" => %{
            "additionalProperties" => false,
            "properties" => %{"kind" => %{"enum" => ["read", "write"]}},
            "required" => ["kind"],
            "type" => "object"
          },
          "maxItems" => 20,
          "type" => "array"
        }
      },
      "required" => ["steps", "title"],
      "type" => "object"
    }
  }

  @catalog [
    @nested,
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

  # A refused call answered a bare "invalid_arguments", and the model guessed
  # which field to change. The answer names each field by JSON Pointer with a
  # stable code and the rule it broke, never what was sent (Emisar's
  # actionable validation, 2026-10-08).
  test "an invalid call names each field it breaks, never the value it sent" do
    secret = "sk-live-0123456789"

    arguments = %{
      "title" => secret <> " is far too long",
      "steps" => [%{"kind" => "read"}, %{"kind" => "delete", "extra" => true}],
      "unknown" => 1
    }

    assert {:error, {:invalid_arguments, report}} =
             SchemaCheck.exact_schema("nested", arguments, @catalog)

    assert report.count == 4
    refute report.truncated

    assert Enum.map(report.issues, &{&1.path, &1.code}) == [
             {"/steps/1/extra", "additional_property"},
             {"/steps/1/kind", "enum"},
             {"/title", "max_length"},
             {"/unknown", "additional_property"}
           ]

    text = ErrorCode.code({:invalid_arguments, report})
    assert text =~ ~s(/steps/1/kind (enum\): must be one of "read", "write".)
    assert text =~ "/title (max_length): takes at most 10 characters."
    refute text =~ secret
    refute text =~ "delete"
  end

  test "a call with many issues lists the first eight and says how many there were" do
    arguments = %{
      "title" => "short",
      "steps" => for(_index <- 1..12, do: %{"kind" => "erase"})
    }

    assert {:error, {:invalid_arguments, report}} =
             SchemaCheck.exact_schema("nested", arguments, @catalog)

    assert {report.count, length(report.issues), report.truncated} == {12, 8, true}

    assert ErrorCode.code({:invalid_arguments, report}) =~
             "invalid_arguments: 12 issues, the first 8 shown. /steps/0/kind (enum)"
  end
end
