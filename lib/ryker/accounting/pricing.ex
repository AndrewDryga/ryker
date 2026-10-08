defmodule Ryker.Accounting.Pricing do
  @moduledoc """
  Cost estimates from the prices saved in Settings › Model prices, for work
  whose provider reported no cost. An estimate is an API-equivalent figure,
  never a provider-reported charge or a subscription bill.

  A call is priced at the latest price saved for its provider and model (its
  effort and account removed) that took effect on or before the UTC day it
  was recorded, so a new price never reaches back to earlier work. A model no
  saved price covers stays unpriced rather than free.
  """
  alias Ryker.Accounting.Execution
  alias Ryker.Repo
  alias Ryker.Settings

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

  @doc "The saved prices that made at least one estimate in an enriched ledger query."
  @spec used(Ecto.Queryable.t()) :: [Settings.PricingRate.t()]
  def used(ledger) do
    ledger
    |> Execution.Query.priced_rate_ids()
    |> Settings.PricingRate.Query.by_ids()
    |> Settings.PricingRate.Query.ordered_by_target()
    |> Repo.all()
  end

  @doc """
  The saved price in effect for one call to `target` on `day`, by the same
  rule as the ledger, or `{:error, :not_found}` when no saved price covers it.
  """
  @spec fetch_in_effect(String.t(), Date.t()) ::
          {:ok, Settings.PricingRate.t()} | {:error, :not_found}
  def fetch_in_effect(target, %Date{} = day) when is_binary(target),
    do: target |> Settings.PricingRate.Query.in_effect(day) |> Repo.fetch()

  @doc """
  What one call's tokens cost at a saved price, in US dollars, by the same
  arithmetic as the ledger: fresh input, cache reads and output at their
  prices, and reasoning only at a reasoning price of its own.
  """
  @spec estimate(Settings.PricingRate.t(), map()) :: Decimal.t()
  def estimate(%Settings.PricingRate{} = rate, usage) do
    [
      {usage.input, rate.input_usd_per_million},
      {usage.cached, rate.cached_input_usd_per_million},
      {usage.output, rate.output_usd_per_million},
      {usage.reasoning, rate.reasoning_usd_per_million}
    ]
    |> Enum.reject(fn {_count, rate} -> is_nil(rate) end)
    |> Enum.reduce(Decimal.new(0), fn {count, rate}, sum ->
      Decimal.add(sum, Decimal.mult(count || 0, rate))
    end)
    |> Decimal.div(1_000_000)
  end
end
