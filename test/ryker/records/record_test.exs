defmodule Ryker.Records.RecordTest do
  # The model's record list and two Slack cards each built this document by
  # hand until 2026-10-08.
  use ExUnit.Case, async: true
  alias Ryker.Records.Record

  test "a record reads as its kind, payload, ref and status" do
    record = %Record{kind: "goal", payload: %{"id" => "scope"}, ref: "goal:1", status: :open}

    assert Record.document(record) == %{
             "kind" => "goal",
             "payload" => %{"id" => "scope"},
             "ref" => "goal:1",
             "status" => "open"
           }
  end
end
