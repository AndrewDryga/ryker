defmodule Ryker.GitHub.LabelWorker do
  @moduledoc """
  Projects current PR work into GitHub's working label. GitHub is the receipt:
  a restart and every uncertain write reread its labels before reconciling.
  A periodic refresh also repairs manual edits. No historical completion
  label or second task state is kept.
  """
  use Ryker.PollingWorker, lane: :github_labels, interval: :interval_ms
  alias Ryker.Adapter
  alias Ryker.Episodes
  alias Ryker.ErrorDetail
  alias Ryker.GitHub
  alias Ryker.GitHub.{Client, Labels}
  alias Ryker.Ingress
  alias Ryker.Options
  alias Ryker.Publication
  alias Ryker.Settings
  require Logger

  @refresh_seconds 300

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def options!(options) do
    options =
      Options.normalize!(
        options,
        [:api, :bindings, :interval_ms],
        [],
        "invalid GitHub label configuration"
      )
      |> Map.put_new(:api, Client)
      |> Map.put_new(:bindings, %{})
      |> Map.put_new(:interval_ms, 10_000)

    unless options.interval_ms in 100..60_000 and is_map(options.bindings) and
             Adapter.implements?(options.api,
               ensure_label: 3,
               labeled_pulls: 3,
               add_pull_label: 4,
               remove_pull_label: 4
             ) and
             Enum.all?(options.bindings, &valid_binding?/1),
           do: raise(ArgumentError, "invalid GitHub label configuration")

    options
  end

  defp valid_binding?({name, %{client: _, repository_id: id, repository_full_name: repository}}),
    do: Settings.adapter_name?(name) and GitHub.id?(id) and GitHub.repository_name?(repository)

  defp valid_binding?(_binding), do: false

  @impl Ryker.PollingWorker
  def setup(options), do: {:ok, Map.put(options!(options), :observed, %{})}

  @impl Ryker.PollingWorker
  def wake_on(_options),
    do: [
      &Ingress.Inbox.subscribe_inputs/0,
      &Episodes.subscribe_episodes/0,
      &Publication.Custody.subscribe_publications/0
    ]

  @impl Ryker.PollingWorker
  def poll(options) do
    now = DateTime.utc_now()

    observed =
      Enum.reduce(options.bindings, options.observed, fn {name, binding}, observed ->
        previous = Map.get(observed, name)

        state = update_binding(name, binding, previous, options.api, now)
        Map.put(observed, name, state)
      end)

    {options.interval_ms, %{options | observed: observed}}
  end

  defp update_binding(name, binding, previous, api, now) do
    if retry_due?(previous, now) do
      case run_once(name, binding, api, current(previous, now)) do
        {:ok, numbers} ->
          %{numbers: numbers, refresh_at: refresh_at(previous, now), retry_at: nil}

        {:error, reason} ->
          Logger.warning("GitHub labels failed: #{ErrorDetail.detail(reason)}")
          %{numbers: nil, refresh_at: now, retry_at: DateTime.add(now, retry_seconds(reason))}
      end
    else
      previous
    end
  end

  def run_once(name, binding, api, observed) do
    desired = Labels.active_pulls(name, binding)

    with {:ok, present} <- observed_labels(binding, api, observed),
         :ok <- change_labels(binding, api, MapSet.difference(desired, present), :add),
         :ok <- change_labels(binding, api, MapSet.difference(present, desired), :remove) do
      {:ok, desired}
    end
  end

  defp observed_labels(_binding, _api, %MapSet{} = observed), do: {:ok, observed}

  defp observed_labels(binding, api, nil) do
    with :ok <- provision(binding, api),
         do: api.labeled_pulls(binding.client, binding.repository_full_name, "ryker:working")
  end

  defp provision(binding, api) do
    Enum.reduce_while(Labels.definitions(), :ok, fn label, :ok ->
      case api.ensure_label(binding.client, binding.repository_full_name, label) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp change_labels(binding, api, numbers, action) do
    Enum.reduce_while(numbers, :ok, fn number, :ok ->
      result =
        case action do
          :add ->
            api.add_pull_label(
              binding.client,
              binding.repository_full_name,
              number,
              "ryker:working"
            )

          :remove ->
            api.remove_pull_label(
              binding.client,
              binding.repository_full_name,
              number,
              "ryker:working"
            )
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp current(%{numbers: numbers, refresh_at: refresh_at}, now) do
    if DateTime.compare(now, refresh_at) == :lt, do: numbers, else: nil
  end

  defp current(nil, _now), do: nil

  defp refresh_at(%{refresh_at: refresh_at}, now) do
    if DateTime.compare(now, refresh_at) == :lt,
      do: refresh_at,
      else: DateTime.add(now, @refresh_seconds)
  end

  defp refresh_at(nil, now), do: DateTime.add(now, @refresh_seconds)

  defp retry_due?(%{retry_at: %DateTime{} = retry_at}, now),
    do: DateTime.compare(now, retry_at) != :lt

  defp retry_due?(_previous, _now), do: true

  defp retry_seconds(reason) do
    case Ryker.Delivery.Retry.rate_limited(reason) do
      {:ok, seconds} -> seconds || 60
      :error -> 60
    end
  end
end
