defmodule Ryker.CoopFleet.ModelPermitSupervisor do
  @moduledoc false
  use DynamicSupervisor

  def start_link(_options), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    key = {__MODULE__, :boot}
    if :persistent_term.get(key, nil) == nil, do: :persistent_term.put(key, Ecto.UUID.generate())
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # A supervisor restart shares this BEAM's PID namespace. A cold restart must
  # retain unknown old requests until their controller has been confirmed stopped.
  def boot, do: :persistent_term.get({__MODULE__, :boot}, nil)
end
