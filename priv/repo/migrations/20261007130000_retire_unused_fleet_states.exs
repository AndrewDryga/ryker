defmodule Ryker.Repo.Migrations.RetireUnusedFleetStates do
  use Ecto.Migration

  # Nothing ever placed a session in the `assigning` or `draining` state, and
  # no certificate came from the `manual` source outside tests: on 2026-10-07
  # no live row held one (2026-10-04 review). `last_command_id` was written on
  # every delivered command and never read. The checks and the current
  # placement index name only the states that exist, the state column no
  # longer defaults to one nothing uses, and the cursor column goes.

  @placement """
  generation > 0
    AND char_length(lease_ref) BETWEEN 1 AND 256
    AND jsonb_typeof(requirements::jsonb) = 'object'
    AND octet_length(requirements) <= 131072
    AND char_length(requirements_fingerprint) = 64
    AND last_acked_event_sequence >= 0
  """

  @certificate """
  sha256 ~ '^[0-9a-f]{64}$'
    AND char_length(serial_number) BETWEEN 1 AND 64
    AND char_length(issued_by) BETWEEN 1 AND 256
    AND expires_at > not_before
    AND ((revoked_at IS NULL AND revoked_by IS NULL)
      OR (revoked_at IS NOT NULL AND char_length(revoked_by) BETWEEN 1 AND 256))
  """

  def up do
    placement_check("'active', 'revoking', 'replaced', 'retired'")
    current_index("'active', 'revoking'")
    execute("ALTER TABLE coop_session_placements ALTER COLUMN state DROP DEFAULT")

    alter table(:coop_session_placements) do
      remove(:last_command_id)
    end

    certificate_check("'enrollment', 'renewal'")
  end

  def down do
    placement_check("'assigning', 'active', 'draining', 'revoking', 'replaced', 'retired'")
    current_index("'assigning', 'active', 'draining', 'revoking'")
    execute("ALTER TABLE coop_session_placements ALTER COLUMN state SET DEFAULT 'assigning'")

    alter table(:coop_session_placements) do
      add(:last_command_id, :uuid)
    end

    certificate_check("'enrollment', 'renewal', 'manual'")
  end

  defp placement_check(states) do
    execute(
      "ALTER TABLE coop_session_placements DROP CONSTRAINT coop_session_placement_identity_valid"
    )

    execute("""
    ALTER TABLE coop_session_placements ADD CONSTRAINT coop_session_placement_identity_valid
      CHECK (#{@placement} AND state IN (#{states}))
    """)
  end

  defp current_index(states) do
    execute("DROP INDEX coop_session_placements_one_current")

    execute("""
    CREATE UNIQUE INDEX coop_session_placements_one_current
      ON coop_session_placements (session_id) WHERE state IN (#{states})
    """)
  end

  defp certificate_check(sources) do
    execute("ALTER TABLE coop_worker_certificates DROP CONSTRAINT coop_worker_certificate_valid")

    execute("""
    ALTER TABLE coop_worker_certificates ADD CONSTRAINT coop_worker_certificate_valid
      CHECK (#{@certificate} AND source IN (#{sources}))
    """)
  end
end
