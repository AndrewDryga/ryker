defmodule Ryker.NewestModelPricesMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.TestMigrations

  @version 20_261_121_000_300
  @anthropic "https://platform.claude.com/docs/en/about-claude/pricing"
  @openai "https://developers.openai.com/api/docs/pricing"

  # The Models page offers the models saved prices name, so Claude Fable 5.2, GPT-6.2 Astra and
  # Sol and GPT-6.1 Terra could not be chosen on an installation upgraded from one without them
  # (Andrew, 2026-11-20: "add support for all latest models"). An upgrade adds them at their
  # published prices, and a price the owner already set for one stays theirs.
  test "an upgrade offers the newest models at their published prices" do
    in_scratch_schema("newest_model_prices", fn repo, prefix ->
      migrate!(repo, prefix, TestMigrations.version_before(@version))
      assert @version in migrate!(repo, prefix, @version)

      assert newest(repo, prefix) == [
               ["claude:claude-fable-5-2", "8", "0.20", "40", ~D[2026-11-21], @anthropic],
               ["codex:gpt-6.1-terra", "1", "0.05", "5", ~D[2026-11-21], @openai],
               ["codex:gpt-6.2-astra", "8", "0.40", "40", ~D[2026-11-21], @openai],
               ["codex:gpt-6.2-sol", "2", "0.10", "10", ~D[2026-11-21], @openai]
             ]

      assert migrate!(repo, prefix, @version) == []
    end)
  end

  test "an upgrade keeps the price an owner already saved for one of the newest models" do
    in_scratch_schema("newest_model_owner_price", fn repo, prefix ->
      migrate!(repo, prefix, TestMigrations.version_before(@version))

      SQL.query!(repo, """
      INSERT INTO #{prefix}.pricing_rates
        (id, execution_target, input_usd_per_million, cached_input_usd_per_million,
         output_usd_per_million, effective_from, revision, provenance, inserted_at)
      VALUES (gen_random_uuid(), 'codex:gpt-6.2-sol', 3, 0.3, 12, '2026-11-20', 2, 'Custom rate', now())
      """)

      assert @version in migrate!(repo, prefix, @version)

      assert ["codex:gpt-6.2-sol", "3", "0.3", "12", ~D[2026-11-20], "Custom rate"] in newest(
               repo,
               prefix
             )

      assert length(newest(repo, prefix)) == 4
    end)
  end

  defp newest(repo, prefix) do
    %{rows: rows} =
      SQL.query!(repo, """
      SELECT execution_target, input_usd_per_million::text, cached_input_usd_per_million::text,
             output_usd_per_million::text, effective_from, provenance
      FROM #{prefix}.pricing_rates
      WHERE execution_target IN
        ('claude:claude-fable-5-2', 'codex:gpt-6.2-astra', 'codex:gpt-6.2-sol', 'codex:gpt-6.1-terra')
      ORDER BY execution_target
      """)

    rows
  end
end
