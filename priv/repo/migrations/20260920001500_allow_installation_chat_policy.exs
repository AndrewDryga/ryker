defmodule Ryker.Repo.Migrations.AllowInstallationChatPolicy do
  use Ecto.Migration

  @reference "^[a-z][a-z0-9_-]{0,63}$"
  @hex64 "^[0-9a-f]{64}$"

  def up do
    drop(constraint(:policy_bindings, :policy_binding_valid))

    create(
      constraint(:policy_bindings, :policy_binding_valid,
        check:
          "purpose IN ('admission', 'learning', 'incident', 'schedule_read_only', 'schedule_governed', " <>
            "'conversational', 'standard', 'deep', 'contributor', 'schedule') " <>
            "AND scope_kind IN ('installation', 'repository', 'context') " <>
            "AND ((scope_kind = 'installation' AND scope_ref = '') OR " <>
            "(scope_kind <> 'installation' AND scope_ref ~ '#{@reference}')) " <>
            "AND ((purpose IN ('admission', 'conversational', 'learning', 'incident', 'schedule_read_only', 'schedule_governed') " <>
            "AND scope_kind = 'installation') OR " <>
            "(purpose IN ('conversational', 'standard', 'deep', 'contributor') AND scope_kind <> 'installation') OR " <>
            "(purpose = 'schedule' AND scope_kind = 'repository')) " <>
            "AND char_length(policy_name) BETWEEN 1 AND 256 AND policy_digest ~ '#{@hex64}' " <>
            "AND (authority_digest IS NULL OR authority_digest ~ '#{@hex64}') " <>
            "AND verified_by IN ('worker', 'import') " <>
            "AND (verified_worker_ref IS NULL OR char_length(verified_worker_ref) BETWEEN 1 AND 256)"
      )
    )
  end

  def down do
    execute(
      "DELETE FROM policy_bindings WHERE purpose = 'conversational' AND scope_kind = 'installation'"
    )

    drop(constraint(:policy_bindings, :policy_binding_valid))

    create(
      constraint(:policy_bindings, :policy_binding_valid,
        check:
          "purpose IN ('admission', 'learning', 'incident', 'schedule_read_only', 'schedule_governed', " <>
            "'conversational', 'standard', 'deep', 'contributor', 'schedule') " <>
            "AND scope_kind IN ('installation', 'repository', 'context') " <>
            "AND ((scope_kind = 'installation' AND scope_ref = '') OR " <>
            "(scope_kind <> 'installation' AND scope_ref ~ '#{@reference}')) " <>
            "AND ((purpose IN ('admission', 'learning', 'incident', 'schedule_read_only', 'schedule_governed') " <>
            "AND scope_kind = 'installation') OR " <>
            "(purpose IN ('conversational', 'standard', 'deep', 'contributor') AND scope_kind <> 'installation') OR " <>
            "(purpose = 'schedule' AND scope_kind = 'repository')) " <>
            "AND char_length(policy_name) BETWEEN 1 AND 256 AND policy_digest ~ '#{@hex64}' " <>
            "AND (authority_digest IS NULL OR authority_digest ~ '#{@hex64}') " <>
            "AND verified_by IN ('worker', 'import') " <>
            "AND (verified_worker_ref IS NULL OR char_length(verified_worker_ref) BETWEEN 1 AND 256)"
      )
    )
  end
end
