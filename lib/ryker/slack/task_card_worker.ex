defmodule Ryker.Slack.TaskCardWorker do
  @moduledoc """
  Repairs and refreshes one Slack engineering-task card at a time.
  """

  use GenServer

  require Logger

  alias Ryker.Observability.Progress
  alias Ryker.Polling

  alias Ryker.Slack.{TaskCardProjection, TaskCards}

  @default_interval_ms 1_000
  @default_max_attempts 8

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
      Polling.run(:slack_task_cards, options.interval_ms, fn ->
        delay =
          case run_once(options) do
            {:ok, :idle} ->
              options.interval_ms

            {:ok, _result} ->
              0

            {:error, reason} ->
              Logger.warning("Slack task-card worker failed: #{inspect(reason)}")
              options.interval_ms
          end

        _ = Progress.beat(:slack_task_cards)
        delay
      end)

    Process.send_after(self(), :work, delay)
    {:noreply, options}
  end

  @spec run_once(map() | keyword()) ::
          {:ok, :idle | {:blocked | :created | :deferred | :updated, String.t()}}
          | {:error, term()}
  def run_once(options) do
    options = options!(options)

    with {:ok, created} <- TaskCards.ensure_one() do
      if created do
        {:ok, {:created, created.ref}}
      else
        claim_and_refresh(options)
      end
    end
  end

  defp claim_and_refresh(options) do
    case TaskCards.claim_next(
           options.worker_ref,
           options.lease_seconds,
           options.check_interval_seconds
         ) do
      {:ok, nil} -> {:ok, :idle}
      {:ok, card} -> refresh(card, options)
      {:error, _reason} = error -> error
    end
  end

  defp refresh(card, options) do
    with {:ok, projection} <- TaskCardProjection.build(card),
         :ok <- maybe_update(card, projection, options),
         {:ok, marked} <-
           TaskCards.mark(
             card.id,
             card.lease_ref,
             projection.fingerprint,
             projection.ui_revision
           ) do
      {:ok, {:updated, marked.ref}}
    else
      {:error, reason} -> settle(card, reason, options)
    end
  end

  # A refresh Slack refused is retried with growing waits until the card has
  # spent its attempts, then blocked for a person: a card once retried hourly
  # for as long as its task existed, editing a message Slack had already said
  # was gone. Slack saying the message or its channel is gone, or the task's
  # own record being gone, blocks at once.
  defp settle(card, reason, options) do
    if permanent?(reason) or card.attempt_count >= options.max_attempts do
      case TaskCards.block(card.id, card.lease_ref, reason) do
        {:ok, blocked} -> {:ok, {:blocked, blocked.ref}}
        {:error, _reason} = error -> error
      end
    else
      defer(card, reason, options)
    end
  end

  @permanent_refusals ~w(message_not_found cant_update_message edit_window_closed channel_not_found is_archived)

  defp permanent?(:task_card_source_not_found), do: true
  defp permanent?({:slack_api_error, code}), do: code in @permanent_refusals
  defp permanent?(_reason), do: false

  defp maybe_update(
         %{card_fingerprint: fingerprint, card_ui_revision: revision},
         %{fingerprint: fingerprint, ui_revision: revision},
         _options
       ),
       do: :ok

  defp maybe_update(card, projection, options) do
    options.api.update_message(
      options.client,
      card.channel_ref,
      card.message_ref,
      projection.document,
      card.ref
    )
  end

  defp defer(card, reason, options) do
    retry_seconds = retry_delay(card.attempt_count, options.retry_base_seconds)

    case TaskCards.defer(card.id, card.lease_ref, retry_seconds, reason) do
      {:ok, deferred} -> {:ok, {:deferred, deferred.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp retry_delay(attempt_count, base) do
    exponent = max(attempt_count - 1, 0) |> min(8)
    min(base * Integer.pow(2, exponent), 3_600)
  end

  @doc false
  def options!(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> options!(),
      else: raise(ArgumentError, "task-card worker requires unique options")
  end

  def options!(%{} = options) do
    required = [:api, :client, :lease_seconds, :retry_base_seconds, :worker_ref]
    optional = [:check_interval_seconds, :interval_ms, :max_attempts, :name]

    prepared =
      options
      |> Map.put_new(:check_interval_seconds, 2)
      |> Map.put_new(:interval_ms, @default_interval_ms)
      |> Map.put_new(:max_attempts, @default_max_attempts)
      |> Map.put_new(:name, nil)

    if valid_options?(prepared, required, optional) do
      prepared
    else
      raise ArgumentError, "invalid task-card worker options"
    end
  end

  def options!(_options), do: raise(ArgumentError, "invalid task-card worker options")

  defp valid_options?(options, required, optional) do
    keys = Map.keys(options)

    Enum.all?([
      keys -- (required ++ optional) == [],
      Enum.all?(required, &(&1 in keys)),
      Map.get(options, :lease_seconds) in 5..3_600,
      Map.get(options, :retry_base_seconds) in 1..3_600,
      Map.get(options, :check_interval_seconds) in 1..86_400,
      Map.get(options, :interval_ms) in 50..3_600_000,
      Map.get(options, :max_attempts) in 1..100,
      is_binary(Map.get(options, :worker_ref)),
      Map.get(options, :worker_ref) != ""
    ])
  end
end
