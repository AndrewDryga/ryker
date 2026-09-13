defmodule Ryker.Operator.Preflight do
  @moduledoc """
  Read-only configuration, database, schema, and readiness checks for operators.

  Every check runs even after an earlier failure so one invocation describes the
  complete repair surface. Configuration values and payload-bearing state never
  cross this boundary.
  """

  alias Ryker.Observability
  alias Ryker.Repo

  @default_stall_after_seconds 15 * 60
  @options [:checks, :configuration, :check_progress, :check_runtimes, :stall_after_seconds]

  @spec run(keyword()) :: {:ok, map()} | {:error, map() | term()}
  def run(options \\ []) do
    with {:ok, settings} <- settings(options) do
      checks = Enum.map(settings.checks, &run_check/1)
      status = if Enum.all?(checks, &(&1.status == :ok)), do: :ok, else: :failed
      report = %{checks: checks, status: status}

      if status == :ok, do: {:ok, report}, else: {:error, report}
    end
  end

  defp settings(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- @options == [] do
      configuration = Keyword.get(options, :configuration)
      check_progress = Keyword.get(options, :check_progress, true)
      check_runtimes = Keyword.get(options, :check_runtimes, true)

      stall_after_seconds =
        Keyword.get(options, :stall_after_seconds, @default_stall_after_seconds)

      with :ok <- optional_configuration(configuration),
           true <- is_boolean(check_progress),
           true <- is_boolean(check_runtimes),
           true <- is_integer(stall_after_seconds) and stall_after_seconds > 0,
           {:ok, checks} <-
             checks(
               Keyword.get(options, :checks),
               configuration,
               check_progress,
               check_runtimes,
               stall_after_seconds
             ) do
        {:ok, %{checks: checks}}
      else
        _invalid -> {:error, {:invalid_operator_preflight, :options}}
      end
    else
      {:error, {:invalid_operator_preflight, :options}}
    end
  end

  defp settings(_options), do: {:error, {:invalid_operator_preflight, :options}}

  defp checks(nil, configuration, check_progress, check_runtimes, stall_after_seconds) do
    {:ok,
     [
       {:configuration, fn -> configuration_check(configuration) end},
       {:database, &Observability.health/0},
       {:schema, &schema_check/0},
       {:readiness,
        fn ->
          Observability.ready(
            check_progress: check_progress,
            check_runtimes: check_runtimes,
            stall_after_seconds: stall_after_seconds
          )
        end}
     ]}
  end

  defp checks(checks, _configuration, _check_progress, _check_runtimes, _stall_after_seconds)
       when is_list(checks) and checks != [] do
    if Enum.all?(checks, fn
         {name, check} when is_atom(name) and is_function(check, 0) -> true
         _invalid -> false
       end),
       do: {:ok, checks},
       else: {:error, {:invalid_operator_preflight, :checks}}
  end

  defp checks(_checks, _configuration, _check_progress, _check_runtimes, _stall_after_seconds),
    do: {:error, {:invalid_operator_preflight, :checks}}

  defp configuration_check(nil) do
    configured =
      :ryker
      |> Application.get_all_env()
      |> Keyword.keys()
      |> Enum.sort()

    {:ok, %{configured: configured}}
  end

  defp configuration_check(configuration) do
    {:ok, %{configured: configuration |> Map.keys() |> Enum.sort()}}
  end

  defp schema_check do
    pending =
      Repo
      |> Ecto.Migrator.migrations()
      |> Enum.flat_map(fn
        {:down, version, name} -> [%{name: name, version: version}]
        _current -> []
      end)

    if pending == [],
      do: {:ok, %{pending: []}},
      else: {:error, {:pending_migrations, pending}}
  end

  defp run_check({name, check}) do
    case safely(check) do
      :ok ->
        %{detail: nil, name: name, status: :ok}

      {:ok, detail} ->
        %{detail: detail, name: name, status: :ok}

      {:error, reason} ->
        %{detail: error_detail(reason), name: name, status: :failed}

      unexpected ->
        %{detail: error_detail({:unexpected_result, unexpected}), name: name, status: :failed}
    end
  end

  defp safely(check) do
    check.()
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp error_detail(reason),
    do: inspect(reason, limit: 20, printable_limit: 3_500, width: 120)

  defp optional_configuration(nil), do: :ok
  defp optional_configuration(configuration) when is_map(configuration), do: :ok
  defp optional_configuration(_configuration), do: {:error, :configuration}
end
