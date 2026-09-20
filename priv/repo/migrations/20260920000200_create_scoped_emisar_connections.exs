defmodule Ryker.Repo.Migrations.CreateScopedEmisarConnections do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("emisar_settings")} WHERE enabled) THEN
        RAISE EXCEPTION 'enabled legacy Emisar connection must be verified and migrated before this release';
      END IF;
      IF EXISTS (SELECT 1 FROM #{qualified("episode_emisar_approvals")}) THEN
        RAISE EXCEPTION 'legacy Emisar approvals require an authenticated account identity before migration';
      END IF;
    END
    $$
    """)

    create table(:emisar_connection_settings, primary_key: false) do
      add(:ref, :text, primary_key: true)
      add(:display_name, :text, null: false)
      add(:rpc_url, :text, null: false)
      add(:account_ref, :text, null: false)
      add(:account_label, :text)
      add(:enabled_for_new_work, :boolean, null: false, default: true)
      add(:monitoring_enabled, :boolean, null: false, default: true)
      add(:verified_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:emisar_connection_settings, [:rpc_url, :account_ref],
        name: :emisar_connection_endpoint_account_index
      )
    )

    create(
      constraint(:emisar_connection_settings, :emisar_connection_settings_valid,
        check:
          "ref ~ '^[a-z0-9][a-z0-9_.:-]{0,63}$' AND char_length(display_name) BETWEEN 1 AND 120 " <>
            "AND char_length(rpc_url) BETWEEN 9 AND 2048 AND rpc_url LIKE 'https://%' " <>
            "AND char_length(account_ref) BETWEEN 1 AND 256 " <>
            "AND (account_label IS NULL OR char_length(account_label) BETWEEN 1 AND 256)"
      )
    )

    create table(:emisar_connection_bindings, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:scope_kind, :text, null: false)
      add(:scope_ref, :text, null: false)
      add(:purpose, :text, null: false)

      add(
        :connection_ref,
        references(:emisar_connection_settings,
          column: :ref,
          type: :text,
          on_delete: :restrict
        ),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:emisar_connection_bindings, [:scope_kind, :scope_ref, :purpose]))

    create(
      constraint(:emisar_connection_bindings, :emisar_connection_binding_valid,
        check:
          "scope_kind IN ('repository', 'context', 'installation_purpose') " <>
            "AND char_length(scope_ref) BETWEEN 1 AND 256 " <>
            "AND purpose IN ('conversation', 'standard', 'deep', 'contributor', 'incident', 'schedule', 'learning')"
      )
    )

    alter table(:episode_work_sessions) do
      add(:emisar_connection_ref, :text)
      add(:emisar_account_ref, :text)
      add(:emisar_rpc_url, :text)
    end

    create(
      constraint(:episode_work_sessions, :episode_work_session_emisar_pin_valid,
        check:
          "(emisar_connection_ref IS NULL AND emisar_account_ref IS NULL AND emisar_rpc_url IS NULL) OR " <>
            "(char_length(emisar_connection_ref) BETWEEN 1 AND 64 AND char_length(emisar_account_ref) BETWEEN 1 AND 256 " <>
            "AND char_length(emisar_rpc_url) BETWEEN 9 AND 2048)"
      )
    )

    alter table(:episode_emisar_approvals) do
      add(
        :connection_ref,
        references(:emisar_connection_settings,
          column: :ref,
          type: :text,
          on_delete: :restrict
        )
      )
    end

    drop(index(:episode_emisar_approvals, [:request_id]))
    create(unique_index(:episode_emisar_approvals, [:connection_ref, :request_id]))
    create(index(:episode_emisar_approvals, [:connection_ref, :status, :next_attempt_at]))

    drop(table(:emisar_settings))
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF (SELECT count(*) FROM #{qualified("emisar_connection_settings")}) > 1 THEN
        RAISE EXCEPTION 'multiple Emisar accounts cannot be collapsed into the legacy singleton';
      END IF;
    END
    $$
    """)

    create table(:emisar_settings, primary_key: false) do
      add(:id, references(:installation_settings, column: :host_ref, type: :text),
        primary_key: true
      )

      add(:enabled, :boolean, null: false, default: false)
      add(:rpc_url, :text, null: false, default: "https://emisar.dev/api/mcp/rpc")
    end

    create(
      constraint(:emisar_settings, :emisar_settings_rpc_url_valid,
        check: "rpc_url ~ '^https://[^/?#]+(:[0-9]+)?/[^?#]+$' AND char_length(rpc_url) <= 2048"
      )
    )

    drop(index(:episode_emisar_approvals, [:connection_ref, :status, :next_attempt_at]))
    drop(index(:episode_emisar_approvals, [:connection_ref, :request_id]))
    create(unique_index(:episode_emisar_approvals, [:request_id]))

    alter(table(:episode_emisar_approvals), do: remove(:connection_ref))
    drop(constraint(:episode_work_sessions, :episode_work_session_emisar_pin_valid))

    alter table(:episode_work_sessions) do
      remove(:emisar_connection_ref)
      remove(:emisar_account_ref)
      remove(:emisar_rpc_url)
    end

    drop(table(:emisar_connection_bindings))
    drop(table(:emisar_connection_settings))
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
