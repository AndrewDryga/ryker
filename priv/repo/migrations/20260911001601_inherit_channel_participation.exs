defmodule Ryker.Repo.Migrations.InheritChannelParticipation do
  use Ecto.Migration

  # One effective channel participation replaces the competing override store.
  # A channel row with no participation inherits the installation default, so
  # inheritance is represented as inheritance instead of copying a default that
  # may later change. Existing rows keep their explicit value: they are the
  # effective setting today, and rewriting them would change live behavior.
  @check "(participation IS NULL OR participation = ANY (ARRAY['mentions'::text, 'proactive'::text, 'shadow'::text])) " <>
           "AND alert_policy = ANY (ARRAY['reply'::text, 'offer'::text, 'automatic'::text]) " <>
           "AND revision > 0 AND char_length(repository_ref) > 0 " <>
           "AND (actor_ref IS NULL OR char_length(actor_ref) > 0) " <>
           "AND (welcome_message_ref IS NULL OR char_length(welcome_message_ref) > 0)"

  def up do
    alter table(:slack_channel_configurations) do
      modify(:participation, :text, null: true, from: {:text, null: false})
    end

    drop(constraint(:slack_channel_configurations, :slack_channel_configuration_valid))

    create(
      constraint(:slack_channel_configurations, :slack_channel_configuration_valid, check: @check)
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("slack_channel_configurations")}
        WHERE participation IS NULL
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'inherited channel participation has data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:slack_channel_configurations, :slack_channel_configuration_valid))

    alter table(:slack_channel_configurations) do
      modify(:participation, :text, null: false, from: {:text, null: true})
    end

    create(
      constraint(:slack_channel_configurations, :slack_channel_configuration_valid,
        check:
          "participation = ANY (ARRAY['mentions'::text, 'proactive'::text, 'shadow'::text]) " <>
            "AND alert_policy = ANY (ARRAY['reply'::text, 'offer'::text, 'automatic'::text]) " <>
            "AND revision > 0 AND char_length(repository_ref) > 0 " <>
            "AND (actor_ref IS NULL OR char_length(actor_ref) > 0) " <>
            "AND (welcome_message_ref IS NULL OR char_length(welcome_message_ref) > 0)"
      )
    )
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
