defmodule Ryker.CurrentCodexPricesMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.TestMigrations

  @version 20_261_025_210_000

  # Existing installations had only 5.6 prices, which also hid all newer
  # models from the picker. An upgrade must add choices without repricing
  # old work or overwriting an owner's price.
  test "an upgrade adds missing models and preserves an existing custom price" do
    in_scratch_schema("codex_prices", fn repo, prefix ->
      migrate!(repo, prefix, TestMigrations.version_before(@version))

      SQL.query!(repo, """
      INSERT INTO #{prefix}.pricing_rates
        (id, execution_target, input_usd_per_million, cached_input_usd_per_million,
         output_usd_per_million, effective_from, revision, provenance, inserted_at)
      VALUES (gen_random_uuid(), 'codex:gpt-6-sol', 3, 0.3, 15, '2026-10-01', 7, 'Custom rate', now())
      """)

      assert @version in migrate!(repo, prefix, @version)

      %{rows: rows} =
        SQL.query!(repo, """
        SELECT execution_target, input_usd_per_million::text, effective_from, revision, provenance
        FROM #{prefix}.pricing_rates WHERE execution_target LIKE 'codex:gpt-6%' ORDER BY execution_target
        """)

      assert length(rows) == 4
      assert ["codex:gpt-6-sol", "3", ~D[2026-10-01], 7, "Custom rate"] in rows

      for [target, _input, day, revision, provenance] <- rows, target != "codex:gpt-6-sol" do
        assert day == ~D[2026-10-25]
        assert revision == 1
        assert provenance == "https://developers.openai.com/api/docs/pricing"
      end

      assert migrate!(repo, prefix, @version) == []
    end)
  end
end
