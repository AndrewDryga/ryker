defmodule Ryker.Repo.Migrations.AddCurrentClaudePrices do
  use Ecto.Migration

  def up do
    # The Models page offers the models saved prices name, and installations started with
    # OpenAI's alone, so no Claude model could be chosen (Andrew, 2026-11-20: "add support for
    # all latest models"). Add the Claude models the worker runs without replacing any price
    # the owner already supplied, or estimating old calls using a rate verified only today.
    execute("""
    INSERT INTO pricing_rates
      (id, execution_target, input_usd_per_million, cached_input_usd_per_million,
       output_usd_per_million, effective_from, revision, provenance, inserted_at)
    SELECT gen_random_uuid(), rates.target, rates.input, rates.cached, rates.output,
           DATE '2026-11-20', 1, 'https://platform.claude.com/docs/en/about-claude/pricing', now()
    FROM (VALUES
      ('claude:claude-fable-5-1', 10, 0.25, 50),
      ('claude:claude-opus-5-5', 4, 0.20, 20),
      ('claude:claude-sonnet-5-5', 2, 0.10, 10),
      ('claude:claude-haiku-5-5', 0.10, 0.01, 0.50)
    ) AS rates(target, input, cached, output)
    WHERE NOT EXISTS (SELECT 1 FROM pricing_rates saved WHERE saved.execution_target = rates.target)
    """)
  end
end
