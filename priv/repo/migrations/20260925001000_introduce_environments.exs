defmodule Ryker.Repo.Migrations.IntroduceEnvironments do
  @moduledoc """
  Channels, Chat and webhook sources select an environment, not a repository.

  An environment names what work in it may use: an ordered list of
  repositories (work changes the first and reads the others) and at most one
  Emisar account. It replaces repository groups, the per-scope Emisar routes,
  the per-channel repository and the Slack default repository. None of those
  held data on the live installation when this shipped (2026-09-25), so they
  are dropped rather than carried over. A webhook source has no environment it
  could be moved into, so the upgrade refuses one instead of deleting it.

  A work session, an incident room and a schedule record the environment they
  ran in; history outlives the settings row, so none of those is a foreign key.
  """
  use Ecto.Migration

  @slug "^[a-z0-9][a-z0-9-]{0,63}$"
  @repository_scope "^[a-z][a-z0-9_-]{0,63}$"
  @reference "^[a-z0-9][a-z0-9_-]{0,63}$"
  @hex64 "^[0-9a-f]{64}$"
  @edit_domains ~w(installation retention slack github publication emisar report learning
                   repositories policies webhooks pricing import work)

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("webhook_source_settings")} LIMIT 1) THEN
        RAISE EXCEPTION 'webhook sources must be removed before environments replace their repository context';
      END IF;
    END
    $$
    """)

    create table(:environment_settings, primary_key: false) do
      add(:ref, :text, primary_key: true)
      add(:display_name, :text, null: false)
      add(:description, :text)

      add(
        :emisar_connection_ref,
        references(:emisar_connection_settings, column: :ref, type: :text, on_delete: :restrict)
      )

      add(:is_default, :boolean, null: false, default: false)
      add(:parallel_goal_limit, :integer, null: false, default: 3)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:environment_settings, :environment_settings_valid,
        check:
          "ref ~ '#{@slug}' AND char_length(display_name) BETWEEN 1 AND 80 " <>
            "AND (description IS NULL OR char_length(description) BETWEEN 1 AND 500) " <>
            "AND parallel_goal_limit BETWEEN 1 AND 3"
      )
    )

    create(
      unique_index(:environment_settings, [:is_default],
        where: "is_default",
        name: :environment_settings_default_index
      )
    )

    create(index(:environment_settings, [:emisar_connection_ref]))

    create table(:environment_repository_settings, primary_key: false) do
      add(
        :environment_ref,
        references(:environment_settings, column: :ref, type: :text, on_delete: :delete_all),
        primary_key: true
      )

      add(
        :repository_ref,
        references(:repository_settings, column: :ref, type: :text, on_delete: :restrict),
        primary_key: true
      )

      add(:position, :integer, null: false)
    end

    create(
      unique_index(:environment_repository_settings, [:environment_ref, :position],
        name: :environment_repository_settings_position_index
      )
    )

    create(index(:environment_repository_settings, [:repository_ref]))

    create(
      constraint(:environment_repository_settings, :environment_repository_settings_valid,
        check: "position BETWEEN 0 AND 32"
      )
    )

    for table <- ~w(environment_settings environment_repository_settings), do: notify(table)

    # A channel keeps its participation, alerts and invitations; the repository
    # it named has no environment to become, so it answers without one.
    drop(constraint(:slack_channel_configurations, :slack_channel_configuration_valid))
    rename(table(:slack_channel_configurations), :repository_ref, to: :environment_ref)

    alter table(:slack_channel_configurations) do
      modify(:environment_ref, :text, null: true, from: {:text, null: false})
    end

    execute("UPDATE #{qualified("slack_channel_configurations")} SET environment_ref = NULL")

    alter table(:slack_channel_configurations) do
      modify(
        :environment_ref,
        references(:environment_settings, column: :ref, type: :text, on_delete: :nilify_all),
        from: :text
      )
    end

    create(
      constraint(:slack_channel_configurations, :slack_channel_configuration_valid,
        check: channel_check(nil)
      )
    )

    drop(constraint(:webhook_source_settings, :webhook_source_settings_valid))
    rename(table(:webhook_source_settings), :context_ref, to: :environment_ref)

    alter table(:webhook_source_settings) do
      modify(
        :environment_ref,
        references(:environment_settings, column: :ref, type: :text, on_delete: :restrict),
        null: false,
        from: {:text, null: false}
      )
    end

    create(
      constraint(:webhook_source_settings, :webhook_source_settings_valid,
        check: webhook_check(nil)
      )
    )

    execute("DELETE FROM #{qualified("policy_bindings")} WHERE scope_kind = 'context'")
    drop(constraint(:policy_bindings, :policy_binding_valid))

    create(
      constraint(:policy_bindings, :policy_binding_valid, check: policy_check("environment"))
    )

    alter table(:episode_work_sessions) do
      add(:environment_ref, :text)
    end

    create(
      constraint(:episode_work_sessions, :episode_work_session_environment_valid,
        check:
          "environment_ref IS NULL OR (execution_kind = 'work' AND environment_ref ~ '#{@slug}')"
      )
    )

    for table <- [:slack_incident_rooms, :episode_schedules] do
      alter table(table) do
        add(:environment_ref, :text)
      end

      create(
        constraint(table, :"#{table}_environment_valid",
          check: "environment_ref IS NULL OR environment_ref ~ '#{@slug}'"
        )
      )
    end

    drop(constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid))

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid,
        check: profile_check(:environment)
      )
    )

    drop(constraint(:settings_edits, :settings_edit_valid))

    create(
      constraint(:settings_edits, :settings_edit_valid,
        check: edit_check(@edit_domains ++ ["environments"])
      )
    )

    alter table(:github_binding_settings) do
      remove(:repository_context_ref)
    end

    alter table(:slack_settings) do
      remove(:default_repository_ref)
    end

    drop(table(:emisar_connection_bindings))
    drop(table(:repository_context_settings))
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("environment_settings")} LIMIT 1)
         OR EXISTS (SELECT 1 FROM #{qualified("slack_channel_configurations")} LIMIT 1)
         OR EXISTS (SELECT 1 FROM #{qualified("webhook_source_settings")} LIMIT 1)
         OR EXISTS (
           SELECT 1 FROM #{qualified("policy_bindings")} WHERE scope_kind = 'environment' LIMIT 1
         )
         OR EXISTS (
           SELECT 1 FROM #{qualified("settings_edits")} WHERE domain = 'environments' LIMIT 1
         )
         OR EXISTS (
           SELECT 1 FROM #{qualified("episode_work_sessions")}
           WHERE environment_ref IS NOT NULL LIMIT 1
         )
         OR EXISTS (
           SELECT 1 FROM #{qualified("slack_incident_rooms")}
           WHERE environment_ref IS NOT NULL LIMIT 1
         )
         OR EXISTS (
           SELECT 1 FROM #{qualified("episode_schedules")} WHERE environment_ref IS NOT NULL LIMIT 1
         )
         OR EXISTS (
           SELECT 1 FROM #{qualified("ingress_inbox_entries")}
           WHERE work_profile IS NOT NULL
             AND work_profile::jsonb ?| ARRAY['environment_ref', 'parallel_goal_limit',
                                              'read_only_repository_refs', 'emisar_connection_ref']
           LIMIT 1
         ) THEN
        RAISE EXCEPTION 'environments have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

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

    notify("repository_context_settings")

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

    alter table(:slack_settings) do
      add(:default_repository_ref, :text)
    end

    alter table(:github_binding_settings) do
      add(
        :repository_context_ref,
        references(:repository_context_settings, column: :ref, type: :text)
      )
    end

    drop(constraint(:settings_edits, :settings_edit_valid))
    create(constraint(:settings_edits, :settings_edit_valid, check: edit_check(@edit_domains)))

    drop(constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid))

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid,
        check: profile_check(:repository_context)
      )
    )

    for table <- [:episode_schedules, :slack_incident_rooms] do
      drop(constraint(table, :"#{table}_environment_valid"))

      alter table(table) do
        remove(:environment_ref)
      end
    end

    drop(constraint(:episode_work_sessions, :episode_work_session_environment_valid))

    alter table(:episode_work_sessions) do
      remove(:environment_ref)
    end

    drop(constraint(:policy_bindings, :policy_binding_valid))
    create(constraint(:policy_bindings, :policy_binding_valid, check: policy_check("context")))

    drop(constraint(:webhook_source_settings, :webhook_source_settings_valid))
    drop(constraint(:webhook_source_settings, :webhook_source_settings_environment_ref_fkey))
    rename(table(:webhook_source_settings), :environment_ref, to: :context_ref)

    create(
      constraint(:webhook_source_settings, :webhook_source_settings_valid,
        check: webhook_check("context_ref ~ '#{@reference}'")
      )
    )

    drop(constraint(:slack_channel_configurations, :slack_channel_configuration_valid))

    drop(
      constraint(
        :slack_channel_configurations,
        :slack_channel_configurations_environment_ref_fkey
      )
    )

    rename(table(:slack_channel_configurations), :environment_ref, to: :repository_ref)

    alter table(:slack_channel_configurations) do
      modify(:repository_ref, :text, null: false, from: {:text, null: true})
    end

    create(
      constraint(:slack_channel_configurations, :slack_channel_configuration_valid,
        check: channel_check("char_length(repository_ref) > 0")
      )
    )

    drop(table(:environment_repository_settings))
    drop(table(:environment_settings))
  end

  defp channel_check(repository_clause) do
    [
      "(participation IS NULL OR participation IN ('mentions', 'proactive', 'shadow'))",
      "alert_policy IN ('reply', 'offer', 'automatic')",
      "revision > 0",
      repository_clause,
      "(actor_ref IS NULL OR char_length(actor_ref) > 0)",
      "(welcome_message_ref IS NULL OR char_length(welcome_message_ref) > 0)"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" AND ")
  end

  defp webhook_check(context_clause) do
    [
      "name ~ '^[a-z][a-z0-9_-]{0,63}$'",
      "adapter_kind IN ('universal', 'grafana', 'mapped_json')",
      "auth_kind IN ('bearer', 'hmac_sha256')",
      "secret_name ~ '^[a-z0-9][a-z0-9_.:-]{0,127}$'",
      "destination_transport ~ '^[a-z][a-z0-9_-]{0,63}$'",
      "char_length(destination_conversation_ref) BETWEEN 1 AND 1024",
      "(destination_thread_ref IS NULL OR char_length(destination_thread_ref) BETWEEN 1 AND 1024)",
      context_clause,
      "cardinality(group_by_labels) <= 64",
      "(adapter_kind <> 'mapped_json' OR mapping IS NOT NULL)"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" AND ")
  end

  defp policy_check(grouped_kind) do
    grouped_scope =
      case grouped_kind do
        "environment" -> "(scope_kind = 'environment' AND scope_ref ~ '#{@slug}')"
        "context" -> "(scope_kind = 'context' AND scope_ref ~ '#{@repository_scope}')"
      end

    "purpose IN ('admission', 'learning', 'incident', 'schedule_read_only', 'schedule_governed', " <>
      "'conversational', 'standard', 'deep', 'contributor', 'schedule') " <>
      "AND scope_kind IN ('installation', 'repository', '#{grouped_kind}') " <>
      "AND ((scope_kind = 'installation' AND scope_ref = '') OR " <>
      "(scope_kind = 'repository' AND scope_ref ~ '#{@repository_scope}') OR #{grouped_scope}) " <>
      "AND ((purpose IN ('admission', 'conversational', 'learning', 'incident', 'schedule_read_only', 'schedule_governed') " <>
      "AND scope_kind = 'installation') OR " <>
      "(purpose IN ('conversational', 'standard', 'deep', 'contributor') AND scope_kind <> 'installation') OR " <>
      "(purpose = 'schedule' AND scope_kind = 'repository')) " <>
      "AND char_length(policy_name) BETWEEN 1 AND 256 AND policy_digest ~ '#{@hex64}' " <>
      "AND (authority_digest IS NULL OR authority_digest ~ '#{@hex64}') " <>
      "AND verified_by IN ('worker', 'import') " <>
      "AND (verified_worker_ref IS NULL OR char_length(verified_worker_ref) BETWEEN 1 AND 256)"
  end

  defp edit_check(domains) do
    "domain IN (#{Enum.map_join(domains, ", ", &"'#{&1}'")}) AND revision > 0 " <>
      "AND char_length(actor_ref) BETWEEN 1 AND 256 AND fingerprint ~ '#{@hex64}'"
  end

  # The frozen Work profile an inbox entry carries. Its placement keys either
  # name an environment (with the goal limit it always has, the read-only
  # companions of its writable repository and its optional Emisar account) or
  # are absent together.
  defp profile_check(placement) do
    {allowed, placement_check} =
      case placement do
        :environment ->
          {"- 'emisar_connection_ref' - 'environment_ref' - 'parallel_goal_limit' - 'read_only_repository_refs'",
           environment_check()}

        :repository_context ->
          {"- 'repository_context'",
           repository_context_check("work_profile::jsonb ->> 'repository_context'")}
      end

    """
    work_profile IS NULL
    OR (
      octet_length(work_profile) BETWEEN 1 AND 16384
      AND jsonb_typeof(work_profile::jsonb) = 'object'
      AND work_profile::jsonb ?& ARRAY['class_policies', 'policy', 'policy_digest', 'repository_ref']
      AND (work_profile::jsonb - 'authority_digest' #{allowed} - 'class_policies' - 'policy' - 'policy_digest' - 'repository_ref') = '{}'::jsonb
      AND work_profile::jsonb ->> 'policy' = work_policy
      AND work_profile::jsonb ->> 'policy_digest' = work_policy_digest
      AND (work_profile::jsonb ->> 'repository_ref') IS NOT DISTINCT FROM repository_ref
      AND #{placement_check}
      AND (
        NOT (work_profile::jsonb ? 'authority_digest')
        OR (
          jsonb_typeof(work_profile::jsonb -> 'authority_digest') = 'string'
          AND work_profile::jsonb ->> 'authority_digest' ~ '#{@hex64}'
        )
      )
      AND (
        work_profile::jsonb -> 'class_policies' = 'null'::jsonb
        OR (
          jsonb_typeof(work_profile::jsonb -> 'class_policies') = 'object'
          AND (work_profile::jsonb -> 'class_policies') ?& ARRAY['conversational', 'standard', 'deep']
          AND ((work_profile::jsonb -> 'class_policies') - 'conversational' - 'standard' - 'deep') = '{}'::jsonb
          AND #{class_policy_check("conversational")}
          AND #{class_policy_check("standard")}
          AND #{class_policy_check("deep")}
          AND (
            (
              NOT (work_profile::jsonb ? 'authority_digest')
              AND NOT (work_profile::jsonb -> 'class_policies' -> 'conversational' ? 'authority_digest')
              AND NOT (work_profile::jsonb -> 'class_policies' -> 'standard' ? 'authority_digest')
              AND NOT (work_profile::jsonb -> 'class_policies' -> 'deep' ? 'authority_digest')
            )
            OR (
              jsonb_typeof(work_profile::jsonb -> 'authority_digest') = 'string'
              AND work_profile::jsonb ->> 'authority_digest' ~ '#{@hex64}'
              AND work_profile::jsonb -> 'class_policies' -> 'conversational' ->> 'authority_digest' = work_profile::jsonb ->> 'authority_digest'
              AND work_profile::jsonb -> 'class_policies' -> 'standard' ->> 'authority_digest' = work_profile::jsonb ->> 'authority_digest'
              AND work_profile::jsonb -> 'class_policies' -> 'deep' ->> 'authority_digest' = work_profile::jsonb ->> 'authority_digest'
            )
          )
        )
      )
    )
    """
  end

  defp environment_check do
    """
    (
      (
        NOT (work_profile::jsonb ? 'environment_ref')
        AND NOT (work_profile::jsonb ? 'parallel_goal_limit')
        AND NOT (work_profile::jsonb ? 'read_only_repository_refs')
        AND NOT (work_profile::jsonb ? 'emisar_connection_ref')
      )
      OR (
        work_profile::jsonb ? 'environment_ref'
        AND work_profile::jsonb ? 'parallel_goal_limit'
        AND jsonb_typeof(work_profile::jsonb -> 'environment_ref') = 'string'
        AND work_profile::jsonb ->> 'environment_ref' ~ '#{@slug}'
        AND jsonb_typeof(work_profile::jsonb -> 'parallel_goal_limit') = 'number'
        AND (work_profile::jsonb ->> 'parallel_goal_limit') ~ '^[1-3]$'
        AND (
          NOT (work_profile::jsonb ? 'emisar_connection_ref')
          OR (
            jsonb_typeof(work_profile::jsonb -> 'emisar_connection_ref') = 'string'
            AND char_length(work_profile::jsonb ->> 'emisar_connection_ref') BETWEEN 1 AND 64
          )
        )
        AND (
          NOT (work_profile::jsonb ? 'read_only_repository_refs')
          OR (
            repository_ref IS NOT NULL
            AND jsonb_typeof(work_profile::jsonb -> 'read_only_repository_refs') = 'array'
            AND jsonb_array_length(work_profile::jsonb -> 'read_only_repository_refs') BETWEEN 1 AND 32
            AND NOT (work_profile::jsonb -> 'read_only_repository_refs') @> jsonb_build_array(repository_ref)
          )
        )
      )
    )
    """
  end

  defp class_policy_check(work_class) do
    """
    jsonb_typeof(work_profile::jsonb -> 'class_policies' -> '#{work_class}') = 'object'
    AND (work_profile::jsonb -> 'class_policies' -> '#{work_class}') ?& ARRAY['policy', 'policy_digest']
    AND ((work_profile::jsonb -> 'class_policies' -> '#{work_class}') - 'authority_digest' - 'policy' - 'policy_digest') = '{}'::jsonb
    AND char_length(work_profile::jsonb -> 'class_policies' -> '#{work_class}' ->> 'policy') > 0
    AND work_profile::jsonb -> 'class_policies' -> '#{work_class}' ->> 'policy_digest' ~ '#{@hex64}'
    AND (
      NOT (work_profile::jsonb -> 'class_policies' -> '#{work_class}' ? 'authority_digest')
      OR (
        jsonb_typeof(work_profile::jsonb -> 'class_policies' -> '#{work_class}' -> 'authority_digest') = 'string'
        AND work_profile::jsonb -> 'class_policies' -> '#{work_class}' ->> 'authority_digest' ~ '#{@hex64}'
      )
    )
    """
  end

  defp repository_context_check(value) do
    """
    (
      #{value} IS NULL
      OR (
        octet_length(#{value}) BETWEEN 1 AND 16384
        AND jsonb_typeof((#{value})::jsonb) = 'object'
        AND (#{value})::jsonb ?& ARRAY['context_ref', 'parallel_goal_limit', 'primary_repository', 'read_only_repositories']
        AND ((#{value})::jsonb - 'context_ref' - 'parallel_goal_limit' - 'primary_repository' - 'read_only_repositories') = '{}'::jsonb
        AND jsonb_typeof((#{value})::jsonb -> 'context_ref') = 'string'
        AND char_length((#{value})::jsonb ->> 'context_ref') BETWEEN 1 AND 256
        AND jsonb_typeof((#{value})::jsonb -> 'primary_repository') = 'string'
        AND (#{value})::jsonb ->> 'primary_repository' = repository_ref
        AND jsonb_typeof((#{value})::jsonb -> 'parallel_goal_limit') = 'number'
        AND ((#{value})::jsonb ->> 'parallel_goal_limit') ~ '^[1-3]$'
        AND jsonb_typeof((#{value})::jsonb -> 'read_only_repositories') = 'array'
        AND jsonb_array_length((#{value})::jsonb -> 'read_only_repositories') <= 32
        AND NOT ((#{value})::jsonb -> 'read_only_repositories') @> jsonb_build_array(repository_ref)
      )
    )
    """
  end

  # Settings pages listen for these to refresh; every other settings table has one.
  defp notify(table) do
    execute("""
    CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR UPDATE OR DELETE
      ON #{qualified(table)} FOR EACH STATEMENT
      EXECUTE FUNCTION #{qualified("ryker_control_plane_notify")}()
    """)
  end

  defp qualified(name) do
    case prefix() do
      nil -> name
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{name})
    end
  end
end
