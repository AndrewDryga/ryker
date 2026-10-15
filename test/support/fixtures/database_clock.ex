defmodule Ryker.Fixtures.DatabaseClock do
  @moduledoc false
  alias Ryker.Repo

  # Transaction-local fault injection: PostgreSQL owns persistence/cursor time,
  # while Ecto's default timestamp generator still sees the real host clock.
  # Sandbox rollback removes the function and schema; production has no clock hook.
  # The schema is named per call: async tests that created one name waited on
  # each other until the first test's transaction ended.
  def behind_host! do
    now = DateTime.add(DateTime.utc_now(), -60, :second)
    schema = "memory_test_clock_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")

    Repo.query!("""
    CREATE FUNCTION #{schema}.clock_timestamp() RETURNS timestamptz
    LANGUAGE sql STABLE AS $clock$
      SELECT '#{DateTime.to_iso8601(now)}'::timestamptz
    $clock$
    """)

    Repo.query!("SET LOCAL search_path = #{schema}, public, pg_catalog")
    %{rows: [[^now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end
end
