defmodule Ryker.Slack.AppHomeActions do
  @moduledoc """
  Reconstructs privileged App Home targets from durable Slack-owned state.

  Home payloads contain no channel or message container. These functions bind
  an opaque resource reference back to its exact workspace before invoking the
  existing generation-fenced publication and retention operators.
  """
  alias Ryker.ConversationRef
  alias Ryker.Episodes
  alias Ryker.Operator
  alias Ryker.Publication
  alias Ryker.Repo
  alias Ryker.Schedules
  alias Ryker.Slack.{HomeInteraction, HomeSubmission}
  alias Ryker.Work

  @destination_actions [
    :delete_schedule,
    :discard_publication,
    :discard_workspace,
    :pause_schedule,
    :resume_schedule,
    :retry_publication,
    :run_schedule,
    :update_publication
  ]

  @doc "Rechecks exact user/channel visibility before a stale Home control can mutate state."
  @spec authorize_resource(HomeInteraction.t() | HomeSubmission.t(), module(), term()) ::
          :ok | {:error, term()}
  def authorize_resource(%{action: action}, _api, _client)
      when action not in @destination_actions,
      do: :ok

  def authorize_resource(
        %HomeInteraction{actor_ref: actor_ref, workspace_ref: workspace_ref} = interaction,
        api,
        client
      ) do
    with true <- is_atom(api) and function_exported?(api, :shared_conversations, 3),
         {:ok, %MapSet{} = shared_conversations} <-
           api.shared_conversations(client, actor_ref, workspace_ref),
         {:ok, destination_ref} <- destination_ref(interaction),
         true <- destination_visible?(destination_ref, workspace_ref, shared_conversations) do
      :ok
    else
      false -> {:error, :app_home_resource_not_visible}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, {:invalid_app_home_authorization, :shared_conversations}}
    end
  end

  def authorize_resource(_interaction, _api, _client),
    do: {:error, {:invalid_app_home_authorization, :interaction}}

  @spec recover_publication(
          String.t(),
          :retry | :update | :discard,
          pos_integer(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def recover_publication(
        publication_ref,
        action,
        expected_generation,
        actor_ref,
        workspace_ref,
        action_ref
      ) do
    with %Publication.Publication{} = publication <-
           Repo.one(Publication.Publication.Query.by_ref(publication_ref)),
         true <- slack_workspace?(publication, workspace_ref) do
      Operator.Publication.recover(publication.ref, action, expected_generation,
        actor_ref: "slack:user:#{actor_ref}",
        action_ref: action_ref
      )
    else
      nil -> {:error, :publication_not_found}
      false -> {:error, :publication_workspace_mismatch}
    end
  end

  @spec discard_workspace(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def discard_workspace(
        session_ref,
        expected_plan_fingerprint,
        actor_ref,
        workspace_ref,
        action_ref
      ) do
    case retained_session(session_ref) do
      {%Work.Session{} = session, %Episodes.Episode{} = episode} ->
        if slack_workspace?(episode, workspace_ref) do
          Operator.Retention.discard_unmerged(
            session.external_ref,
            expected_plan_fingerprint,
            "slack:user:#{actor_ref}",
            action_ref
          )
        else
          {:error, :retention_session_workspace_mismatch}
        end

      nil ->
        {:error, :retention_session_not_found}
    end
  end

  defp retained_session(session_ref) do
    session_ref
    |> Work.Session.Query.by_external_ref()
    |> Work.Session.Query.select_with_episode()
    |> Repo.one()
  end

  defp destination_ref(%HomeInteraction{action: :run_schedule, resource_ref: ref}),
    do: schedule_destination(ref)

  defp destination_ref(%HomeInteraction{
         action: action,
         resource_ref: "schedule-control:" <> value
       })
       when action in [:pause_schedule, :resume_schedule, :delete_schedule] do
    case String.split(value, ":") do
      parts when length(parts) >= 3 ->
        parts |> Enum.drop(-1) |> Enum.join(":") |> schedule_destination()

      _invalid ->
        {:error, :app_home_resource_not_visible}
    end
  end

  defp destination_ref(%HomeInteraction{
         action: action,
         resource_ref: "publication-recovery:" <> value
       })
       when action in [:retry_publication, :update_publication, :discard_publication] do
    case String.split(value, ":", parts: 2) do
      [id, _generation] ->
        case Repo.one(Publication.Publication.Query.by_ref("publication:#{id}")) do
          %Publication.Publication{destination_conversation_ref: destination_ref} ->
            {:ok, destination_ref}

          nil ->
            {:error, :app_home_resource_not_visible}
        end

      _invalid ->
        {:error, :app_home_resource_not_visible}
    end
  end

  defp destination_ref(%HomeInteraction{
         action: :discard_workspace,
         resource_ref: "ryker-work-control:" <> value
       }) do
    case String.split(value, ":") do
      parts when length(parts) >= 4 ->
        session_ref = parts |> Enum.drop(-1) |> Enum.join(":")

        case retained_session(session_ref) do
          {%Work.Session{}, %Episodes.Episode{destination_conversation_ref: destination_ref}} ->
            {:ok, destination_ref}

          nil ->
            {:error, :app_home_resource_not_visible}
        end

      _invalid ->
        {:error, :app_home_resource_not_visible}
    end
  end

  defp destination_ref(_interaction), do: {:error, :app_home_resource_not_visible}

  defp schedule_destination("schedule:" <> _ = schedule_ref) do
    case Repo.one(Schedules.Schedule.Query.by_ref(schedule_ref)) do
      %Schedules.Schedule{destination_conversation_ref: destination_ref} -> {:ok, destination_ref}
      nil -> {:error, :app_home_resource_not_visible}
    end
  end

  defp schedule_destination(_ref), do: {:error, :app_home_resource_not_visible}

  defp destination_visible?("slack:" <> _ = destination_ref, workspace_ref, conversations) do
    case ConversationRef.parse_slack(destination_ref) do
      {:ok, ^workspace_ref, channel_ref} -> MapSet.member?(conversations, channel_ref)
      _other -> false
    end
  end

  defp destination_visible?(_destination_ref, _workspace_ref, _conversations), do: false

  defp slack_workspace?(resource, workspace_ref) do
    resource.destination_transport == "slack" and
      String.starts_with?(
        resource.destination_conversation_ref,
        ConversationRef.slack_prefix(workspace_ref)
      )
  end
end
