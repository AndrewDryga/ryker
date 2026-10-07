defmodule Mix.Tasks.Ryker.LearningEval do
  @moduledoc """
  Runs a harvested conversation through production learning in an empty DB.

      RYKER_EVAL_SOCKET=/absolute/coop.sock MIX_ENV=test \
        PGDATABASE=ryker_learning_eval_example mix ryker.learning_eval \
        --database ryker_learning_eval_example \
        --target <provider:model/effort@account> \
        --results /absolute/new-report.json --scenario haproxy

  The eval worker is the one `RYKER_EVAL_SOCKET` names, as for `mix ryker.eval`.
  Scenarios are `Ryker.Evals.LearningRunner.scenarios/0`, haproxy by default;
  each needs its own empty database.

  Create and migrate the explicitly disposable database first. This task starts
  only Repo and Finch, not Ryker workers or transports. It refuses nonempty
  databases and existing report files. Failed run custody remains in PostgreSQL;
  do not drop that database until outstanding remote work has been reconciled.
  """
  use Mix.Task
  alias Ryker.Coop.Client
  alias Ryker.Evals.{Job, LearningRunner}
  alias Ryker.Evals.Runtime, as: EvalRuntime
  alias Ryker.Repo

  @shortdoc "Runs isolated longitudinal learning; never publishes messages"

  @impl Mix.Task
  def run(arguments) do
    unless Mix.env() == :test, do: Mix.raise("learning evaluation requires MIX_ENV=test")
    Logger.configure(level: :warning)
    options = parse_options!(arguments)
    scenario = Keyword.get(options, :scenario, "haproxy")
    validate_options!(options, scenario)
    client = start_client!(options)

    settings = %{
      database: options[:database],
      api: Client,
      client: client,
      job: client.job,
      probe_question: if(options[:probe], do: probe_question(scenario))
    }

    execute(options, scenario, settings)
  end

  defp parse_options!(arguments) do
    keys = [:database, :target, :results]

    {options, rest, invalid} =
      OptionParser.parse(arguments,
        strict: [
          {:probe, [:boolean, :keep]} | Enum.map(keys ++ [:scenario], &{&1, [:string, :keep]})
        ]
      )

    supplied = Keyword.keys(options)

    unless rest == [] and invalid == [] and supplied -- (keys ++ [:scenario, :probe]) == [] and
             keys -- supplied == [] and length(Enum.uniq(supplied)) == length(supplied) do
      Mix.raise(
        "provide each required flag once: --database --target --results; optional --scenario " <>
          Enum.join(LearningRunner.scenarios(), "|") <> " --probe"
      )
    end

    options
  end

  defp validate_options!(options, scenario) do
    unless scenario in LearningRunner.scenarios(), do: Mix.raise("unknown learning scenario")

    if scenario in ["chatter", "one-off-request", "people"] and options[:probe],
      do: Mix.raise("#{scenario} has no learned topic to probe")

    if scenario == "unoffered-draft-match" and options[:probe],
      do: Mix.raise("unoffered-draft-match qualifies retry judgment, not held-out recall")

    unless Path.type(options[:results]) == :absolute,
      do: Mix.raise("--results must be an absolute new file path")
  end

  defp start_client!(options) do
    if Process.whereis(Ryker.Supervisor),
      do: Mix.raise("run without the Ryker application running")

    unless Process.whereis(Repo) == nil,
      do: Mix.raise("Repo must not already be running")

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:finch)
    {:ok, _} = Repo.start_link(pool: DBConnection.ConnectionPool)
    {:ok, _} = Finch.start_link(name: Ryker.LearningEvalFinch)
    {:ok, job} = Job.new(:learning, options[:target])

    # The worker and the receive timeout `mix ryker.eval` uses: this took a
    # --socket of its own and waited a hard-coded 30 s (2026-10-04 review).
    with {:ok, socket} <- Job.socket(),
         {:ok, client} <-
           Client.new(
             socket: socket,
             job: job,
             finch: Ryker.LearningEvalFinch,
             receive_timeout: EvalRuntime.receive_timeout_ms()
           ) do
      client
    else
      {:error, reason} -> Mix.raise("learning evaluation failed: #{inspect(reason)}")
    end
  end

  defp execute(options, scenario, settings) do
    with :ok <- LearningRunner.preflight(settings),
         {:ok, file} <- File.open(options[:results], [:write, :exclusive, :binary]) do
      :ok = File.chmod(options[:results], 0o600)

      try do
        result =
          write_result(file, scenario, fn ->
            LearningRunner.run(LearningRunner.recorded_sequence(scenario), settings)
          end)

        Mix.shell().info(
          "Public learning report: #{options[:results]}; custody retained in #{options[:database]}"
        )

        unless match?({:ok, %{passed: true}}, result) do
          Mix.raise(
            "learning structural qualification failed; inspect report and retained custody"
          )
        end
      after
        File.close(file)
      end
    else
      {:error, reason} -> Mix.raise("learning evaluation refused: #{inspect(reason)}")
    end
  end

  # Authored evaluation questions, deliberately separate from harvested inputs.
  defp probe_question("haproxy") do
    "What do we know about the website HAProxy OOM on nomad-hst01, and what does the later resolved alert establish or leave unverified? Answer from the conversation history; do not run infrastructure checks."
  end

  defp probe_question("auth-memory-recurrence") do
    "What is the latest recorded state of auth/auth resident-memory pressure on nomad-hst02, and how does it relate to the earlier firing and resolved alerts? Answer from the conversation history, distinguish separate occurrences, and do not inspect live infrastructure."
  end

  defp probe_question("draft-keep") do
    "What did the team decide about keeping draft-ai-suggestions, and why? Answer from the conversation history; do not change code or inspect live systems."
  end

  defp probe_question("starfall-correction") do
    "Was the Starfall release stuck, and what did the team clarify about how updates happen? Answer from the conversation history, distinguish the initial concern from the later clarification, and do not inspect live systems."
  end

  @doc false
  def write_result(file, scenario, execute) do
    result =
      try do
        execute.()
      rescue
        exception ->
          {:error,
           %{
             kind: "runner_exception",
             detail: Exception.message(exception) |> String.slice(0, 4096)
           }}
      catch
        kind, reason ->
          {:error, %{kind: "runner_#{kind}", detail: inspect(reason, printable_limit: 4096)}}
      end

    :ok =
      IO.binwrite(
        file,
        Jason.encode!(
          %{kind: "longitudinal_learning", scenario: scenario, result: encode_result(result)},
          pretty: true
        )
      )

    result
  end

  defp encode_result({:ok, report}), do: report

  defp encode_result({:error, reason}) do
    retained =
      try do
        LearningRunner.retained_report()
      rescue
        exception ->
          %{custody_snapshot_error: Exception.message(exception) |> String.slice(0, 4096)}
      end

    Map.merge(retained, %{
      passed: false,
      error: if(is_map(reason), do: reason, else: inspect(reason, printable_limit: 4096)),
      notice: "Execution failed; retained database custody must be reconciled before disposal."
    })
  end
end
