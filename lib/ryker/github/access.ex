defmodule Ryker.GitHub.Access do
  @moduledoc "Applies authenticated GitHub App installation and repository access changes."

  alias Ryker.GitHub.Binding
  alias Ryker.{IntegrationSetup, Settings}

  @actor "github:webhook"

  def affected("installation_repositories", payload, bindings) do
    installation_id = get_in(payload, ["installation", "id"])
    changed_ids = ids(payload["repositories_added"]) ++ ids(payload["repositories_removed"])
    matching(bindings, installation_id) |> Enum.filter(&(&1.repository_id in changed_ids))
  end

  def affected("installation", payload, bindings),
    do: matching(bindings, get_in(payload, ["installation", "id"]))

  def affected("repository", payload, bindings) do
    installation_id = get_in(payload, ["installation", "id"])
    repository_id = get_in(payload, ["repository", "id"])

    bindings
    |> Map.values()
    |> Enum.filter(&(&1.installation_id == installation_id and &1.repository_id == repository_id))
  end

  def affected(_event, _payload, _bindings), do: []

  def apply("installation_repositories", payload, bindings) do
    installation_id = get_in(payload, ["installation", "id"])
    added = ids(payload["repositories_added"])
    removed = ids(payload["repositories_removed"])
    installed = matching(bindings, installation_id)

    with :ok <- refresh_permissions(installed, payload),
         {:ok, changed} <-
           installed
           |> Enum.filter(&(&1.repository_id in added or &1.repository_id in removed))
           |> update_many(&repository_membership(&1, removed)),
         :ok <- maybe_import_new_repositories(payload) do
      {:ok, changed}
    end
  end

  def apply("installation", payload, bindings) do
    installation_id = get_in(payload, ["installation", "id"])
    installed = matching(bindings, installation_id)

    state =
      case payload["action"] do
        "suspended" -> {:suspended, :blocked, "The GitHub App installation is suspended."}
        "deleted" -> {:removed, :blocked, "The GitHub App installation was removed."}
        "unsuspended" -> {:available, :pending, nil}
        "created" -> {:available, :pending, nil}
        _action -> nil
      end

    with :ok <- refresh_permissions(installed, payload) do
      if state do
        update_many(installed, &apply_access_state(&1, state))
      else
        {:ok, []}
      end
    end
  end

  def apply("repository", payload, bindings) do
    installation_id = get_in(payload, ["installation", "id"])
    repository_id = get_in(payload, ["repository", "id"])

    state =
      case payload["action"] do
        action when action in ["deleted", "archived"] ->
          {:removed, :blocked, "This repository is no longer available to Ryker."}

        action when action in ["renamed", "transferred", "unarchived", "edited"] ->
          {:available, nil, nil}

        _action ->
          nil
      end

    if state do
      bindings
      |> Map.values()
      |> Enum.filter(
        &(&1.installation_id == installation_id and &1.repository_id == repository_id)
      )
      |> update_many(&update_repository(&1, state, payload))
    else
      {:ok, []}
    end
  end

  def apply(_event, _payload, _bindings), do: {:ok, []}

  defp repository_membership(binding, removed) do
    if binding.repository_id in removed,
      do: access(binding, :removed, :blocked, "GitHub App access was removed."),
      else: access(binding, :available, :pending, nil)
  end

  defp apply_access_state(binding, state),
    do: access(binding, elem(state, 0), elem(state, 1), elem(state, 2))

  defp update_repository(binding, state, payload) do
    with {:ok, _snapshot} <- apply_access_state(binding, state),
         full_name when is_binary(full_name) <- get_in(payload, ["repository", "full_name"]) do
      rename(binding, full_name)
    else
      {:error, _reason} = error -> error
      _invalid_name -> :ok
    end
  end

  defp maybe_import_new_repositories(payload) do
    snapshot = Settings.fetch!()

    case snapshot.github.auto_add_repositories do
      true -> import_new_repositories(payload, snapshot.github.bot_actor_id)
      false -> :ok
    end
  end

  defp import_new_repositories(payload, actor_id) do
    payload
    |> repositories_added()
    |> import_repositories(actor_id)
  end

  defp repositories_added(payload) do
    account = get_in(payload, ["installation", "account"]) || %{}
    installation_id = get_in(payload, ["installation", "id"])
    permissions = get_in(payload, ["installation", "permissions"]) || %{}

    for repository <- List.wrap(payload["repositories_added"]),
        is_integer(repository["id"]),
        is_binary(repository["full_name"]) do
      %{
        default_branch: repository["default_branch"] || "main",
        full_name: repository["full_name"],
        installation_account: account["login"],
        installation_account_id: account["id"],
        installation_id: installation_id,
        permissions: permissions,
        private: repository["private"] == true,
        repository_id: repository["id"]
      }
    end
  end

  defp import_repositories([], _actor_id), do: :ok

  defp import_repositories(repositories, actor_id) do
    case IntegrationSetup.import_github_repositories(repositories, ryker_actor_id: actor_id) do
      {:ok, %{failed: []}} -> :ok
      {:ok, _partial} -> {:error, :github_repository_auto_import_failed}
      {:error, _reason} = error -> error
    end
  end

  defp matching(bindings, installation_id) do
    bindings |> Map.values() |> Enum.filter(&(&1.installation_id == installation_id))
  end

  defp refresh_permissions(bindings, payload) do
    case get_in(payload, ["installation", "permissions"]) do
      permissions when is_map(permissions) and map_size(permissions) > 0 ->
        bindings
        |> update_many(fn binding ->
          snapshot = Settings.fetch!()

          Settings.put_github_binding(
            %{
              name: binding.name,
              action_grants: IntegrationSetup.github_action_grants(permissions),
              granted_permissions: permissions
            },
            snapshot.installation.revision,
            @actor
          )
        end)
        |> case do
          {:ok, _updated} -> :ok
          {:error, _reason} = error -> error
        end

      _missing ->
        :ok
    end
  end

  defp ids(values) when is_list(values),
    do: for(%{"id" => id} <- values, is_integer(id), do: id)

  defp ids(_values), do: []

  defp update_many(bindings, callback) do
    Enum.reduce_while(bindings, {:ok, []}, fn binding, {:ok, changed} ->
      case callback.(binding) do
        :ok -> {:cont, {:ok, [binding | changed]}}
        {:ok, _snapshot} -> {:cont, {:ok, [binding | changed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp access(%Binding{name: ref}, access, onboarding, error) do
    snapshot = Settings.fetch!()
    repository = Enum.find(snapshot.repositories, &(&1.ref == ref))

    if repository do
      attributes =
        %{ref: ref, github_access: access, onboarding_error: error}
        |> maybe_put(:onboarding_state, onboarding)

      Settings.put_repository(attributes, snapshot.installation.revision, @actor)
    else
      {:ok, nil}
    end
  end

  defp rename(%Binding{name: ref}, full_name) do
    snapshot = Settings.fetch!()

    Settings.put_repository(
      %{ref: ref, display_name: full_name, github_repository: full_name},
      snapshot.installation.revision,
      @actor
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
