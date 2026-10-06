defmodule Ryker.Memories.ForgettingKeepsNoIdentifyingKeysMigrationTest do
  use Ryker.MigrationCase
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ecto.Adapters.SQL

  @version 20_261_005_161_000

  # A forgotten fact kept its kind, such as "medical-leave", and a forgotten
  # topic its key and anchors (2026-10-04 review). What was forgotten before
  # keeps what a forgetting writes now; what is kept keeps its names.
  test "what was forgotten before keeps no name for what it was" do
    assert :ok = migrate_down(@version)

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

    assert :ok = migrate_up(@version)

    digest =
      digest("slack:user:UERIN\nmedical-leave")

    assert SQL.query!(Repo, "SELECT key FROM person_facts ORDER BY status").rows ==
             [["f" <> binary_part(digest, 0, 47)], ["birthday"]]

    assert SQL.query!(
             Repo,
             "SELECT topic_key, anchor_keys FROM conversation_knowledge ORDER BY forgotten_at NULLS LAST"
           ).rows == [["retired:" <> forgotten, []], ["checkout-readiness", ["nomad-hst01"]]]
  end
end
