defmodule Ryker.Repo.Migrations.AddPolicyAuthorityDigests do
  use Ecto.Migration

  def up do
    alter table(:episode_work_sessions) do
      add(:authority_digest, :text)
    end

    alter table(:coop_workers) do
      add(:policy_authority_digests, :text, null: false, default: "{}")
    end

    drop(constraint(:episode_work_sessions, :episode_work_session_identity_valid))

    create(
      constraint(:episode_work_sessions, :episode_work_session_identity_valid,
        check:
          "char_length(policy) > 0 AND generation > 0 AND create_generation > 0" <>
            " AND char_length(policy_digest) = 64 AND char_length(external_ref) > 0" <>
            " AND (authority_digest IS NULL OR authority_digest ~ '^[0-9a-f]{64}$')"
      )
    )

    drop(constraint(:coop_workers, :coop_worker_documents_valid))

    create(
      constraint(:coop_workers, :coop_worker_documents_valid, check: worker_documents_check())
    )

    drop(constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid))

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid,
        check: authority_profile_check()
      )
    )
  end

  def down do
    drop(constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid))

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid,
        check: legacy_profile_check()
      )
    )

    drop(constraint(:coop_workers, :coop_worker_documents_valid))

    create(
      constraint(:coop_workers, :coop_worker_documents_valid,
        check:
          "jsonb_typeof(policy_digests::jsonb) = 'object'" <>
            " AND jsonb_typeof(repositories::jsonb) = 'array'" <>
            " AND jsonb_typeof(capabilities::jsonb) = 'array'" <>
            " AND jsonb_typeof(capacity::jsonb) = 'object'" <>
            " AND octet_length(policy_digests) <= 131072" <>
            " AND octet_length(repositories) <= 131072" <>
            " AND octet_length(capabilities) <= 131072" <>
            " AND octet_length(capacity) <= 131072"
      )
    )

    drop(constraint(:episode_work_sessions, :episode_work_session_identity_valid))

    create(
      constraint(:episode_work_sessions, :episode_work_session_identity_valid,
        check:
          "char_length(policy) > 0 AND generation > 0 AND create_generation > 0" <>
            " AND char_length(policy_digest) = 64 AND char_length(external_ref) > 0"
      )
    )

    alter table(:coop_workers) do
      remove(:policy_authority_digests)
    end

    alter table(:episode_work_sessions) do
      remove(:authority_digest)
    end
  end

  defp worker_documents_check do
    "jsonb_typeof(policy_digests::jsonb) = 'object'" <>
      " AND jsonb_typeof(policy_authority_digests::jsonb) = 'object'" <>
      " AND jsonb_typeof(repositories::jsonb) = 'array'" <>
      " AND jsonb_typeof(capabilities::jsonb) = 'array'" <>
      " AND jsonb_typeof(capacity::jsonb) = 'object'" <>
      " AND octet_length(policy_digests) <= 131072" <>
      " AND octet_length(policy_authority_digests) <= 131072" <>
      " AND octet_length(repositories) <= 131072" <>
      " AND octet_length(capabilities) <= 131072" <>
      " AND octet_length(capacity) <= 131072"
  end

  defp authority_profile_check do
    """
    work_profile IS NULL
    OR (
      octet_length(work_profile) BETWEEN 1 AND 16384
      AND jsonb_typeof(work_profile::jsonb) = 'object'
      AND work_profile::jsonb ?& ARRAY['class_policies', 'policy', 'policy_digest', 'repository_ref']
      AND (work_profile::jsonb - 'authority_digest' - 'class_policies' - 'policy' - 'policy_digest' - 'repository_ref') = '{}'::jsonb
      AND work_profile::jsonb ->> 'policy' = work_policy
      AND work_profile::jsonb ->> 'policy_digest' = work_policy_digest
      AND (work_profile::jsonb ->> 'repository_ref') IS NOT DISTINCT FROM repository_ref
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
              AND jsonb_typeof(work_profile::jsonb -> 'class_policies' -> 'conversational' -> 'authority_digest') = 'string'
              AND jsonb_typeof(work_profile::jsonb -> 'class_policies' -> 'standard' -> 'authority_digest') = 'string'
              AND jsonb_typeof(work_profile::jsonb -> 'class_policies' -> 'deep' -> 'authority_digest') = 'string'
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

  defp legacy_profile_check do
    """
    work_profile IS NULL
    OR (
      octet_length(work_profile) BETWEEN 1 AND 16384
      AND jsonb_typeof(work_profile::jsonb) = 'object'
      AND work_profile::jsonb ?& ARRAY['class_policies', 'policy', 'policy_digest', 'repository_ref']
      AND (work_profile::jsonb - 'class_policies' - 'policy' - 'policy_digest' - 'repository_ref') = '{}'::jsonb
      AND work_profile::jsonb ->> 'policy' = work_policy
      AND work_profile::jsonb ->> 'policy_digest' = work_policy_digest
      AND (work_profile::jsonb ->> 'repository_ref') IS NOT DISTINCT FROM repository_ref
      AND (
        work_profile::jsonb -> 'class_policies' = 'null'::jsonb
        OR (
          jsonb_typeof(work_profile::jsonb -> 'class_policies') = 'object'
          AND (work_profile::jsonb -> 'class_policies') ?& ARRAY['conversational', 'standard', 'deep']
          AND ((work_profile::jsonb -> 'class_policies') - 'conversational' - 'standard' - 'deep') = '{}'::jsonb
          AND #{legacy_class_policy_check("conversational")}
          AND #{legacy_class_policy_check("standard")}
          AND #{legacy_class_policy_check("deep")}
        )
      )
    )
    """
  end

  defp legacy_class_policy_check(work_class) do
    """
    jsonb_typeof(work_profile::jsonb -> 'class_policies' -> '#{work_class}') = 'object'
    AND (work_profile::jsonb -> 'class_policies' -> '#{work_class}') ?& ARRAY['policy', 'policy_digest']
    AND ((work_profile::jsonb -> 'class_policies' -> '#{work_class}') - 'policy' - 'policy_digest') = '{}'::jsonb
    AND char_length(work_profile::jsonb -> 'class_policies' -> '#{work_class}' ->> 'policy') > 0
    AND work_profile::jsonb -> 'class_policies' -> '#{work_class}' ->> 'policy_digest' ~ '^[0-9a-f]{64}$'
    """
  end
end
