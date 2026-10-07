defmodule Ryker.ControlPlane.ChannelDirectory.Query do
  @moduledoc """
  What the Channels page reads across the Slack channels
  (`Ryker.ControlPlane.ChannelDirectory`): the newest incident room of each
  channel and how many requests each Slack conversation holds.
  """
  use Ryker, :query
  alias Ryker.Episodes.Episode
  alias Ryker.Slack.IncidentRoom

  @doc """
  The newest incident room of each channel, as `{{workspace_ref,
  channel_ref}, status, channel_state, channel_name}`.
  """
  def latest_rooms do
    from(room in IncidentRoom,
      where: not is_nil(room.channel_ref),
      distinct: [room.workspace_ref, room.channel_ref],
      order_by: [
        asc: room.workspace_ref,
        asc: room.channel_ref,
        desc: room.updated_at,
        desc: room.id
      ],
      select:
        {{room.workspace_ref, room.channel_ref}, room.status, room.channel_state,
         room.channel_name}
    )
  end

  @doc """
  How many requests each Slack conversation holds and when the latest
  changed, as `%{conversation_ref, episodes, last_at}`.
  """
  def episode_counts do
    from(episode in Episode,
      where:
        episode.destination_transport == "slack" and
          like(episode.destination_conversation_ref, "slack:%"),
      group_by: episode.destination_conversation_ref,
      select: %{
        conversation_ref: episode.destination_conversation_ref,
        episodes: count(episode.id),
        last_at: max(episode.updated_at)
      }
    )
  end
end
