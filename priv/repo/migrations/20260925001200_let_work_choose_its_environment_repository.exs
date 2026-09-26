defmodule Ryker.Repo.Migrations.LetWorkChooseItsEnvironmentRepository do
  @moduledoc """
  An environment's repositories are a set: each piece of work chooses the one
  it changes, and every session mounts the others read-only beside it.

  An environment's policy bindings are therefore per repository:
  `policy_bindings.repository_ref` names the repository a binding of scope
  `environment` is for, and is empty for every other scope. A binding saved
  before this declared the environment's first repository as the working copy,
  so it becomes that repository's binding.

  The Work profile frozen on an inbox entry describes the whole environment:
  its repositories in order and each one's class policies. The first pass
  froze only the writable first repository and the ones it read, which names
  no choice, so the upgrade refuses an entry still carrying that shape rather
  than rewriting its history. None existed on the live installation.

  A Chat conversation stores the environment chosen for it, nil for "No
  environment". A removed environment leaves its conversations outside any.
  Rolling back refuses while a conversation has a stored environment, an
  environment has bindings for more than one repository, or an entry carries
  the per-repository profile.
  """
  use Ecto.Migration

  @slug "^[a-z0-9][a-z0-9-]{0,63}$"
  @reference "^[a-z0-9][a-z0-9_-]{0,63}$"
  @hex64 "^[0-9a-f]{64}$"

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("ingress_inbox_entries")}
        WHERE work_profile IS NOT NULL
          AND work_profile::jsonb ? 'environment_ref'
          AND repository_ref IS NOT NULL
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'inbox entries frozen with a first-pass environment profile must be resolved before work chooses its environment repository';
      END IF;
    END
    $$
    """)

    alter table(:policy_bindings) do
      add(:repository_ref, :text, null: false, default: "")
    end

    execute("""
    UPDATE #{qualified("policy_bindings")} AS binding
    SET repository_ref = repository.repository_ref
    FROM #{qualified("environment_repository_settings")} AS repository
    WHERE binding.scope_kind = 'environment'
      AND repository.environment_ref = binding.scope_ref
      AND repository.position = 0
    """)

    execute("""
    DELETE FROM #{qualified("policy_bindings")}
    WHERE scope_kind = 'environment' AND repository_ref = ''
    """)

    drop(unique_index(:policy_bindings, [:purpose, :scope_kind, :scope_ref]))
    create(unique_index(:policy_bindings, [:purpose, :scope_kind, :scope_ref, :repository_ref]))

    create(
      constraint(:policy_bindings, :policy_binding_repository_valid,
        check:
          "(scope_kind = 'environment' AND repository_ref ~ '#{@reference}') OR " <>
            "(scope_kind <> 'environment' AND repository_ref = '')"
      )
    )

    drop(constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid))

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid,
        check: profile_check(:repository_set)
      )
    )

    create table(:control_plane_conversations, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :environment_ref,
        references(:environment_settings, column: :ref, type: :text, on_delete: :nilify_all)
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:control_plane_conversations, [:environment_ref]))

    execute("""
    CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR UPDATE OR DELETE
      ON #{qualified("control_plane_conversations")} FOR EACH STATEMENT
      EXECUTE FUNCTION #{qualified("ryker_control_plane_notify")}()
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
           SELECT 1 FROM #{qualified("control_plane_conversations")}
           WHERE environment_ref IS NOT NULL LIMIT 1
         )
         OR EXISTS (
           SELECT 1 FROM #{qualified("policy_bindings")}
           WHERE scope_kind = 'environment'
           GROUP BY purpose, scope_ref HAVING count(*) > 1
         )
         OR EXISTS (
           SELECT 1 FROM #{qualified("ingress_inbox_entries")}
           WHERE work_profile IS NOT NULL AND work_profile::jsonb ? 'policies' LIMIT 1
         ) THEN
        RAISE EXCEPTION 'environment repository choices have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(table(:control_plane_conversations))

    drop(constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid))

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid,
        check: profile_check(:first_repository)
      )
    )

    drop(constraint(:policy_bindings, :policy_binding_repository_valid))
    drop(unique_index(:policy_bindings, [:purpose, :scope_kind, :scope_ref, :repository_ref]))
    create(unique_index(:policy_bindings, [:purpose, :scope_kind, :scope_ref]))

    alter table(:policy_bindings) do
      remove(:repository_ref)
    end
  end

  # The Work profile an inbox entry carries: an environment's repository set
  # with each repository's class policies, or one placement (outside any
  # environment, or in one without repositories). The first pass froze an
  # environment's writable repository and the ones it read instead.
  defp profile_check(:repository_set) do
    """
    work_profile IS NULL
    OR (
      octet_length(work_profile) BETWEEN 1 AND 65536
      AND jsonb_typeof(work_profile::jsonb) = 'object'
      AND (
        (NOT (work_profile::jsonb ? 'policies') AND #{single_check()})
        OR (work_profile::jsonb ? 'policies' AND #{repository_set_check()})
      )
    )
    """
  end

  defp profile_check(:first_repository) do
    """
    work_profile IS NULL
    OR (
      octet_length(work_profile) BETWEEN 1 AND 16384
      AND jsonb_typeof(work_profile::jsonb) = 'object'
      AND work_profile::jsonb ?& ARRAY['class_policies', 'policy', 'policy_digest', 'repository_ref']
      AND (work_profile::jsonb - 'authority_digest' - 'emisar_connection_ref' - 'environment_ref' - 'parallel_goal_limit' - 'read_only_repository_refs' - 'class_policies' - 'policy' - 'policy_digest' - 'repository_ref') = '{}'::jsonb
      AND #{base_check()}
      AND #{first_repository_placement_check()}
      AND #{class_policies_check()}
    )
    """
  end

  # Outside an environment nothing else is placed; an environment without
  # repositories has its goal limit, optionally an Emisar account, and no
  # repository.
  defp single_check do
    """
    (
      work_profile::jsonb ?& ARRAY['class_policies', 'policy', 'policy_digest', 'repository_ref']
      AND (work_profile::jsonb - 'authority_digest' - 'emisar_connection_ref' - 'environment_ref' - 'parallel_goal_limit' - 'class_policies' - 'policy' - 'policy_digest' - 'repository_ref') = '{}'::jsonb
      AND #{base_check()}
      AND (
        (
          NOT (work_profile::jsonb ? 'environment_ref')
          AND NOT (work_profile::jsonb ? 'parallel_goal_limit')
          AND NOT (work_profile::jsonb ? 'emisar_connection_ref')
        )
        OR (
          #{environment_placement_check()}
          AND repository_ref IS NULL
        )
      )
      AND #{class_policies_check()}
    )
    """
  end

  # The inbox columns hold the default placement: the first repository and its
  # conversation policy.
  defp repository_set_check do
    """
    (
      work_profile::jsonb ?& ARRAY['environment_ref', 'parallel_goal_limit', 'policies', 'repositories']
      AND (work_profile::jsonb - 'emisar_connection_ref' - 'environment_ref' - 'parallel_goal_limit' - 'policies' - 'repositories') = '{}'::jsonb
      AND #{environment_placement_check()}
      AND jsonb_typeof(work_profile::jsonb -> 'repositories') = 'array'
      AND jsonb_array_length(work_profile::jsonb -> 'repositories') BETWEEN 1 AND 33
      AND NOT jsonb_path_exists(work_profile::jsonb, '$.repositories[*] ? (@.type() != "string" || @ == "")')
      AND jsonb_typeof(work_profile::jsonb -> 'policies') = 'object'
      AND jsonb_path_query_array(work_profile::jsonb, '$.policies.keyvalue().key') @> (work_profile::jsonb -> 'repositories')
      AND (work_profile::jsonb -> 'repositories') @> jsonb_path_query_array(work_profile::jsonb, '$.policies.keyvalue().key')
      AND jsonb_array_length(jsonb_path_query_array(work_profile::jsonb, '$.policies.keyvalue().key')) = jsonb_array_length(work_profile::jsonb -> 'repositories')
      AND NOT jsonb_path_exists(work_profile::jsonb, '$.policies.* ? (@.type() != "object" || !exists(@.conversational) || !exists(@.standard) || !exists(@.deep))')
      AND NOT jsonb_path_exists(work_profile::jsonb, '$.policies.*.keyvalue() ? (@.key != "conversational" && @.key != "standard" && @.key != "deep")')
      AND NOT jsonb_path_exists(work_profile::jsonb, '$.policies.*.* ? (@.type() != "object" || !exists(@.policy) || !exists(@.policy_digest))')
      AND NOT jsonb_path_exists(work_profile::jsonb, '$.policies.*.*.keyvalue() ? (@.key != "policy" && @.key != "policy_digest" && @.key != "authority_digest")')
      AND NOT jsonb_path_exists(work_profile::jsonb, '$.policies.*.* ? (@.policy.type() != "string" || @.policy == "" || @.policy_digest.type() != "string" || !(@.policy_digest like_regex "#{@hex64}"))')
      AND NOT jsonb_path_exists(work_profile::jsonb, '$.policies.*.* ? (exists(@.authority_digest) && (@.authority_digest.type() != "string" || !(@.authority_digest like_regex "#{@hex64}")))')
      AND work_profile::jsonb -> 'repositories' ->> 0 = repository_ref
      AND work_profile::jsonb -> 'policies' -> (work_profile::jsonb -> 'repositories' ->> 0) -> 'conversational' ->> 'policy' = work_policy
      AND work_profile::jsonb -> 'policies' -> (work_profile::jsonb -> 'repositories' ->> 0) -> 'conversational' ->> 'policy_digest' = work_policy_digest
    )
    """
  end

  defp base_check do
    """
    (
      work_profile::jsonb ->> 'policy' = work_policy
      AND work_profile::jsonb ->> 'policy_digest' = work_policy_digest
      AND (work_profile::jsonb ->> 'repository_ref') IS NOT DISTINCT FROM repository_ref
      AND (
        NOT (work_profile::jsonb ? 'authority_digest')
        OR (
          jsonb_typeof(work_profile::jsonb -> 'authority_digest') = 'string'
          AND work_profile::jsonb ->> 'authority_digest' ~ '#{@hex64}'
        )
      )
    )
    """
  end

  defp environment_placement_check do
    """
    (
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
    )
    """
  end

  defp first_repository_placement_check do
    """
    (
      (
        NOT (work_profile::jsonb ? 'environment_ref')
        AND NOT (work_profile::jsonb ? 'parallel_goal_limit')
        AND NOT (work_profile::jsonb ? 'read_only_repository_refs')
        AND NOT (work_profile::jsonb ? 'emisar_connection_ref')
      )
      OR (
        #{environment_placement_check()}
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

  defp class_policies_check do
    """
    (
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

  defp qualified(name) do
    case prefix() do
      nil -> name
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{name})
    end
  end
end
