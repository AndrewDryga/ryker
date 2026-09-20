defmodule Ryker.Evals.WorldDatabase do
  @moduledoc """
  Custody of the disposable database a model-world observation runs in.

  A scenario may only start on an empty `ryker_world_eval_*` database, apart
  from shipped reference data such as the built-in token-rate card, and
  the database is only truncated after the observation passed and its remote
  Coop sessions were discarded. Failed runs keep their rows: they are the
  fixtures the next fix needs.
  """

  import Ecto.Query

  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Episode}
  alias Ryker.Repo

  @reference_tables ~w(pricing_rates)

  @type result :: {:ok, map()} | {:error, term()}

  @doc """
  Refuses to run unless every application table is empty and, when cleanup
  is requested, the current database carries the disposable name prefix.
  """
  @spec disposable_database(boolean()) :: :ok | {:error, term()}
  def disposable_database(cleanup) do
    with :ok <- disposable_name(cleanup) do
      if Enum.all?(application_tables(), &table_empty?/1),
        do: :ok,
        else: {:error, :model_world_requires_an_empty_disposable_database}
    end
  end

  @doc """
  Runs the remote and local cleanup a finished observation is entitled to and
  folds any cleanup failure into its result.
  """
  @spec finish_execution(result(), map()) :: result()
  def finish_execution(result, %{cleanup: false}), do: result

  def finish_execution(result, %{cleanup: true} = settings) do
    cleanup_result = run_cleanup(result, settings.cleanup_remote, &maybe_cleanup/0)

    finish_result(result, cleanup_result)
  end

  @doc false
  @spec run_cleanup(result(), (-> term()), (-> term())) :: :ok | {:error, term()}
  def run_cleanup(result, remote_cleanup, local_cleanup)
      when is_function(remote_cleanup, 0) and is_function(local_cleanup, 0) do
    # Failed runs are the fixtures we need next. A safe workcopy discard must
    # not erase the database containing the failure or unresolved cleanup custody.
    with :ok <- cleanup_call(remote_cleanup) do
      if match?({:ok, %{status: :passed}}, result),
        do: cleanup_call(local_cleanup),
        else: :ok
    end
  end

  @doc false
  @spec finish_result(result(), :ok | {:error, term()}) :: result()
  def finish_result(result, :ok), do: result

  def finish_result({:error, {:world_eval_assertions, report}}, {:error, cleanup}) do
    cleanup_failure(report, cleanup)
  end

  def finish_result({:ok, report}, {:error, cleanup}) do
    cleanup_failure(report, cleanup)
  end

  @doc false
  @spec terminalize_waiting_episodes() :: :ok | {:error, term()}
  def terminalize_waiting_episodes do
    now = Repo.now!()

    Episode
    |> where([episode], episode.state in [:waiting_for_input, :waiting_for_event])
    |> order_by([episode], [episode.inserted_at, episode.id])
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn episode, :ok ->
      command = %Command.CancelEpisode{
        cancel_ref: "model-world-cleanup:#{episode.id}:v#{episode.semantic_version}",
        episode_key: episode.key,
        expected_owner: %{kind: episode.owner_kind, ref: episode.owner_ref},
        occurred_at: now,
        reason: "The disposable model-world observation finished."
      }

      case Episodes.apply(command) do
        {:ok, _transition} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:world_cleanup_cancel_failed, episode.id, reason}}}
      end
    end)
  end

  defp cleanup_failure(report, cleanup) do
    report =
      report
      |> Map.put(:cleanup_error, cleanup)
      |> Map.put(:status, if(report.status == :unrun, do: :unrun, else: :failed))

    {:error, {:world_eval_assertions, report}}
  end

  defp cleanup_call(callback) do
    case callback.() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      invalid -> {:error, invalid}
    end
  rescue
    error -> {:error, {:model_world_cleanup_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:model_world_cleanup_caught, kind, inspect(reason)}}
  end

  defp disposable_name(false), do: :ok

  defp disposable_name(true) do
    %{rows: [[database]]} = Repo.query!("SELECT current_database()")

    if String.starts_with?(database, "ryker_world_eval_"),
      do: :ok,
      else: {:error, :model_world_database_not_disposable}
  end

  defp maybe_cleanup do
    case application_tables() do
      [] ->
        :ok

      tables ->
        targets = Enum.map_join(tables, ", ", &quoted_identifier/1)

        case Repo.query("TRUNCATE TABLE #{targets} RESTART IDENTITY CASCADE") do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, {:model_world_cleanup_failed, reason}}
        end
    end
  end

  defp quoted_identifier(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")

  defp application_tables do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = current_schema()
          AND table_type = 'BASE TABLE'
          AND table_name <> 'schema_migrations'
          AND table_name <> ALL($1::text[])
        ORDER BY table_name
        """,
        [@reference_tables]
      )

    Enum.map(rows, fn [table] -> table end)
  end

  defp table_empty?(table) when is_binary(table) do
    quoted = quoted_identifier(table)
    %{rows: [[empty]]} = Repo.query!("SELECT NOT EXISTS (SELECT 1 FROM #{quoted} LIMIT 1)")
    empty
  end
end
