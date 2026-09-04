defmodule Mix.Tasks.Responder.Failures do
  @moduledoc """
  Lists bounded retryable failure context as JSON.

      MIX_ENV=prod mix responder.failures --config /etc/responder/responder-elixir.yaml
  """

  use Mix.Task

  alias Mix.Tasks.Responder.OperatorSupport, as: Support
  alias Responder.Operator.Failures

  @shortdoc "Lists typed retryable durable failures"

  @impl Mix.Task
  def run(arguments) do
    with {:ok, options, []} <- Support.parse(arguments, [config: :string], 0),
         {:ok, _configuration} <- Support.configuration(options) do
      Support.with_repo(&Failures.list/0)
      |> print_result()
    else
      {:error, reason} -> Support.fail("operator failures", reason)
    end
  end

  defp print_result({:ok, failures}), do: Support.print(failures)
  defp print_result({:error, reason}), do: Support.fail("operator failures", reason)
end
