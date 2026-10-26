defmodule Ryker.Repo.Migrations.AddCurrentCodexPrices do
  use Ecto.Migration

  def up do
    # The model picker offers saved prices. Add the current models on existing
    # installs without replacing any price the owner already supplied, or
    # estimating old calls using a rate verified only on this day.
    execute("""
    INSERT INTO pricing_rates
      (id, execution_target, input_usd_per_million, cached_input_usd_per_million,
       output_usd_per_million, effective_from, revision, provenance, inserted_at)
    SELECT gen_random_uuid(), rates.target, rates.input, rates.cached, rates.output,
           DATE '2026-10-25', 1, 'https://developers.openai.com/api/docs/pricing', now()
    FROM (VALUES
      ('codex:gpt-6.1-sol', 2, 0.10, 10),
      ('codex:gpt-6-astra', 10, 1, 50),
      ('codex:gpt-6-sol', 2, 0.20, 10),
      ('codex:gpt-6-luna', 0.10, 0.01, 0.50)
    ) AS rates(target, input, cached, output)
    WHERE NOT EXISTS (SELECT 1 FROM pricing_rates saved WHERE saved.execution_target = rates.target)
    """)
  end
end
