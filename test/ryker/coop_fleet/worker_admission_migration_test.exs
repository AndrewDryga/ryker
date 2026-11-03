defmodule Ryker.CoopFleet.WorkerAdmissionMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_103_090_000

  test "existing workers keep admission and stopped admission requires a complete operator receipt" do
    assert migrate_down(@version) == :ok

    SQL.query!(Repo, """
    INSERT INTO coop_workers
      (id, workspace_ref, certificate_sha256, state, inserted_at, updated_at)
    VALUES ('admission-migration', 'workspace-main', repeat('a', 64), 'offline', now(), now())
    """)

    assert migrate_up(@version) == :ok

    assert %{rows: [[nil, nil]]} =
             SQL.query!(Repo, """
             SELECT admission_stopped_at, admission_stopped_by
             FROM coop_workers WHERE id = 'admission-migration'
             """)

    for assignments <- [
          "admission_stopped_at = now()",
          "admission_stopped_by = 'operator:cutover'",
          "admission_stopped_at = now(), admission_stopped_by = ''"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{constraint: "coop_worker_admission_valid"}}} =
               SQL.query(
                 Repo,
                 "UPDATE coop_workers SET #{assignments} WHERE id = 'admission-migration'",
                 [],
                 mode: :savepoint
               )
    end

    assert %{num_rows: 1} =
             SQL.query!(Repo, """
             UPDATE coop_workers
             SET admission_stopped_at = now(), admission_stopped_by = 'operator:cutover'
             WHERE id = 'admission-migration'
             """)
  end
end
