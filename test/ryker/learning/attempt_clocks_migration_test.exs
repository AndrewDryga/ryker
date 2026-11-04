defmodule Ryker.Learning.AttemptClocksMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @captured ~w(batch_key generation status inputs source_dependencies knowledge omissions policy
    policy_digest prompt prompt_sha256 output_schema producer)

  for {version, clock} <- [
        {20_261_104_050_000, "submit_started_at"},
        {20_261_104_061_000, "create_window_started_at"}
      ] do
    # Resource waits outlived the original execution window. An upgrade must
    # not invent a later start for an attempt whose actual send time is unknown.
    test "historical evidence survives adding #{clock} without an invented clock" do
      assert migrate_down(unquote(version)) == :ok
      raw = captured_run()
      id = Ecto.UUID.dump!(raw["id"])
      original_start = NaiveDateTime.from_iso8601!(raw["inserted_at"])
      fields = ["id" | @captured] ++ ~w(started_at submit_revision inserted_at updated_at)

      values =
        [id | Enum.map(@captured, &Map.fetch!(raw, &1))] ++
          [original_start, 1, original_start, original_start]

      placeholders = Enum.map_join(1..length(fields), ",", &"$#{&1}")

      SQL.query!(
        Repo,
        "INSERT INTO conversation_learning_runs (#{Enum.join(fields, ",")}) VALUES (#{placeholders})",
        values
      )

      evidence = "started_at,submit_revision,prompt,prompt_sha256,producer"

      %{rows: [before]} =
        SQL.query!(Repo, "SELECT #{evidence} FROM conversation_learning_runs WHERE id=$1", [id])

      assert migrate_up(unquote(version)) == :ok

      assert %{rows: [after_upgrade]} =
               SQL.query!(
                 Repo,
                 "SELECT #{evidence},#{unquote(clock)} FROM conversation_learning_runs WHERE id=$1",
                 [id]
               )

      assert after_upgrade == before ++ [nil]

      clock = ~N[2026-11-04 05:00:00.123456]

      SQL.query!(Repo, "UPDATE conversation_learning_runs SET #{unquote(clock)}=$1 WHERE id=$2", [
        clock,
        id
      ])

      assert %{rows: [[^clock]]} =
               SQL.query!(
                 Repo,
                 "SELECT #{unquote(clock)} FROM conversation_learning_runs WHERE id=$1",
                 [id]
               )
    end
  end

  defp captured_run do
    "testdata/learning/retained-output-contract-failure.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("learning_run")
  end
end
