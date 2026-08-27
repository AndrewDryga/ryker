defmodule Responder.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([Responder.Repo], name: Responder.Supervisor, strategy: :one_for_one)
  end
end
