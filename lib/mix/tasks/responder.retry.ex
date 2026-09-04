defmodule Mix.Tasks.Responder.Retry do
  @moduledoc """
  Rearms one exact typed failure after operator inspection.

      MIX_ENV=prod mix responder.retry KIND REF --config /absolute/responder.yaml \
        --operator SLACK_USER_ID --action-ref UNIQUE_ACTION_REF

  Supported kinds are admission, delivery, emisar, retention,
  slack_incident, slack_interaction, and work. Publication review is not a
  generic infrastructure retry.
  """

  use Mix.Task

  alias Mix.Tasks.Responder.OperatorSupport, as: Support
  alias Responder.Operator.Failures

  @shortdoc "Rearms one exact typed durable failure"

  @impl Mix.Task
  def run(arguments) do
    switches = [config: :string, operator: :string, action_ref: :string]

    with {:ok, options, [kind, ref]} <- Support.parse(arguments, switches, 2),
         {:ok, configuration} <- Support.configuration(options, true),
         :ok <- Support.install_configuration(configuration),
         {:ok, actor_ref} <- Support.authorized_actor(configuration, options),
         {:ok, action_ref} <- Support.required_option(options, :action_ref),
         retry_options <- [actor_ref: actor_ref, action_ref: action_ref],
         result <- Support.with_repo(fn -> Failures.retry(kind, ref, retry_options) end) do
      print_result(result)
    else
      {:error, reason} -> Support.fail("operator retry", reason)
    end
  end

  defp print_result({:ok, outcome}), do: Support.print(outcome)
  defp print_result({:error, reason}), do: Support.fail("operator retry", reason)
end
