defmodule Ryker.Repo.Migrations.MoveIncidentInvitationsIntoChannels do
  use Ecto.Migration

  # Who joins an incident room was configured in two places: a global list in
  # `slack_settings`, edited in the configuration page, and the people a channel
  # named in its own setup thread. The setup card then had to explain both,
  # offering "On-call responders only — I'll invite the 2 configured on-call
  # responders" beside "Choose responders", which is a question about our
  # storage rather than about their team. The channel list is the one a person
  # can actually maintain from Slack, so it becomes the only one, and the global
  # list is folded into every channel that does not already name its people.
  def up do
    execute("""
    UPDATE #{qualified("slack_channel_configurations")} AS channels
    SET invite_user_refs = (
          SELECT ARRAY(
            SELECT DISTINCT unnest(channels.invite_user_refs || settings.incident_invite_users)
          )
          FROM #{qualified("slack_settings")} AS settings
          LIMIT 1
        ),
        updated_at = now()
    WHERE EXISTS (
      SELECT 1
      FROM #{qualified("slack_settings")} AS settings
      WHERE array_length(settings.incident_invite_users, 1) > 0
    )
    """)

    alter table(:slack_settings) do
      remove(:incident_invite_users)
    end
  end

  def down do
    alter table(:slack_settings) do
      add(:incident_invite_users, {:array, :text}, default: [], null: false)
    end

    # The channels kept the people; rolling back restores the column, not a
    # second copy of a list somebody may have since edited in one place only.
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
