defmodule Responder.Work.ValidatorTest do
  use ExUnit.Case, async: true

  alias Responder.Work.{Final, Validator}

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "a complete reply accepts only existing records and artifacts without policing its prose" do
    candidate =
      candidate(
        %{
          "artifact_refs" => ["artifact:memory-chart:1"],
          "record_refs" => ["record:source:1"],
          "state" => "complete"
        },
        "I cannot yet explain the cause, but the requested file is attached."
      )

    context =
      context(%{
        artifacts: ["artifact:memory-chart:1"],
        records: %{"record:source:1" => record("source_citation")}
      })

    assert {:accept, accepted} = Validator.validate(candidate, context, @now)
    assert accepted.final.state == :complete
    assert accepted.result.continuation == %{"kind" => "complete"}
    assert accepted.result.delivery == :reply
    assert accepted.result.delivery_document == Final.document(accepted.final)
  end

  test "one rejection returns every actionable reference and visibility violation" do
    document = %{
      "decision_reason" => "No visible response is needed.",
      "delivery" => "none",
      "message" => nil,
      "outcome" => %{
        "artifact_refs" => ["artifact:missing"],
        "record_refs" => ["record:missing"],
        "state" => "complete"
      }
    }

    assert {:reject, violations} =
             Validator.validate(
               Jason.encode!(document),
               context(visible_reply_required: true),
               @now
             )

    assert length(violations) == 3
    assert Enum.any?(violations, &String.contains?(&1, "explicit human request"))
    assert Enum.any?(violations, &String.contains?(&1, "record:missing"))
    assert Enum.any?(violations, &String.contains?(&1, "artifact:missing"))
  end

  test "a waiting result must reference exactly one matching durable wait" do
    wait = %{
      "deadline_at" => nil,
      "kind" => "wait",
      "wait_kind" => "input",
      "wait_ref" => "wait:operator:1"
    }

    candidate =
      candidate(
        %{
          "artifact_refs" => [],
          "record_refs" => ["record:question:1", "record:source:1"],
          "state" => "waiting_for_input"
        },
        "Which deployment should I inspect?"
      )

    context =
      context(
        records: %{
          "record:question:1" => record("operator_input", wait),
          "record:source:1" => record("source_citation")
        }
      )

    assert {:accept, accepted} = Validator.validate(candidate, context, @now)
    assert accepted.result.continuation == wait

    wrong_state =
      candidate(
        %{
          "artifact_refs" => [],
          "record_refs" => ["record:question:1"],
          "state" => "waiting_for_event"
        },
        "I will wait for the rollout."
      )

    assert {:reject, [violation]} = Validator.validate(wrong_state, context, @now)
    assert violation =~ "waiting_for_event"
    assert violation =~ "event wait"
  end

  test "invalid JSON and an elapsed event wait receive self-contained correction text" do
    assert {:reject, [invalid_json]} = Validator.validate("not json", context(), @now)
    assert invalid_json =~ "not valid JSON"
    assert invalid_json =~ "attached output schema"

    elapsed = %{
      "deadline_at" => "2026-08-28T11:59:59.000000Z",
      "kind" => "wait",
      "wait_kind" => "event",
      "wait_ref" => "wait:rollout:1"
    }

    candidate =
      candidate(
        %{
          "artifact_refs" => [],
          "record_refs" => ["record:wait:1"],
          "state" => "waiting_for_event"
        },
        "I will check after the event."
      )

    assert {:reject, [violation]} =
             Validator.validate(
               candidate,
               context(records: %{"record:wait:1" => record("event_wait", elapsed)}),
               @now
             )

    assert violation =~ "record:wait:1"
    assert violation =~ "deadline"
    assert violation =~ "new wait"
  end

  test "every malformed final receives the correction for the field that is wrong" do
    valid = Jason.decode!(candidate(empty_outcome(), "Done."))

    cases = [
      {"[]", "not a JSON object"},
      {Jason.encode!(Map.delete(valid, "outcome")), "top-level object"},
      {Jason.encode!(%{valid | "delivery" => "later"}), "delivery must"},
      {Jason.encode!(%{valid | "message" => " "}), "message must"},
      {Jason.encode!(%{valid | "decision_reason" => "hidden"}), "provide message"},
      {Jason.encode!(%{valid | "outcome" => nil}), "outcome must"},
      {Jason.encode!(put_in(valid, ["outcome", "state"], "blocked")), "outcome.state"},
      {Jason.encode!(put_in(valid, ["outcome", "record_refs"], ["bad ref"])),
       "outcome.record_refs"},
      {Jason.encode!(put_in(valid, ["outcome", "artifact_refs"], ["bad ref"])),
       "outcome.artifact_refs"},
      {Jason.encode!(
         valid
         |> Map.put("delivery", "none")
         |> Map.put("message", nil)
         |> Map.put("decision_reason", "Wait silently.")
         |> put_in(["outcome", "state"], "waiting_for_input")
         |> put_in(["outcome", "record_refs"], ["record:wait:1"])
       ), "waiting outcome requires delivery reply"},
      {Jason.encode!(put_in(valid, ["outcome", "state"], "waiting_for_input")),
       "must reference the durable"}
    ]

    Enum.each(cases, fn {encoded, expected} ->
      assert {:reject, [violation]} = Validator.validate(encoded, context(), @now)
      assert violation =~ expected
    end)

    assert {:reject, [violation]} = Validator.validate(:not_json, context(), @now)
    assert violation =~ "not valid JSON"
  end

  test "validation context rejects malformed host records before judging the model" do
    candidate = candidate(empty_outcome(), "Done.")

    cases = [
      {nil, :type},
      {%{}, :fields},
      {Map.put(context(), "visible_reply_required", "yes"), :visible_reply_required},
      {Map.put(context(), "artifact_refs", "artifact:1"), :artifact_refs},
      {Map.put(context(), "artifact_refs", ["artifact:1", "artifact:1"]), :artifact_refs},
      {Map.put(context(), "records", []), :records},
      {Map.put(context(), "records", %{"bad ref" => record("source")}), :record},
      {Map.put(context(), "records", %{"record:1" => %{"kind" => "source"}}), :record},
      {Map.put(context(), "records", %{"record:1" => record("source", "wait")}), :continuation},
      {Map.put(context(), "records", %{
         "record:1" => record("source", %{"kind" => "unknown"})
       }), :continuation}
    ]

    Enum.each(cases, fn {invalid_context, field} ->
      assert Validator.validate(candidate, invalid_context, @now) ==
               {:error, {:invalid_work_validation_context, field}}
    end)

    assert Validator.validate(candidate, context(), :not_a_datetime) ==
             {:error, {:invalid_work_validation_context, :now}}
  end

  test "waiting and complete outcomes name exactly one compatible durable wait" do
    input_wait = %{
      "deadline_at" => nil,
      "kind" => "wait",
      "wait_kind" => "input",
      "wait_ref" => "wait:input"
    }

    second_input_wait = %{input_wait | "wait_ref" => "wait:second"}

    records = %{
      "record:input:1" => record("operator_input", input_wait),
      "record:input:2" => record("operator_input", second_input_wait),
      "record:source" => record("source")
    }

    cases = [
      {empty_outcome(%{"record_refs" => ["record:input:1"]}), "complete cannot reference"},
      {empty_outcome(%{
         "record_refs" => ["record:source"],
         "state" => "waiting_for_input"
       }), "no input wait was referenced"},
      {empty_outcome(%{
         "record_refs" => ["record:source"],
         "state" => "waiting_for_event"
       }), "no event wait was referenced"},
      {empty_outcome(%{
         "record_refs" => ["record:input:1", "record:input:2"],
         "state" => "waiting_for_input"
       }), "exactly one durable input wait"},
      {empty_outcome(%{
         "record_refs" => ["record:input:1", "record:input:2"],
         "state" => "waiting_for_event"
       }), "exactly one durable event wait"}
    ]

    Enum.each(cases, fn {outcome, expected} ->
      assert {:reject, [violation]} =
               Validator.validate(candidate(outcome, "Waiting."), context(records: records), @now)

      assert violation =~ expected
    end)
  end

  test "a deliberate no-delivery result is accepted with its audited reason" do
    encoded =
      Jason.encode!(%{
        "decision_reason" => "This is the exact duplicate already handled above.",
        "delivery" => "none",
        "message" => nil,
        "outcome" => empty_outcome()
      })

    assert {:accept, accepted} = Validator.validate(encoded, context(), @now)
    assert accepted.result.delivery == :none
    assert accepted.result.decision_reason =~ "exact duplicate"
  end

  defp candidate(outcome, message) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => outcome
    })
  end

  defp empty_outcome(overrides \\ %{}) do
    Map.merge(
      %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"},
      overrides
    )
  end

  defp context(overrides \\ []) do
    overrides = Map.new(overrides)

    %{
      "artifact_refs" => Map.get(overrides, :artifacts, []),
      "records" => Map.get(overrides, :records, %{}),
      "visible_reply_required" => Map.get(overrides, :visible_reply_required, false)
    }
  end

  defp record(kind, continuation \\ nil),
    do: %{"continuation" => continuation, "kind" => kind}
end
