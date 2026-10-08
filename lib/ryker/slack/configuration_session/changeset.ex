defmodule Ryker.Slack.ConfigurationSession.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.Slack.ConfigurationSession

  @fields [
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

  def insert(attributes) do
    %ConfigurationSession{}
    |> cast(attributes, @fields)
    |> validate_required(
      @fields -- [:current_message_ref, :initiator_ref, :response_thread_ref, :root_message_ref]
    )
    |> unique_constraint(:channel_ref, name: :slack_configuration_sessions_active_channel_index)
    |> check_constraint(:status, name: :slack_configuration_session_valid)
  end

  def update(%ConfigurationSession{} = session, attributes) do
    session
    |> cast(attributes, @fields -- [:id, :workspace_ref, :channel_ref])
    |> validate_required([:draft, :expires_at, :membership_generation, :revision, :status, :step])
    |> unique_constraint(:channel_ref, name: :slack_configuration_sessions_active_channel_index)
    |> check_constraint(:status, name: :slack_configuration_session_valid)
  end
end
