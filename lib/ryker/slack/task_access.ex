defmodule Ryker.Slack.TaskAccess do
  @moduledoc "The conversation's current repository policy, shared by task requests and task buttons."
  alias Ryker.ConversationRef
  alias Ryker.Ingress
  alias Ryker.Maps

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
