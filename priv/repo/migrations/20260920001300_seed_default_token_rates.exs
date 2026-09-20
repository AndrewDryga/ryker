defmodule Ryker.Repo.Migrations.SeedDefaultTokenRates do
  use Ecto.Migration

  @provenance "https://developers.openai.com/api/docs/pricing"

  def up do
    execute("""
    INSERT INTO pricing_rates
      (id, execution_target, input_usd_per_million, cached_input_usd_per_million,
       output_usd_per_million, reasoning_usd_per_million, effective_from, revision,
       provenance, inserted_at)
    VALUES
      ('965d6213-adc4-40b3-8972-e654169ec25c', 'codex:gpt-5.6-sol', 4, 0.40, 20, NULL, '2026-09-05', 1, '#{@provenance}', NOW()),
      ('b974d5b1-eab3-4e53-a466-781f92fe9558', 'codex:gpt-5.6-terra', 2, 0.20, 12, NULL, '2026-09-05', 1, '#{@provenance}', NOW()),
      ('d47b779d-1768-4df7-9910-08666322d285', 'codex:gpt-5.6-luna', 0.20, 0.02, 1.20, NULL, '2026-09-05', 1, '#{@provenance}', NOW())
    ON CONFLICT (execution_target, effective_from) DO NOTHING
    """)
  end

  def down do
    execute("""
    DELETE FROM pricing_rates
    WHERE provenance = '#{@provenance}'
      AND effective_from = '2026-09-05'
      AND execution_target IN ('codex:gpt-5.6-sol', 'codex:gpt-5.6-terra', 'codex:gpt-5.6-luna')
    """)
  end
end
