defmodule Responder.Work.ResultTest do
  use ExUnit.Case, async: true

  alias Responder.Work.Result

  test "event deadlines are compared chronologically across calendar boundaries" do
    assert {:ok, future} =
             Result.new(
               :reply,
               %{"message" => "I will check next month."},
               nil,
               %{
                 "deadline_at" => "2027-02-01T00:00:00.000000Z",
                 "kind" => "wait",
                 "wait_kind" => "event",
                 "wait_ref" => "wait:future"
               }
             )

    assert Result.validate_at(future, ~U[2027-01-31 23:59:59.000000Z]) == :ok

    assert {:ok, elapsed} =
             Result.new(
               :reply,
               %{"message" => "This deadline already passed."},
               nil,
               %{
                 "deadline_at" => "2026-12-31T23:59:59.000000Z",
                 "kind" => "wait",
                 "wait_kind" => "event",
                 "wait_ref" => "wait:elapsed"
               }
             )

    assert Result.validate_at(elapsed, ~U[2027-01-01 00:00:00.000000Z]) ==
             {:error, :work_continuation_deadline_elapsed}
  end

  test "result reconstruction rejects every malformed durable shape" do
    valid = %{
      "continuation" => %{"kind" => "complete"},
      "decision_reason" => nil,
      "delivery" => "reply",
      "delivery_document" => %{"message" => "Done."}
    }

    assert {:ok, prepared} = Result.prepare_document(valid)
    assert Result.prepare(prepared) == {:ok, prepared}
    assert Result.document(prepared) == valid

    cases = [
      {Map.delete(valid, "continuation"), :fields},
      {%{valid | "delivery" => "later"}, :delivery},
      {%{valid | "delivery_document" => %{"message" => <<255>>}}, :delivery_document},
      {%{valid | "continuation" => %{"kind" => "unknown"}}, :continuation},
      {%{valid | "continuation" => "complete"}, :continuation}
    ]

    Enum.each(cases, fn {document, field} ->
      assert Result.prepare_document(document) == {:error, {:invalid_work_result, field}}
    end)

    assert Result.prepare_document([]) == {:error, {:invalid_work_result, :document}}
    assert Result.prepare(:not_a_result) == {:error, {:invalid_work_result, :value}}
    assert Result.new(:later, nil, nil) == {:error, {:invalid_work_result, :later}}
  end

  test "wait continuations require exact UTC fields and a useful reference" do
    input_wait = %{
      "deadline_at" => nil,
      "kind" => "wait",
      "wait_kind" => "input",
      "wait_ref" => "wait:operator"
    }

    assert {:ok, input_result} = Result.new(:reply, %{"message" => "Question?"}, nil, input_wait)
    assert Result.validate_at(input_result, ~U[2026-08-28 12:00:00Z]) == :ok

    invalid_continuations = [
      %{input_wait | "wait_ref" => " "},
      Map.put(input_wait, "unknown", true),
      %{input_wait | "deadline_at" => "2026-08-29T00:00:00Z"},
      %{
        "deadline_at" => "not-a-date",
        "kind" => "wait",
        "wait_kind" => "event",
        "wait_ref" => "wait:event"
      },
      %{
        "deadline_at" => DateTime.add(~U[2026-08-28 12:00:00Z], 1, :hour),
        "kind" => "wait",
        "wait_kind" => "unknown",
        "wait_ref" => "wait:event"
      }
    ]

    Enum.each(invalid_continuations, fn continuation ->
      assert Result.new(:reply, %{"message" => "Waiting."}, nil, continuation) ==
               {:error, {:invalid_work_result, :continuation}}
    end)

    invalid_runtime = %{input_result | continuation: %{"kind" => "unknown"}}

    assert Result.validate_at(invalid_runtime, ~U[2026-08-28 12:00:00Z]) ==
             {:error, {:invalid_work_result, :continuation}}
  end

  test "event wait accepts a UTC DateTime and normalizes its precision" do
    continuation = %{
      "deadline_at" => ~U[2026-08-29 12:00:00Z],
      "kind" => "wait",
      "wait_kind" => "event",
      "wait_ref" => "wait:event"
    }

    assert {:ok, result} = Result.new(:reply, %{"message" => "Waiting."}, nil, continuation)
    assert result.continuation["deadline_at"] == "2026-08-29T12:00:00.000000Z"

    non_utc = %{
      ~U[2026-08-29 12:00:00Z]
      | time_zone: "Etc/GMT+1",
        zone_abbr: "-01",
        utc_offset: -3_600
    }

    invalid = %{continuation | "deadline_at" => non_utc}

    assert Result.new(:reply, %{"message" => "Waiting."}, nil, invalid) ==
             {:error, {:invalid_work_result, :continuation}}
  end
end
