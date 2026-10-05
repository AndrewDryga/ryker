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

  @doc """
  Whether an event gives the App repositories, which auto-add may add even
  though no binding names them yet: repositories added to an installation, or
  a new installation's.
  """
  @spec adds_repositories?(String.t(), map()) :: boolean()
  def adds_repositories?(event, payload), do: repositories_added(event, payload) != []

  @events ["installation", "installation_repositories", "repository"]

  @doc """
  Applies one event as one settings change.

  The permission refresh, access states, renames and auto-imported
  repositories commit together or not at all, so a failed event that GitHub
  redelivers finds nothing half applied.
  """
  def apply(event, payload, bindings) when event in @events,
    do: Settings.atomically(fn -> apply_event(event, payload, bindings, Settings.fetch!()) end)

  def apply(_event, _payload, _bindings), do: {:ok, []}

  defp apply_event("installation_repositories", payload, bindings, snapshot) do
    removed = ids(payload["repositories_removed"])
    installed = matching(bindings, get_in(payload, ["installation", "id"]))
    changed = affected("installation_repositories", payload, bindings)

    with {:ok, snapshot} <- refresh_permissions(installed, payload, snapshot),
         {:ok, snapshot} <- update_many(changed, snapshot, &membership(&1, &2, removed)),
         :ok <- import_new_repositories("installation_repositories", payload, snapshot) do
      {:ok, changed}
    end
  end

  defp apply_event("installation", payload, bindings, snapshot) do
    installed = matching(bindings, get_in(payload, ["installation", "id"]))

    with {:ok, snapshot} <- refresh_permissions(installed, payload, snapshot),
         {:ok, changed} <- installation_access(installed, snapshot, payload["action"]),
         :ok <- import_new_repositories("installation", payload, snapshot) do
      {:ok, changed}
    end
  end

  defp apply_event("repository", payload, bindings, snapshot) do
    named = affected("repository", payload, bindings)
    full_name = get_in(payload, ["repository", "full_name"])

    case repository_state(payload["action"]) do
      nil -> {:ok, []}
      state -> change(named, snapshot, &update_repository(&1, &2, state, full_name))
    end
  end

  defp installation_access(installed, snapshot, action) do
    case installation_state(action) do
      nil -> {:ok, []}
      state -> change(installed, snapshot, &access(&1, &2, state))
    end
  end

  defp installation_state("suspended"),
    do: {:suspended, :blocked, "The GitHub App installation is suspended."}

  defp installation_state("deleted"),
    do: {:removed, :blocked, "The GitHub App installation was removed."}

  defp installation_state(action) when action in ["unsuspended", "created"],
    do: {:available, :pending, nil}

  defp installation_state(_action), do: nil

  defp repository_state(action) when action in ["deleted", "archived"],
    do: {:removed, :blocked, "This repository is no longer available to Ryker."}

  defp repository_state(action) when action in ["renamed", "transferred", "unarchived", "edited"],
    do: {:available, nil, nil}

  defp repository_state(_action), do: nil

  defp change(bindings, snapshot, update) do
    with {:ok, _snapshot} <- update_many(bindings, snapshot, update), do: {:ok, bindings}
  end

  defp membership(binding, snapshot, removed) do
    state =
      if binding.repository_id in removed,
        do: {:removed, :blocked, "GitHub App access was removed."},
        else: {:available, :pending, nil}

    access(binding, snapshot, state)
  end

  defp update_repository(binding, snapshot, state, full_name) do
    with {:ok, snapshot} <- access(binding, snapshot, state) do
      if is_binary(full_name), do: rename(binding, snapshot, full_name), else: {:ok, snapshot}
    end
  end

  defp import_new_repositories(event, payload, %{github: %{auto_add_repositories: true} = github}) do
    case repositories_added(event, payload) do
      [] ->
        :ok

      repositories ->
        case IntegrationSetup.import_github_repositories(repositories,
               ryker_actor_id: github.bot_actor_id
             ) do
          {:ok, %{failed: []}} -> :ok
          {:ok, _partial} -> {:error, :github_repository_auto_import_failed}
          {:error, _reason} = error -> error
        end
    end
  end

  defp import_new_repositories(_event, _payload, _snapshot), do: :ok

  defp repositories_added(event, payload) do
    account = get_in(payload, ["installation", "account"]) || %{}
    installation_id = get_in(payload, ["installation", "id"])
    permissions = get_in(payload, ["installation", "permissions"]) || %{}

    for repository <- List.wrap(new_repositories(event, payload)),
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

  # A changed permission names the installation's repositories too, but none
  # is new to the App, and one removed from Ryker stays removed.
  defp new_repositories("installation_repositories", payload), do: payload["repositories_added"]

  defp new_repositories("installation", %{"action" => "created"} = payload),
    do: payload["repositories"]

  defp new_repositories(_event, _payload), do: []

  defp matching(bindings, installation_id) do
    bindings |> Map.values() |> Enum.filter(&(&1.installation_id == installation_id))
  end

  defp refresh_permissions(bindings, payload, snapshot) do
    case get_in(payload, ["installation", "permissions"]) do
      permissions when is_map(permissions) and map_size(permissions) > 0 ->
        grants = IntegrationSetup.github_action_grants(permissions)

        update_many(bindings, snapshot, fn binding, snapshot ->
          Settings.put_github_binding(
            %{name: binding.name, action_grants: grants, granted_permissions: permissions},
            snapshot.installation.revision,
            @actor
          )
        end)

      _missing ->
        {:ok, snapshot}
    end
  end

  defp ids(values) when is_list(values),
    do: for(%{"id" => id} <- values, is_integer(id), do: id)

  defp ids(_values), do: []

  # Each write returns the snapshot it saved, so the next write builds on it
  # without reading the settings again.
  defp update_many(bindings, snapshot, update) do
    Enum.reduce_while(bindings, {:ok, snapshot}, fn binding, {:ok, snapshot} ->
      case update.(binding, snapshot) do
        {:ok, snapshot} -> {:cont, {:ok, snapshot}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp access(%Binding{name: ref}, snapshot, {access, onboarding, error}) do
    if saved?(snapshot, ref) do
      %{ref: ref, github_access: access, onboarding_error: error}
      |> maybe_put(:onboarding_state, onboarding)
      |> Settings.put_repository(snapshot.installation.revision, @actor)
    else
      {:ok, snapshot}
    end
  end

  defp rename(%Binding{name: ref}, snapshot, full_name) do
    if saved?(snapshot, ref) do
      Settings.put_repository(
        %{ref: ref, display_name: full_name, github_repository: full_name},
        snapshot.installation.revision,
        @actor
      )
    else
      {:ok, snapshot}
    end
  end

  defp saved?(snapshot, ref), do: Enum.any?(snapshot.repositories, &(&1.ref == ref))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
