defmodule Ryker.RepoTest do
  use ExUnit.Case, async: true
  alias Ryker.Repo

  # Every column is `timestamp without time zone` holding UTC, and SQL compares them with
  # now() and clock_timestamp(), which PostgreSQL reads in the session's zone. Against a
  # server in another zone every lease and retention horizon shifted by its offset
  # (2026-10-04 review); the Compose database happens to run in UTC.
  test "every connection talks UTC to PostgreSQL, whatever zone its configuration names" do
    configured = Keyword.put(Repo.config(), :parameters, timezone: "America/New_York")
    assert {:ok, config} = Repo.init(:runtime, configured)

    {:ok, connection} =
      config
      |> Keyword.drop([:pool, :pool_size, :name])
      |> Keyword.put(:pool_size, 1)
      |> Postgrex.start_link()

    assert %{rows: [["UTC"]]} = Postgrex.query!(connection, "SHOW TIME ZONE", [])
    GenServer.stop(connection)
  end

  test "a lost concurrent transaction is a conflict and an exhausted budget, a timeout only the latter" do
    for code <- [:serialization_failure, :deadlock_detected] do
      assert Repo.conflict?(postgres_error(code))
      assert Repo.budget_exhausted?(postgres_error(code))
    end

    for code <- [:query_canceled, :lock_not_available] do
      refute Repo.conflict?(postgres_error(code))
      assert Repo.budget_exhausted?(postgres_error(code))
    end

    refute Repo.conflict?(postgres_error(:unique_violation))
    refute Repo.budget_exhausted?(postgres_error(:unique_violation))
    refute Repo.conflict?(%RuntimeError{message: "not a database error"})
  end

  defp postgres_error(code), do: %Postgrex.Error{postgres: %{code: code}}
end
