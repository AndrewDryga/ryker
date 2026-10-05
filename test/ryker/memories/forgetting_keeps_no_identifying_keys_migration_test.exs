defmodule Ryker.Memories.ForgettingKeepsNoIdentifyingKeysMigrationTest do
  # The migrator runs inside this test's sandbox transaction, so nothing else
  # may run beside it.
  use Ryker.DataCase, async: false

  alias Ecto.Adapters.SQL

  @version 20_261_005_161_000
  @migration Ryker.Repo.Migrations.ForgettingKeepsNoIdentifyingKeys
  @file_name "20261005161000_forgetting_keeps_no_identifying_keys.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]

  # A forgotten fact kept its kind, such as "medical-leave", and a forgotten
  # topic its key and anchors (2026-10-04 review). What was forgotten before
  # keeps what a forgetting writes now; what is kept keeps its names.
  test "what was forgotten before keeps no name for what it was" do
    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)

    SQL.query!(
      Repo,
      """
      INSERT INTO person_facts
        (id, person_ref, key, fact, status, source_input_id, source_message_ref,
         conversation_ref, private, said_at, forgotten_at)
      VALUES
        (gen_random_uuid(), 'slack:user:UERIN', 'medical-leave', NULL, 'forgotten',
         gen_random_uuid(), 'slack-message:1', 'slack:TPEOPLE:CPUBLIC', false,
         '2026-10-01 08:00:00', '2026-10-02 08:00:00'),
        (gen_random_uuid(), 'slack:user:UERIN', 'birthday', 'Birthday is 2 May.', 'kept',
         gen_random_uuid(), 'slack-message:2', 'slack:TPEOPLE:CPUBLIC', false,
         '2026-10-01 08:00:00', NULL)
      """,
      []
    )

    forgotten = Ecto.UUID.generate()

    for {id, key, forgotten_at} <- [
          {forgotten, "nomad-hst01-oom", ~N[2026-10-02 08:00:00]},
          {Ecto.UUID.generate(), "checkout-readiness", nil}
        ] do
      SQL.query!(
        Repo,
        """
        INSERT INTO conversation_knowledge
          (id, scope_key, topic_key, transport, workspace_ref, conversation_ref, visibility,
           state, version, source_generation, source_dependencies, source_input_id,
           latest_source_at, inserted_at, updated_at, anchor_keys, forgotten_at)
        VALUES
          ($1::uuid, 'scope', $2, 'slack', 'TPEOPLE', 'slack:TPEOPLE:CPUBLIC', 'conversation',
           '{"retention":"pruned"}', 1, 1, '[]', gen_random_uuid(),
           '2026-10-01 08:00:00', '2026-10-01 08:00:00', '2026-10-01 08:00:00',
           ARRAY['nomad-hst01'], $3)
        """,
        [Ecto.UUID.dump!(id), key, forgotten_at]
      )
    end

    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)

    digest =
      :crypto.hash(:sha256, "slack:user:UERIN\nmedical-leave") |> Base.encode16(case: :lower)

    assert SQL.query!(Repo, "SELECT key FROM person_facts ORDER BY status").rows ==
             [["f" <> binary_part(digest, 0, 47)], ["birthday"]]

    assert SQL.query!(
             Repo,
             "SELECT topic_key, anchor_keys FROM conversation_knowledge ORDER BY forgotten_at NULLS LAST"
           ).rows == [["retired:" <> forgotten, []], ["checkout-readiness", ["nomad-hst01"]]]
  end

  # `ecto.migrate` loads a migration only while it is pending, so a database
  # migrated by an earlier run leaves it for this test to load.
  defp migration do
    unless Code.ensure_loaded?(@migration) do
      :ryker
      |> Application.app_dir(Path.join("priv/repo/migrations", @file_name))
      |> Code.compile_file()
    end

    @migration
  end
end
