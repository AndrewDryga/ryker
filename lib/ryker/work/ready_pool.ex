defmodule Ryker.Work.ReadyPool do
  @moduledoc """
  Keeps a Work session started for each of the pins new conversations use most.

  "Work sessions kept ready" (Settings › Advanced) says for how many pins; 0
  turns it off. Each pass reads the pins new conversations froze in the last
  day (`Ryker.Work.ReadySessions.recent_pins/1`), keeps the most used of those
  current settings still give, retires the sessions that can no longer serve
  one (another pin, past their age, or a second for the same pin), opens any
  whose create Coop finished after its pass stopped waiting, settles any a
  stopped pass left starting, and starts one for each kept pin that has none.
  Cleanup closes what the pass retires. The pool never hands a session
  out: a conversation claims one itself when its episode is pinned
  (`Ryker.Work.Custody.Sessions`), and the next pass replaces it.

  Unlike routing's, these sessions are not prepared: a Work job stops its
  agent after each turn (`Ryker.CoopFleet.JobTemplates`), so an agent kept
  running would hold one of the worker's runtime slots while it waits. The
  create was the larger part of the wait, and that is what the pool takes off
  a first answer.

  A start that fails holds the next one back, 5 s after the first failure and
  twice as long after each one in a row, up to 5 minutes, counted from the
  failed starts on record.
  """
  use Ryker.PollingWorker, lane: :work_ready, interval: :poll_interval_ms
  alias Ryker.{Adapter, Coop, Emisar, Options, Repo, Settings}
  alias Ryker.Backoff
  alias Ryker.CoopFleet
  alias Ryker.Work.{OperationKeys, ReadySessions}
  require Logger

  @fields [:api, :client, :operation_polls, :pins, :poll_interval_ms, :sleep, :target]
  @required [:api, :client, :target]
  # A pass reads a day of pins and the current settings, so it runs less often
  # than routing's: a claimed session is replaced within this, plus its create.
  @poll_interval_ms 10_000
  # A Work create fetches the session's repositories before the worker opens
  # it. A pass waits up to 60 s, and a later one opens a session Coop made after
  # that: an environment of 17 repositories took about 90 s (2026-10-13).
  @operation_polls 120
  @operation_poll_ms 500
  @idle_interval_ms 60_000
  # Well past the longest a start can wait on the worker, so a pass never
  # settles a start another pass is still making.
  @stranded_seconds 600
  @window_seconds 24 * 60 * 60
  @retry_base_seconds 5
  @retry_max_seconds 300

  @type pass :: %{
          opened: non_neg_integer(),
          retired: non_neg_integer(),
          started: non_neg_integer()
        }

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
        Logger.warning("Work sessions kept ready not kept: #{inspect(reason, limit: 5)}")
    end

    if options.target == 0, do: @idle_interval_ms, else: options.poll_interval_ms
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    case settings(configuration) do
      {:ok, options} -> options
      {:error, reason} -> raise ArgumentError, "ready Work sessions #{reason}"
    end
  end

  @doc """
  One pass: retire what can no longer serve a conversation, open what Coop
  finished creating since an earlier pass stopped waiting, settle what a stopped
  pass left starting, then start a session for each kept pin that has none.
  """
  @spec keep(keyword() | map()) :: {:ok, pass()} | {:error, term()}
  def keep(options) do
    with {:ok, settings} <- settings(options),
         {:ok, pins} <- settings.pins.(settings.target) do
      unusable = retire_unusable(pins)
      opened = open_finished(settings)
      retired = unusable + settle_stranded(settings)
      {:ok, %{opened: opened, retired: retired, started: start(settings, pins, 0)}}
    end
  end

  # `:pins` answers the pins to keep for a target; tests give their own. By
  # default they are the most used pins of the last day that current settings still give: a
  # policy, its digests and the environment's Emisar pin exactly as a new
  # conversation would freeze them now. One they no longer give would only
  # fail to start, or be started for nobody.
  defp kept_pins(0), do: {:ok, []}

  defp kept_pins(target) do
    with {:ok, snapshot} <- Settings.fetch() do
      bindings = CoopFleet.JobTemplates.from_settings(snapshot)
      since = DateTime.add(Repo.now!(), -@window_seconds, :second)

      {:ok,
       since
       |> ReadySessions.recent_pins()
       |> Enum.filter(&current?(&1, snapshot, bindings))
       |> Enum.take(target)}
    end
  end

  defp current?(pin, snapshot, bindings) do
    Enum.any?(bindings, fn binding ->
      binding.policy_name == pin.policy and binding.policy_digest == pin.policy_digest and
        (is_nil(pin.authority_digest) or binding.authority_digest == pin.authority_digest)
    end) and emisar_pin(snapshot, pin.environment_ref) == emisar_fields(pin)
  end

  defp emisar_pin(_snapshot, nil), do: emisar_fields(%{})

  defp emisar_pin(snapshot, environment_ref) do
    case Emisar.Connections.resolve(snapshot, environment_ref) do
      {:ok, %{connection_ref: ref, account_ref: account, rpc_url: url}} ->
        %{emisar_connection_ref: ref, emisar_account_ref: account, emisar_rpc_url: url}

      _unconfigured ->
        emisar_fields(%{})
    end
  end

  defp emisar_fields(pin) do
    %{
      emisar_connection_ref: pin[:emisar_connection_ref],
      emisar_account_ref: pin[:emisar_account_ref],
      emisar_rpc_url: pin[:emisar_rpc_url]
    }
  end

  defp retire_unusable(pins) do
    pins
    |> ReadySessions.unusable()
    |> Enum.count(&match?({:ok, _retired}, ReadySessions.retire(&1)))
  end

  # The tenant install, 2026-10-13: every create there outlasted its pass's wait, and each
  # session was retired once stranded although Coop had made it, so none was ever ready and a
  # new create held the worker every ten minutes.
  defp open_finished(settings) do
    0
    |> ReadySessions.stranded()
    |> Enum.count(&(open_if_created(&1, settings) == :ready))
  end

  defp open_if_created(session, settings) do
    with {:ok, operation} <-
           settings.api.operation_by_key(settings.client, OperationKeys.create(session)),
         {:created, coop_session_id} <- Coop.CreateOutcome.of(operation) do
      fetch(session, coop_session_id, settings)
    else
      :absent -> retire(session, nil)
      _still_running -> :starting
    end
  end

  defp settle_stranded(settings) do
    @stranded_seconds
    |> ReadySessions.stranded()
    |> Enum.count(&(settle(&1, settings) == :retired))
  end

  defp start(_settings, [], started), do: started

  defp start(settings, [pin | pins], started) do
    with :ok <- retry_due(),
         {:ok, session} <- ReadySessions.reserve(pin),
         :ready <- create(session, settings) do
      start(settings, pins, started + 1)
    else
      :kept -> start(settings, pins, started)
      _waiting_or_failed -> started
    end
  end

  defp create(session, settings) do
    key = OperationKeys.create(session)

    result =
      with :ok <-
             Coop.API.prepare_create_session(
               settings.api,
               settings.client,
               key,
               session.policy,
               session.external_ref,
               session.repository_source
             ) do
        settings.api.create_session(
          settings.client,
          key,
          session.policy,
          session.external_ref,
          session.repository_source
        )
      end

    case result do
      {:ok, %{"session" => remote}} when is_map(remote) ->
        open(session, remote, settings)

      {:ok, %{"operation" => operation}} ->
        case await_created(operation, key, settings, settings.operation_polls) do
          {:created, coop_session_id} -> fetch(session, coop_session_id, settings)
          :absent -> failed(session, {:coop_operation_failed, operation}, settings)
          # Still running: a later pass opens it once Coop has made it.
          :unknown -> :starting
        end

      {:ok, _response} ->
        failed(session, {:coop_protocol_error, :create_session_response}, settings)

      {:error, reason} ->
        failed(session, reason, settings)
    end
  end

  # The fleet accepts a create and its worker finishes it later; the pool waits
  # for it as routing's pool does (`Ryker.Admission.ReadyPool`).
  defp await_created(operation, key, settings, polls_left) do
    case Coop.CreateOutcome.of(operation) do
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

  # Only the exact frozen job can wait for a conversation under this reservation.
  defp open(session, %{"id" => coop_session_id} = remote, settings)
       when is_binary(coop_session_id) do
    exact? =
      remote["state"] == "open" and CoopFleet.JobAuthority.exact_receipt(session, remote) == :ok

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
    Logger.warning("a Work session kept ready did not start: #{inspect(reason, limit: 5)}")
    _settled = settle(session, settings)
    :failed
  end

  # A start that failed or stopped halfway either made a Coop session or never
  # will once its create is fenced. The one it made is recorded so cleanup
  # closes it; one never made leaves nothing to close.
  defp settle(session, settings) do
    fenced =
      settings.api.fence_create_session(
        settings.client,
        OperationKeys.create(session),
        session.policy,
        session.external_ref,
        session.repository_source
      )

    case Coop.CreateOutcome.of(fenced) do
      {:created, coop_session_id} -> retire(session, coop_session_id)
      :absent -> retire(session, nil)
      :unknown -> :starting
    end
  end

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

      [%{updated_at: failed_at} | _earlier] = failures ->
        wait = Backoff.delay(length(failures), @retry_base_seconds, @retry_max_seconds)
        if Repo.passed?(failed_at, wait), do: :ok, else: :waiting
    end
  end

  defp settings(configuration) do
    options =
      configuration
      |> Options.normalize!(@fields, @required, "configuration has missing or unknown fields")
      |> Map.put_new(:poll_interval_ms, @poll_interval_ms)
      |> Map.put_new(:operation_polls, @operation_polls)
      |> Map.put_new(:sleep, &Process.sleep/1)
      |> Map.put_new(:pins, &kept_pins/1)

    case Enum.find(checks(), fn {valid?, _refusal} -> not valid?.(options) end) do
      nil -> {:ok, options}
      {_valid?, refusal} -> {:error, refusal}
    end
  rescue
    error in ArgumentError -> {:error, error.message}
  end

  defp checks do
    maximum = Settings.Work.maximum_ready_work_sessions()

    [
      {&Adapter.implements?(&1.api, create_session: 5), "need a trusted Coop adapter"},
      {&(not is_nil(&1.client)), "need a Coop client"},
      {&(is_integer(&1.target) and &1.target in 0..maximum),
       "target must be between 0 and #{maximum}"},
      {&(is_integer(&1.poll_interval_ms) and &1.poll_interval_ms > 0),
       "poll_interval_ms must be a positive integer"},
      {&(is_integer(&1.operation_polls) and &1.operation_polls >= 0),
       "operation_polls must be a non-negative integer"},
      {&is_function(&1.sleep, 1), "sleep must be a one-argument function"},
      {&is_function(&1.pins, 1), "pins must be a one-argument function"}
    ]
  end
end
