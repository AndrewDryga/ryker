defmodule Ryker.Repo.Migrations.AnEnvironmentMayOnlyReadSomeOfItsRepositories do
  use Ecto.Migration

  # An environment may mark a repository read only (2026-09-27): work mounts it beside the
  # working copy and is never placed in it, so the environment's work profile names it in
  # `repositories` with no `policies`. The inbox's check still required the two to name the same
  # repositories, so no message could be recorded with such a profile: a Chat message in an
  # environment with a read-only repository was answered 409, "Message could not be accepted"
  # (2026-10-17). A profile's policies now name some of its repositories, the first, its
  # default, always among them; a CHECK passes a null, so that one is a test of its own.

  @head ~S"""
  ((work_profile IS NULL) OR (((octet_length(work_profile) >= 1) AND (octet_length(work_profile) <= 65536)) AND (jsonb_typeof((work_profile)::jsonb) = 'object'::text) AND (((NOT ((work_profile)::jsonb ? 'policies'::text)) AND (((work_profile)::jsonb ?& ARRAY['class_policies'::text, 'policy'::text, 'policy_digest'::text, 'repository_ref'::text]) AND ((((((((((work_profile)::jsonb - 'authority_digest'::text) - 'emisar_connection_ref'::text) - 'environment_ref'::text) - 'parallel_goal_limit'::text) - 'class_policies'::text) - 'policy'::text) - 'policy_digest'::text) - 'repository_ref'::text) = '{}'::jsonb) AND ((((work_profile)::jsonb ->> 'policy'::text) = work_policy) AND (((work_profile)::jsonb ->> 'policy_digest'::text) = work_policy_digest) AND (NOT (((work_profile)::jsonb ->> 'repository_ref'::text) IS DISTINCT FROM repository_ref)) AND ((NOT ((work_profile)::jsonb ? 'authority_digest'::text)) OR ((jsonb_typeof(((work_profile)::jsonb -> 'authority_digest'::text)) = 'string'::text) AND (((work_profile)::jsonb ->> 'authority_digest'::text) ~ '^[0-9a-f]{64}$'::text)))) AND (((NOT ((work_profile)::jsonb ? 'environment_ref'::text)) AND (NOT ((work_profile)::jsonb ? 'parallel_goal_limit'::text)) AND (NOT ((work_profile)::jsonb ? 'emisar_connection_ref'::text))) OR (((work_profile)::jsonb ? 'environment_ref'::text) AND ((work_profile)::jsonb ? 'parallel_goal_limit'::text) AND (jsonb_typeof(((work_profile)::jsonb -> 'environment_ref'::text)) = 'string'::text) AND (((work_profile)::jsonb ->> 'environment_ref'::text) ~ '^[a-z0-9][a-z0-9-]{0,63}$'::text) AND (jsonb_typeof(((work_profile)::jsonb -> 'parallel_goal_limit'::text)) = 'number'::text) AND (((work_profile)::jsonb ->> 'parallel_goal_limit'::text) ~ '^[1-3]$'::text) AND ((NOT ((work_profile)::jsonb ? 'emisar_connection_ref'::text)) OR ((jsonb_typeof(((work_profile)::jsonb -> 'emisar_connection_ref'::text)) = 'string'::text) AND ((char_length(((work_profile)::jsonb ->> 'emisar_connection_ref'::text)) >= 1) AND (char_length(((work_profile)::jsonb ->> 'emisar_connection_ref'::text)) <= 64)))) AND (repository_ref IS NULL))) AND ((((work_profile)::jsonb -> 'class_policies'::text) = 'null'::jsonb) OR ((jsonb_typeof(((work_profile)::jsonb -> 'class_policies'::text)) = 'object'::text) AND (((work_profile)::jsonb -> 'class_policies'::text) ?& ARRAY['conversational'::text, 'standard'::text, 'deep'::text]) AND ((((((work_profile)::jsonb -> 'class_policies'::text) - 'conversational'::text) - 'standard'::text) - 'deep'::text) = '{}'::jsonb) AND (jsonb_typeof((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text)) = 'object'::text) AND ((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ?& ARRAY['policy'::text, 'policy_digest'::text]) AND (((((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) - 'authority_digest'::text) - 'policy'::text) - 'policy_digest'::text) = '{}'::jsonb) AND (char_length(((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ->> 'policy'::text)) > 0) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ->> 'policy_digest'::text) ~ '^[0-9a-f]{64}$'::text) AND ((NOT ((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ? 'authority_digest'::text)) OR ((jsonb_typeof(((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) -> 'authority_digest'::text)) = 'string'::text) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ->> 'authority_digest'::text) ~ '^[0-9a-f]{64}$'::text))) AND (jsonb_typeof((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text)) = 'object'::text) AND ((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ?& ARRAY['policy'::text, 'policy_digest'::text]) AND (((((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) - 'authority_digest'::text) - 'policy'::text) - 'policy_digest'::text) = '{}'::jsonb) AND (char_length(((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ->> 'policy'::text)) > 0) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ->> 'policy_digest'::text) ~ '^[0-9a-f]{64}$'::text) AND ((NOT ((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ? 'authority_digest'::text)) OR ((jsonb_typeof(((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) -> 'authority_digest'::text)) = 'string'::text) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ->> 'authority_digest'::text) ~ '^[0-9a-f]{64}$'::text))) AND (jsonb_typeof((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text)) = 'object'::text) AND ((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ?& ARRAY['policy'::text, 'policy_digest'::text]) AND (((((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) - 'authority_digest'::text) - 'policy'::text) - 'policy_digest'::text) = '{}'::jsonb) AND (char_length(((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ->> 'policy'::text)) > 0) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ->> 'policy_digest'::text) ~ '^[0-9a-f]{64}$'::text) AND ((NOT ((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ? 'authority_digest'::text)) OR ((jsonb_typeof(((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) -> 'authority_digest'::text)) = 'string'::text) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ->> 'authority_digest'::text) ~ '^[0-9a-f]{64}$'::text))) AND (((NOT ((work_profile)::jsonb ? 'authority_digest'::text)) AND (NOT ((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ? 'authority_digest'::text)) AND (NOT ((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ? 'authority_digest'::text)) AND (NOT ((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ? 'authority_digest'::text))) OR ((jsonb_typeof(((work_profile)::jsonb -> 'authority_digest'::text)) = 'string'::text) AND (((work_profile)::jsonb ->> 'authority_digest'::text) ~ '^[0-9a-f]{64}$'::text) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ->> 'authority_digest'::text) = ((work_profile)::jsonb ->> 'authority_digest'::text)) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ->> 'authority_digest'::text) = ((work_profile)::jsonb ->> 'authority_digest'::text)) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ->> 'authority_digest'::text) = ((work_profile)::jsonb ->> 'authority_digest'::text)))))))) OR (((work_profile)::jsonb ? 'policies'::text) AND (((work_profile)::jsonb ?& ARRAY['environment_ref'::text, 'parallel_goal_limit'::text, 'policies'::text, 'repositories'::text]) AND (((((((work_profile)::jsonb - 'emisar_connection_ref'::text) - 'environment_ref'::text) - 'parallel_goal_limit'::text) - 'policies'::text) - 'repositories'::text) = '{}'::jsonb) AND (((work_profile)::jsonb ? 'environment_ref'::text) AND ((work_profile)::jsonb ? 'parallel_goal_limit'::text) AND (jsonb_typeof(((work_profile)::jsonb -> 'environment_ref'::text)) = 'string'::text) AND (((work_profile)::jsonb ->> 'environment_ref'::text) ~ '^[a-z0-9][a-z0-9-]{0,63}$'::text) AND (jsonb_typeof(((work_profile)::jsonb -> 'parallel_goal_limit'::text)) = 'number'::text) AND (((work_profile)::jsonb ->> 'parallel_goal_limit'::text) ~ '^[1-3]$'::text) AND ((NOT ((work_profile)::jsonb ? 'emisar_connection_ref'::text)) OR ((jsonb_typeof(((work_profile)::jsonb -> 'emisar_connection_ref'::text)) = 'string'::text) AND ((char_length(((work_profile)::jsonb ->> 'emisar_connection_ref'::text)) >= 1) AND (char_length(((work_profile)::jsonb ->> 'emisar_connection_ref'::text)) <= 64))))) AND (jsonb_typeof(((work_profile)::jsonb -> 'repositories'::text)) = 'array'::text) AND ((jsonb_array_length(((work_profile)::jsonb -> 'repositories'::text)) >= 1) AND (jsonb_array_length(((work_profile)::jsonb -> 'repositories'::text)) <= 33)) AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."repositories"[*]?(@.type() != "string" || @ == "")'::jsonpath)) AND (jsonb_typeof(((work_profile)::jsonb -> 'policies'::text)) = 'object'::text)
  """

  @every_repository_has_policies ~S"""
   AND (jsonb_path_query_array((work_profile)::jsonb, '$."policies".keyvalue()."key"'::jsonpath) @> ((work_profile)::jsonb -> 'repositories'::text)) AND (((work_profile)::jsonb -> 'repositories'::text) @> jsonb_path_query_array((work_profile)::jsonb, '$."policies".keyvalue()."key"'::jsonpath)) AND (jsonb_array_length(jsonb_path_query_array((work_profile)::jsonb, '$."policies".keyvalue()."key"'::jsonpath)) = jsonb_array_length(((work_profile)::jsonb -> 'repositories'::text)))
  """

  @policies_name_some_repositories ~S"""
   AND (((work_profile)::jsonb -> 'repositories'::text) @> jsonb_path_query_array((work_profile)::jsonb, '$."policies".keyvalue()."key"'::jsonpath)) AND (((work_profile)::jsonb -> 'policies'::text) ? (((work_profile)::jsonb -> 'repositories'::text) ->> 0))
  """

  @tail ~S"""
   AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."policies".*?(((@.type() != "object" || !(exists (@."conversational"))) || !(exists (@."standard"))) || !(exists (@."deep")))'::jsonpath)) AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."policies".*.keyvalue()?((@."key" != "conversational" && @."key" != "standard") && @."key" != "deep")'::jsonpath)) AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."policies".*.*?((@.type() != "object" || !(exists (@."policy"))) || !(exists (@."policy_digest")))'::jsonpath)) AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."policies".*.*.keyvalue()?((@."key" != "policy" && @."key" != "policy_digest") && @."key" != "authority_digest")'::jsonpath)) AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."policies".*.*?(((@."policy".type() != "string" || @."policy" == "") || @."policy_digest".type() != "string") || !(@."policy_digest" like_regex "^[0-9a-f]{64}$"))'::jsonpath)) AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."policies".*.*?(exists (@."authority_digest") && (@."authority_digest".type() != "string" || !(@."authority_digest" like_regex "^[0-9a-f]{64}$")))'::jsonpath)) AND ((((work_profile)::jsonb -> 'repositories'::text) ->> 0) = repository_ref) AND ((((((work_profile)::jsonb -> 'policies'::text) -> (((work_profile)::jsonb -> 'repositories'::text) ->> 0)) -> 'conversational'::text) ->> 'policy'::text) = work_policy) AND ((((((work_profile)::jsonb -> 'policies'::text) -> (((work_profile)::jsonb -> 'repositories'::text) ->> 0)) -> 'conversational'::text) ->> 'policy_digest'::text) = work_policy_digest))))))
  """

  def up, do: replace(@policies_name_some_repositories)

  def down do
    # The earlier check refuses a message recorded with a read-only repository in its profile.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("ingress_inbox_entries")}
        WHERE work_profile IS NOT NULL
          AND work_profile::jsonb ? 'policies'
          AND jsonb_array_length(work_profile::jsonb -> 'repositories') <>
            (SELECT count(*) FROM jsonb_object_keys(work_profile::jsonb -> 'policies'))
      ) THEN
        RAISE EXCEPTION 'Messages from environments that only read some of their repositories are still recorded; remove them before rolling back';
      END IF;
    END
    $$
    """)

    replace(@every_repository_has_policies)
  end

  defp replace(repositories) do
    drop(constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid))

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_work_class_profile_valid,
        check: Enum.map_join([@head, repositories, @tail], "", &String.trim_trailing(&1, "\n"))
      )
    )
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> "#{prefix}.#{table}"
    end
  end
end
