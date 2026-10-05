defmodule Ryker.Work.ValidationIntentTest do
  use ExUnit.Case, async: true

  alias Ryker.Work.{Result, ValidationIntent}

  test "accept preserves the exact host result that Coop is asked to validate" do
    assert {:ok, result} = Result.new(:reply, %{"message" => "Ready for review."})
    assert {:ok, intent} = ValidationIntent.new(:accept, result)

    assert intent["verdict"] == "accept"
    assert intent["violations"] == []
    assert {:ok, ^result} = ValidationIntent.result(intent)
    assert byte_size(ValidationIntent.fingerprint(intent)) == 64
    assert ValidationIntent.prepare(intent) == {:ok, intent}
  end

  test "reject matches Coop's one-to-twenty and combined 4096-byte violation bound" do
    violations = Enum.map(1..20, &"Violation #{&1}")

    assert {:ok, intent} = ValidationIntent.new({:reject, violations}, nil)
    assert intent["verdict"] == "reject"
    assert intent["violations"] == violations
    assert ValidationIntent.result(intent) == {:ok, nil}
    assert ValidationIntent.prepare(intent) == {:ok, intent}

    assert {:ok, boundary} =
             ValidationIntent.new(
               {:reject, ["  " <> String.duplicate("x", 4_095) <> "  "]},
               nil
             )

    assert boundary["violations"] == [String.duplicate("x", 4_095)]
    assert {:error, _empty} = ValidationIntent.new({:reject, []}, nil)
    assert {:error, _blank} = ValidationIntent.new({:reject, ["   "]}, nil)
  end

  # A candidate with more problems than Coop takes back with a rejection,
  # twenty and 4 KiB in all, was refused outright, and the turn blocked for a
  # person instead of going back to the model (2026-10-04 review).
  test "a rejection sends back the first problems that fit, and how many more there were" do
    many = Enum.map(1..25, &"Violation #{&1}")
    assert {:ok, %{"violations" => sent}} = ValidationIntent.new({:reject, many}, nil)
    assert length(sent) == 20
    assert Enum.take(sent, 19) == Enum.take(many, 19)
    assert List.last(sent) =~ "6 more problems were found"

    long = [String.duplicate("a", 3_000), String.duplicate("b", 3_000)]
    assert {:ok, %{"violations" => [first, more]}} = ValidationIntent.new({:reject, long}, nil)
    assert first == String.duplicate("a", 3_000)
    assert more =~ "1 more problem was found"

    assert {:ok, %{"violations" => [cut]}} =
             ValidationIntent.new({:reject, [String.duplicate("x", 5_000)]}, nil)

    assert byte_size(cut) <= 4_095
    assert String.ends_with?(cut, "…")

    for {:ok, intent} <- [ValidationIntent.new({:reject, many}, nil)] do
      assert ValidationIntent.prepare(intent) == {:ok, intent}
    end
  end

  test "accept and reject shapes cannot be mixed" do
    assert {:ok, result} = Result.new(:none, nil, "This is an exact duplicate.")

    assert ValidationIntent.new(:accept, nil) ==
             {:error, {:invalid_work_validation_intent, :result}}

    assert ValidationIntent.new({:reject, ["Use a visible reply."]}, result) ==
             {:error, {:invalid_work_validation_intent, :result}}

    invalid_result = %Result{continuation: %{"kind" => "complete"}, delivery: :reply}

    assert ValidationIntent.new(:accept, invalid_result) ==
             {:error, {:invalid_work_validation_intent, :result}}
  end

  test "a frozen intent has one exact durable shape" do
    assert {:ok, result} = Result.new(:reply, %{"message" => "Done."})
    assert {:ok, intent} = ValidationIntent.new(:accept, result)

    cases = [
      {Map.put(intent, "extra", true), :fields},
      {%{intent | "result" => %{}}, :result},
      {%{intent | "verdict" => "reject"}, :shape},
      {%{intent | "violations" => ["unexpected"]}, :shape}
    ]

    Enum.each(cases, fn {document, field} ->
      assert ValidationIntent.prepare(document) ==
               {:error, {:invalid_work_validation_intent, field}}
    end)

    assert ValidationIntent.prepare([]) ==
             {:error, {:invalid_work_validation_intent, :document}}

    assert ValidationIntent.result(%{}) ==
             {:error, {:invalid_work_validation_intent, :result}}

    assert ValidationIntent.new(:later, nil) ==
             {:error, {:invalid_work_validation_intent, :verdict}}
  end

  test "reject violations are trimmed and reject empty or non-text sets" do
    assert {:ok, intent} = ValidationIntent.new({:reject, ["  repair this  "]}, nil)
    assert intent["violations"] == ["repair this"]

    invalid = [
      [],
      ["   "],
      [<<255>>],
      ["contains\0nul"],
      [123]
    ]

    Enum.each(invalid, fn violations ->
      assert ValidationIntent.new({:reject, violations}, nil) ==
               {:error, {:invalid_work_validation_intent, :violations}}
    end)
  end
end
