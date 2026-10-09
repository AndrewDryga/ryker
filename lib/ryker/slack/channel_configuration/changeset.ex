defmodule Ryker.Slack.ChannelConfiguration.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.Slack.ChannelConfiguration

  @fields [
    :actor_ref,
    :alert_policy,
    :channel_ref,
    :environment_ref,
    :id,
    :invite_user_group_refs,
    :invite_user_refs,
    :participation,
    :revision,
    :saved_at,
    :welcome_digest,
    :welcome_message_ref,
    :workspace_ref
  ]
  # A configuration with no participation inherits the installation default;
  # one with no environment runs outside any; an absent actor is a
  # configuration nobody was asked to make.
  @optional_fields [
    :actor_ref,
    :environment_ref,
    :participation,
    :welcome_digest,
    :welcome_message_ref
  ]

  def insert(attributes) do
    %ChannelConfiguration{}
    |> cast(attributes, @fields)
    |> validate_required(@fields -- @optional_fields)
    |> unique_constraint(:channel_ref,
      name: :slack_channel_configurations_workspace_ref_channel_ref_index
    )
    |> environment_constraint()
    |> check_constraint(:participation, name: :slack_channel_configuration_valid)
  end

  def update(%ChannelConfiguration{} = configuration, attributes) do
    fields = @fields -- [:id, :workspace_ref, :channel_ref]

    configuration
    |> cast(attributes, fields)
    |> validate_required(fields -- @optional_fields)
    |> environment_constraint()
    |> check_constraint(:participation, name: :slack_channel_configuration_valid)
  end

  # An environment removed after it was offered is refused by its foreign key.
  defp environment_constraint(changeset) do
    foreign_key_constraint(changeset, :environment_ref,
      name: :slack_channel_configurations_environment_ref_fkey
    )
  end
end
