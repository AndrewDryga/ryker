defmodule Responder.Evals.WorldReport do
  @moduledoc false

  alias Responder.CanonicalJSON

  @required_fields ~w(deliveries episode_id failures lane quality record_history records repeat_index runtime scenario_id source_calls status turn_id)a

  @spec write(Path.t(), [map()], keyword() | map()) :: :ok | {:error, term()}
  def write(path, reports, options \\ []) do
    with :ok <- absolute_path(path),
         true <- (is_list(reports) and reports != []) or {:error, :reports},
         {:ok, options} <- options(options),
         {:ok, results} <- results(reports),
         %DateTime{} = now <- options.now.() do
      document = %{
        "generated_at" => timestamp(now),
        "kind" => "responder_model_world",
        "results" => results,
        "summary" => json_value(options.summary),
        "version" => 2
      }

      atomic_write(path, CanonicalJSON.encode!(document))
    else
      {:error, field}
      when field in [:path, :reports, :report, :options, :clock, :summary] ->
        {:error, {:invalid_world_report, field}}

      _invalid ->
        {:error, {:invalid_world_report, :clock}}
    end
  end

  @spec result(map()) :: {:ok, map()} | {:error, :report}
  def result(%{} = report) do
    if Enum.all?(@required_fields, &Map.has_key?(report, &1)) and
         report.status in [:passed, :failed, :unrun] and
         report.lane in [:baseline, :candidate] and
         report.repeat_index in 1..10 do
      {:ok,
       %{
         "deliveries" => json_value(report.deliveries),
         "episode_id" => report.episode_id,
         "failures" => json_value(report.failures),
         "lane" => Atom.to_string(report.lane),
         "quality" => json_value(report.quality),
         "record_history" => json_value(report.record_history),
         "records" => json_value(report.records),
         "repeat_index" => report.repeat_index,
         "runtime" => json_value(report.runtime),
         "scenario_id" => report.scenario_id,
         "source_calls" => json_value(report.source_calls),
         "status" => Atom.to_string(report.status),
         "turn_id" => report.turn_id
       }}
    else
      {:error, :report}
    end
  end

  def result(_report), do: {:error, :report}

  defp results(reports) do
    Enum.reduce_while(reports, {:ok, []}, fn report, {:ok, values} ->
      case result(report) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        {:error, :report} -> {:halt, {:error, :report}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, :report} = error -> error
    end
  end

  defp options(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> options(),
      else: {:error, :options}
  end

  defp options(%{} = options) do
    if Map.keys(options) -- [:now, :summary] == [] do
      now = Map.get(options, :now, &DateTime.utc_now/0)
      summary = Map.get(options, :summary)

      cond do
        not is_function(now, 0) -> {:error, :options}
        not valid_summary?(summary) -> {:error, :summary}
        true -> {:ok, %{now: now, summary: summary}}
      end
    else
      {:error, :options}
    end
  end

  defp options(_options), do: {:error, :options}

  defp valid_summary?(nil), do: true

  defp valid_summary?(%{} = summary) do
    Enum.all?(~w(candidate failures passed? thresholds)a, &Map.has_key?(summary, &1)) and
      is_boolean(summary.passed?) and is_list(summary.failures)
  end

  defp valid_summary?(_summary), do: false

  defp absolute_path(path) when is_binary(path) do
    if Path.type(path) == :absolute and Path.basename(path) != "",
      do: :ok,
      else: {:error, :path}
  end

  defp absolute_path(_path), do: {:error, :path}

  defp atomic_write(path, bytes) do
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, bytes, [:binary]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, {:world_report_write_failed, reason}}
    end
  end

  defp timestamp(now) do
    utc = DateTime.shift_zone!(now, "Etc/UTC")
    {microseconds, _precision} = utc.microsecond

    utc
    |> Map.put(:microsecond, {microseconds, 6})
    |> DateTime.to_iso8601()
  end

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_value(item)} end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp json_value(value), do: value
end
