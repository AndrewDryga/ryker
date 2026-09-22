defmodule Ryker.Repo.Migrations.BackfillDefaultTokenRates do
  use Ecto.Migration

  @provenance "https://developers.openai.com/api/docs/pricing"

  def up do
    table = rates_table()

    execute("""
    INSERT INTO #{table}
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

  # This is a repair migration for installations that had already recorded
  # the original seed version without the reference rows. A rollback must not
  # delete rates an operator may since have reviewed or changed.
  def down, do: :ok

  defp rates_table,
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}".pricing_rates)
end
