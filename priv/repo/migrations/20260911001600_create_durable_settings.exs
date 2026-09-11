defmodule Responder.Repo.Migrations.CreateDurableSettings do
  use Ecto.Migration

  # Product settings previously assembled from application YAML at boot become
  # typed PostgreSQL rows behind one installation identity and one monotonic
  # settings revision. Every table here is either the single installation row,
  # a singleton domain keyed by that installation, or a named collection whose
  # rows are edited through the same revision-checked write path.
  @hex64 "^[0-9a-f]{64}$"
  @slack_id "^[A-Z0-9]{1,255}$"
  @reference "^[a-z0-9][a-z0-9_-]{0,63}$"
  @ten_years 10 * 365 * 86_400
  @tables ~w(
    pricing_rates
    webhook_source_settings
    github_binding_settings
    policy_bindings
    repository_context_settings
    repository_settings
    learning_settings
    report_settings
    emisar_settings
    publication_settings
    github_settings
    slack_settings
    retention_settings
    settings_edits
    installation_settings
  )

  def up do
    create table(:installation_settings, primary_key: false) do
      add(:host_ref, :text, primary_key: true)
      add(:singleton, :boolean, null: false, default: true)
      add(:revision, :bigint, null: false)
      add(:applied_revision, :bigint, null: false, default: 0)
      add(:failure_code, :text)
      add(:saved_by, :text, null: false)
      add(:saved_at, :utc_datetime_usec, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:installation_settings, [:singleton]))

    create(
      constraint(:installation_settings, :installation_settings_valid,
        check:
          "singleton AND char_length(host_ref) BETWEEN 1 AND 128 AND revision > 0 " <>
            "AND applied_revision >= 0 AND applied_revision <= revision " <>
            "AND (failure_code IS NULL OR failure_code ~ '^[a-z][a-z0-9_]{0,63}$') " <>
            "AND char_length(saved_by) BETWEEN 1 AND 256"
      )
    )

    create table(:settings_edits, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:domain, :text, null: false)
      add(:revision, :bigint, null: false)
      add(:actor_ref, :text, null: false)
      add(:fingerprint, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:settings_edits, [:revision]))

    create(
      constraint(:settings_edits, :settings_edit_valid,
        check:
          "domain IN ('installation', 'retention', 'slack', 'github', 'publication', " <>
            "'emisar', 'report', 'learning', 'repositories', 'policies', 'webhooks', " <>
            "'pricing', 'import') AND revision > 0 " <>
            "AND char_length(actor_ref) BETWEEN 1 AND 256 AND fingerprint ~ '#{@hex64}'"
      )
    )

    create table(:retention_settings, primary_key: false) do
      add(:id, installation_reference(), primary_key: true)
      add(:operational_data_seconds, :bigint, null: false)
      add(:conversation_memory_seconds, :bigint, null: false)
      add(:closed_work_seconds, :bigint, null: false)
      add(:episode_history_seconds, :bigint, null: false)
      add(:audit_data_seconds, :bigint, null: false)
    end

    create(
      constraint(:retention_settings, :retention_settings_valid,
        check:
          Enum.map_join(
            ~w(operational_data_seconds conversation_memory_seconds closed_work_seconds episode_history_seconds audit_data_seconds),
            " AND ",
            &"#{&1} BETWEEN 60 AND #{@ten_years}"
          ) <>
            " AND operational_data_seconds <= closed_work_seconds" <>
            " AND closed_work_seconds <= episode_history_seconds" <>
            " AND episode_history_seconds <= audit_data_seconds" <>
            " AND operational_data_seconds <= conversation_memory_seconds"
      )
    )

    create table(:slack_settings, primary_key: false) do
      add(:id, installation_reference(), primary_key: true)
      add(:enabled, :boolean, null: false, default: false)
      add(:workspace_ref, :text)
      add(:bot_ref, :text)
      add(:bot_user_ref, :text)
      add(:default_repository_ref, :text)
      add(:channel_prefix, :text, null: false, default: "ems")
      add(:incident_private, :boolean, null: false, default: true)
      add(:default_participation, :text, null: false, default: "mentions")
      add(:operators, {:array, :text}, null: false, default: [])
      add(:incident_invite_users, {:array, :text}, null: false, default: [])
    end

    create(
      constraint(:slack_settings, :slack_settings_valid,
        check:
          "(workspace_ref IS NULL OR workspace_ref ~ '#{@slack_id}') " <>
            "AND (bot_ref IS NULL OR bot_ref ~ '#{@slack_id}') " <>
            "AND (bot_user_ref IS NULL OR bot_user_ref ~ '#{@slack_id}') " <>
            "AND (default_repository_ref IS NULL OR default_repository_ref ~ '#{@reference}') " <>
            "AND channel_prefix ~ '^[a-z0-9_-]{1,20}$' " <>
            "AND default_participation IN ('mentions', 'proactive', 'shadow') " <>
            "AND cardinality(operators) <= 256 AND cardinality(incident_invite_users) <= 256 " <>
            "AND (NOT enabled OR (workspace_ref IS NOT NULL AND bot_ref IS NOT NULL " <>
            "AND bot_user_ref IS NOT NULL AND default_repository_ref IS NOT NULL))"
      )
    )

    create table(:github_settings, primary_key: false) do
      add(:id, installation_reference(), primary_key: true)
      add(:enabled, :boolean, null: false, default: false)
      add(:app_id, :bigint)
      add(:app_slug, :text)
    end

    create(
      constraint(:github_settings, :github_settings_valid,
        check:
          "(app_id IS NULL OR app_id > 0) AND (app_slug IS NULL OR char_length(app_slug) BETWEEN 1 AND 256) " <>
            "AND (NOT enabled OR app_id IS NOT NULL)"
      )
    )

    create table(:publication_settings, primary_key: false) do
      add(:id, installation_reference(), primary_key: true)
      add(:enabled, :boolean, null: false, default: false)
      add(:branch_prefix, :text, null: false, default: "responder")
      add(:commit_name, :text, null: false, default: "Responder")
      add(:commit_email, :text, null: false, default: "responder@localhost")
    end

    create(
      constraint(:publication_settings, :publication_settings_valid,
        check:
          "char_length(branch_prefix) BETWEEN 1 AND 240 AND char_length(commit_name) BETWEEN 1 AND 256 " <>
            "AND char_length(commit_email) BETWEEN 3 AND 320"
      )
    )

    create table(:emisar_settings, primary_key: false) do
      add(:id, installation_reference(), primary_key: true)
      add(:enabled, :boolean, null: false, default: false)
    end

    create table(:report_settings, primary_key: false) do
      add(:id, installation_reference(), primary_key: true)
      add(:weekly_self_report_enabled, :boolean, null: false, default: false)
      add(:channel_ref, :text)
      add(:weekday, :integer, null: false, default: 1)
      add(:local_time, :time, null: false, default: fragment("'09:00'::time"))
      add(:timezone, :text, null: false, default: "Etc/UTC")
    end

    create(
      constraint(:report_settings, :report_settings_valid,
        check:
          "weekday BETWEEN 1 AND 7 AND char_length(timezone) BETWEEN 1 AND 64 " <>
            "AND (channel_ref IS NULL OR channel_ref ~ '#{@slack_id}') " <>
            "AND (NOT weekly_self_report_enabled OR channel_ref IS NOT NULL)"
      )
    )

    create table(:learning_settings, primary_key: false) do
      add(:id, installation_reference(), primary_key: true)
      add(:enabled, :boolean, null: false, default: false)
    end

    create table(:repository_settings, primary_key: false) do
      add(:ref, :text, primary_key: true)
      add(:display_name, :text)
      add(:description, :text)
      add(:github_repository, :text)
      add(:base_branch, :text, null: false, default: "main")
      add(:publication_checkout_path, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:repository_settings, :repository_settings_valid,
        check:
          "ref ~ '#{@reference}' AND (display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 120) " <>
            "AND (description IS NULL OR char_length(description) BETWEEN 1 AND 1000) " <>
            "AND (github_repository IS NULL OR github_repository ~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') " <>
            "AND char_length(base_branch) BETWEEN 1 AND 240 " <>
            "AND (publication_checkout_path IS NULL OR publication_checkout_path ~ '^/')"
      )
    )

    create table(:repository_context_settings, primary_key: false) do
      add(:ref, :text, primary_key: true)
      add(:display_name, :text)

      add(:primary_repository_ref, references(:repository_settings, column: :ref, type: :text),
        null: false
      )

      add(:read_only_repository_refs, {:array, :text}, null: false, default: [])
      add(:parallel_goal_limit, :integer, null: false, default: 3)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:repository_context_settings, :repository_context_settings_valid,
        check:
          "ref ~ '#{@reference}' AND (display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 120) " <>
            "AND cardinality(read_only_repository_refs) <= 32 " <>
            "AND NOT (primary_repository_ref = ANY (read_only_repository_refs)) " <>
            "AND parallel_goal_limit BETWEEN 1 AND 3"
      )
    )

    create table(:policy_bindings, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:purpose, :text, null: false)
      add(:scope_kind, :text, null: false)
      add(:scope_ref, :text, null: false)
      add(:policy_name, :text, null: false)
      add(:policy_digest, :text, null: false)
      add(:authority_digest, :text)
      add(:verified_by, :text, null: false)
      add(:verified_worker_ref, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:policy_bindings, [:purpose, :scope_kind, :scope_ref]))

    create(
      constraint(:policy_bindings, :policy_binding_valid,
        check:
          "purpose IN ('admission', 'learning', 'incident', 'schedule_read_only', 'schedule_governed', " <>
            "'conversational', 'standard', 'deep', 'contributor', 'schedule') " <>
            "AND scope_kind IN ('installation', 'repository', 'context') " <>
            "AND ((scope_kind = 'installation' AND scope_ref = '') OR " <>
            "(scope_kind <> 'installation' AND scope_ref ~ '#{@reference}')) " <>
            "AND ((purpose IN ('admission', 'learning', 'incident', 'schedule_read_only', 'schedule_governed') " <>
            "AND scope_kind = 'installation') OR " <>
            "(purpose IN ('conversational', 'standard', 'deep', 'contributor') AND scope_kind <> 'installation') OR " <>
            "(purpose = 'schedule' AND scope_kind = 'repository')) " <>
            "AND char_length(policy_name) BETWEEN 1 AND 256 AND policy_digest ~ '#{@hex64}' " <>
            "AND (authority_digest IS NULL OR authority_digest ~ '#{@hex64}') " <>
            "AND verified_by IN ('worker', 'import') " <>
            "AND (verified_worker_ref IS NULL OR char_length(verified_worker_ref) BETWEEN 1 AND 256)"
      )
    )

    create table(:github_binding_settings, primary_key: false) do
      add(:name, :text, primary_key: true)

      add(:repository_ref, references(:repository_settings, column: :ref, type: :text),
        null: false
      )

      add(:installation_id, :bigint, null: false)
      add(:repository_id, :bigint, null: false)
      add(:responder_actor_id, :bigint, null: false)
      add(:authorized_actor_ids, {:array, :bigint}, null: false)

      add(
        :repository_context_ref,
        references(:repository_context_settings, column: :ref, type: :text)
      )

      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:github_binding_settings, [:repository_ref]))

    create(
      constraint(:github_binding_settings, :github_binding_settings_valid,
        check:
          "name ~ '^[a-z][a-z0-9_-]{0,63}$' AND installation_id > 0 AND repository_id > 0 " <>
            "AND responder_actor_id > 0 AND cardinality(authorized_actor_ids) BETWEEN 1 AND 256"
      )
    )

    create table(:webhook_source_settings, primary_key: false) do
      add(:name, :text, primary_key: true)
      add(:enabled, :boolean, null: false, default: true)
      add(:adapter_kind, :text, null: false)
      add(:auth_kind, :text, null: false)
      add(:secret_name, :text, null: false)
      add(:destination_transport, :text, null: false)
      add(:destination_conversation_ref, :text, null: false)
      add(:destination_thread_ref, :text)
      add(:context_ref, :text, null: false)
      add(:group_by_labels, {:array, :text}, null: false, default: [])
      add(:mapping, :map)
      add(:publication_lifecycle, :map)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:webhook_source_settings, :webhook_source_settings_valid,
        check:
          "name ~ '^[a-z][a-z0-9_-]{0,63}$' AND adapter_kind IN ('universal', 'grafana', 'mapped_json') " <>
            "AND auth_kind IN ('bearer', 'hmac_sha256') AND secret_name ~ '^[A-Z][A-Z0-9_]{0,127}$' " <>
            "AND destination_transport ~ '^[a-z][a-z0-9_-]{0,63}$' " <>
            "AND char_length(destination_conversation_ref) BETWEEN 1 AND 1024 " <>
            "AND (destination_thread_ref IS NULL OR char_length(destination_thread_ref) BETWEEN 1 AND 1024) " <>
            "AND context_ref ~ '#{@reference}' AND cardinality(group_by_labels) <= 64 " <>
            "AND (adapter_kind <> 'mapped_json' OR mapping IS NOT NULL)"
      )
    )

    create table(:pricing_rates, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:execution_target, :text, null: false)
      add(:input_usd_per_million, :decimal, null: false)
      add(:cached_input_usd_per_million, :decimal, null: false)
      add(:output_usd_per_million, :decimal, null: false)
      add(:reasoning_usd_per_million, :decimal)
      add(:effective_from, :date, null: false)
      add(:revision, :bigint, null: false)
      add(:provenance, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:pricing_rates, [:execution_target, :effective_from]))

    create(
      constraint(:pricing_rates, :pricing_rate_valid,
        check:
          "char_length(execution_target) BETWEEN 1 AND 256 AND input_usd_per_million >= 0 " <>
            "AND cached_input_usd_per_million >= 0 AND output_usd_per_million >= 0 " <>
            "AND (reasoning_usd_per_million IS NULL OR reasoning_usd_per_million >= 0) " <>
            "AND input_usd_per_million <= 100000 AND cached_input_usd_per_million <= 100000 " <>
            "AND output_usd_per_million <= 100000 " <>
            "AND revision > 0 AND char_length(provenance) BETWEEN 1 AND 1024"
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("installation_settings")} LIMIT 1)
         OR EXISTS (SELECT 1 FROM #{qualified("settings_edits")} LIMIT 1)
         OR EXISTS (SELECT 1 FROM #{qualified("repository_settings")} LIMIT 1)
         OR EXISTS (SELECT 1 FROM #{qualified("policy_bindings")} LIMIT 1)
         OR EXISTS (SELECT 1 FROM #{qualified("webhook_source_settings")} LIMIT 1)
         OR EXISTS (SELECT 1 FROM #{qualified("pricing_rates")} LIMIT 1) THEN
        RAISE EXCEPTION 'durable settings have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    Enum.each(@tables, &drop(table(&1)))
  end

  defp installation_reference do
    references(:installation_settings, column: :host_ref, type: :text, on_delete: :delete_all)
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
