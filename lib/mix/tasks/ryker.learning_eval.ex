defmodule Mix.Tasks.Ryker.LearningEval do
  @moduledoc """
  Runs a harvested conversation through production learning in an empty DB.

      MIX_ENV=test PGDATABASE=ryker_learning_eval_example mix ryker.learning_eval \
        --database ryker_learning_eval_example --socket /absolute/coop.sock \
        --scratch /absolute/empty-git-repository --policy learning-eval-only \
        --policy-digest <sha256> --results /absolute/new-report.json --scenario haproxy

  Scenarios: haproxy (default), auth-memory-recurrence, draft-keep, unoffered-draft-match,
  fortnite-correction, chatter, one-off-request.
  Each needs its own empty database.

  Create and migrate the explicitly disposable database first. This task starts
  only Repo and Finch, not Ryker workers or transports. It refuses nonempty
  databases and existing report files. Failed run custody remains in PostgreSQL;
  do not drop that database until outstanding remote work has been reconciled.
  """
  use Mix.Task
  alias Ryker.Coop.Client
  alias Ryker.Evals.LearningRunner
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
      scratch_repository: options[:scratch],
      api: Client,
      client: client,
      policy: options[:policy],
      policy_digest: options[:policy_digest],
      probe_question: if(options[:probe], do: probe_question(scenario))
    }

    execute(options, scenario, settings)
  end

  defp parse_options!(arguments) do
    keys = [:database, :socket, :scratch, :policy, :policy_digest, :results]

    {options, rest, invalid} =
      OptionParser.parse(arguments,
        strict: [
          {:probe, [:boolean, :keep]} | Enum.map(keys ++ [:scenario], &{&1, [:string, :keep]})
        ]
      )

    supplied = Keyword.keys(options)

    unless rest == [] and invalid == [] and supplied -- (keys ++ [:scenario, :probe]) == [] and
             keys -- supplied == [] and length(Enum.uniq(supplied)) == length(supplied),
           do:
             Mix.raise(
               "provide each required flag once: --database --socket --scratch --policy --policy-digest --results; optional --scenario haproxy|auth-memory-recurrence|draft-keep|unoffered-draft-match|fortnite-correction|chatter|one-off-request --probe"
             )

    options
  end

  defp validate_options!(options, scenario) do
    unless scenario in [
             "haproxy",
             "auth-memory-recurrence",
             "draft-keep",
             "unoffered-draft-match",
             "fortnite-correction",
             "chatter",
             "one-off-request"
           ],
           do: Mix.raise("unknown learning scenario")

    if scenario in ["chatter", "one-off-request"] and options[:probe],
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

    configuration = Application.fetch_env!(:ryker, Repo)

    Application.put_env(
      :ryker,
      Repo,
      Keyword.put(configuration, :pool, DBConnection.ConnectionPool)
    )

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:finch)
    {:ok, _} = Repo.start_link()
    {:ok, _} = Finch.start_link(name: Ryker.LearningEvalFinch)

    {:ok, client} =
      Client.new(
        socket: options[:socket],
        finch: Ryker.LearningEvalFinch,
        receive_timeout: 30_000
      )

    client
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

        unless match?({:ok, %{passed: true}}, result),
          do:
            Mix.raise(
              "learning structural qualification failed; inspect report and retained custody"
            )
      after
        File.close(file)
      end
    else
      {:error, reason} -> Mix.raise("learning evaluation refused: #{inspect(reason)}")
    end
  end

  # Authored evaluation questions, deliberately separate from harvested inputs.
  defp probe_question("haproxy"),
    do:
      "What do we know about the website HAProxy OOM on nomad-hvn01, and what does the later resolved alert establish or leave unverified? Answer from the conversation history; do not run infrastructure checks."

  defp probe_question("auth-memory-recurrence"),
    do:
      "What is the latest recorded state of auth/auth resident-memory pressure on nomad-hvn02, and how does it relate to the earlier firing and resolved alerts? Answer from the conversation history, distinguish separate occurrences, and do not inspect live infrastructure."

  defp probe_question("draft-keep"),
    do:
      "What did the team decide about keeping draft-ai-suggestions, and why? Answer from the conversation history; do not change code or inspect live systems."

  defp probe_question("fortnite-correction"),
    do:
      "Was the Fortnite release stuck, and what did the team clarify about how updates happen? Answer from the conversation history, distinguish the initial concern from the later clarification, and do not inspect live systems."

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
