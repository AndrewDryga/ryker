defmodule Ryker.Repo.Migrations.AddIngressWorkClasses do
  use Ecto.Migration

  def up do
    alter table(:ingress_inbox_entries) do
      add(:work_profile, :text)
    end

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid,
        check: """
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
              AND jsonb_typeof(work_profile::jsonb -> 'class_policies' -> 'conversational') = 'object'
              AND (work_profile::jsonb -> 'class_policies' -> 'conversational') ?& ARRAY['policy', 'policy_digest']
              AND ((work_profile::jsonb -> 'class_policies' -> 'conversational') - 'policy' - 'policy_digest') = '{}'::jsonb
              AND char_length(work_profile::jsonb -> 'class_policies' -> 'conversational' ->> 'policy') > 0
              AND work_profile::jsonb -> 'class_policies' -> 'conversational' ->> 'policy_digest' ~ '^[0-9a-f]{64}$'
              AND jsonb_typeof(work_profile::jsonb -> 'class_policies' -> 'standard') = 'object'
              AND (work_profile::jsonb -> 'class_policies' -> 'standard') ?& ARRAY['policy', 'policy_digest']
              AND ((work_profile::jsonb -> 'class_policies' -> 'standard') - 'policy' - 'policy_digest') = '{}'::jsonb
              AND char_length(work_profile::jsonb -> 'class_policies' -> 'standard' ->> 'policy') > 0
              AND work_profile::jsonb -> 'class_policies' -> 'standard' ->> 'policy_digest' ~ '^[0-9a-f]{64}$'
              AND jsonb_typeof(work_profile::jsonb -> 'class_policies' -> 'deep') = 'object'
              AND (work_profile::jsonb -> 'class_policies' -> 'deep') ?& ARRAY['policy', 'policy_digest']
              AND ((work_profile::jsonb -> 'class_policies' -> 'deep') - 'policy' - 'policy_digest') = '{}'::jsonb
              AND char_length(work_profile::jsonb -> 'class_policies' -> 'deep' ->> 'policy') > 0
              AND work_profile::jsonb -> 'class_policies' -> 'deep' ->> 'policy_digest' ~ '^[0-9a-f]{64}$'
            )
          )
        )
        """
      )
    )
  end

  def down do
    drop(constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid))

    alter table(:ingress_inbox_entries) do
      remove(:work_profile)
    end
  end
end
