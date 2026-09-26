defmodule Ryker.GitHub.OnboardingWorker do
  @moduledoc "Drains durable repository onboarding states without coupling repositories together."
  use GenServer

  alias Ryker.{BundledCoop, Polling, Settings}
  alias Ryker.GitHub.Onboarding

  @default_interval 2_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def options!(options) when is_map(options) do
    interval = Map.get(options, :interval_ms, @default_interval)
    api = Map.get(options, :api, Ryker.GitHub.Onboarding.Remote)

    unless is_integer(interval) and interval in 100..60_000 and
             is_atom(api) and Code.ensure_loaded?(api) and function_exported?(api, :pin, 2) and
             function_exported?(api, :scan, 3) and function_exported?(api, :publish, 4),
           do: raise(ArgumentError, "GitHub onboarding worker configuration is invalid")

    %{api: api, interval_ms: interval}
  end

  def options!(options) when is_list(options), do: options |> Map.new() |> options!()

  @impl true
  def init(options) do
    state = options!(options)
    send(self(), :drain)
    {:ok, state}
  end

  # A database the worker cannot read backs off and says so. Choosing the
  # next repository used to turn every error into "nothing to do", so an
  # outage looked like an idle queue.
  @impl true
  def handle_info(:drain, state) do
    delay = Polling.run(:github_onboarding, state.interval_ms, fn -> drain(state) end)
    Process.send_after(self(), :drain, delay)
    {:noreply, state}
  end

  defp drain(state) do
    case next_repository() do
      nil -> :ok
      {:onboard, ref} -> _ = Onboarding.run(ref, api: state.api)
      {:sync, ref} -> _ = BundledCoop.materialize_repository(ref)
    end

    state.interval_ms
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
            &1.onboarding_state in [:pending, :cloning, :scanning, :publishing])
      )
      |> Enum.sort_by(&{&1.updated_at, &1.ref})
      |> List.first()

    cond do
      onboarding ->
        {:onboard, onboarding.ref}

      repository = Enum.find(snapshot.repositories, &materialization_due?/1) ->
        {:sync, repository.ref}

      true ->
        nil
    end
  end

  defp materialization_due?(repository) do
    repository.github_access == :available and repository.onboarding_state == :ready and
      match?(%DateTime{}, repository.last_github_event_at) and
      (is_nil(repository.materialized_at) or
         DateTime.compare(repository.last_github_event_at, repository.materialized_at) == :gt)
  end
end
