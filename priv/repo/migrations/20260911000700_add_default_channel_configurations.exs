defmodule Responder.Repo.Migrations.AddDefaultChannelConfigurations do
  use Ecto.Migration

  # A joined channel is configured with defaults the moment Responder is added,
  # with no operator click. Such a configuration has no human actor, and the
  # welcome message that presents it is re-rendered in place after every save.
  @check "participation = ANY (ARRAY['mentions'::text, 'proactive'::text, 'shadow'::text]) " <>
           "AND alert_policy = ANY (ARRAY['reply'::text, 'offer'::text, 'automatic'::text]) " <>
           "AND revision > 0 AND char_length(repository_ref) > 0 " <>
           "AND (actor_ref IS NULL OR char_length(actor_ref) > 0) " <>
           "AND (welcome_message_ref IS NULL OR char_length(welcome_message_ref) > 0)"

  def up do
    alter table(:slack_channel_configurations) do
      add(:welcome_message_ref, :text)
      modify(:actor_ref, :text, null: true, from: {:text, null: false})
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
        WHERE actor_ref IS NULL
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'default channel configurations have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:slack_channel_configurations, :slack_channel_configuration_valid))

    alter table(:slack_channel_configurations) do
      remove(:welcome_message_ref)
      modify(:actor_ref, :text, null: false, from: {:text, null: true})
    end

    create(
      constraint(:slack_channel_configurations, :slack_channel_configuration_valid,
        check:
          "participation = ANY (ARRAY['mentions'::text, 'proactive'::text, 'shadow'::text]) " <>
            "AND alert_policy = ANY (ARRAY['reply'::text, 'offer'::text, 'automatic'::text]) " <>
            "AND revision > 0 AND char_length(repository_ref) > 0 " <>
            "AND char_length(actor_ref) > 0"
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
