defmodule Mix.Tasks.Responder.Status do
  @moduledoc """
  Prints one payload-free durable operator snapshot as JSON.

      MIX_ENV=prod mix responder.status --config /etc/responder/responder-elixir.yaml
  """

  use Mix.Task

  alias Mix.Tasks.Responder.OperatorSupport, as: Support
  alias Responder.Operator.Status

  @shortdoc "Prints unified durable Responder status"

  @impl Mix.Task
  def run(arguments) do
    with {:ok, options, []} <- Support.parse(arguments, [config: :string], 0),
         {:ok, configuration} <- Support.configuration(options, true),
         :ok <- Support.install_configuration(configuration) do
      Support.with_repo(fn ->
        Status.snapshot(
          configuration: configuration,
          check_progress: false,
          check_runtimes: false
        )
      end)
      |> print_result()
    else
      {:error, reason} -> Support.fail("operator status", reason)
    end
  end

  defp print_result({:ok, snapshot}), do: Support.print(snapshot)
  defp print_result({:error, reason}), do: Support.fail("operator status", reason)
end
