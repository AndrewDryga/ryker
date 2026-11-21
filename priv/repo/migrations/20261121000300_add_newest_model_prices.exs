defmodule Ryker.Repo.Migrations.AddNewestModelPrices do
  use Ecto.Migration

  def up do
    # The Models page offers the models saved prices name (Andrew, 2026-11-20: "add support for
    # all latest models"). Claude Fable 5.2 runs on the worker from Claude Code 2.1.330 and its
    # adapter 0.109.0; Codex's own model list offers GPT-6.2 Astra and Sol from client 0.166.0
    # and GPT-6.1 Terra from 0.153.0. Add them without replacing a price the owner already
    # supplied, or estimating old calls at rates verified only today.
    execute("""
    INSERT INTO pricing_rates
      (id, execution_target, input_usd_per_million, cached_input_usd_per_million,
       output_usd_per_million, effective_from, revision, provenance, inserted_at)
    SELECT gen_random_uuid(), rates.target, rates.input, rates.cached, rates.output,
           DATE '2026-11-21', 1, rates.provenance, now()
    FROM (VALUES
      ('claude:claude-fable-5-2', 8, 0.20, 40, 'https://platform.claude.com/docs/en/about-claude/pricing'),
      ('codex:gpt-6.2-astra', 8, 0.40, 40, 'https://developers.openai.com/api/docs/pricing'),
      ('codex:gpt-6.2-sol', 2, 0.10, 10, 'https://developers.openai.com/api/docs/pricing'),
      ('codex:gpt-6.1-terra', 1, 0.05, 5, 'https://developers.openai.com/api/docs/pricing')
    ) AS rates(target, input, cached, output, provenance)
    WHERE NOT EXISTS (SELECT 1 FROM pricing_rates saved WHERE saved.execution_target = rates.target)
    """)
  end
end
