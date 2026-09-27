defmodule Ryker.GitHub.OnboardingWorker do
  @moduledoc """
  Drains durable repository onboarding states without coupling repositories together.

  Every settings save is announced, a repository added or a setup step taken
  among them, and that wakes the worker at once. With no repository to set
  up it sleeps for its safety-net interval.
  """
  use Ryker.PollingWorker, lane: :github_onboarding, interval: :interval_ms

  alias Ryker.GitHub.Onboarding
  alias Ryker.PollingWorker
  alias Ryker.Settings

  @default_interval 2_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def options!(options) when is_map(options) do
    interval = Map.get(options, :interval_ms, @default_interval)
    idle_interval = Map.get(options, :idle_interval_ms, PollingWorker.idle_interval_ms())
    api = Map.get(options, :api, Ryker.GitHub.RepositoryFiles)

    unless interval in 100..60_000 and idle_interval in 100..3_600_000 and remote?(api),
      do: raise(ArgumentError, "GitHub onboarding worker configuration is invalid")

    %{api: api, idle_interval_ms: idle_interval, interval_ms: interval}
  end

  def options!(options) when is_list(options), do: options |> Map.new() |> options!()

  defp remote?(api),
    do: is_atom(api) and Code.ensure_loaded?(api) and function_exported?(api, :pin, 2)

  @impl PollingWorker
  def setup(options), do: {:ok, options!(options)}

  @impl PollingWorker
  def wake_on(_state), do: [&Settings.subscribe/0]

  # A database the worker cannot read backs off and says so. Choosing the
  # next repository used to turn every error into "nothing to do", so an
  # outage looked like an idle queue.
  @impl PollingWorker
  def poll(state) do
    case next_repository() do
      nil ->
        state.idle_interval_ms

      {:onboard, ref} ->
        _ = Onboarding.run(ref, api: state.api)
        state.interval_ms
    end
  end

  defp next_repository do
    case Settings.fetch() do
      {:ok, snapshot} -> next_repository(snapshot)
      {:error, :settings_not_initialized} -> nil
    end
  end

  defp next_repository(snapshot) do
    onboarding =
      snapshot.repositories
      |> Enum.filter(
        &(&1.github_access == :available and
            &1.onboarding_state in [:pending, :cloning])
      )
      |> Enum.min_by(&{DateTime.to_unix(&1.updated_at, :microsecond), &1.ref}, fn -> nil end)

    if onboarding, do: {:onboard, onboarding.ref}
  end
end
