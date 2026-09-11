defmodule Responder.Repo.Migrations.PinWorkRepositorySource do
  use Ecto.Migration

  # Null means the session was already bound before source selection existed, or
  # carries no workspace at all. Responder never persisted a pull-request-only
  # session binding, so no existing row holds values that could prove a generic
  # selector; backfilling `default` here would relabel work that is already
  # pinned somewhere else and invite a silent re-resolution on the next rotation.
  def change do
    alter table(:episode_work_sessions) do
      add(:repository_source, :text)
    end

    create(
      constraint(:episode_work_sessions, :episode_work_session_repository_source_valid,
        check: """
        repository_source IS NULL
        OR (
          repository_ref IS NOT NULL
          AND octet_length(repository_source) BETWEEN 1 AND 1024
          AND jsonb_typeof(repository_source::jsonb) = 'object'
          AND repository_source::jsonb ? 'kind'
          AND jsonb_typeof(repository_source::jsonb -> 'kind') = 'string'
          AND (
            (
              repository_source::jsonb ->> 'kind' = 'default'
              AND (repository_source::jsonb - 'kind') = '{}'::jsonb
            )
            OR (
              repository_source::jsonb ->> 'kind' = 'branch'
              AND repository_source::jsonb ?& ARRAY['kind', 'name']
              AND (repository_source::jsonb - 'kind' - 'name') = '{}'::jsonb
              AND jsonb_typeof(repository_source::jsonb -> 'name') = 'string'
              AND octet_length(repository_source::jsonb ->> 'name') BETWEEN 1 AND 255
            )
            OR (
              repository_source::jsonb ->> 'kind' = 'pull_request'
              AND repository_source::jsonb ?& ARRAY['kind', 'number']
              AND (repository_source::jsonb - 'kind' - 'number') = '{}'::jsonb
              AND jsonb_typeof(repository_source::jsonb -> 'number') = 'number'
              AND (repository_source::jsonb ->> 'number') ~ '^([1-9][0-9]{0,6}|10000000)$'
            )
            OR (
              repository_source::jsonb ->> 'kind' = 'commit'
              AND repository_source::jsonb ?& ARRAY['kind', 'sha']
              AND (repository_source::jsonb - 'kind' - 'sha') = '{}'::jsonb
              AND jsonb_typeof(repository_source::jsonb -> 'sha') = 'string'
              AND repository_source::jsonb ->> 'sha' ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'
            )
          )
        )
        """
      )
    )
  end
end
