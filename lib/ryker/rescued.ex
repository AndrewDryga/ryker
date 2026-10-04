defmodule Ryker.Rescued do
  @moduledoc """
  Raises that Ryker turns into a soft answer, logged.

  A tool that raises answers the model "temporarily_unavailable", a readiness
  check answers "not ready", a lookup answers "unknown". Each soft answer is
  right for the caller, but without a log line a host bug looked like Slack
  being down (2026-10-04 review). The log names what raised, the raise and
  the five innermost frames. A lost database connection is an outage that
  every database caller reports already, so it is not logged again here.
  """

  require Logger

  @doc "Logs a raise rescued inside `what`."
  @spec log(String.t(), Exception.t(), Exception.stacktrace()) :: :ok
  def log(_what, %DBConnection.ConnectionError{}, _stacktrace), do: :ok

  def log(what, error, stacktrace) when is_binary(what) do
    Logger.error(
      "#{what} raised: " <>
        Exception.format_banner(:error, error) <>
        "\n" <> Exception.format_stacktrace(Enum.take(stacktrace, 5))
    )
  end

  @doc "Logs a raise inside a model tool and gives the tool's soft answer."
  @spec tool(String.t(), Exception.t(), Exception.stacktrace()) :: {:error, String.t()}
  def tool(tool, error, stacktrace) do
    log(tool, error, stacktrace)
    {:error, "temporarily_unavailable"}
  end
end
