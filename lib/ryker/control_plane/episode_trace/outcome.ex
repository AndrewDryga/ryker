defmodule Ryker.ControlPlane.EpisodeTrace.Outcome do
  @moduledoc """
  "What came of it": platform actions and their confirmations, incident rooms
  and schedules the episode created, publications it offered, and the current
  follow-through on anything still outstanding.
  """

  import Ecto.Query
  import Ryker.ControlPlane.EpisodeTrace.Step

  alias Ryker.ControlPlane.InspectionRedactor
  alias Ryker.Delivery.PlatformAction
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.Slack.IncidentRoom
  alias Ryker.State.Schedule

  @doc "The episode's platform actions, oldest first, bounded."
  def platform_actions(episode_id) do
    Repo.all(
      from(action in PlatformAction,
        where: action.episode_id == ^episode_id,
        order_by: [asc: action.inserted_at, asc: action.id],
        limit: 200
      )
    )
  end

  @doc "Each platform action as queued, and as confirmed when it was."
  def platform_action_steps(actions) do
    Enum.flat_map(actions, fn action ->
      queued =
        step(
          "platform-action-#{action.id}",
          :outcome,
          action.inserted_at,
          %{
            actor: action.transport,
            details:
              compact_details([
                {"Action", action.action_ref, identifier: true},
                {"Conversation", action.conversation_ref, identifier: true},
                {"Thread", action.thread_ref, identifier: true}
              ]),
            stage: "Platform action",
            state: "queued",
            summary: "Queued for #{capitalize(action.transport)} delivery.",
            title: platform_action_title(action.tool),
            tone: nil
          }
        )

      if action.delivered_at do
        [
          queued,
          step("platform-action-#{action.id}-confirmed", :outcome, action.delivered_at, %{
            actor: action.transport,
            details: [],
            stage: "Platform action",
            state: "confirmed",
            title: platform_action_title(action.tool) <> " confirmed",
            summary: "#{capitalize(action.transport)} confirmed the action.",
            tone: :good
          })
        ]
      else
        [queued]
      end
    end)
  end

  @doc "Incident rooms the episode requested or was opened from."
  def incident_steps(episode_id) do
    Repo.all(
      from(room in IncidentRoom,
        where: room.episode_id == ^episode_id or room.source_episode_id == ^episode_id,
        order_by: [asc: room.requested_at, asc: room.id],
        limit: 50
      )
    )
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
          href: "/incident-rooms/#{segment(room.ref)}",
          stage: "Incident",
          state: nil,
          summary: "An incident room was requested. Open the room for its current state.",
          title: "Incident room requested",
          tone: nil
        }
      )
    end)
  end

  @doc "The episode's publications, oldest first, bounded."
  def publications(episode_id) do
    Repo.all(
      from(publication in Publication,
        where: publication.episode_id == ^episode_id,
        order_by: [asc: publication.inserted_at, asc: publication.id],
        limit: 50
      )
    )
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
          href:
            if(action.status == :blocked, do: "/failures/delivery/#{segment(action.action_ref)}"),
          link_label: "Open recovery"
        }
      end

    publication_status =
      for publication <- publications, publication.status != :published do
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
        order_by: [asc: schedule.confirmed_at, asc: schedule.id],
        limit: 50
      )
    )
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
          href: "/schedules/#{segment(schedule.ref)}",
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
  defp platform_action_title(:set_slack_reaction), do: "Slack reaction"
  defp platform_action_title(:set_github_reaction), do: "GitHub reaction"
  defp platform_action_title(tool), do: human(tool)
end
