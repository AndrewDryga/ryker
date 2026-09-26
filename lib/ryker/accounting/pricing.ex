defmodule Ryker.Accounting.Pricing do
  @moduledoc """
  Cost estimates from the prices saved in Settings › Model prices, for work
  whose provider reported no cost. An estimate is an API-equivalent figure,
  never a provider-reported charge or a subscription bill.

  A call is priced at the latest price saved for its provider and model (its
  effort and profile removed) that took effect on or before the UTC day it
  was recorded, so a new price never reaches back to earlier work. A model no
  saved price covers stays unpriced rather than free.
  """
  import Ecto.Query
  alias Ryker.Repo
  alias Ryker.Settings.PricingRate

  # The prices a new installation starts with; after that the saved prices
  # are the only ones any estimate reads.
  # Verified 2026-09-05: https://developers.openai.com/api/docs/pricing
  # Codex ACP src/TokenCount.ts reports fresh input separately from cache reads;
  # output includes reasoning, so these carry no reasoning price. Turns can
  # contain several provider calls. Their context lengths, cache writes,
  # service tiers and tool fees are unavailable, so these are baseline
  # estimates at this rate-card date, not historical invoices.
  @defaults %{
    "codex:gpt-5.6-sol" => {"4", "0.40", "20"},
    "codex:gpt-5.6-terra" => {"2", "0.20", "12"},
    "codex:gpt-5.6-luna" => {"0.20", "0.02", "1.20"}
  }
  @effective_from ~D[2026-09-05]
  @provenance "https://developers.openai.com/api/docs/pricing"

  @doc "The prices a new installation's Model prices start with."
  def settings_defaults do
    Enum.map(@defaults, fn {target, {input, cached, output}} ->
      %{
        execution_target: target,
        input_usd_per_million: Decimal.new(input),
        cached_input_usd_per_million: Decimal.new(cached),
        output_usd_per_million: Decimal.new(output),
        effective_from: @effective_from,
        provenance: @provenance
      }
    end)
  end

  @doc """
  The ledger with each execution's estimate (`estimated_cost_usd`) and the
  saved price in effect for it (`pricing_rate_id`). The estimate is nil when
  the provider reported a cost, no usage was recorded, a token count is
  negative or missing, or no saved price covers the model on that day.
  """
  def enrich(query) do
    price =
      in_effect_query(
        dynamic(parent_as(:execution).execution_target),
        dynamic(fragment("(?)::date", parent_as(:execution).recorded_at))
      )

    # Input, cache reads and output at their prices, per million tokens.
    # Reasoning is charged only at a reasoning price of its own: Codex and
    # Claude count it in output, so their prices leave it empty.
    query =
      from(e in query,
        as: :execution,
        left_lateral_join: p in subquery(price),
        on: true,
        select_merge: %{
          estimated_cost_usd:
            fragment(
              "CASE WHEN ? IS NOT NULL AND ? AND NOT ? AND ? >= 0 AND ? >= 0 AND ? >= 0 AND (? IS NULL OR ? >= 0) THEN (? * ? + ? * ? + ? * ? + COALESCE(? * ?, 0)) / 1000000 END",
              p.id,
              e.usage_recorded,
              e.usage_cost_recorded,
              e.usage_input_tokens,
              e.usage_cached_input_tokens,
              e.usage_output_tokens,
              p.reasoning_usd_per_million,
              e.usage_reasoning_tokens,
              e.usage_input_tokens,
              p.input_usd_per_million,
              e.usage_cached_input_tokens,
              p.cached_input_usd_per_million,
              e.usage_output_tokens,
              p.output_usd_per_million,
              e.usage_reasoning_tokens,
              p.reasoning_usd_per_million
            ),
          pricing_rate_id: p.id
        }
      )

    from(e in subquery(query))
  end

  @doc "The saved prices that made at least one estimate in an enriched ledger query."
  @spec used(Ecto.Queryable.t()) :: [PricingRate.t()]
  def used(executions) do
    ids =
      from(e in executions, where: not is_nil(e.estimated_cost_usd), select: e.pricing_rate_id)

    Repo.all(
      from(p in PricingRate,
        where: p.id in subquery(ids),
        order_by: [p.execution_target, p.effective_from]
      )
    )
  end

  @doc """
  The saved price in effect for one call to `target` on `day`, by the same
  rule as the ledger, or nil when no saved price covers it.
  """
  @spec in_effect(String.t(), Date.t()) :: PricingRate.t() | nil
  def in_effect(target, %Date{} = day) when is_binary(target),
    do: Repo.one(in_effect_query(dynamic(type(^target, :string)), dynamic(type(^day, :date))))

  @doc """
  What one call's tokens cost at a saved price, in US dollars, by the same
  arithmetic as the ledger: fresh input, cache reads and output at their
  prices, and reasoning only at a reasoning price of its own.
  """
  @spec estimate(PricingRate.t(), map()) :: Decimal.t()
  def estimate(%PricingRate{} = price, usage) do
    [
      {usage.input, price.input_usd_per_million},
      {usage.cached, price.cached_input_usd_per_million},
      {usage.output, price.output_usd_per_million},
      {usage.reasoning, price.reasoning_usd_per_million}
    ]
    |> Enum.reject(fn {_count, rate} -> is_nil(rate) end)
    |> Enum.reduce(Decimal.new(0), fn {count, rate}, sum ->
      Decimal.add(sum, Decimal.mult(count || 0, rate))
    end)
    |> Decimal.div(1_000_000)
  end

  # The one rule for which saved price covers a call: the price saved for its
  # provider and model, without `/effort` or `@profile`, with the latest
  # effective day on or before the day the call was recorded.
  defp in_effect_query(target, day) do
    model = dynamic(fragment("split_part(split_part(?, '@', 1), '/', 1)", ^target))

    from(p in PricingRate,
      where: ^dynamic([p], p.execution_target == ^model and p.effective_from <= ^day),
      order_by: [desc: p.effective_from],
      limit: 1
    )
  end

  def label(%{estimated: count}) when count > 0, do: "Cost · includes estimates"
  def label(_), do: "Reported cost"

  def amount(row) do
    count = Map.get(row, :costed, 0) + Map.get(row, :estimated, 0)

    if count > 0 do
      cost = Decimal.add(row.cost_usd || 0, Map.get(row, :estimated_cost_usd) || 0)
      prefix = if Map.get(row, :estimated, 0) > 0, do: "≈ $", else: "$"
      prefix <> Decimal.to_string(Decimal.round(cost, 4), :normal)
    else
      "Not measured"
    end
  end
end
