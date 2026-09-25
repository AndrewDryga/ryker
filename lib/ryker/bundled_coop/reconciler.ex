defmodule Ryker.BundledCoop.Reconciler do
  @moduledoc """
  Keeps the bundled Compose worker able to replace an expired client identity,
  and rewrites its policies when a settings save changes them.
  """

  use GenServer
  require Logger

  @interval_ms 5_000

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(options) do
    :ok = Ryker.Settings.subscribe()
    send(self(), :reconcile)
    {:ok, %{interval_ms: Keyword.get(options, :interval_ms, @interval_ms)}, {:continue, :sync}}
  end

  # A new release or a restart may run with models the policy file does not
  # have yet. An unchanged file is rewritten byte for byte, so the worker only
  # reloads when something actually changed.
  @impl true
  def handle_continue(:sync, state) do
    sync_policies()
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile()
    Process.send_after(self(), :reconcile, state.interval_ms)
    {:noreply, state}
  end

  # One rewrite answers every save already queued behind it.
  def handle_info({:settings_saved, _revision}, state) do
    drain_saves()
    sync_policies()
    {:noreply, state}
  end

  defp drain_saves do
    receive do
      {:settings_saved, _revision} -> drain_saves()
    after
      0 -> :ok
    end
  end

  defp sync_policies do
    Ryker.BundledCoop.sync_policies()
  rescue
    error -> Logger.warning("bundled co:op policy update failed: #{Exception.message(error)}")
  end

  defp reconcile do
    Ryker.BundledCoop.ensure_enrollment_file!()
  rescue
    error ->
      Logger.warning("bundled co:op identity reconciliation failed: #{Exception.message(error)}")
  end
end
