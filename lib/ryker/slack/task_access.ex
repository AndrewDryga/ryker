defmodule Ryker.Slack.TaskAccess do
  @moduledoc "The conversation's current repository policy, shared by task requests and task buttons."
  alias Ryker.ConversationRef
  alias Ryker.CoopFleet
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Maps
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Slack.{ChannelMembership, ChannelSettings}
  alias Ryker.Slack.IncidentRooms

  @doc "The settings that determine writable task policies, without unrelated runtime settings."
  @spec authority_configuration(map()) :: map()
  def authority_configuration(snapshot) do
    %{
      policies:
        for binding <- CoopFleet.JobTemplates.from_settings(snapshot),
            binding.purpose == :contributor do
          {binding.policy_name, binding.policy_digest}
        end,
      environments:
        for environment <- snapshot.environments do
          {environment.ref, Settings.Environment.repository_refs(environment),
           Settings.Environment.writable_refs(environment), environment.parallel_goal_limit}
        end
    }
  end

  @doc "Authorize a current full workspace member's repository request."
  def authorize(
        %Ingress.Inbox.Entry{source_kind: "slack", actor_kind: :user} = entry,
        repository,
        options
      ) do
    with {:ok, workspace, channel} <-
           ConversationRef.parse_slack(entry.destination_conversation_ref),
         true <- workspace == options.workspace_ref and workspace == entry.source_ref,
         {:ok, true} <- options.directory.user_allowed(options.client, entry.actor_ref, workspace) do
      policy(workspace, channel, repository, options)
    else
      _ -> {:error, :task_instruction_not_authorized}
    end
  end

  def authorize(_entry, _repository, _options), do: {:error, :task_instruction_not_authorized}

  @doc "Whether the current live channel participation permits proactive code fixes."
  @spec proactive?(Episodes.Episode.t() | Ingress.Inbox.Entry.t()) :: boolean()
  def proactive?(%Episodes.Episode{
        execution_mode: :live,
        destination_transport: "slack",
        destination_conversation_ref: conversation,
        id: episode_id
      }),
      do: proactive_channel?(conversation, episode_id)

  def proactive?(
        %Ingress.Inbox.Entry{
          execution_mode: :live,
          destination_transport: "slack",
          source_kind: "slack",
          source_ref: workspace,
          destination_conversation_ref: conversation
        } = entry
      ) do
    case ConversationRef.parse_slack(conversation) do
      {:ok, ^workspace, _channel} -> proactive_channel?(conversation, entry.episode_id)
      _invalid -> false
    end
  end

  def proactive?(
        %Ingress.Inbox.Entry{
          execution_mode: :live,
          destination_transport: "slack",
          source_kind: kind,
          destination_conversation_ref: conversation
        } = entry
      )
      when kind in ["github", "webhook"],
      do: proactive_channel?(conversation, entry.episode_id)

  def proactive?(%Records.IncidentInstruction{} = source),
    do: proactive_channel?(source.destination_conversation_ref, source.episode_id)

  def proactive?(_source), do: false

  defp proactive_channel?(conversation, episode_id) do
    with {:ok, workspace, channel} <- ConversationRef.parse_slack(conversation),
         false <- String.starts_with?(channel, "D"),
         {:ok,
          %Settings.Slack{
            enabled: true,
            workspace_ref: ^workspace,
            default_participation: default
          }} <- Repo.fetch(Settings.Slack.Query.all()) do
      effective = ChannelSettings.effective(workspace, conversation, default)

      case IncidentRooms.fetch_channel_room(workspace, channel) do
        {:ok, room} ->
          # Successful provisioning and the pinned root prove access before
          # Slack's asynchronous join event arrives. Known leaves still refuse.
          membership_status(workspace, channel) not in [:left, :deleted] and
            current_room?(room, episode_id) and
            confirmed_room?(room) and
            room_permission?(room, effective, default)

        {:error, :not_found} ->
          joined?(workspace, channel) and effective.proactive.value and not effective.shadow.value
      end
    else
      _not_proactive -> false
    end
  end

  defp current_room?(room, episode_id) do
    room.episode_id == episode_id and room.status == :ready and
      room.channel_state == :active and is_nil(room.close_requested_at)
  end

  defp confirmed_room?(room) do
    case Repo.fetch(Records.Record.Query.by_id(room.record_id)) do
      {:ok,
       %{
         kind: "task_offer",
         status: :confirmed,
         confirmed_episode_id: episode_id,
         payload: %{"kind" => "incident"}
       }} ->
        episode_id == room.episode_id

      _not_confirmed ->
        false
    end
  end

  defp room_permission?(_room, %{shadow: %{source: :channel, value: true}}, _default), do: false
  defp room_permission?(_room, %{proactive: %{source: :channel, value: true}}, _default), do: true

  defp room_permission?(_room, %{proactive: %{source: :channel, value: false}}, _default),
    do: false

  defp room_permission?(room, _inherited, default) do
    source = ConversationRef.slack(room.workspace_ref, room.source_channel_ref)

    joined?(room.workspace_ref, room.source_channel_ref) and
      ChannelSettings.effective(room.workspace_ref, source, default).proactive.value
  end

  defp joined?(workspace, channel) do
    membership_status(workspace, channel) == :joined
  end

  defp membership_status(workspace, channel) do
    Repo.one(
      ChannelMembership.Query.select_statuses(
        ChannelMembership.Query.by_channel(workspace, channel)
      )
    )
  end

  @doc "Authorize a proactive fix using the current channel and unchanged writable task settings."
  def authorize_proactive(%Ingress.Inbox.Entry{} = entry, repository, options),
    do: authorize_channel_fix(entry, repository, options)

  def authorize_proactive(%Records.IncidentInstruction{} = source, repository, options),
    do: authorize_channel_fix(source, repository, options)

  def authorize_proactive(_entry, _repository, _options),
    do: {:error, :task_instruction_not_authorized}

  defp authorize_channel_fix(entry, repository, options) do
    with true <- proactive?(entry),
         {:ok, workspace, channel} <-
           ConversationRef.parse_slack(entry.destination_conversation_ref),
         true <- workspace == options.workspace_ref,
         configuration when is_map(configuration) <- Map.get(options, :authority_configuration),
         true <- authority_configuration(Settings.fetch!()) == configuration do
      case IncidentRooms.fetch_channel_room(workspace, channel) do
        {:ok, room} -> policy(workspace, room.source_channel_ref, repository, options)
        {:error, :not_found} -> policy(workspace, channel, repository, options)
      end
    else
      _changed -> {:error, :task_instruction_not_authorized}
    end
  end

  @doc "Resolve the writable repository in the environment this conversation selects now."
  def policy(workspace, channel, repository, options) do
    environment_ref = options.conversation_environment.(workspace, channel)

    case environment_ref && Map.get(options.environments, environment_ref) do
      %{contributor_policies: policies} when map_size(policies) > 0 ->
        case Map.get(policies, repository) do
          %{digest: digest, name: name} = policy ->
            {:ok,
             %{digest: digest, environment_ref: environment_ref, name: name}
             |> Maps.put_present(:repository_ref, Map.get(policy, :repository_ref))
             |> Maps.put_present(:repository_context, Map.get(policy, :repository_context))}

          nil ->
            {:error, {:slack_task_outside_environment, repository}}
        end

      _ ->
        {:error, {:slack_task_policy_not_configured, repository}}
    end
  end
end
