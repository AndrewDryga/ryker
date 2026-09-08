defmodule Responder.Fixtures.DatabaseClock do
  @moduledoc false
  alias Responder.Repo

  # Transaction-local fault injection: PostgreSQL owns persistence/cursor time,
  # while Ecto's default timestamp generator still sees the real host clock.
  # Sandbox rollback removes the function and schema; production has no clock hook.
  def behind_host! do
    now = DateTime.add(DateTime.utc_now(), -60, :second)
    Repo.query!("CREATE SCHEMA memory_test_clock")

    Repo.query!("""
    CREATE FUNCTION memory_test_clock.clock_timestamp() RETURNS timestamptz
    LANGUAGE sql STABLE AS $clock$
      SELECT '#{DateTime.to_iso8601(now)}'::timestamptz
    $clock$
    """)

    Repo.query!("SET LOCAL search_path = memory_test_clock, public, pg_catalog")
    %{rows: [[^now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end
end
