defmodule Ryker.Slack.InteractionFeedbackWorker do
  @moduledoc """
  Reconciles stale Slack controls by repainting their exact source message.
  """

  use GenServer

  require Logger

  alias Ryker.Observability.Progress
  alias Ryker.Polling

  alias Ryker.Slack.{InteractionAudits, InteractionRepaint}

  @default_interval_ms 1_000

  def start_link(options) do
    options = options!(options)

    case options.name do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @impl GenServer
  def init(options) do
    send(self(), :work)
    {:ok, options}
  end

  @impl GenServer
  def handle_info(:work, options) do
    delay =
      Polling.run(:slack_interactions, options.interval_ms, fn ->
        delay =
          case run_once(options) do
            {:ok, :idle} ->
              options.interval_ms

            {:ok, _result} ->
              0

            {:error, reason} ->
              Logger.warning("Slack interaction repaint worker failed: #{inspect(reason)}")
              options.interval_ms
          end

        _ = Progress.beat(:slack_interactions)
        delay
      end)

    Process.send_after(self(), :work, delay)
    {:noreply, options}
  end

  @spec run_once(map() | keyword()) ::
          {:ok, :idle | {:blocked | :deferred | :repainted, String.t()}} | {:error, term()}
  def run_once(options) do
    options = options!(options)

    case InteractionAudits.claim_next(options.worker_ref, options.lease_seconds) do
      {:ok, nil} -> {:ok, :idle}
      {:ok, audit} -> repaint(audit, options)
      {:error, _reason} = error -> error
    end
  end

  defp repaint(audit, options) do
    case options.repaint.(audit, %{api: options.api, client: options.client}) do
      :ok ->
        with {:ok, settled} <- InteractionAudits.settle(audit.id, audit.lease_ref),
             do: {:ok, {:repainted, settled.event_ref}}

      {:error, reason} ->
        retry_or_block(audit, reason, options)
    end
  end

  defp retry_or_block(audit, reason, options) do
    if audit.attempt_count >= options.max_attempts do
      with {:ok, blocked} <- InteractionAudits.block(audit.id, audit.lease_ref, reason) do
        tell_the_presser(blocked, options)
        {:ok, {:blocked, blocked.event_ref}}
      end
    else
      retry_seconds = retry_delay(audit.attempt_count, options.retry_base_seconds)

      with {:ok, deferred} <-
             InteractionAudits.defer(audit.id, audit.lease_ref, retry_seconds, reason),
           do: {:ok, {:deferred, deferred.event_ref}}
    end
  end

  # The acknowledgement a click gets is optimistic: it is sent before the repaint
  # is attempted. When the repaint is given up on, the person is left holding an
  # accepted press and a card that never changed, which is indistinguishable
  # from the host having ignored them. The press really was recorded, so that is
  # what this says; the failure reason is host diagnostics and stays out of it.
  defp tell_the_presser(audit, options) do
    if function_exported?(options.api, :post_ephemeral, 5) do
      options.api.post_ephemeral(
        options.client,
        audit.channel_ref,
        audit.actor_ref,
        audit.thread_ref,
        "Your press was recorded. I couldn't update the message to show it, so what you see may be out of date."
      )
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp retry_delay(attempt_count, base) do
    exponent = max(attempt_count - 1, 0) |> min(8)
    min(base * Integer.pow(2, exponent), 3_600)
  end

  @doc false
  def options!(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> options!(),
      else: raise(ArgumentError, "Slack interaction feedback worker requires unique options")
  end

  def options!(%{} = options) do
    required = [:api, :client, :lease_seconds, :max_attempts, :retry_base_seconds, :worker_ref]
    optional = [:interval_ms, :name, :repaint]

    prepared =
      options
      |> Map.put_new(:interval_ms, @default_interval_ms)
      |> Map.put_new(:name, nil)
      |> Map.put_new(:repaint, &InteractionRepaint.repaint/2)

    if valid_options?(prepared, required, optional),
      do: prepared,
      else: raise(ArgumentError, "invalid Slack interaction feedback worker options")
  end

  def options!(_options),
    do: raise(ArgumentError, "invalid Slack interaction feedback worker options")

  defp valid_options?(options, required, optional) do
    keys = Map.keys(options)

    Enum.all?([
      keys -- (required ++ optional) == [],
      Enum.all?(required, &(&1 in keys)),
      is_atom(options.api),
      is_function(options.repaint, 2),
      is_integer(options.interval_ms) and options.interval_ms in 1..300_000,
      is_integer(options.lease_seconds) and options.lease_seconds in 5..3_600,
      is_integer(options.max_attempts) and options.max_attempts in 1..100,
      is_integer(options.retry_base_seconds) and options.retry_base_seconds in 1..3_600,
      is_binary(options.worker_ref) and options.worker_ref != "",
      is_nil(options.name) or is_atom(options.name) or is_tuple(options.name)
    ])
  end
end
