defmodule Ryker.CoopFleet.EnrollmentAdmissionMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_103_100_000

  test "existing enrollment tokens keep normal admission and every new token has an explicit policy" do
    assert migrate_down(@version) == :ok

    SQL.query!(Repo, """
    INSERT INTO coop_worker_enrollment_tokens
      (id, worker_id, workspace_ref, operator_ref, token_sha256, expires_at, inserted_at)
    VALUES ('8f71fc1c-078e-456e-951d-f8388681b0e1', 'migration-worker', 'workspace-main',
      'operator:migration', repeat('a', 64), now() + interval '1 hour', now())
    """)

    assert migrate_up(@version) == :ok

    assert %{rows: [[false]]} =
             SQL.query!(Repo, "SELECT stop_admission FROM coop_worker_enrollment_tokens")

    assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}}} =
             SQL.query(Repo, "UPDATE coop_worker_enrollment_tokens SET stop_admission = NULL", [],
               mode: :savepoint
             )
  end
end
