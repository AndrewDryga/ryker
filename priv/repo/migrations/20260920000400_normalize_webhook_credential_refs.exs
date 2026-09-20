defmodule Ryker.Repo.Migrations.NormalizeWebhookCredentialRefs do
  use Ecto.Migration

  def up do
    execute("UPDATE webhook_source_settings SET secret_name = lower(secret_name)")
    drop(constraint(:webhook_source_settings, :webhook_source_settings_valid))

    create(
      constraint(:webhook_source_settings, :webhook_source_settings_valid,
        check:
          "name ~ '^[a-z][a-z0-9_-]{0,63}$' AND adapter_kind IN ('universal', 'grafana', 'mapped_json') " <>
            "AND auth_kind IN ('bearer', 'hmac_sha256') AND secret_name ~ '^[a-z0-9][a-z0-9_.:-]{0,127}$' " <>
            "AND destination_transport ~ '^[a-z][a-z0-9_-]{0,63}$' " <>
            "AND char_length(destination_conversation_ref) BETWEEN 1 AND 1024 " <>
            "AND (destination_thread_ref IS NULL OR char_length(destination_thread_ref) BETWEEN 1 AND 1024) " <>
            "AND context_ref ~ '^[a-z0-9][a-z0-9_-]{0,63}$' AND cardinality(group_by_labels) <= 64 " <>
            "AND (adapter_kind <> 'mapped_json' OR mapping IS NOT NULL)"
      )
    )
  end

  def down do
    execute("UPDATE webhook_source_settings SET secret_name = upper(secret_name)")
    drop(constraint(:webhook_source_settings, :webhook_source_settings_valid))

    create(
      constraint(:webhook_source_settings, :webhook_source_settings_valid,
        check:
          "name ~ '^[a-z][a-z0-9_-]{0,63}$' AND adapter_kind IN ('universal', 'grafana', 'mapped_json') " <>
            "AND auth_kind IN ('bearer', 'hmac_sha256') AND secret_name ~ '^[A-Z][A-Z0-9_]{0,127}$' " <>
            "AND destination_transport ~ '^[a-z][a-z0-9_-]{0,63}$' " <>
            "AND char_length(destination_conversation_ref) BETWEEN 1 AND 1024 " <>
            "AND (destination_thread_ref IS NULL OR char_length(destination_thread_ref) BETWEEN 1 AND 1024) " <>
            "AND context_ref ~ '^[a-z0-9][a-z0-9_-]{0,63}$' AND cardinality(group_by_labels) <= 64 " <>
            "AND (adapter_kind <> 'mapped_json' OR mapping IS NOT NULL)"
      )
    )
  end
end
