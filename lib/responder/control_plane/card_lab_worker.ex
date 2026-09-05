defmodule Responder.ControlPlane.CardLabWorker do
  @moduledoc "Single local delivery slot; pending specimens recover from PostgreSQL after restart."
  use GenServer
  require Logger

  alias Responder.ControlPlane.CardLabDelivery

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    send(self(), :poll)
    {:ok, options}
  end

  @impl true
  def handle_info(:poll, options) do
    case CardLabDelivery.run_once() do
      {:ok, _} -> :ok
      {:error, :card_lab_slack_not_configured} -> :ok
      {:error, _} -> Logger.warning("Card Lab delivery custody could not advance")
    end

    Process.send_after(self(), :poll, 1_000)
    {:noreply, options}
  end
end
