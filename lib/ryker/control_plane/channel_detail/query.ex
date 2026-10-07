defmodule Ryker.ControlPlane.ChannelDetail.Query do
  @moduledoc """
  What a Slack channel's page reads of the channel itself
  (`Ryker.ControlPlane.ChannelDetail`): how it is set up, Ryker's membership,
  its latest incident room, and the requests and schedules of its
  conversation. Every read keys on the channel's identity
  (`Ryker.ControlPlane.ChannelScope`).
  """
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Schedules.Schedule
  alias Ryker.Slack.{ChannelConfiguration, ChannelMembership, IncidentRoom}

  @doc "The channel's setup, with the revision the page's choices are drawn from."
  def configuration(scope) do
    from(configuration in ChannelConfiguration,
      where:
        configuration.workspace_ref == ^scope.workspace_ref and
          configuration.channel_ref == ^scope.channel_ref,
      limit: 1,
      select: %{
        id: configuration.id,
        actor_ref: configuration.actor_ref,
        alert_policy: configuration.alert_policy,
        invite_user_group_refs: configuration.invite_user_group_refs,
        invite_user_refs: configuration.invite_user_refs,
        participation: configuration.participation,
        environment_ref: configuration.environment_ref,
        revision: configuration.revision,
        saved_at: configuration.saved_at
      }
    )
  end

  @doc "Ryker's membership of the channel."
  def membership(scope) do
    from(membership in ChannelMembership,
      where:
        membership.workspace_ref == ^scope.workspace_ref and
          membership.channel_ref == ^scope.channel_ref,
      limit: 1,
      select: %{
        deleted_at: membership.deleted_at,
        external_shared: membership.external_shared,
        generation: membership.generation,
        joined_at: membership.joined_at,
        left_at: membership.left_at,
        private: membership.private,
        status: membership.status,
        updated_at: membership.updated_at
      }
    )
  end

  @doc "The incident room the channel is, if it is one, as its page names it."
  def incident_room(scope) do
    from(room in IncidentRoom,
      left_join: episode in Episode,
      on: episode.id == room.episode_id,
      where:
        room.workspace_ref == ^scope.workspace_ref and room.channel_ref == ^scope.channel_ref,
      order_by: [desc: room.updated_at, desc: room.id],
      limit: 1,
      select: %{
        channel_name: room.channel_name,
        channel_state: room.channel_state,
        episode_id: room.episode_id,
        private: room.private,
        ref: room.ref,
        repository_ref: room.repository_ref,
        status: room.status,
        title: room.title,
        updated_at: room.updated_at
      }
    )
  end

  @doc "The requests of the channel's conversation, as its page lists them."
  def episodes(scope) do
    from(episode in Episode,
      where:
        episode.destination_transport == "slack" and
          episode.destination_conversation_ref == ^scope.conversation_ref,
      select: %{
        execution_mode: episode.execution_mode,
        id: episode.id,
        ref: episode.key,
        state: episode.state,
        thread_ref: episode.destination_thread_ref,
        updated_at: episode.updated_at
      }
    )
  end

  @doc "The schedules that post to the channel's conversation, as its page lists them."
  def schedules(scope) do
    from(schedule in Schedule,
      where:
        schedule.destination_transport == "slack" and
          schedule.destination_conversation_ref == ^scope.conversation_ref,
      select: %{
        next_occurrence_at: schedule.next_occurrence_at,
        ref: schedule.ref,
        status: schedule.status,
        title: schedule.title
      }
    )
  end
end
