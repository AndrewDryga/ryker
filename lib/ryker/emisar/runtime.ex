defmodule Ryker.Emisar.Runtime do
  @moduledoc "Supervises one isolated approval-monitor pool per Emisar connection."

  use Supervisor

  alias Ryker.Emisar.ApprovalRuntime

  def child_spec(configuration) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [configuration]}, type: :supervisor}
  end

  def start_link(configuration),
    do: Supervisor.start_link(__MODULE__, configuration, name: __MODULE__)

  @impl Supervisor
  def init(configuration) do
    connections = options!(configuration)
    Supervisor.init(Enum.map(connections, &ApprovalRuntime.child_spec/1), strategy: :one_for_one)
  end

  def options!(%{connections: connections}) when is_list(connections) do
    refs = Enum.map(connections, &ApprovalRuntime.options!(&1).connection_ref)

    if refs == Enum.uniq(refs) and length(refs) <= 64,
      do: connections,
      else: raise(ArgumentError, "Emisar connection runtimes must be unique and bounded")
  end

  def options!(_configuration),
    do: raise(ArgumentError, "Emisar runtime requires a connections list")
end
