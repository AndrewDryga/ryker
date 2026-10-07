defmodule Ryker.CoopFleet.RetireUnusedFleetStatesMigrationTest do
  # Nothing ever placed a session as `assigning` or `draining`, no certificate
  # came from the `manual` source outside tests, and `last_command_id` was
  # written on every delivered command and never read (2026-10-04 review).
  # The migration narrows the checks and the current-placement index to what
  # exists; this holds each change and its way back.
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_007_130_000

  test "placements and certificates name only the states and sources that exist" do
    assert :ok = migrate_down(@version)
    assert "last_command_id" in columns("coop_session_placements")
    assert check("coop_session_placement_identity_valid") =~ "'assigning'::text"
    assert check("coop_worker_certificate_valid") =~ "'manual'::text"
    assert current_index() =~ "'draining'::text"
    assert state_default() == "'assigning'::text"

    assert :ok = migrate_up(@version)
    refute "last_command_id" in columns("coop_session_placements")
    assert state_default() == nil

    placement = check("coop_session_placement_identity_valid")

    for state <- ~w(active revoking replaced retired),
        do: assert(placement =~ "'#{state}'::text")

    refute placement =~ "'assigning'::text"
    refute placement =~ "'draining'::text"

    certificate = check("coop_worker_certificate_valid")
    assert certificate =~ "'enrollment'::text"
    assert certificate =~ "'renewal'::text"
    refute certificate =~ "'manual'::text"

    index = current_index()
    assert index =~ "'active'::text"
    assert index =~ "'revoking'::text"
    refute index =~ "'assigning'::text"
    refute index =~ "'draining'::text"
  end

  defp columns(table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
        [table]
      )

    List.flatten(rows)
  end

  defp check(name) do
    %{rows: [[definition]]} =
      SQL.query!(
        Repo,
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1",
        [name]
      )

    definition
  end

  defp current_index do
    %{rows: [[definition]]} =
      SQL.query!(
        Repo,
        "SELECT indexdef FROM pg_indexes WHERE indexname = 'coop_session_placements_one_current'",
        []
      )

    definition
  end

  defp state_default do
    %{rows: [[default]]} =
      SQL.query!(
        Repo,
        "SELECT column_default FROM information_schema.columns " <>
          "WHERE table_name = 'coop_session_placements' AND column_name = 'state'",
        []
      )

    default
  end
end
