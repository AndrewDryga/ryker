defmodule Ryker.Defaults do
  @moduledoc """
  Checked-in operational defaults: concurrency, polling, deadlines and retries.

  These are implementation tuning, not product decisions, so they ship with the
  code instead of being typed by an operator. Every value here reproduces the
  bound the previous YAML loader validated, so an installation that never set
  the field keeps its exact behavior across the cutover. Related values that
  must agree (a drain pass inside its poll, retry ceilings above their base,
  delivery lanes inside the total) are checked together by `validate!/0` rather
  than being independently settable into an inconsistent combination.
  """

  @coop %{receive_timeout_ms: 30_000}
  @admission %{concurrency: 4, decision_timeout_ms: 30_000, poll_interval_ms: 250}
  @work %{capability_names: ["responder-state"], concurrency: 4, poll_interval_ms: 250}
  @learning %{
    batch_size: 16,
    concurrency: 1,
    execution_timeout_seconds: 600,
    maximum_delay_seconds: 60,
    poll_interval_ms: 1_000,
    quiet_seconds: 10
  }
  @delivery %{
    action_concurrency: 2,
    lease_seconds: 60,
    max_attempts: 8,
    message_concurrency: 4,
    poll_interval_ms: 250,
    reaction_concurrency: 2,
    retry_base_seconds: 1,
    retry_max_seconds: 60
  }
  # Cleanup mechanics only. The history, memory and audit horizons are product
  # settings and live in PostgreSQL, never here.
  @retention %{
    batch_limit: 25,
    batch_seconds: 30,
    closed_session_grace_seconds: 900,
    disposable_bytes_limit: 10_737_418_240,
    lease_seconds: 300,
    max_attempts: 8,
    poll_interval_ms: 60_000,
    reclaim_target_seconds: 3_600,
    retained_recheck_seconds: 21_600,
    retry_base_seconds: 5,
    retry_max_seconds: 300,
    storage_high_watermark_bytes: 64_424_509_440,
    storage_low_watermark_bytes: 48_318_382_080,
    storage_reserve_bytes: 5_368_709_120
  }
  @publication %{
    concurrency: 2,
    followup_interval_seconds: 120,
    lease_seconds: 60,
    poll_interval_ms: 250,
    retry_base_seconds: 1,
    retry_max_seconds: 60
  }
  @emisar %{
    concurrency: 2,
    lease_seconds: 60,
    poll_interval_ms: 1_000,
    poll_seconds: 3,
    receive_timeout_ms: 30_000,
    retry_base_seconds: 2,
    retry_max_seconds: 300
  }
  @schedules %{
    lease_seconds: 60,
    misfire_grace_seconds: 900,
    poll_interval_ms: 1_000,
    retry_base_seconds: 5,
    retry_max_seconds: 1_800
  }
  @event_waits %{poll_interval_ms: 1_000}
  @slack %{
    api_url: "https://slack.com/api",
    handshake_timeout_ms: 10_000,
    incident_room_interval_ms: 1_000,
    incident_room_reconcile_ms: 300_000,
    maximum_open_incidents: 25,
    membership_reconcile_ms: 300_000,
    receive_timeout_ms: 30_000,
    reconnect_ms: 1_000,
    task_card_interval_ms: 1_000,
    task_card_reconcile_ms: 2_000,
    thread_status_interval_ms: 1_000
  }
  @github %{max_body_bytes: 40_000, receive_timeout_ms: 30_000}
  @webhooks %{max_body_bytes: 40_000, max_clock_skew_seconds: 300}
  @coop_worker_gateway %{certificate_ttl_seconds: 86_400}
  @owners %{
    admission: @admission,
    coop: @coop,
    coop_worker_gateway: @coop_worker_gateway,
    delivery: @delivery,
    emisar: @emisar,
    event_waits: @event_waits,
    github: @github,
    learning: @learning,
    publication: @publication,
    retention: @retention,
    schedules: @schedules,
    slack: @slack,
    webhooks: @webhooks,
    work: @work
  }

  @spec owners() :: [atom()]
  def owners, do: @owners |> Map.keys() |> Enum.sort()

  @doc "The operational defaults for one owner. An unknown owner is a programming error."
  @spec fetch!(atom()) :: map()
  def fetch!(owner) do
    case Map.fetch(@owners, owner) do
      {:ok, defaults} -> defaults
      :error -> raise ArgumentError, "no operational defaults own #{inspect(owner)}"
    end
  end

  @doc """
  The execution topology chosen by the build, not by an operator.

  `config/config.exs` places Work on the enrolled worker fleet; tests and
  development select an isolated topology in their own files. The key is
  always set, so an absent one is a broken build and raises rather than
  quietly turning into a topology.
  """
  @spec execution() :: :fleet | :direct
  def execution, do: Application.fetch_env!(:ryker, :execution)

  @doc "Raises when two defaults that must agree have drifted apart."
  @spec validate!() :: :ok
  def validate! do
    checks = [
      {@retention.batch_seconds * 1_000 <= @retention.poll_interval_ms,
       "a retention drain pass must fit inside its own poll"},
      {@retention.storage_low_watermark_bytes < @retention.storage_high_watermark_bytes and
         @retention.storage_reserve_bytes < @retention.storage_high_watermark_bytes and
         @retention.disposable_bytes_limit <= @retention.storage_high_watermark_bytes,
       "retention storage watermarks must be ordered below capacity"},
      {@learning.quiet_seconds <= @learning.maximum_delay_seconds,
       "learning quiet_seconds must fit maximum_delay_seconds"},
      {@delivery.action_concurrency + @delivery.message_concurrency +
         @delivery.reaction_concurrency <= 32, "delivery lanes must fit the total pool"},
      {@emisar.receive_timeout_ms <= @emisar.lease_seconds * 1_000,
       "an Emisar request must fit inside its lease"}
    ]

    increasing =
      for {owner, defaults} <- @owners,
          Map.has_key?(defaults, :retry_base_seconds),
          do:
            {defaults.retry_max_seconds >= defaults.retry_base_seconds,
             "#{owner} retry_max_seconds must not be below retry_base_seconds"}

    Enum.each(checks ++ increasing, fn
      {true, _reason} -> :ok
      {false, reason} -> raise ArgumentError, reason
    end)
  end
end
