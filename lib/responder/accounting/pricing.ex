defmodule Responder.Accounting.Pricing do
  @moduledoc "Standard-context API-equivalent estimates, never provider-reported charges."
  import Ecto.Query

  # Verified 2026-09-05: https://developers.openai.com/api/docs/pricing
  # Codex ACP src/TokenCount.ts reports fresh input separately from cache reads;
  # output includes reasoning. Do not add thoughtTokens a second time.
  # Turns can contain several provider calls. Their context lengths, cache writes,
  # service tiers and tool fees are unavailable, so these are baseline estimates
  # at this rate-card date, not historical invoices or subscription charges.
  @rates %{
    "codex:gpt-5.6-sol" => {"4", "0.40", "20"},
    "codex:gpt-5.6-terra" => {"2", "0.20", "12"},
    "codex:gpt-5.6-luna" => {"0.20", "0.02", "1.20"}
  }

  def rates, do: @rates

  def enrich(query) do
    estimate =
      Enum.reduce(@rates, dynamic([_], fragment("NULL::numeric")), fn {target,
                                                                       {input, cached, output}},
                                                                      rest ->
        input = Decimal.new(input)
        cached = Decimal.new(cached)
        output = Decimal.new(output)

        dynamic(
          [e],
          fragment(
            "CASE WHEN split_part(split_part(?, '@', 1), '/', 1) = ? AND ? AND NOT ? AND ? >= 0 AND ? >= 0 AND ? >= 0 THEN (? * ?::numeric + ? * ?::numeric + ? * ?::numeric) / 1000000 ELSE ? END",
            e.execution_target,
            ^target,
            e.usage_recorded,
            e.usage_cost_recorded,
            e.usage_input_tokens,
            e.usage_cached_input_tokens,
            e.usage_output_tokens,
            e.usage_input_tokens,
            ^input,
            e.usage_cached_input_tokens,
            ^cached,
            e.usage_output_tokens,
            ^output,
            ^rest
          )
        )
      end)

    fields = %{estimated_cost_usd: estimate}
    from(e in subquery(select_merge(query, ^fields)))
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
