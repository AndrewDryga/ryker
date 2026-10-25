defmodule Ryker.Repo.Migrations.KeepPersonFactWithdrawals do
  use Ecto.Migration

  def up do
    create table(:person_fact_withdrawals, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:person_ref, :text, null: false)
      add(:source_message_ref, :text)
      add(:withdrawn_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:person_fact_withdrawals, [:person_ref, :source_message_ref],
        nulls_distinct: false
      )
    )

    create(index(:person_fact_withdrawals, [:source_message_ref]))

    create(
      constraint(:person_fact_withdrawals, :person_fact_withdrawals_valid,
        check:
          "char_length(person_ref) BETWEEN 1 AND 1024 AND (source_message_ref IS NULL OR char_length(source_message_ref) BETWEEN 1 AND 1024)"
      )
    )

    # Earlier rows do not identify which forgetting path wrote them. Preserve
    # their known sources and conservatively retain the historical cutoff.
    # Kept profiles remain intact; erased historical tombstones are not guessed.
    execute("""
    INSERT INTO #{qualified("person_fact_withdrawals")}
      (id, person_ref, source_message_ref, withdrawn_at, inserted_at, updated_at)
    SELECT uuidv7(), person_ref, source_message_ref, withdrawn_at, clock_timestamp(), clock_timestamp()
    FROM (
      SELECT person_ref, NULL::text AS source_message_ref, max(GREATEST(said_at, forgotten_at)) AS withdrawn_at
      FROM #{qualified("person_facts")} WHERE status = 'forgotten' GROUP BY person_ref
      UNION ALL
      SELECT person_ref, source_message_ref, max(forgotten_at) AS withdrawn_at
      FROM #{qualified("person_facts")} WHERE status = 'forgotten' GROUP BY person_ref, source_message_ref
    ) AS withdrawals
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("person_fact_withdrawals")}) THEN
        RAISE EXCEPTION 'personal fact withdrawals are retained; the previous release cannot preserve them';
      END IF;
    END
    $$
    """)

    drop(table(:person_fact_withdrawals))
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
