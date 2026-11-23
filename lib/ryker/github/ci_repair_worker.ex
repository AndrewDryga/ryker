defmodule Ryker.GitHub.CIRepairWorker do
  @moduledoc "Checks only signaled or active PRs, then projects their durable repair status."
  use Ryker.PollingWorker, lane: :github_ci_repairs, interval: :interval_ms
  alias Ryker.Adapter
  alias Ryker.Backoff
  alias Ryker.Delivery
  alias Ryker.GitHub.{CIRepairMessages, CIRepairs, CIRepairStop, Client, Publisher}
  alias Ryker.Options

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def options!(options) do
    options =
      Options.normalize!(
        options,
        [:bindings, :interval_ms, :api],
        [],
        "invalid CI repair options"
      )
      |> Map.put_new(:bindings, %{})
      |> Map.put_new(:interval_ms, 5_000)
      |> Map.put_new(:api, Client.CIRepair)

    unless is_map(options.bindings) and options.interval_ms in 100..60_000 and
             Adapter.implements?(options.api, snapshot: 4),
           do: raise(ArgumentError, "invalid CI repair options")

    options
  end

  @impl Ryker.PollingWorker
  def setup(options), do: {:ok, options!(options)}
  @impl Ryker.PollingWorker
  def poll(options) do
    case run_once(options) do
      {:ok, :updated} -> 0
      _idle -> options.interval_ms
    end
  end

  def run_once(options) do
    case CIRepairs.claim_next(Map.keys(options.bindings)) do
      {:ok, nil} -> {:ok, :idle}
      {:ok, claimed} -> process(claimed, options)
      error -> error
    end
  end

  defp process(claimed, options) do
    configured = Map.fetch!(options.bindings, claimed.binding_ref)

    with {:ok, local} <- CIRepairs.configuration(claimed.binding_ref),
         {:ok, pull} <- snapshot(claimed, configured, local, options.api),
         {:ok, projected} <- CIRepairs.evaluate(claimed, pull),
         :ok <- CIRepairStop.request(projected),
         {:ok, _saved} <- finish_poll(projected, options.bindings) do
      {:ok, :updated}
    else
      {:error, reason} ->
        seconds =
          if reason == :ci_repair_changed,
            do: 0,
            else: Backoff.delay(claimed.attempt_count, 10, 900, 8)

        seconds =
          case Delivery.Retry.rate_limited(reason) do
            {:ok, delay} when is_integer(delay) -> max(seconds, delay)
            _ordinary -> seconds
          end

        with {:ok, _deferred} <- CIRepairs.defer(claimed, reason, seconds), do: {:ok, :deferred}
    end
  end

  defp finish_poll(%{round: nil} = projected, _bindings),
    do: CIRepairs.complete_without_delivery(projected)

  defp finish_poll(projected, bindings) do
    with {:ok, request} <- CIRepairMessages.request(projected),
         {:ok, receipt} <-
           Delivery.ReconciledMessage.publish(
             request,
             projected.repair.external_receipt,
             projected.repair.rendered_fingerprint,
             adapters(bindings)
           ) do
      CIRepairs.delivered(projected, receipt)
    end
  end

  defp snapshot(claimed, _configured, %{repository: %{github_ci_repair: :off}}, _api),
    do: {:ok, claimed.observation || %{}}

  defp snapshot(claimed, configured, local, api) do
    api.snapshot(
      configured.read_client,
      local.repository.github_repository,
      claimed.repository_id,
      claimed.number
    )
  end

  defp adapters(bindings),
    do: %{
      "github" => %{
        message_publisher: Publisher,
        reaction_publisher: Publisher,
        binding: %{bindings: bindings}
      }
    }
end
