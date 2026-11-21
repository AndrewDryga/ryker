defmodule Ryker.CurrentClaudePricesMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.TestMigrations

  @version 20_261_121_000_200

  # The Models page offers the models saved prices name, and installations had OpenAI's alone,
  # so no Claude model could be chosen (Andrew, 2026-11-20: "add support for all latest
  # models"). An upgrade adds them without repricing old work or overwriting an owner's price.
  test "an upgrade adds the Claude models and keeps a price the owner set" do
    in_scratch_schema("claude_prices", fn repo, prefix ->
      migrate!(repo, prefix, TestMigrations.version_before(@version))

      SQL.query!(repo, """
      INSERT INTO #{prefix}.pricing_rates
        (id, execution_target, input_usd_per_million, cached_input_usd_per_million,
         output_usd_per_million, effective_from, revision, provenance, inserted_at)
      VALUES (gen_random_uuid(), 'claude:claude-opus-5-5', 3, 0.3, 15, '2026-11-01', 4, 'Custom rate', now())
      """)

      assert @version in migrate!(repo, prefix, @version)

      %{rows: rows} =
        SQL.query!(repo, """
        SELECT execution_target, input_usd_per_million::text, cached_input_usd_per_million::text,
               output_usd_per_million::text, effective_from, provenance
        FROM #{prefix}.pricing_rates WHERE execution_target LIKE 'claude:%' ORDER BY execution_target
        """)

      assert rows == [
               [
                 "claude:claude-fable-5-1",
                 "10",
                 "0.25",
                 "50",
                 ~D[2026-11-20],
                 "https://platform.claude.com/docs/en/about-claude/pricing"
               ],
               [
                 "claude:claude-haiku-5-5",
                 "0.10",
                 "0.01",
                 "0.50",
                 ~D[2026-11-20],
                 "https://platform.claude.com/docs/en/about-claude/pricing"
               ],
               ["claude:claude-opus-5-5", "3", "0.3", "15", ~D[2026-11-01], "Custom rate"],
               [
                 "claude:claude-sonnet-5-5",
                 "2",
                 "0.10",
                 "10",
                 ~D[2026-11-20],
                 "https://platform.claude.com/docs/en/about-claude/pricing"
               ]
             ]

      assert migrate!(repo, prefix, @version) == []
    end)
  end
end
