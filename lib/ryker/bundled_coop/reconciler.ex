defmodule Ryker.BundledCoop.Reconciler do
  @moduledoc "Keeps the bundled Compose worker able to replace an expired client identity."

  use GenServer
  require Logger

  @interval_ms 5_000

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(options) do
    send(self(), :reconcile)
    {:ok, %{interval_ms: Keyword.get(options, :interval_ms, @interval_ms)}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile()
    Process.send_after(self(), :reconcile, state.interval_ms)
    {:noreply, state}
  end

  defp reconcile do
    Ryker.BundledCoop.ensure_enrollment_file!()
  rescue
    error ->
      Logger.warning("bundled co:op identity reconciliation failed: #{Exception.message(error)}")
  end
end
