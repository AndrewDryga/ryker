defmodule Ryker.Repo.Migrations.StoreOldestSourceOfSummaries do
  @moduledoc """
  Retention prunes a summary or rollup once any source it was written from is
  past its time, and found those by expanding every row's sources each minute:
  1.5 s of each minute on the tenant install with nothing to prune, growing
  with what each topic cites (2026-11-04).

  A row's sources do not change without the row changing: a reference to a topic
  pins the version it read. So the oldest is stored on the row and indexed, and
  a pass reads only the rows it prunes. A clock that is not a valid UTC time
  never counted as expired, and does not here. A pruned row keeps no sources, so
  it has no oldest and leaves the index.
  """
  use Ecto.Migration

  # `Ryker.Learning.LearningSources.utc_timestamp_pattern/0`.
  @utc_timestamp ~S/\A[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])[T ]([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]([.,][0-9]+)?(Z|[+]00(:?00)?|-00(00)?)\Z/
  @tables ~w(conversation_summaries conversation_rollups)

  def up do
    execute("""
    CREATE FUNCTION #{qualified("ryker_oldest_source_at")}(dependencies text)
    RETURNS timestamptz LANGUAGE sql STABLE AS $$
      SELECT min(CASE WHEN receipt->>'retained_at' ~ '#{@utc_timestamp}'
        AND pg_input_is_valid(replace(receipt->>'retained_at', ',', '.'), 'timestamptz')
        THEN replace(receipt->>'retained_at', ',', '.')::timestamptz END)
      FROM #{qualified("ryker_learning_roots")}(dependencies) receipt
    $$
    """)

    execute("""
    CREATE FUNCTION #{qualified("ryker_keep_oldest_source_at")}()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      NEW.oldest_source_at := #{qualified("ryker_oldest_source_at")}(NEW.source_dependencies);
      RETURN NEW;
    END
    $$
    """)

    for table <- @tables do
      execute("""
      UPDATE #{table} SET source_dependencies = '[]'
      WHERE state::jsonb = '{"retention":"pruned"}'::jsonb
        AND source_dependencies IS DISTINCT FROM '[]'
      """)

      alter table(table) do
        add(:oldest_source_at, :timestamptz)
      end

      execute(
        "UPDATE #{table} SET oldest_source_at = #{qualified("ryker_oldest_source_at")}(source_dependencies)"
      )

      create(
        index(table, [:oldest_source_at, :id],
          name: :"#{table}_oldest_source",
          where: "oldest_source_at IS NOT NULL"
        )
      )

      execute("""
      CREATE TRIGGER ryker_keep_oldest_source_at
      BEFORE INSERT OR UPDATE OF source_dependencies ON #{table}
      FOR EACH ROW EXECUTE FUNCTION #{qualified("ryker_keep_oldest_source_at")}()
      """)
    end
  end

  def down do
    for table <- @tables do
      execute("DROP TRIGGER ryker_keep_oldest_source_at ON #{table}")
      drop(index(table, [], name: :"#{table}_oldest_source"))

      alter table(table) do
        remove(:oldest_source_at)
      end
    end

    execute("DROP FUNCTION #{qualified("ryker_keep_oldest_source_at")}()")
    execute("DROP FUNCTION #{qualified("ryker_oldest_source_at")}(text)")
  end

  defp qualified(name),
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}"."#{name}")
end
