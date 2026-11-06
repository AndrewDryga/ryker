defmodule Ryker.IntegrationSetup.Diagnostics do
  @moduledoc "Read-only checks of the connections a saved environment can offer new work."
  alias Ryker.Emisar
  alias Ryker.IntegrationSetup
  alias Ryker.Settings

  @spec check(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def check(ref, options) do
    with {:ok, snapshot} <- Settings.fetch(),
         %Settings.Environment{} = environment <- Settings.environment(snapshot, ref) do
      repositories = Settings.Environment.repository_refs(environment)
      chosen = Enum.filter(snapshot.repositories, &(&1.ref in repositories))

      discover =
        Keyword.get(options, :github_repositories, &IntegrationSetup.github_repositories/0)

      probe = Keyword.get(options, :emisar_probe, &Emisar.Tools.probe/1)

      listed =
        cond do
          chosen == [] -> {:ok, []}
          not snapshot.github.enabled -> {:error, :disabled}
          true -> discover.()
        end

      {:ok,
       %{
         environment_ref: ref,
         revision: snapshot.installation.revision,
         checked_at: DateTime.utc_now(),
         repositories: Enum.map(chosen, &repository(&1, listed)),
         emisar: emisar(snapshot, ref, probe),
         next_step:
           "New investigations use the saved environment. For a request blocked on old access, start a new conversation and choose this environment; earlier work keeps its original access and evidence."
       }}
    else
      nil -> {:error, :environment_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repository(repository, {:ok, available}) do
    name = repository.github_repository || repository.display_name
    listed = Enum.any?(available, &(&1.full_name == repository.github_repository))

    if listed and repository.github_access == :available,
      do: %{
        name: name,
        status: :available,
        detail:
          "Listed by the connected GitHub App. File access is checked when work reads the repository."
      },
      else: %{
        name: name,
        status: :unavailable,
        detail:
          "Not available through the connected GitHub App. Check its repository selection and reconnect if needed."
      }
  end

  defp repository(repository, {:error, :disabled}),
    do: %{
      name: repository.github_repository || repository.display_name,
      status: :unavailable,
      detail: "GitHub is turned off. Enable the connection before investigating repository code."
    }

  defp repository(repository, {:error, _reason}),
    do: %{
      name: repository.github_repository || repository.display_name,
      status: :unavailable,
      detail:
        "GitHub repository access could not be checked. Check the GitHub connection and try again."
    }

  defp emisar(snapshot, ref, probe) do
    case Emisar.Connections.resolve(snapshot, ref) do
      {:ok, pin} ->
        emisar_result(probe.(pin))

      {:error, :disabled} ->
        %{
          status: :missing,
          detail:
            "The Emisar account is paused for new work. Enable it before investigating alerts."
        }

      {:error, :not_configured} ->
        %{
          status: :missing,
          detail:
            "No Emisar account is selected. Application logs and infrastructure tools are not connected here."
        }
    end
  end

  defp emisar_result({:ok, %{tools: [_ | _]}}),
    do: %{
      status: :available,
      detail:
        "Emisar's tool catalog was reached. Log access and resource permissions are checked by Emisar when an investigation uses them."
    }

  defp emisar_result({:ok, %{tools: []}}),
    do: %{
      status: :unavailable,
      detail: "Emisar returned no tools. Check the connected agent key's access."
    }

  defp emisar_result({:error, _reason}),
    do: %{
      status: :unavailable,
      detail:
        "Emisar's tool catalog could not be reached with the saved key. Check the connection and try again."
    }
end
