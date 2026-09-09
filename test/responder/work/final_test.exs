defmodule Responder.Work.FinalTest do
  use ExUnit.Case, async: true

  alias Responder.Work.Final

  test "an unchanged lifecycle may wait silently without discarding its durable record" do
    # The Terraform episode posted every fallback despite no status change.
    document = %{
      "delivery" => "none",
      "message" => nil,
      "decision_reason" => "No lifecycle change; retain the existing notification watch.",
      "outcome" => %{
        "state" => "waiting_for_event",
        "record_refs" => ["record:event_wait:e6d68ba5ee965c0a7052a684502370e3"],
        "artifact_refs" => []
      }
    }

    assert {:ok, final} = Final.parse(document)
    assert Final.document(final) == document
  end

  test "the published JSON Schema and parser accept the same boundary values" do
    schema = JSV.build!(Final.json_schema())

    documents = [
      reply_document(String.duplicate("😀", 20_000)),
      %{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "I will check again after the rollout settles.",
        "outcome" => %{
          "artifact_refs" => [],
          "record_refs" => ["record:wait:1"],
          "state" => "waiting_for_event"
        }
      }
    ]

    Enum.each(documents, fn document ->
      assert {:ok, _validated} = JSV.validate(document, schema)
      assert {:ok, final} = Final.parse(document)
      assert Final.document(final) == document
    end)
  end

  test "delivery shape is exact and rejects hidden fallback prose" do
    assert {:error, {:invalid_work_final, :delivery_shape}} =
             Final.parse(%{
               "decision_reason" => "Do not send.",
               "delivery" => "reply",
               "message" => "Visible answer.",
               "outcome" => empty_outcome()
             })

    assert {:error, {:invalid_work_final, :decision_reason}} =
             Final.parse(%{
               "decision_reason" => "   ",
               "delivery" => "none",
               "message" => nil,
               "outcome" => empty_outcome()
             })

    assert {:error, {:invalid_work_final, :state_requires_visible_reply}} =
             Final.parse(%{
               "decision_reason" => "Waiting is already visible elsewhere.",
               "delivery" => "none",
               "message" => nil,
               "outcome" => %{
                 "artifact_refs" => [],
                 "record_refs" => ["record:wait:1"],
                 "state" => "waiting_for_input"
               }
             })
  end

  test "the audited silence reason accepts 240 Unicode characters and rejects 241" do
    schema = JSV.build!(Final.json_schema())
    accepted = silent_document(String.duplicate("😀", 240))
    rejected = silent_document(String.duplicate("😀", 241))

    assert {:ok, _validated} = JSV.validate(accepted, schema)
    assert {:ok, _final} = Final.parse(accepted)
    assert {:error, _reason} = JSV.validate(rejected, schema)
    assert {:error, {:invalid_work_final, :decision_reason}} = Final.parse(rejected)
  end

  test "record and artifact references are bounded and unique" do
    duplicate = reply_document("Done.")
    duplicate = put_in(duplicate, ["outcome", "record_refs"], ["record:1", "record:1"])

    assert {:error, {:invalid_work_final, :record_refs}} = Final.parse(duplicate)

    too_many = reply_document("Done.")

    too_many =
      put_in(
        too_many,
        ["outcome", "artifact_refs"],
        Enum.map(1..6, &"artifact:#{&1}")
      )

    assert {:error, {:invalid_work_final, :artifact_refs}} = Final.parse(too_many)
  end

  test "the final parser rejects malformed envelope and enum fields" do
    valid = reply_document("Done.")

    cases = [
      {nil, :type},
      {Map.put(valid, "extra", true), :fields},
      {%{valid | "delivery" => 1}, :delivery},
      {%{valid | "outcome" => nil}, :outcome},
      {put_in(valid, ["outcome", "state"], 1), :state},
      {put_in(valid, ["outcome", "record_refs"], "record:1"), :record_refs},
      {put_in(valid, ["outcome", "artifact_refs"], "artifact:1"), :artifact_refs},
      {put_in(valid, ["outcome", "state"], "waiting_for_event"), :waiting_state_requires_record}
    ]

    Enum.each(cases, fn {document, field} ->
      assert Final.parse(document) == {:error, {:invalid_work_final, field}}
    end)
  end

  defp reply_document(message) do
    %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => empty_outcome()
    }
  end

  defp empty_outcome do
    %{
      "artifact_refs" => [],
      "record_refs" => [],
      "state" => "complete"
    }
  end

  defp silent_document(reason) do
    %{
      "decision_reason" => reason,
      "delivery" => "none",
      "message" => nil,
      "outcome" => empty_outcome()
    }
  end
end
