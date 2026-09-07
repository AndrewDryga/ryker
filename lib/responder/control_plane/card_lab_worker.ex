defmodule Responder.ControlPlane.CardLabWorker do
  @moduledoc "Single local delivery slot; pending specimens recover from PostgreSQL after restart."
  use GenServer
  require Logger

  alias Responder.ControlPlane.CardLabDelivery
  alias Responder.Polling

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    send(self(), :poll)
    {:ok, options}
  end

  @impl true
  def handle_info(:poll, options) do
    delay =
      Polling.run(:card_lab, 1_000, fn ->
        case CardLabDelivery.run_once() do
          {:ok, _} -> :ok
          {:error, :card_lab_slack_not_configured} -> :ok
          {:error, _} -> Logger.warning("Card Lab delivery custody could not advance")
        end

        1_000
      end)

    Process.send_after(self(), :poll, delay)
    {:noreply, options}
  end
end
