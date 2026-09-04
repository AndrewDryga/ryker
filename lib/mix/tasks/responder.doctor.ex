defmodule Mix.Tasks.Responder.Doctor do
  @moduledoc """
  Runs every read-only operator preflight check.

      MIX_ENV=prod mix responder.doctor --config /etc/responder/responder-elixir.yaml

  The separate Mix process checks configuration, PostgreSQL, migrations, and
  durable queue readiness. Live runtime PID and progress checks remain owned by
  the running release's `/readyz` endpoint.
  """

  use Mix.Task

  alias Mix.Tasks.Responder.OperatorSupport, as: Support
  alias Responder.Operator.Preflight

  @shortdoc "Runs read-only configuration and durable-state preflight"

  @impl Mix.Task
  def run(arguments) do
    with {:ok, options, []} <- Support.parse(arguments, [config: :string], 0),
         {:ok, configuration} <- Support.configuration(options, true),
         :ok <- Support.install_configuration(configuration) do
      Support.with_repo(fn ->
        Preflight.run(
          configuration: configuration,
          check_progress: false,
          check_runtimes: false
        )
      end)
      |> print_result()
    else
      {:error, reason} -> Support.fail("operator preflight", reason)
    end
  end

  defp print_result({:ok, report}), do: Support.print(report)

  defp print_result({:error, %{} = report}) do
    Support.print(report)
    Support.fail("operator preflight", :checks_failed)
  end

  defp print_result({:error, reason}), do: Support.fail("operator preflight", reason)
end
