defmodule Ryker.Fixtures.ChannelEnvironments do
  @moduledoc false
  # Environments a Slack channel can select, saved the way an operator saves
  # them: through the settings store, so each one is a real row a channel's
  # environment reference can point at, with its repositories in order.

  alias Ryker.Settings
  alias Ryker.Settings.Environment

  @actor "control-plane:local"

  @doc """
  Saves the environment `ref` and returns it. `repositories` is the ordered
  list of repository refs (the first is the one work changes); any it names
  that the settings do not hold yet are imported first.
  """
  @spec environment!(String.t(), map()) :: Environment.t()
  def environment!(ref, attributes \\ %{}) do
    {:ok, snapshot} = Settings.initialize(@actor)
    repositories = Map.get(attributes, :repositories, [])
    snapshot = Enum.reduce(repositories, snapshot, &ensure_repository!/2)

    {:ok, saved} =
      Settings.put_environment(
        Map.merge(%{ref: ref, display_name: display_name(ref)}, attributes),
        snapshot.installation.revision,
        @actor
      )

    Environment.find(saved, :ref, ref)
  end

  @doc "The catalog entry the Slack runtime builds for a saved environment."
  @spec choice(Environment.t(), map()) :: map()
  def choice(%Environment{} = environment, urls \\ %{}) do
    %{
      emisar: not is_nil(environment.emisar_connection_ref),
      name: environment.display_name,
      ref: environment.ref,
      repositories:
        environment
        |> Environment.repository_refs()
        |> Enum.map(&%{ref: &1, url: Map.get(urls, &1)})
    }
  end

  defp ensure_repository!(ref, snapshot) do
    if Enum.any?(snapshot.repositories, &(&1.ref == ref)) do
      snapshot
    else
      {:ok, saved} = Settings.put_repository(%{ref: ref}, snapshot.installation.revision, @actor)
      saved
    end
  end

  defp display_name(ref),
    do: ref |> String.split("-") |> Enum.map_join(" ", &String.capitalize/1)
end
