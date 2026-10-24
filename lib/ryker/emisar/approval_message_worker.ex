defmodule Ryker.Emisar.ApprovalMessageWorker do
  @moduledoc "Publishes and refreshes separate review messages independently of Work and Emisar observation."
  use Ryker.PollingWorker, lane: :emisar_approval, interval: :interval_ms
  alias Ryker.Backoff
  alias Ryker.Delivery
  alias Ryker.Emisar.{ApprovalMessages, Approvals}
  alias Ryker.Records
  require Logger

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl Ryker.PollingWorker
  def wake_on(_options), do: [&Approvals.subscribe_approvals/0, &Records.subscribe_records/0]

  @impl Ryker.PollingWorker
  def poll(options) do
    case run_once(options) do
      {:ok, :idle} ->
        Ryker.PollingWorker.idle_delay(fn _since -> nil end, 10_000)

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning("Emisar review message delivery failed: #{inspect(reason)}")
        options.interval_ms
    end
  end

  @doc "Internal — one independent review-message delivery attempt; called by this worker and deterministic integration tests."
  @spec run_once(map()) :: {:ok, atom()} | {:error, term()}
  def run_once(options) do
    with :ok <- ApprovalMessages.repair_one(options.connection_ref),
         {:ok, message} <-
           ApprovalMessages.claim_next(
             options.connection_ref,
             options.worker_ref,
             options.lease_seconds
           ) do
      deliver(message, options)
    end
  end

  defp deliver(nil, _options), do: {:ok, :idle}

  defp deliver(message, options) do
    with {:ok, request} <- ApprovalMessages.request(message),
         {:ok, receipt} <- publish(message, request, options.presentation),
         {:ok, _} <- ApprovalMessages.mark(message, request, receipt) do
      {:ok, :updated}
    else
      {:error, reason} ->
        seconds = retry_seconds(message, reason, options)

        Logger.warning("Emisar review message deferred: #{inspect(reason)}")

        case ApprovalMessages.failed(message, reason, seconds, false) do
          {:ok, _} -> {:ok, :deferred}
          {:error, error} -> {:error, error}
        end
    end
  end

  defp retry_seconds(message, reason, options) do
    backoff =
      Backoff.delay(
        message.attempt_count,
        options.retry_base_seconds,
        options.retry_max_seconds,
        8
      )

    case Delivery.Retry.rate_limited(reason) do
      {:ok, seconds} when is_integer(seconds) -> max(backoff, seconds)
      _ -> backoff
    end
  end

  defp publish(%{external_receipt: nil} = message, request, adapters) do
    # A lost post response may reconcile an older projection. Repaint before
    # acknowledging this fingerprint, including newly registered siblings.
    with {:ok, receipt} <- Delivery.Adapters.publish(request, adapters),
         :ok <- ApprovalMessages.validate_receipt(message, receipt),
         :ok <-
           Delivery.Adapters.update_message(
             request,
             receipt["message_ref"],
             request.document,
             adapters
           ),
         do: {:ok, receipt}
  end

  defp publish(message, request, adapters) do
    if message.card_fingerprint == ApprovalMessages.fingerprint(request) do
      {:ok, message.external_receipt}
    else
      with :ok <-
             Delivery.Adapters.update_message(
               request,
               message.external_receipt["message_ref"],
               request.document,
               adapters
             ),
           do: {:ok, message.external_receipt}
    end
  end
end
