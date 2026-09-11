defmodule Responder.Repo.Migrations.RecordCoopSessionEvidence do
  use Ecto.Migration

  def up do
    # One worker-exported account of a remote session: the network posture it was
    # admitted under, what its runs were observed doing, and the host-approved
    # Coop task bound into its workspace.
    #
    # A worker keeps no transition ledger, so this is a series of snapshots, not a
    # history it can be asked for. Recording keys on the content fingerprint --
    # the capture minus its capture time -- so a poll that found nothing changed
    # updates the times on the state it already recorded instead of manufacturing
    # a history of identical rows, while a genuinely changed session records a new
    # one. That is also what makes ingestion idempotent under redelivery.
    #
    # The document is the exact validated export. It is stored whole because every
    # section states its own availability, and splitting it into columns is how
    # "the registry was unreadable" quietly becomes "no denials".
    create table(:coop_session_evidence, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :session_id,
        references(:episode_work_sessions, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :episode_id,
        references(:episode_kernel_episodes, type: :binary_id, on_delete: :delete_all)
      )

      add(:coop_session_id, :text, null: false)
      add(:worker_id, :text, null: false)
      add(:placement_generation, :bigint, null: false)
      add(:evidence_version, :integer, null: false)
      add(:content_fingerprint, :text, null: false)
      # Canonical JSON text, like every other frozen document here: JSONB would
      # normalize the unsigned decimal strings the collector's counters use, and a
      # counter above 2^53 is exactly the value that must not be normalized.
      add(:document, :text, null: false)
      add(:session_revision, :bigint, null: false)
      add(:session_state, :text, null: false)
      add(:network_mode, :text, null: false)
      add(:task_status, :text, null: false)
      add(:first_captured_at, :utc_datetime_usec, null: false)
      add(:last_captured_at, :utc_datetime_usec, null: false)
      add(:capture_count, :bigint, null: false, default: 1)
    end

    create(unique_index(:coop_session_evidence, [:session_id, :content_fingerprint]))
    create(index(:coop_session_evidence, [:session_id, :last_captured_at]))
    create(index(:coop_session_evidence, [:episode_id]))
    create(index(:coop_session_evidence, [:first_captured_at]))

    create(
      constraint(:coop_session_evidence, :coop_session_evidence_valid,
        check: """
        char_length(coop_session_id) BETWEEN 1 AND 1024 AND
        char_length(worker_id) BETWEEN 1 AND 256 AND
        placement_generation > 0 AND
        evidence_version = 1 AND
        char_length(content_fingerprint) = 64 AND
        octet_length(document) BETWEEN 2 AND 524288 AND
        jsonb_typeof(document::jsonb) = 'object' AND
        session_revision > 0 AND
        session_state IN ('open', 'exhausted', 'closed', 'discarded') AND
        network_mode IN ('open', 'none', 'filtered') AND
        task_status IN ('bound', 'unbound', 'unavailable') AND
        capture_count > 0 AND
        last_captured_at >= first_captured_at
        """
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("coop_session_evidence")} LIMIT 1) THEN
        RAISE EXCEPTION 'recorded Coop session evidence cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(table(:coop_session_evidence))
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
