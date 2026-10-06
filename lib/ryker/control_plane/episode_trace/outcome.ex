defmodule Ryker.ControlPlane.EpisodeTrace.Outcome do
  @moduledoc """
  "What came of it": platform actions and their confirmations, incident rooms
  and schedules the episode created, publications it offered, and the current
  follow-through on anything still outstanding.
  """

  import Ecto.Query
  import Ryker.ControlPlane.EpisodeTrace.Step
  alias Ryker.ControlPlane.Emoji
  alias Ryker.ControlPlane.Paths
  alias Ryker.Delivery.PlatformAction
  alias Ryker.InspectionRedactor
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.Schedules.Schedule
  alias Ryker.Slack.IncidentRoom

  @doc "The episode's newest 200 platform actions, oldest first."
  def platform_actions(episode_id) do
    Repo.all(
      from(action in PlatformAction,
        where: action.episode_id == ^episode_id,
        order_by: [desc: action.inserted_at, desc: action.id],
        limit: 200
      )
    )
    |> Enum.reverse()
  end

  @doc """
  Each platform action as Ryker asked for it, and as its platform confirmed
  it when it did. History cards stay as they were at their time, so the first
  one says what was asked rather than a state ("Queued") that went stale
  beside its own confirmation (Andrew, 2026-09-26). A reply's supporting
  record links to the first card.
  """
  def platform_action_steps(actions) do
    Enum.flat_map(actions, fn action ->
      platform = platform(action.transport)

      asked =
        step(
          "platform-action-#{action.id}",
          :outcome,
          action.inserted_at,
          %{
            actor: platform,
            details:
              compact_details([
                {"Action", action.action_ref, identifier: true},
                {"Conversation", action.conversation_ref, identifier: true},
                {"Thread", action.thread_ref, identifier: true}
              ]),
            record_ref: action.action_ref,
            stage: "Platform action",
            state: nil,
            summary: "Asked #{platform} to #{platform_action_request(action)}.",
            title: platform_action_title(action.tool),
            tone: nil
          }
        )

      if action.delivered_at do
        [
          asked,
          step("platform-action-#{action.id}-confirmed", :outcome, action.delivered_at, %{
            actor: platform,
            delivery_ref: action.action_ref,
            details: [],
            stage: "Platform action",
            state: "confirmed",
            title: platform_action_title(action.tool) <> " confirmed",
            summary: "#{platform} #{platform_action_done(action)}.",
            tone: :good
          })
        ]
      else
        [asked]
      end
    end)
  end

  defp platform_action_request(%PlatformAction{kind: :reaction, document: document}) do
    case reaction(document) do
      {"remove", emoji} -> "remove #{emoji} from the message"
      {_add, emoji} -> "add #{emoji} to the message"
    end
  end

  defp platform_action_request(_action), do: "post the message"

  # Where an action went, as people call it: "Asked Control_plane to post the
  # message." (2026-10-04 review).
  defp platform("control_plane"), do: "Chat"
  defp platform("github"), do: "GitHub"
  defp platform(transport), do: capitalize(transport)

  defp platform_action_done(%PlatformAction{kind: :reaction, document: document}) do
    case reaction(document) do
      {"remove", emoji} -> "removed #{emoji} from the message"
      {_add, emoji} -> "added #{emoji} to the message"
    end
  end

  defp platform_action_done(_action), do: "posted the message"

  defp reaction(%{"action" => action, "emoji_name" => name}) when is_binary(name),
    do: {action, Emoji.glyph(name)}

  defp reaction(_document), do: {"add", "the reaction"}

  @doc "Incident rooms the episode requested or was opened from."
  def incident_steps(episode_id) do
    Repo.all(
      from(room in IncidentRoom,
        where: room.episode_id == ^episode_id or room.source_episode_id == ^episode_id,
        order_by: [desc: room.requested_at, desc: room.id],
        limit: 50
      )
    )
    |> Enum.reverse()
    |> Enum.map(fn room ->
      step(
        "incident-#{room.id}",
        :outcome,
        room.requested_at || room.inserted_at,
        %{
          actor: "Ryker",
          details:
            compact_details([
              {"Incident room", room.ref, identifier: true},
              {"Repository", room.repository_ref}
            ]),
          href: Paths.incident_room(room.ref),
          stage: "Incident",
          state: nil,
          summary: "An incident room was requested. Open the room for its current state.",
          title: "Incident room requested",
          tone: nil
        }
      )
    end)
  end

  @doc "The episode's newest 50 publications, oldest first."
  def publications(episode_id) do
    Repo.all(
      from(publication in Publication,
        where: publication.episode_id == ^episode_id,
        order_by: [desc: publication.inserted_at, desc: publication.id],
        limit: 50
      )
    )
    |> Enum.reverse()
  end

  @doc "Each publication as requested, and as published when it was."
  def publication_steps(publications) do
    Enum.flat_map(publications, fn publication ->
      requested =
        step(
          "publication-#{publication.id}",
          :outcome,
          publication.inserted_at,
          %{
            actor: "Ryker",
            details:
              compact_details([
                {"Publication", publication.ref, identifier: true},
                {"Repository", publication.repository}
              ]),
            stage: "Publication",
            state: nil,
            summary: "Changes were offered for review before publication.",
            title: "Publication requested",
            tone: nil
          }
        )

      if publication.published_at do
        [
          requested,
          step("publication-#{publication.id}-published", :outcome, publication.published_at, %{
            actor: "Ryker",
            stage: "Publication",
            state: nil,
            title: "Draft pull request published",
            summary: "Pull request ##{publication.pull_request_number}",
            details:
              compact_details([
                {"Repository", publication.repository},
                {"Branch", publication.branch_ref},
                {"Commit", publication.commit_sha, identifier: true}
              ]),
            tone: :good
          })
        ]
      else
        [requested]
      end
    end)
  end

  @doc """
  What is still outstanding, as it stands now.

  Current follow-through is deliberately outside historical timeline events.
  Retrying may change this status; it must not rewrite the original request.
  """
  def follow_through(actions, publications, source) do
    action_status =
      for action <- actions,
          action.status != :delivered,
          action.status == :blocked or not is_nil(action.last_error_code) do
        %{
          id: "platform-action-#{action.id}",
          title: platform_action_title(action.tool),
          state: capitalize(human(action.status)),
          error: InspectionRedactor.artifact(action.last_error_code).text,
          href: if(action.status == :blocked, do: Paths.failure("delivery", action.action_ref)),
          link_label: "Open recovery"
        }
      end

    # A discarded draft ended; nothing more will happen to it (2026-10-04 review).
    publication_status =
      for publication <- publications, publication.status not in [:published, :discarded] do
        %{
          id: "publication-#{publication.id}",
          title: InspectionRedactor.artifact(publication.title).text,
          state: capitalize(human(publication.status)),
          error: InspectionRedactor.artifact(publication.last_error_code).text,
          href: if(source, do: source.href),
          link_label: "Open conversation"
        }
      end

    action_status ++ publication_status
  end

  @doc "Schedules the episode created."
  def schedule_steps(episode_id) do
    Repo.all(
      from(schedule in Schedule,
        where: schedule.source_episode_id == ^episode_id,
        order_by: [desc: schedule.confirmed_at, desc: schedule.id],
        limit: 50
      )
    )
    |> Enum.reverse()
    |> Enum.map(fn schedule ->
      step(
        "schedule-#{schedule.id}",
        :outcome,
        schedule.confirmed_at || schedule.inserted_at,
        %{
          actor: "Ryker",
          details:
            compact_details([
              {"Schedule", schedule.ref, identifier: true}
            ]),
          href: Paths.schedule(schedule.ref),
          stage: "Schedule",
          state: nil,
          summary: "A schedule was created. Open it for its configuration and next run.",
          title: "Schedule created",
          tone: nil
        }
      )
    end)
  end

  defp platform_action_title(:post_slack_message), do: "Additional message"
  defp platform_action_title(:post_slack_update), do: "Update"
  defp platform_action_title(:set_slack_reaction), do: "Slack reaction"
  defp platform_action_title(:set_github_reaction), do: "GitHub reaction"
  defp platform_action_title(tool), do: human(tool)
end
