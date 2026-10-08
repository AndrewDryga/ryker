defmodule Ryker.Observability.Progress do
  @moduledoc """
  Rate-limited, payload-free scheduler progress persisted in PostgreSQL.

  A live PID is not evidence that its loop is still advancing. Workers call
  `beat/2` only after a dispatcher cycle returns; readiness can therefore tell
  a healthy idle loop from one blocked forever inside a call.
  """
  alias Ryker.Observability.Reads
  alias Ryker.Repo
  alias Ryker.UTCDateTime

  @lanes ~w(
    admission
    learning
    delivery
    emisar_approval
    event_waits
    publication
    publication_followup
    retention
    schedule
    slack_incidents
    slack_interactions
    slack_status
    slack_task_cards
    work
  )a
  @outcomes ~w(cycle error)a
  # Readiness calls a lane stalled after fifteen minutes without a beat. An
  # idle worker now polls about every ten seconds, so a beat every five made
  # nearly every idle poll write this table: a quarter of all an idle install
  # still committed. Once a minute proves the loop turns all the same.
  @minimum_interval_ms 60_000

  @spec beat(atom(), atom()) :: :ok | {:error, term()}
  def beat(lane, outcome \\ :cycle) do
    now = System.monotonic_time(:millisecond)
    key = {__MODULE__, lane}
    last = Process.get(key)

    if is_nil(last) or now - last >= @minimum_interval_ms do
      case record(lane, outcome) do
        :ok ->
          # When this lane's process last recorded a beat, to record at most one a interval.
          # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
          Process.put(key, now)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  @spec record(atom(), atom()) :: :ok | {:error, term()}
  # A literal statement with bound parameters.
  # sobelow_skip ["SQL.Query"]
  def record(lane, outcome) when lane in @lanes and outcome in @outcomes do
    sql = """
    INSERT INTO ryker_runtime_progress
      (lane, outcome, cycle_count, observed_at, inserted_at, updated_at)
    VALUES ($1, $2, 1, clock_timestamp(), clock_timestamp(), clock_timestamp())
    ON CONFLICT (lane) DO UPDATE
    SET outcome = EXCLUDED.outcome,
        cycle_count = ryker_runtime_progress.cycle_count + 1,
        observed_at = clock_timestamp(),
        updated_at = clock_timestamp()
    """

    case Repo.query(sql, [Atom.to_string(lane), Atom.to_string(outcome)], log: false) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:runtime_progress_persistence_failed, reason}}
    end
  rescue
    error -> {:error, {:runtime_progress_persistence_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:runtime_progress_persistence_failed, kind, inspect(reason)}}
  end

  def record(_lane, _outcome), do: {:error, {:invalid_runtime_progress, :fields}}

  @doc """
  Every lane's last heartbeat, aged from the database clock reading `now`.

  Only this release's lanes are read. A lane a later release retired or
  renamed leaves its last heartbeat behind, and failing the read on it held
  `/readyz` and `/metrics` unavailable for good. The table's check constraint
  admits only the outcomes `record/2` writes.
  """
  @spec snapshot(DateTime.t()) :: {:ok, [map()]} | {:error, Reads.failure()}
  def snapshot(now) do
    with {:ok, rows} <-
           Reads.rows(
             """
             SELECT lane, outcome, cycle_count, observed_at FROM ryker_runtime_progress
             WHERE lane = ANY($1) ORDER BY lane
             """,
             [Enum.map(@lanes, &Atom.to_string/1)]
           ) do
      {:ok, Enum.map(rows, &heartbeat(&1, now))}
    end
  end

  defp heartbeat([lane, outcome, cycle_count, observed_at], now) do
    %{
      age_seconds: UTCDateTime.age_seconds(now, observed_at),
      cycle_count: cycle_count,
      lane: String.to_existing_atom(lane),
      outcome: String.to_existing_atom(outcome),
      observed_at: observed_at
    }
  end
end
