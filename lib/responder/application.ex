defmodule Responder.Application do
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
    Responder.Defaults.validate!()

    children =
      [
        Responder.Repo,
        {Finch, name: Responder.CoopFinch},
        {Phoenix.PubSub, name: Responder.ControlPlane.PubSub},
        {DynamicSupervisor, name: Responder.Runtime.Supervisor, strategy: :one_for_one}
      ] ++ runtime_owner()

    Supervisor.start_link(children, name: Responder.Supervisor, strategy: :one_for_one)
  end

  # Tests and development drive the owner explicitly instead of applying
  # whatever happens to be in the local database at boot.
  defp runtime_owner do
    if Application.get_env(:responder, :runtime_owner, true),
      do: [Responder.Runtime.Owner],
      else: []
  end
end
