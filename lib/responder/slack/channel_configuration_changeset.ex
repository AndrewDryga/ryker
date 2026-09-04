defmodule Responder.Slack.ChannelConfigurationChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Slack.{
    ChannelConfiguration,
    ChannelMembership,
    ChannelMembershipEvent,
    ConfigurationAction,
    ConfigurationSession
  }

  @membership_fields [
    :channel_ref,
    :deleted_at,
    :external_shared,
    :generation,
    :id,
    :joined_at,
    :left_at,
    :private,
    :status,
    :workspace_ref
  ]
  @event_fields [
    :actor_ref,
    :channel_ref,
    :event_fingerprint,
    :event_ref,
    :id,
    :kind,
    :membership_id,
    :occurred_at,
    :workspace_ref
  ]
  @session_fields [
    :channel_ref,
    :current_message_ref,
    :draft,
    :expires_at,
    :id,
    :initiator_ref,
    :membership_generation,
    :response_thread_ref,
    :revision,
    :root_message_ref,
    :start_event_ref,
    :start_fingerprint,
    :status,
    :step,
    :workspace_ref
  ]
  @configuration_fields [
    :actor_ref,
    :alert_policy,
    :channel_ref,
    :id,
    :invite_user_group_refs,
    :invite_user_refs,
    :participation,
    :repository_ref,
    :revision,
    :saved_at,
    :workspace_ref
  ]
  @action_fields [
    :action,
    :actor_ref,
    :event_fingerprint,
    :event_ref,
    :id,
    :outcome,
    :session_id,
    :session_revision
  ]

  def membership(attributes) do
    %ChannelMembership{}
    |> cast(attributes, @membership_fields)
    |> validate_required([:channel_ref, :generation, :id, :status, :workspace_ref])
    |> unique_constraint(:channel_ref)
    |> check_constraint(:status, name: :slack_channel_membership_valid)
  end

  def membership(%ChannelMembership{} = membership, attributes) do
    membership
    |> cast(attributes, [
      :deleted_at,
      :external_shared,
      :generation,
      :joined_at,
      :left_at,
      :private,
      :status
    ])
    |> validate_required([:generation, :status])
    |> check_constraint(:status, name: :slack_channel_membership_valid)
  end

  def membership_event(attributes) do
    %ChannelMembershipEvent{}
    |> cast(attributes, @event_fields)
    |> validate_required(@event_fields -- [:actor_ref])
    |> unique_constraint(:event_ref)
    |> check_constraint(:kind, name: :slack_channel_membership_event_valid)
  end

  def session(attributes) do
    %ConfigurationSession{}
    |> cast(attributes, @session_fields)
    |> validate_required(
      @session_fields --
        [:current_message_ref, :initiator_ref, :response_thread_ref, :root_message_ref]
    )
    |> unique_constraint(:channel_ref,
      name: :slack_configuration_sessions_active_channel_index
    )
    |> check_constraint(:status, name: :slack_configuration_session_valid)
  end

  def session(%ConfigurationSession{} = session, attributes) do
    session
    |> cast(attributes, @session_fields -- [:id, :workspace_ref, :channel_ref])
    |> validate_required([:draft, :expires_at, :membership_generation, :revision, :status, :step])
    |> unique_constraint(:channel_ref,
      name: :slack_configuration_sessions_active_channel_index
    )
    |> check_constraint(:status, name: :slack_configuration_session_valid)
  end

  def configuration(attributes) do
    %ChannelConfiguration{}
    |> cast(attributes, @configuration_fields)
    |> validate_required(@configuration_fields)
    |> unique_constraint(:channel_ref)
    |> check_constraint(:participation, name: :slack_channel_configuration_valid)
  end

  def configuration(%ChannelConfiguration{} = configuration, attributes) do
    configuration
    |> cast(attributes, @configuration_fields -- [:id, :workspace_ref, :channel_ref])
    |> validate_required(@configuration_fields -- [:id, :workspace_ref, :channel_ref])
    |> check_constraint(:participation, name: :slack_channel_configuration_valid)
  end

  def action(attributes) do
    %ConfigurationAction{}
    |> cast(attributes, @action_fields)
    |> validate_required(@action_fields)
    |> unique_constraint(:event_ref)
    |> check_constraint(:event_ref, name: :slack_configuration_action_valid)
  end
end
