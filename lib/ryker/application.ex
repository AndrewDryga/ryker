defmodule Ryker.Application do
  @moduledoc """
  Starts the process in dependency order: bootstrap, then PostgreSQL, then the
  runtime owner that applies durable settings.

  Nothing product-configured is started from this module. The owner reads the
  saved settings and supervises exactly what they describe, so a database that
  has never been configured starts a reachable local console and nothing else.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    Ryker.Defaults.validate!()

    children =
      [
        Ryker.Repo,
        {Finch, name: Ryker.CoopFinch},
        {Phoenix.PubSub, name: Ryker.ControlPlane.PubSub},
        {DynamicSupervisor, name: Ryker.Runtime.Supervisor, strategy: :one_for_one}
      ] ++ bundled_coop_reconciler() ++ runtime_owner()

    Supervisor.start_link(children, name: Ryker.Supervisor, strategy: :one_for_one)
  end

  # Tests and development drive the owner explicitly instead of applying
  # whatever happens to be in the local database at boot.
  defp runtime_owner do
    if Application.get_env(:ryker, :runtime_owner, true),
      do: [Ryker.Runtime.Owner],
      else: []
  end

  defp bundled_coop_reconciler do
    if System.get_env("RYKER_BUNDLED_COOP_ROOT") &&
         System.get_env("RYKER_BUNDLED_COOP_SHARED"),
       do: [Ryker.BundledCoop.Reconciler],
       else: []
  end
end
