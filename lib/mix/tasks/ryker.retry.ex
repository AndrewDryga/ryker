defmodule Mix.Tasks.Ryker.Retry do
  @moduledoc """
  Rearms one exact typed failure after operator inspection.

      MIX_ENV=prod mix ryker.retry KIND REF \
        --operator SLACK_USER_ID --action-ref UNIQUE_ACTION_REF

  Supported kinds are admission, delivery, emisar, retention,
  slack_incident, slack_interaction, and work. Publication review is not a
  generic infrastructure retry.

  Work recovery also requires --expected-recovery SHA256 from the inspected
  failure's work_recovery.fingerprint. A changed turn requires fresh inspection.
  """

  use Mix.Task

  alias Mix.Tasks.Ryker.OperatorSupport, as: Support
  alias Ryker.Operator.Failures

  @shortdoc "Rearms one exact typed durable failure"

  @impl Mix.Task
  def run(arguments) do
    switches = [
      operator: :string,
      action_ref: :string,
      expected_recovery: :string
    ]

    case Support.parse(arguments, switches, 2) do
      {:ok, options, [kind, ref]} -> print_result(retry(kind, ref, options))
      {:error, reason} -> Support.fail("operator retry", reason)
    end
  end

  defp retry(kind, ref, options) do
    Support.with_configuration(fn _configuration ->
      with {:ok, actor_ref} <- Support.authorized_actor(options),
           {:ok, action_ref} <- Support.required_option(options, :action_ref) do
        Failures.retry(kind, ref,
          actor_ref: actor_ref,
          action_ref: action_ref,
          expected_recovery: Keyword.get(options, :expected_recovery)
        )
      end
    end)
  end

  defp print_result({:ok, outcome}), do: Support.print(outcome)
  defp print_result({:error, reason}), do: Support.fail("operator retry", reason)
end
