defmodule Ryker.Defaults do
  @moduledoc """
  Checked-in operational defaults: concurrency, polling, deadlines and retries.

  These are implementation tuning, not product decisions, so they ship with the
  code instead of being typed by an operator. Related values that must agree (a
  drain pass inside its poll, retry ceilings above their base, delivery lanes
  inside the total) are checked together by `validate!/0` rather than being
  independently settable into an inconsistent combination.
  """

  alias Ryker.Admission.Runtime, as: AdmissionRuntime
  alias Ryker.Config

  # A caller waiting on a worker command hears when it settles
  # (`Ryker.CoopFleet.ControlPlane.Commands.subscribe_settled/1`), and reads it
  # again this often for an end nothing announces, such as its placement being
  # revoked.
  @coop %{command_recheck_ms: 1_000, receive_timeout_ms: 30_000}
  @admission %{concurrency: 4, decision_timeout_ms: 30_000, poll_interval_ms: 250}
  @work %{capability_names: ["controller-tools"], concurrency: 4, poll_interval_ms: 250}
  # Learning reads a conversation once it has been quiet for five minutes, or
  # half an hour after its oldest unlearned message if it never goes quiet;
  # sixteen waiting messages start a pass at once. Ten quiet seconds made
  # nearly every message a pass of its own (2026-09-27).
  @learning %{
    batch_size: 16,
    concurrency: 1,
    execution_timeout_seconds: 600,
    maximum_delay_seconds: 1_800,
    poll_interval_ms: 1_000,
    quiet_seconds: 300
  }
  # Self-analysis of requests people were unhappy with (`Ryker.Improvement`):
  # one slot, and a request is read once no new negative feedback has come
  # for five minutes, so a thumbs-down, a question asked again and an angry
  # reply are one analysis, not three.
  @improvement %{
    concurrency: 1,
    execution_timeout_seconds: 600,
    poll_interval_ms: 1_000,
    quiet_seconds: 300
  }
  # RYKER.md for each repository (`Ryker.RepositoryKnowledge`): one slot. A
  # model reading a whole repository takes minutes, so its turn gets half an
  # hour before it is cancelled.
  @repository_knowledge %{execution_timeout_seconds: 1_800, poll_interval_ms: 1_000}
  # An outage of Slack, GitHub or the network is waited out for about three
  # hours, trying again at least every five minutes, before a reply waits for a
  # person. Eight attempts capped at a minute gave up after about two minutes
  # (2026-10-04 review).
  @delivery %{
    action_concurrency: 2,
    lease_seconds: 60,
    max_attempts: 45,
    message_concurrency: 4,
    poll_interval_ms: 250,
    report_concurrency: 1,
    routing_concurrency: 2,
    retry_base_seconds: 1,
    retry_max_seconds: 300
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
    retry_max_seconds: 300,
    # How long one read of an approval waits on Emisar for its run to change.
    # Emisar holds a wait for up to 60 s; receive_timeout_ms gives the whole
    # request 30.
    wait_seconds: 20
  }
  @schedules %{
    lease_seconds: 60,
    misfire_grace_seconds: 900,
    poll_interval_ms: 1_000,
    retry_base_seconds: 5,
    retry_max_seconds: 1_800
  }
  @event_waits %{poll_interval_ms: 1_000}
  # The local routing model's shadow comparisons (`Ryker.LocalRouting`): one
  # lane asks one question at a time, each cut off at `timeout_ms`; an
  # unreachable model is asked again after 30 s, 2 min and 8 min, then given
  # up.
  @local_routing %{
    max_attempts: 4,
    poll_interval_ms: 1_000,
    retry_base_seconds: 30,
    retry_max_seconds: 600,
    timeout_ms: 120_000
  }
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
  # Copying routing examples for training. Whether they are kept and for how
  # long are product settings in PostgreSQL, never here.
  @routing_examples %{batch_size: 25, poll_interval_ms: 10_000}
  # A work example's briefing is about fifty times a routing prompt, so a pass copies fewer.
  @work_examples %{batch_size: 5, poll_interval_ms: 10_000}
  @github %{max_body_bytes: 1_048_576, receive_timeout_ms: 30_000}
  @webhooks %{max_body_bytes: 1_048_576, max_clock_skew_seconds: 300}
  @coop_worker_gateway %{certificate_ttl_seconds: 86_400}
  @owners %{
    admission: @admission,
    coop: @coop,
    coop_worker_gateway: @coop_worker_gateway,
    delivery: @delivery,
    emisar: @emisar,
    event_waits: @event_waits,
    github: @github,
    improvement: @improvement,
    learning: @learning,
    local_routing: @local_routing,
    publication: @publication,
    repository_knowledge: @repository_knowledge,
    retention: @retention,
    routing_examples: @routing_examples,
    work_examples: @work_examples,
    schedules: @schedules,
    slack: @slack,
    webhooks: @webhooks,
    work: @work
  }

  # Tests walk every owner to check what its defaults must not contain.
  @doc false
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

  `config/config.exs` selects `:fleet` for product builds, which place Work on
  the enrolled worker fleet, and `:isolated` for development and test, which
  run one process with no fleet. The key is always set, so an absent one is a
  broken build and raises rather than quietly turning into a topology.
  """
  @spec execution() :: :fleet | :isolated
  def execution, do: Config.fetch_env!(:execution)

  @doc "Raises when two defaults that must agree have drifted apart."
  @spec validate!() :: :ok
  def validate! do
    checks = [
      {@retention.batch_seconds * 1_000 <= @retention.poll_interval_ms,
       "a retention drain pass must fit inside its own poll"},
      {@learning.quiet_seconds <= @learning.maximum_delay_seconds,
       "learning quiet_seconds must fit maximum_delay_seconds"},
      {@delivery.action_concurrency + @delivery.message_concurrency +
         @delivery.report_concurrency + @delivery.routing_concurrency <= 32,
       "delivery lanes must fit the total pool"},
      {@emisar.receive_timeout_ms <= @emisar.lease_seconds * 1_000,
       "an Emisar request must fit inside its lease"},
      # Admission talks to Coop through the Work fleet client. One call longer
      # than its heartbeat window, a third of its lease, could let another
      # worker claim the same input while the first is still waiting.
      {@coop.receive_timeout_ms <= div(AdmissionRuntime.lease_seconds() * 1_000, 3),
       "a Coop call must fit inside the admission heartbeat window"}
    ]

    increasing =
      for {owner, defaults} <- @owners,
          Map.has_key?(defaults, :retry_base_seconds) do
        {defaults.retry_max_seconds >= defaults.retry_base_seconds,
         "#{owner} retry_max_seconds must not be below retry_base_seconds"}
      end

    Enum.each(checks ++ increasing, fn
      {true, _reason} -> :ok
      {false, reason} -> raise ArgumentError, reason
    end)
  end
end
