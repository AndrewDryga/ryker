defmodule Ryker.Observability.Progress do
  @moduledoc """
  Rate-limited, payload-free scheduler progress persisted in PostgreSQL.

  A live PID is not evidence that its loop is still advancing. Workers call
  `beat/2` only after a dispatcher cycle returns; readiness can therefore tell
  a healthy idle loop from one blocked forever inside a call.
  """

  alias Ryker.Repo

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
  @minimum_interval_ms 5_000

  @spec lanes() :: [atom()]
  def lanes, do: @lanes

  @spec beat(atom(), atom()) :: :ok | {:error, term()}
  def beat(lane, outcome \\ :cycle) do
    now = System.monotonic_time(:millisecond)
    key = {__MODULE__, lane}
    last = Process.get(key)

    if is_nil(last) or now - last >= @minimum_interval_ms do
      case record(lane, outcome) do
        :ok ->
          Process.put(key, now)
          :ok

        {:error, _reason} = error ->
          error
      end
    else
      :ok
    end
  end

  @spec record(atom(), atom()) :: :ok | {:error, term()}
  def record(lane, outcome) when lane in @lanes and outcome in @outcomes do
    sql = """
    INSERT INTO responder_runtime_progress
      (lane, outcome, cycle_count, observed_at, inserted_at, updated_at)
    VALUES ($1, $2, 1, clock_timestamp(), clock_timestamp(), clock_timestamp())
    ON CONFLICT (lane) DO UPDATE
    SET outcome = EXCLUDED.outcome,
        cycle_count = responder_runtime_progress.cycle_count + 1,
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
end
