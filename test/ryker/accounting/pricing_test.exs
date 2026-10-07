defmodule Ryker.Accounting.PricingTest do
  # Prices are saved through Settings, whose writes hold its lock until the
  # test ends, so these run apart from the asynchronous suites.
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ryker.Accounting.Execution
  alias Ryker.Settings

  @actor "control-plane:local"
  @sol "codex:gpt-5.6-sol/medium@emisar"

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

    row =
      Repo.one!(from(e in Execution.Query.ledger(nil), select: %{estimate: e.estimated_cost_usd}))

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

    assert Repo.all(from(e in Execution.Query.ledger(nil), select: e.estimated_cost_usd)) == [
             nil,
             nil,
             nil
           ]
  end

  # Found in manual testing on 2026-09-26: edits to Model prices never changed
  # any estimate. Usage & cost priced every execution from rates compiled into
  # Ryker, so a price corrected in Settings changed nothing anyone could see.
  test "usage estimates follow an edited saved price" do
    {:ok, snapshot} = Settings.initialize(@actor)
    execution = execution!(@sol, ~U[2026-09-24 12:00:00.000000Z])
    assert_estimate(execution, "0.0176")

    sol = Enum.find(snapshot.pricing_rates, &(&1.execution_target == "codex:gpt-5.6-sol"))
    save_price!(%{id: sol.id, output_usd_per_million: "30"})

    # 1,000 fresh × $4 + 9,000 cached × $0.40 + 500 out × $30, per million.
    assert_estimate(execution, "0.0226")
  end

  # Found in manual testing on 2026-09-26: edits to Model prices never changed
  # any estimate. A new price has to start on its own day: repricing the
  # month before it would rewrite spend already reported.
  test "a price from a later day leaves earlier executions at the price before it" do
    Settings.initialize(@actor)

    save_price!(%{
      execution_target: "codex:gpt-5.6-sol",
      input_usd_per_million: "4",
      cached_input_usd_per_million: "0.40",
      output_usd_per_million: "40",
      effective_from: "2026-09-20",
      provenance: "https://developers.openai.com/api/docs/pricing"
    })

    before = execution!(@sol, ~U[2026-09-19 23:59:59.999999Z])
    from_day = execution!(@sol, ~U[2026-09-20 00:00:00.000000Z])
    before_any_price = execution!(@sol, ~U[2026-09-04 23:59:59.999999Z])

    # The price saved from 5 Sep: $4, $0.40 and $20 per million.
    assert_estimate(before, "0.0176")
    # The price from 20 Sep charges $40 for output.
    assert_estimate(from_day, "0.0276")
    assert estimate(before_any_price) == nil
  end

  # Found in manual testing on 2026-09-26: edits to Model prices never changed
  # any estimate. A price added for a newly signed-in provider left all of its
  # work unpriced, although Settings said Ryker uses these prices to estimate.
  test "a price saved for a new provider prices that provider's executions" do
    Settings.initialize(@actor)
    claude = execution!("claude:claude-sonnet-5/high@default", ~U[2026-09-26 09:00:00.000000Z])
    assert estimate(claude) == nil

    save_price!(%{
      execution_target: "claude:claude-sonnet-5",
      input_usd_per_million: "3",
      cached_input_usd_per_million: "0.30",
      output_usd_per_million: "15",
      effective_from: "2026-09-26",
      provenance: "https://www.anthropic.com/pricing"
    })

    # 1,000 × $3 + 9,000 × $0.30 + 500 × $15; its reasoning is already output.
    assert_estimate(claude, "0.0132")
  end

  # Found in manual testing on 2026-09-26: edits to Model prices never changed
  # any estimate, and a saved reasoning price was never charged at all. It is
  # for a provider that bills reasoning apart from output; Codex and Claude
  # count reasoning in output, so theirs stays empty and is never charged twice.
  test "reasoning is charged only at a reasoning price of its own" do
    Settings.initialize(@actor)

    save_price!(%{
      execution_target: "acme:reasoner",
      input_usd_per_million: "1",
      cached_input_usd_per_million: "0.10",
      output_usd_per_million: "2",
      reasoning_usd_per_million: "10",
      effective_from: "2026-09-01",
      provenance: "acme price list"
    })

    execution = execution!("acme:reasoner/high", ~U[2026-09-26 09:00:00.000000Z])

    # 1,000 × $1 + 9,000 × $0.10 + 500 × $2 + 400 reasoning × $10.
    assert_estimate(execution, "0.0069")
  end

  defp execution!(target, recorded_at) do
    Repo.insert!(%Execution{
      kind: "admission",
      source_id: Ecto.UUID.generate(),
      generation: "1",
      transport: "slack",
      conversation_ref: "T1:C1",
      status: "succeeded",
      execution_mode: "live",
      recorded_at: recorded_at,
      execution_target: target,
      usage_recorded: true,
      usage_input_tokens: 1000,
      usage_cached_input_tokens: 9000,
      usage_output_tokens: 500,
      usage_reasoning_tokens: 400
    })
  end

  defp save_price!(attributes) do
    revision = Settings.fetch!().installation.revision
    {:ok, snapshot} = Settings.put_pricing_rate(attributes, revision, @actor)
    snapshot
  end

  defp estimate(execution) do
    Repo.one!(
      from(e in Execution.Query.ledger(nil),
        where: e.id == ^execution.id,
        select: e.estimated_cost_usd
      )
    )
  end

  defp assert_estimate(execution, expected) do
    actual = estimate(execution)

    assert actual && Decimal.equal?(actual, Decimal.new(expected)),
           "expected an estimate of $#{expected}, got #{inspect(actual)}"
  end
end
