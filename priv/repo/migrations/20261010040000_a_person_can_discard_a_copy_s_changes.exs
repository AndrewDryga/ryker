defmodule Ryker.Repo.Migrations.APersonCanDiscardACopysChanges do
  use Ecto.Migration

  # A working copy kept for uncommitted changes was checked again forever and the page offered
  # no way to let it go (manual test, 2026-10-09). A person can now discard the changes: the
  # session records that acceptance, and the audited operator action has a name for it.

  @with_unmerged "((char_length(action_ref) >= 1) AND (char_length(action_ref) <= 1024) AND (char_length(request_fingerprint) = 64) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 1024)) AND (action = ANY (ARRAY['rearm'::text, 'discard_unmerged'::text])) AND (previous_status = ANY (ARRAY['blocked'::text, 'retained'::text])) AND (result_status = ANY (ARRAY['close_pending'::text, 'plan_pending'::text, 'discard_pending'::text])) AND ((previous_plan_fingerprint IS NULL) OR (char_length(previous_plan_fingerprint) = 64)))"
  @with_changes "((char_length(action_ref) >= 1) AND (char_length(action_ref) <= 1024) AND (char_length(request_fingerprint) = 64) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 1024)) AND (action = ANY (ARRAY['rearm'::text, 'discard_unmerged'::text, 'discard_changes'::text])) AND (previous_status = ANY (ARRAY['blocked'::text, 'retained'::text])) AND (result_status = ANY (ARRAY['close_pending'::text, 'plan_pending'::text, 'discard_pending'::text])) AND ((previous_plan_fingerprint IS NULL) OR (char_length(previous_plan_fingerprint) = 64)))"

  def up do
    alter table(:episode_work_sessions) do
      add(:discard_plan_accept_dirty, :boolean, null: false, default: false)
    end

    replace_check(@with_changes)
  end

  # A recorded "discard_changes" action has no name under the previous rule, so a rollback with
  # one on file refuses rather than losing the audit row.
  def down do
    replace_check(@with_unmerged)

    alter table(:episode_work_sessions) do
      remove(:discard_plan_accept_dirty)
    end
  end

  defp replace_check(check) do
    drop(constraint(:retention_operator_actions, :retention_operator_action_valid))

    create(
      constraint(:retention_operator_actions, :retention_operator_action_valid, check: check)
    )
  end
end
