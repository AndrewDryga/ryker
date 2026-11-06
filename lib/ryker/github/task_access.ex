defmodule Ryker.GitHub.TaskAccess do
  @moduledoc "Authorizes a human GitHub instruction against current repository task access."
  alias Ryker.CoopFleet
  alias Ryker.GitHub.Binding
  alias Ryker.Ingress
  alias Ryker.Settings

  @doc "The saved authority an applied GitHub task grant depends on."
  def authority_configuration(snapshot) do
    %{
      github: Map.take(snapshot.github, [:enabled, :app_id, :api_url, :bot_actor_id]),
      bindings:
        Enum.map(
          snapshot.github_bindings,
          &Map.take(&1, [
            :name,
            :installation_id,
            :repository_id,
            :repository_ref,
            :ryker_actor_id
          ])
        ),
      repositories:
        Enum.map(
          snapshot.repositories,
          &Map.take(&1, [:ref, :github_repository, :github_access, :base_branch])
        ),
      environments:
        Enum.map(snapshot.environments, fn environment ->
          {environment.ref, Settings.Environment.repository_refs(environment),
           Settings.Environment.writable_refs(environment), environment.parallel_goal_limit}
        end),
      policies:
        for template <- CoopFleet.JobTemplates.from_settings(snapshot),
            template.purpose == :contributor do
          {template.policy_name, template.policy_digest}
        end
    }
  end

  @doc "Recheck the sender's write access before starting work in the event's own repository."
  def authorize(entry, repository, options) do
    with {:ok, _policy} <- policy(entry, repository, options),
         %{binding: binding} <- Map.fetch!(options.bindings, entry.source_ref),
         :ok <- options.repository_access.(binding, entry.content["payload"]) do
      policy(entry, repository, options)
    end
  end

  @doc "Resolve the unchanged local grant, also under the task-start settings fence."
  def policy(
        %Ingress.Inbox.Entry{
          execution_mode: :live,
          source_kind: "github",
          source_ref: source,
          destination_transport: "github",
          actor_kind: :user,
          actor_ref: actor,
          content: %{"payload" => payload}
        },
        repository,
        options
      ) do
    with %{binding: binding, repository: ^repository, policy: %{} = policy} <-
           Map.get(options.bindings, source),
         %{"sender" => %{"id" => sender, "type" => "User"}} <- payload,
         true <- actor == "github-user:#{sender}",
         :ok <- Binding.authorize_payload(binding, payload),
         {:ok, snapshot} <- Settings.fetch(),
         true <- snapshot.github.enabled,
         true <- authority_configuration(snapshot) == options.configuration do
      {:ok,
       Map.take(policy, [
         :name,
         :digest,
         :environment_ref,
         :repository_ref,
         :repository_context
       ])}
    else
      _invalid -> {:error, :task_instruction_not_authorized}
    end
  end

  def policy(_entry, _repository, _options),
    do: {:error, :task_instruction_not_authorized}
end
