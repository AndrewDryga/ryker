defmodule Responder.Repo.Migrations.AddRepositoryContexts do
  use Ecto.Migration

  def up do
    alter table(:episode_work_sessions) do
      add(:repository_context, :text)
    end

    alter table(:slack_incident_rooms) do
      add(:repository_context, :text)
    end

    drop(constraint(:episode_work_sessions, :episode_work_session_owner_valid))

    create(
      constraint(:episode_work_sessions, :episode_work_session_owner_valid,
        check:
          "(execution_kind = 'work' AND episode_id IS NOT NULL) OR " <>
            "(execution_kind = 'admission' AND episode_id IS NULL AND repository_ref IS NULL " <>
            "AND repository_context IS NULL AND workspace_task IS NULL)"
      )
    )

    create(
      constraint(:episode_work_sessions, :episode_work_session_repository_context_valid,
        check: repository_context_check("repository_context", "repository_ref")
      )
    )

    create(
      constraint(:slack_incident_rooms, :slack_incident_room_repository_context_valid,
        check: repository_context_check("repository_context", "repository_ref")
      )
    )

    drop(constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid))

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid,
        check: authority_profile_check(true)
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("episode_work_sessions")}
        WHERE repository_context IS NOT NULL
        LIMIT 1
      ) OR EXISTS (
        SELECT 1 FROM #{qualified("slack_incident_rooms")}
        WHERE repository_context IS NOT NULL
        LIMIT 1
      ) OR EXISTS (
        SELECT 1 FROM #{qualified("ingress_inbox_entries")}
        WHERE work_profile IS NOT NULL AND work_profile::jsonb ? 'repository_context'
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'repository context has data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid))

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid,
        check: authority_profile_check(false)
      )
    )

    drop(constraint(:episode_work_sessions, :episode_work_session_repository_context_valid))
    drop(constraint(:slack_incident_rooms, :slack_incident_room_repository_context_valid))

    drop(constraint(:episode_work_sessions, :episode_work_session_owner_valid))

    create(
      constraint(:episode_work_sessions, :episode_work_session_owner_valid,
        check:
          "(execution_kind = 'work' AND episode_id IS NOT NULL) OR " <>
            "(execution_kind = 'admission' AND episode_id IS NULL AND repository_ref IS NULL " <>
            "AND workspace_task IS NULL)"
      )
    )

    alter table(:episode_work_sessions) do
      remove(:repository_context)
    end

    alter table(:slack_incident_rooms) do
      remove(:repository_context)
    end
  end

  defp authority_profile_check(repository_context?) do
    allowed_context = if repository_context?, do: " - 'repository_context'", else: ""

    context_check =
      if repository_context? do
        " AND #{repository_context_check("work_profile::jsonb ->> 'repository_context'", "repository_ref")}"
      else
        ""
      end

    """
    work_profile IS NULL
    OR (
      octet_length(work_profile) BETWEEN 1 AND 16384
      AND jsonb_typeof(work_profile::jsonb) = 'object'
      AND work_profile::jsonb ?& ARRAY['class_policies', 'policy', 'policy_digest', 'repository_ref']
      AND (work_profile::jsonb - 'authority_digest'#{allowed_context} - 'class_policies' - 'policy' - 'policy_digest' - 'repository_ref') = '{}'::jsonb
      AND work_profile::jsonb ->> 'policy' = work_policy
      AND work_profile::jsonb ->> 'policy_digest' = work_policy_digest
      AND (work_profile::jsonb ->> 'repository_ref') IS NOT DISTINCT FROM repository_ref
      #{context_check}
      AND (
        NOT (work_profile::jsonb ? 'authority_digest')
        OR (
          jsonb_typeof(work_profile::jsonb -> 'authority_digest') = 'string'
          AND work_profile::jsonb ->> 'authority_digest' ~ '^[0-9a-f]{64}$'
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
              AND work_profile::jsonb ->> 'authority_digest' ~ '^[0-9a-f]{64}$'
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

  defp class_policy_check(work_class) do
    """
    jsonb_typeof(work_profile::jsonb -> 'class_policies' -> '#{work_class}') = 'object'
    AND (work_profile::jsonb -> 'class_policies' -> '#{work_class}') ?& ARRAY['policy', 'policy_digest']
    AND ((work_profile::jsonb -> 'class_policies' -> '#{work_class}') - 'authority_digest' - 'policy' - 'policy_digest') = '{}'::jsonb
    AND char_length(work_profile::jsonb -> 'class_policies' -> '#{work_class}' ->> 'policy') > 0
    AND work_profile::jsonb -> 'class_policies' -> '#{work_class}' ->> 'policy_digest' ~ '^[0-9a-f]{64}$'
    AND (
      NOT (work_profile::jsonb -> 'class_policies' -> '#{work_class}' ? 'authority_digest')
      OR (
        jsonb_typeof(work_profile::jsonb -> 'class_policies' -> '#{work_class}' -> 'authority_digest') = 'string'
        AND work_profile::jsonb -> 'class_policies' -> '#{work_class}' ->> 'authority_digest' ~ '^[0-9a-f]{64}$'
      )
    )
    """
  end

  defp repository_context_check(value, repository_ref) do
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
        AND (#{value})::jsonb ->> 'primary_repository' = #{repository_ref}
        AND jsonb_typeof((#{value})::jsonb -> 'parallel_goal_limit') = 'number'
        AND ((#{value})::jsonb ->> 'parallel_goal_limit') ~ '^[1-3]$'
        AND jsonb_typeof((#{value})::jsonb -> 'read_only_repositories') = 'array'
        AND jsonb_array_length((#{value})::jsonb -> 'read_only_repositories') <= 32
        AND NOT ((#{value})::jsonb -> 'read_only_repositories') @> jsonb_build_array(#{repository_ref})
      )
    )
    """
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
