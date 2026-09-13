defmodule Ryker.Repo.Migrations.MeterLearningExecutions do
  use Ecto.Migration

  # Learning turns spend tokens exactly like admission and Work turns do; the
  # ledger now holds them under their frozen learning attempt.

  def up do
    drop(constraint(:execution_usage, :execution_usage_identity_valid))

    create(
      constraint(:execution_usage, :execution_usage_identity_valid,
        check:
          "kind IN ('work', 'admission', 'learning') AND execution_mode IN ('live', 'shadow') AND octet_length(generation) BETWEEN 1 AND 64"
      )
    )
  end

  def down do
    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM #{schema()}.execution_usage WHERE kind = 'learning' LIMIT 1) THEN RAISE EXCEPTION 'export learning execution accounting before rollback'; END IF; END $$"
    )

    drop(constraint(:execution_usage, :execution_usage_identity_valid))

    create(
      constraint(:execution_usage, :execution_usage_identity_valid,
        check:
          "kind IN ('work', 'admission') AND execution_mode IN ('live', 'shadow') AND octet_length(generation) BETWEEN 1 AND 64"
      )
    )
  end

  defp schema, do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}")
end
