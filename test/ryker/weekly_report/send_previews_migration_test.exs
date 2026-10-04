defmodule Ryker.WeeklyReport.SendPreviewsMigrationTest do
  @moduledoc """
  V17, 2026-09-28: Settings › Weekly report can send the report to its
  channel at once as a preview. A preview is a `weekly_reports` row outside
  the one-report-per-week index, so the week's report still posts after one.
  Every report already on record stays the week's report, and rolling back
  refuses while a preview would read as a week already sent.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @previous_version 20_260_929_010_000
  @version 20_260_929_020_000

  test "a preview is never the week's report, and rolling back waits until none is on record" do
    repo = start_migration_repo!()
    prefix = "report_previews_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :up,
        to: @previous_version,
        prefix: prefix,
        log: false
      )

      sent = report!(repo, prefix, "weekly-report:2026-10-05", [])

      assert @version in Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :up,
               to: @version,
               prefix: prefix,
               log: false
             )

      assert preview?(repo, prefix, sent) == false

      # Any number of previews in the week that already has its report.
      first = report!(repo, prefix, "weekly-report-preview:1", preview: true)
      _second = report!(repo, prefix, "weekly-report-preview:2", preview: true)
      assert preview?(repo, prefix, first)

      # Still one report per week.
      assert_raise Postgrex.Error, ~r/weekly_reports_week_index/, fn ->
        report!(repo, prefix, "weekly-report:again", [])
      end

      assert_raise Postgrex.Error, ~r/previews are on record/, fn ->
        Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :down,
          step: 1,
          prefix: prefix,
          log: false
        )
      end

      SQL.query!(repo, "DELETE FROM #{prefix}.weekly_reports WHERE preview", [])

      assert Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@version]

      assert_raise Postgrex.Error, ~r/weekly_reports_week_index/, fn ->
        report!(repo, prefix, "weekly-report:again", [])
      end
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  defp report!(repo, prefix, delivery_ref, options) do
    id = Ecto.UUID.generate()
    at = ~N[2026-10-05 09:00:00.000000]
    {columns, values} = if options[:preview], do: {", preview", ", true"}, else: {"", ""}

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.weekly_reports
        (id, week, due_at, period_start, timezone, delivery_ref, transport, conversation_ref,
         document, inserted_at, updated_at#{columns})
      VALUES ($1, '2026-10-05', $2, $3, 'Etc/UTC', $4, 'slack', 'slack:T1:C1',
              '{"message":"Weekly update"}', $2, $2#{values})
      """,
      [Ecto.UUID.dump!(id), at, NaiveDateTime.add(at, -7, :day), delivery_ref]
    )

    id
  end

  defp preview?(repo, prefix, id) do
    %{rows: [[preview]]} =
      SQL.query!(repo, "SELECT preview FROM #{prefix}.weekly_reports WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    preview
  end

  defp start_migration_repo! do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end
end
