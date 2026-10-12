defmodule Ryker.Repo.Migrations.WorkReadsAnyRepositoryItMounts do
  use Ecto.Migration

  # A Work session's repository had to be its working copy. Work that only reads runs in its
  # environment's default placement now, which mounts every repository of the environment, and
  # keeps the repository it is about as its own: one session kept ready serves a conversation
  # about any of them (Andrew, 2026-10-12: "any session should be able to serve any repo").
  # The session's repository may be the working copy or one mounted read-only beside it; the
  # working copy itself is still never also mounted read-only.

  @shape_before_repository """
  ((repository_context IS NULL) OR (((octet_length(repository_context) >= 1) AND (octet_length(repository_context) <= 16384)) AND (jsonb_typeof((repository_context)::jsonb) = 'object'::text) AND ((repository_context)::jsonb ?& ARRAY['context_ref'::text, 'parallel_goal_limit'::text, 'primary_repository'::text, 'read_only_repositories'::text]) AND ((((((repository_context)::jsonb - 'context_ref'::text) - 'parallel_goal_limit'::text) - 'primary_repository'::text) - 'read_only_repositories'::text) = '{}'::jsonb) AND (jsonb_typeof(((repository_context)::jsonb -> 'context_ref'::text)) = 'string'::text) AND ((char_length(((repository_context)::jsonb ->> 'context_ref'::text)) >= 1) AND (char_length(((repository_context)::jsonb ->> 'context_ref'::text)) <= 256)) AND (jsonb_typeof(((repository_context)::jsonb -> 'primary_repository'::text)) = 'string'::text) AND 
  """

  @shape_between """
   AND (jsonb_typeof(((repository_context)::jsonb -> 'parallel_goal_limit'::text)) = 'number'::text) AND (((repository_context)::jsonb ->> 'parallel_goal_limit'::text) ~ '^[1-3]$'::text) AND (jsonb_typeof(((repository_context)::jsonb -> 'read_only_repositories'::text)) = 'array'::text) AND (jsonb_array_length(((repository_context)::jsonb -> 'read_only_repositories'::text)) <= 32) AND 
  """

  @shape_after """
  ))
  """

  @working_copy """
  (((repository_context)::jsonb ->> 'primary_repository'::text) = repository_ref)
  """

  @mounted """
  ((((repository_context)::jsonb ->> 'primary_repository'::text) = repository_ref) OR (((repository_context)::jsonb -> 'read_only_repositories'::text) @> jsonb_build_array(repository_ref)))
  """

  @working_copy_not_read_only """
  (NOT (((repository_context)::jsonb -> 'read_only_repositories'::text) @> jsonb_build_array(repository_ref)))
  """

  @primary_not_read_only """
  (NOT (((repository_context)::jsonb -> 'read_only_repositories'::text) @> jsonb_build_array(((repository_context)::jsonb ->> 'primary_repository'::text))))
  """

  def up, do: replace(@mounted, @primary_not_read_only)

  def down do
    # The earlier check holds only work whose repository is its working copy.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("episode_work_sessions")}
        WHERE repository_context IS NOT NULL
          AND (repository_context::jsonb ->> 'primary_repository') <> repository_ref
      ) THEN
        RAISE EXCEPTION 'Work sessions about a repository mounted beside their working copy are still recorded; remove them before rolling back';
      END IF;
    END
    $$
    """)

    replace(@working_copy, @working_copy_not_read_only)
  end

  defp replace(repository, read_only) do
    drop(constraint(:episode_work_sessions, :episode_work_session_repository_context_valid))

    create(
      constraint(:episode_work_sessions, :episode_work_session_repository_context_valid,
        check:
          Enum.map_join(
            [@shape_before_repository, repository, @shape_between, read_only, @shape_after],
            " ",
            &String.trim/1
          )
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
