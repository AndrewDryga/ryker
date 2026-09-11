defmodule Mix.Tasks.Responder.Replay do
  @moduledoc """
  Queues or inspects a private Slack replay.

      MIX_ENV=prod mix responder.replay slack SOURCE_INPUT_REF REQUEST_REF \
        --operator SLACK_USER_ID \
        --action-ref UNIQUE_ACTION_REF
      MIX_ENV=prod mix responder.replay show REPLAY_INPUT_REF

  The replay enters normal admission and Work as shadow execution; all visible
  Slack and other platform effects are forbidden by that shared host boundary.
  """

  use Mix.Task

  alias Mix.Tasks.Responder.OperatorSupport, as: Support
  alias Responder.Operator.SlackReplay

  @shortdoc "Queues or inspects a private no-delivery Slack replay"

  @impl Mix.Task
  def run(arguments) do
    switches = [operator: :string, action_ref: :string]

    case Support.parse(arguments, switches, [2, 3]) do
      {:ok, options, positional} -> print_result(operation(positional, options))
      {:error, reason} -> Support.fail("operator replay", reason)
    end
  end

  # Reading a recorded replay mutates nothing and needs no operator identity, so
  # it does not require the installation to be configured.
  defp operation(["show", replay_input_ref], []),
    do: Support.with_repo(fn -> SlackReplay.fetch(replay_input_ref) end)

  defp operation(["slack", source_input_ref, request_ref], options) do
    Support.with_configuration(fn _configuration ->
      with {:ok, actor_ref} <- Support.authorized_actor(options),
           {:ok, action_ref} <- Support.required_option(options, :action_ref) do
        SlackReplay.enqueue(source_input_ref, request_ref,
          action_ref: action_ref,
          actor_ref: actor_ref
        )
      end
    end)
  end

  defp operation(_positional, _options), do: {:error, :invalid_arguments}

  defp print_result({:ok, outcome}), do: Support.print(outcome)
  defp print_result({:error, reason}), do: Support.fail("operator replay", reason)
end
