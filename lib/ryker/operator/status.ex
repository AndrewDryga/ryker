defmodule Ryker.Operator.Status do
  @moduledoc """
  Shared read-only operator snapshot used by CLI and local control surfaces.
  """

  alias Ryker.ControlPlane.{FailureProjection, OverviewProjection}
  alias Ryker.Observability
  alias Ryker.Operator.Preflight

  @default_stall_after_seconds 15 * 60
  @options [:configuration, :check_progress, :check_runtimes, :stall_after_seconds]

  @spec snapshot(keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(options \\ []) do
    with :ok <- options(options),
         stall_after_seconds <-
           Keyword.get(options, :stall_after_seconds, @default_stall_after_seconds),
         preflight <- preflight(options),
         {:ok, observability} <- Observability.snapshot(stall_after_seconds),
         {:ok, failures} <- FailureProjection.list(%{}) do
      {:ok,
       %{
         failures: failure_summary(failures),
         observability: observability,
         overview: OverviewProjection.overview(),
         preflight: preflight,
         queues: observability.queues
       }}
    end
  rescue
    error -> {:error, {:operator_status_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:operator_status_failed, kind, inspect(reason)}}
  end

  defp preflight(options) do
    case Preflight.run(options) do
      {:ok, report} -> report
      {:error, %{} = report} -> report
      {:error, reason} -> %{checks: [], detail: inspect(reason), status: :failed}
    end
  end

  defp failure_summary(failures) do
    %{
      by_kind: Enum.frequencies_by(failures, & &1.kind),
      total: length(failures)
    }
  end

  defp options(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         keys <- Keyword.keys(options),
         true <- Enum.uniq(keys) == keys,
         true <- keys -- @options == [],
         true <- is_boolean(Keyword.get(options, :check_progress, true)),
         true <- is_boolean(Keyword.get(options, :check_runtimes, true)),
         true <- valid_stall_after_seconds?(options),
         true <- valid_configuration?(Keyword.get(options, :configuration)) do
      :ok
    else
      _invalid -> {:error, {:invalid_operator_status, :options}}
    end
  end

  defp options(_options), do: {:error, {:invalid_operator_status, :options}}

  defp valid_stall_after_seconds?(options) do
    value = Keyword.get(options, :stall_after_seconds, @default_stall_after_seconds)
    is_integer(value) and value > 0
  end

  defp valid_configuration?(nil), do: true
  defp valid_configuration?(configuration), do: is_map(configuration)
end
