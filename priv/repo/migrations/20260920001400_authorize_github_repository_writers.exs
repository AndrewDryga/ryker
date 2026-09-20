defmodule Ryker.Repo.Migrations.AuthorizeGitHubRepositoryWriters do
  use Ecto.Migration

  def up do
    drop(constraint(:github_binding_settings, :github_binding_settings_valid))
    drop(constraint(:github_settings, :github_settings_operator_valid))

    alter table(:github_binding_settings) do
      remove(:authorized_actor_ids)
    end

    alter table(:github_settings) do
      remove(:operator_actor_id)
      remove(:operator_login)
    end

    create(
      constraint(:github_binding_settings, :github_binding_settings_valid,
        check:
          "name ~ '^[a-z][a-z0-9_-]{0,63}$' AND installation_id > 0 AND repository_id > 0 " <>
            "AND ryker_actor_id > 0"
      )
    )
  end

  def down do
    drop(constraint(:github_binding_settings, :github_binding_settings_valid))

    alter table(:github_settings) do
      add(:operator_actor_id, :bigint)
      add(:operator_login, :text)
    end

    alter table(:github_binding_settings) do
      add(:authorized_actor_ids, {:array, :bigint}, null: false, default: [])
    end

    create(
      constraint(:github_binding_settings, :github_binding_settings_valid,
        check:
          "name ~ '^[a-z][a-z0-9_-]{0,63}$' AND installation_id > 0 AND repository_id > 0 " <>
            "AND ryker_actor_id > 0 AND cardinality(authorized_actor_ids) BETWEEN 0 AND 256"
      )
    )

    create(
      constraint(:github_settings, :github_settings_operator_valid,
        check:
          "(operator_actor_id IS NULL AND operator_login IS NULL) OR " <>
            "(operator_actor_id > 0 AND char_length(operator_login) BETWEEN 1 AND 256)"
      )
    )
  end
end
