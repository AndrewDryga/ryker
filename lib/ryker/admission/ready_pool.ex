defmodule Ryker.Admission.ReadyPool do
  @moduledoc """
  Keeps as many routing sessions started ahead of time as the setting asks.

  "Routing sessions kept ready" (Settings › Advanced) says how many; 0 turns
  it off. Each pass retires the sessions that can no longer serve a message
  (started under another routing policy, past their age, or beyond the
  setting), settles any a stopped pass left starting, and starts new ones
  until the setting is met. Cleanup closes what the pass retires. The pool
  never hands a session out: a message claims one itself through
  `Ryker.Admission.ReadySessions`, and the next pass replaces it.

  A start that fails holds the next one back, 5 s after the first failure and
  twice as long after each one in a row, up to 5 minutes. The wait is counted
  from the failed starts on record, so a worker that cannot create sessions is
  not asked every second, and a restart does not forget the wait.
  """

  use Ryker.PollingWorker, lane: :admission_ready, interval: :poll_interval_ms

  require Logger

  alias Ryker.Admission.ReadySessions
  alias Ryker.{Options, Repo}
  alias Ryker.Settings.Work
  alias Ryker.Work.Session

  @fields [
    :api,
    :client,
    :operation_polls,
    :policy,
    :policy_digest,
    :poll_interval_ms,
    :sleep,
    :target
  ]
  @required [:api, :client, :policy, :policy_digest, :target]
  @poll_interval_ms 1_000
  # The worker finishes a create a few seconds after accepting it; waiting up
  # to 30 s stays well inside `@stranded_seconds`.
  @operation_polls 60
  @operation_poll_ms 500
  # With nothing to keep, a pass only has leftovers to retire, and the first
  # pass after the setting changed has already done that.
  @idle_interval_ms 60_000
  # Well past the longest a start can wait on the worker, so a pass never
  # settles a start another pass is still making.
  @stranded_seconds 120
  @retry_base_seconds 5
  @retry_max_seconds 300

  @type pass :: %{retired: non_neg_integer(), started: non_neg_integer()}

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    _options = options!(configuration)
    %{id: __MODULE__, start: {__MODULE__, :start_link, [configuration]}}
  end

  def start_link(configuration),
    do: GenServer.start_link(__MODULE__, configuration, name: __MODULE__)

  @impl Ryker.PollingWorker
  def setup(configuration), do: {:ok, options!(configuration)}

  @impl Ryker.PollingWorker
  def poll(options) do
    case keep(options) do
      {:ok, _pass} ->
        :ok

      {:error, reason} ->
        Logger.warning("routing sessions kept ready not kept: #{inspect(reason, limit: 5)}")
    end

    if options.target == 0, do: @idle_interval_ms, else: options.poll_interval_ms
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    case settings(configuration) do
      {:ok, options} -> options
      {:error, reason} -> raise ArgumentError, "ready routing sessions #{reason}"
    end
  end

  @doc """
  One pass: retire what can no longer serve a message, settle what a stopped
  pass left starting, then start sessions until the setting is met.
  """
  @spec keep(keyword() | map()) :: {:ok, pass()} | {:error, term()}
  def keep(options) do
    with {:ok, settings} <- settings(options) do
      policy = %{name: settings.policy, digest: settings.policy_digest}
      retired = retire_unusable(policy, settings.target) + settle_stranded(settings)
      {:ok, %{retired: retired, started: start(settings, policy, 0)}}
    end
  end

  defp retire_unusable(policy, target) do
    policy
    |> ReadySessions.unusable(target)
    |> Enum.count(&match?({:ok, _retired}, ReadySessions.retire(&1)))
  end

  defp settle_stranded(settings) do
    @stranded_seconds
    |> ReadySessions.stranded()
    |> Enum.count(&(settle(&1, settings) == :retired))
  end

  defp start(settings, policy, started) do
    with :ok <- retry_due(),
         {:ok, session} <- ReadySessions.reserve(policy, settings.target),
         :ready <- create(session, settings) do
      start(settings, policy, started + 1)
    else
      _full_waiting_or_failed -> started
    end
  end

  defp create(session, settings) do
    key = create_key(session)

    case settings.api.create_session(
           settings.client,
           key,
           session.policy,
           session.external_ref,
           nil
         ) do
      {:ok, %{"session" => remote}} when is_map(remote) ->
        open(session, remote, settings)

      {:ok, %{"operation" => operation}} ->
        case await_created(operation, key, settings, settings.operation_polls) do
          {:created, coop_session_id} -> fetch(session, coop_session_id, settings)
          :absent -> failed(session, {:coop_operation_failed, operation}, settings)
          :unknown -> failed(session, {:coop_operation_unfinished, operation}, settings)
        end

      {:ok, _response} ->
        failed(session, {:coop_protocol_error, :create_session_response}, settings)

      {:error, reason} ->
        failed(session, reason, settings)
    end
  end

  # The fleet accepts a create and its worker finishes it a few seconds
  # later, as routing's own create does; the pool waits for it the same way.
  # Reading the first "running" answer as a failed start fenced and retired
  # every start on the live install on 2026-09-26, one every five seconds,
  # while the worker kept creating sessions nobody used.
  defp await_created(operation, key, settings, polls_left) do
    case created(operation) do
      :unknown when polls_left > 0 ->
        settings.sleep.(@operation_poll_ms)

        case settings.api.operation_by_key(settings.client, key) do
          {:ok, current} -> await_created(current, key, settings, polls_left - 1)
          :not_found -> await_created(operation, key, settings, polls_left - 1)
          {:error, _reason} -> :unknown
        end

      result ->
        result
    end
  end

  defp fetch(session, coop_session_id, settings) do
    case settings.api.get_session(settings.client, coop_session_id) do
      {:ok, remote} -> open(session, remote, settings)
      {:error, reason} -> failed(session, reason, settings)
    end
  end

  # Only the exact session asked for can wait for a message: open, under the
  # policy and digest routing uses, and named for this reservation.
  defp open(session, %{"id" => coop_session_id} = remote, settings)
       when is_binary(coop_session_id) do
    exact? =
      remote["state"] == "open" and remote["external_ref"] == session.external_ref and
        remote["policy"] == session.policy and remote["policy_digest"] == session.policy_digest

    with true <- exact?,
         {:ok, _ready} <- ReadySessions.mark_ready(session, coop_session_id) do
      :ready
    else
      false -> failed(session, {:coop_protocol_error, :ready_session_authority}, settings)
      {:error, reason} -> failed(session, reason, settings)
    end
  end

  defp open(session, _remote, settings),
    do: failed(session, {:coop_protocol_error, :session_resource}, settings)

  defp failed(session, reason, settings) do
    Logger.warning("a routing session kept ready did not start: #{inspect(reason, limit: 5)}")
    _settled = settle(session, settings)
    :failed
  end

  # A start that failed or stopped halfway either made a Coop session or
  # never will once its create is fenced. The one it made is recorded so
  # cleanup closes it; one never made leaves nothing to close.
  defp settle(session, settings) do
    fenced =
      settings.api.fence_create_session(
        settings.client,
        create_key(session),
        session.policy,
        session.external_ref,
        nil
      )

    case created(fenced) do
      {:created, coop_session_id} -> retire(session, coop_session_id)
      :absent -> retire(session, nil)
      :unknown -> :starting
    end
  end

  defp created({:ok, operation}), do: created(operation)

  defp created(%{"state" => "succeeded", "resource_type" => "session", "resource_id" => id})
       when is_binary(id),
       do: {:created, id}

  defp created(%{"state" => "failed"}), do: :absent
  defp created(_operation), do: :unknown

  defp retire(session, coop_session_id) do
    case ReadySessions.retire(session, coop_session_id) do
      {:ok, _retired} -> :retired
      {:error, _reason} -> :starting
    end
  end

  defp retry_due do
    case ReadySessions.failed_starts() do
      [] ->
        :ok

      [%Session{updated_at: failed_at} | _earlier] = failures ->
        wait =
          min(@retry_base_seconds * Integer.pow(2, length(failures) - 1), @retry_max_seconds)

        if DateTime.compare(DateTime.add(failed_at, wait, :second), Repo.now!()) == :gt,
          do: :waiting,
          else: :ok
    end
  end

  defp create_key(%Session{id: id}), do: "ryker:admission-ready:create:#{id}"

  defp settings(configuration) do
    options =
      configuration
      |> Options.normalize!(@fields, @required, "configuration has missing or unknown fields")
      |> Map.put_new(:poll_interval_ms, @poll_interval_ms)
      |> Map.put_new(:operation_polls, @operation_polls)
      |> Map.put_new(:sleep, &Process.sleep/1)

    case Enum.find(checks(), fn {valid?, _refusal} -> not valid?.(options) end) do
      nil -> {:ok, options}
      {_valid?, refusal} -> {:error, refusal}
    end
  rescue
    error in ArgumentError -> {:error, error.message}
  end

  defp checks do
    maximum = Work.maximum_ready_routing_sessions()

    [
      {&coop_adapter?(&1.api), "need a trusted Coop adapter"},
      {&(not is_nil(&1.client)), "need a Coop client"},
      {&valid_ref?(&1.policy), "policy must be a bounded string"},
      {&digest?(&1.policy_digest), "policy_digest must be a lowercase SHA-256 digest"},
      {&(is_integer(&1.target) and &1.target in 0..maximum),
       "target must be between 0 and #{maximum}"},
      {&(is_integer(&1.poll_interval_ms) and &1.poll_interval_ms > 0),
       "poll_interval_ms must be a positive integer"},
      {&(is_integer(&1.operation_polls) and &1.operation_polls >= 0),
       "operation_polls must be a non-negative integer"},
      {&is_function(&1.sleep, 1), "sleep must be a one-argument function"}
    ]
  end

  defp coop_adapter?(api) do
    is_atom(api) and not is_nil(api) and Code.ensure_loaded?(api) and
      function_exported?(api, :create_session, 5)
  end

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_ref?(value) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= 1_024
  end
end
