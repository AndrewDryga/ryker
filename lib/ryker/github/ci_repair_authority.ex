defmodule Ryker.GitHub.CIRepairAuthority do
  @moduledoc "Local host custody and fresh GitHub checks behind an automatic repair grant."
  alias Ryker.Episodes
  alias Ryker.GitHub.{CIRepair, CIRepairPolicy, CIRepairRound, Client}
  alias Ryker.Ingress
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Work

  def instruction(
        %Ingress.Inbox.Entry{
          execution_mode: :live,
          actor_kind: :system,
          source_kind: "github",
          content: %{"event_name" => "ryker_ci_repair", "repair_round_id" => id}
        } = entry,
        repository
      ) do
    with {:ok, round} <- Repo.fetch(CIRepairRound.Query.by_entry_id(entry.id)),
         true <- round.id == id and entry.event_ref == "github-ci-repair:" <> id,
         true <- entry.actor_ref == "system:github-ci-repair:" <> id,
         true <- entry.source_item_ref == entry.event_ref,
         {:ok, repair, _configured} <- current(round.snapshot["target"]),
         true <- repair.repository_ref == repository and repair.binding_ref == entry.source_ref,
         true <-
           entry.destination_conversation_ref ==
             "github:#{repair.binding_ref}:repository:#{repair.repository_id}",
         true <-
           entry.destination_thread_ref == "github:#{repair.binding_ref}:pull:#{repair.number}" do
      {:ok, {entry, entry.actor_ref}}
    else
      _revoked -> {:error, :task_instruction_not_authorized}
    end
  end

  def instruction(_entry, _repository), do: {:error, :task_instruction_not_authorized}

  def target(entry, repository) do
    with {:ok, {_entry, _actor}} <- instruction(entry, repository),
         {:ok, round} <- Repo.fetch(CIRepairRound.Query.by_entry_id(entry.id)),
         do: {:ok, round.snapshot["target"]}
  end

  @doc "Settings and the exact current round must still authorize this stored target."
  def current(
        %{
          "authorization" => %{
            "kind" => "repository_ci_policy",
            "repair_id" => repair_id,
            "round_id" => round_id
          }
        } = target
      ) do
    with {:ok, repair} <- Repo.fetch(CIRepair.Query.by_id(repair_id)),
         true <- repair.allowed and repair.current_round_id == round_id,
         {:ok, round} <- Repo.fetch(CIRepairRound.Query.by_id(round_id)),
         true <- is_nil(round.finished_at) and round.snapshot["target"] == target,
         {:ok, settings} <- Settings.fetch(),
         true <- settings.github.enabled,
         binding when not is_nil(binding) <-
           Enum.find(settings.github_bindings, &(&1.name == repair.binding_ref)),
         repository when not is_nil(repository) <-
           Enum.find(settings.repositories, &(&1.ref == repair.repository_ref)),
         true <-
           binding.repository_id == repair.repository_id and
             binding.installation_id == repair.installation_id and
             binding.repository_ref == repair.repository_ref,
         true <- binding.ryker_actor_id == target["app_actor_id"],
         :ok <- CIRepairPolicy.eligibility(repository, binding, round.snapshot["pull"]) do
      {:ok, repair, %{binding: binding, repository: repository}}
    else
      _revoked -> {:error, :ci_repair_revoked}
    end
  end

  def current(_target), do: {:error, :ci_repair_revoked}

  @doc "An old in-flight CI wakeup cannot bypass the new repair custody after upgrade."
  def ordinary_publication_allowed?(%Work.Session{episode_id: episode_id}) do
    case Repo.fetch(Episodes.Episode.Query.by_id(episode_id)) do
      {:ok, episode} ->
        events =
          episode_id
          |> Episodes.Event.Query.by_episode_id()
          |> Episodes.Event.Query.admitted_inputs(episode.active_input_refs)
          |> Repo.all()

        last_failure =
          events
          |> Enum.filter(fn event ->
            get_in(event.payload, ["payload", "content", "lifecycle", "kind"]) == "checks" and
              get_in(event.payload, ["payload", "content", "lifecycle", "state"]) == "failed"
          end)
          |> Enum.map(& &1.sequence)
          |> Enum.max(fn -> 0 end)

        last_failure == 0 or
          Enum.any?(events, fn event ->
            event.sequence > last_failure and
              get_in(event.payload, ["payload", "actor", "kind"]) == "user"
          end)

      _missing ->
        false
    end
  end

  @doc "Rechecks current labels, PR identity and head with the fresh publication credential."
  def fresh(target, client) do
    with {:ok, repair, configured} <- current(target),
         {:ok, pull} <-
           Client.CIRepair.target(
             client,
             configured.repository.github_repository,
             repair.repository_id,
             repair.number
           ),
         :ok <- CIRepairPolicy.eligibility(configured.repository, configured.binding, pull),
         true <-
           pull["head"] == target["head_commit"] and
             "refs/heads/" <> pull["branch"] == target["head_ref"] and
             "refs/heads/" <> pull["base_branch"] == target["base_ref"],
         {:ok, _repair, _configured} <- current(target) do
      :ok
    else
      {:error, reason}
      when reason in [
             :disabled,
             :skipped,
             :closed,
             :fork,
             :not_owned,
             :default_branch,
             :ci_repair_revoked
           ] ->
        {:error, :publication_grant_denied}

      false ->
        {:error, :publication_grant_denied}

      _unavailable ->
        {:error, :publication_grant_unavailable}
    end
  end
end
