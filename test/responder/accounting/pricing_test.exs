defmodule Responder.Accounting.PricingTest do
  use Responder.DataCase, async: true
  import Ecto.Query
  alias Responder.Accounting.{Execution, Query}

  test "API estimates price fresh input and cache separately but never charge reasoning twice" do
    # Codex ACP TokenCount subtracts cache from input and INCLUDES reasoning in
    # output. Adding all four counters inflated both cost and token totals.
    Repo.insert!(%Execution{
      kind: "admission",
      source_id: Ecto.UUID.generate(),
      generation: "1",
      transport: "slack",
      conversation_ref: "T1:C1",
      status: "succeeded",
      execution_mode: "live",
      recorded_at: DateTime.utc_now(),
      execution_target: "codex:gpt-5.6-sol/medium@emisar",
      usage_recorded: true,
      usage_input_tokens: 1000,
      usage_cached_input_tokens: 9000,
      usage_output_tokens: 500,
      usage_reasoning_tokens: 400
    })

    row = Repo.one!(from(e in Query.executions(nil), select: %{estimate: e.estimated_cost_usd}))
    assert Decimal.equal?(row.estimate, Decimal.new("0.0176"))
  end

  test "reported zero is authoritative and unknown models are never priced as zero" do
    for {target, reported, amount} <- [
          {"codex:gpt-5.6-terra/medium", true, Decimal.new(0)},
          {"codex:future-model/medium", false, nil},
          {"claude:gpt-5.6-sol/medium", false, nil}
        ] do
      Repo.insert!(%Execution{
        kind: "admission",
        source_id: Ecto.UUID.generate(),
        generation: "1",
        transport: "slack",
        conversation_ref: "T1:C1",
        status: "succeeded",
        execution_mode: "live",
        recorded_at: DateTime.utc_now(),
        execution_target: target,
        usage_recorded: true,
        usage_cost_recorded: reported,
        usage_cost_usd: amount,
        usage_input_tokens: 1000,
        usage_cached_input_tokens: 0,
        usage_output_tokens: 50,
        usage_reasoning_tokens: 0
      })
    end

    assert Repo.all(from(e in Query.executions(nil), select: e.estimated_cost_usd)) == [
             nil,
             nil,
             nil
           ]
  end
end
