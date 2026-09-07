defmodule Responder.Repo.Migrations.FreezeSlackAddressingOnIngress do
  use Ecto.Migration

  def up do
    alter table(:ingress_inbox_entries) do
      add(:slack_audience, :text)
      add(:slack_bot_user_ref, :text)
    end

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_slack_addressing_valid,
        check: """
        (slack_audience IS NULL AND slack_bot_user_ref IS NULL) OR (
          slack_audience IS NOT NULL AND slack_bot_user_ref IS NOT NULL AND
          source_kind = 'slack' AND slack_audience IN ('ambient', 'direct', 'mention') AND
          octet_length(slack_bot_user_ref) BETWEEN 1 AND 256 AND
          slack_bot_user_ref !~ '[^A-Z0-9]'
        )
        """
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("ingress_inbox_entries")}
        WHERE slack_audience IS NOT NULL OR slack_bot_user_ref IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'Slack addressing history cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:ingress_inbox_entries, :ingress_inbox_slack_addressing_valid))

    alter table(:ingress_inbox_entries) do
      remove(:slack_audience)
      remove(:slack_bot_user_ref)
    end
  end

  defp qualified(table) do
    escaped = String.replace(prefix() || "public", "\"", "\"\"")
    "\"#{escaped}\".\"#{table}\""
  end
end
