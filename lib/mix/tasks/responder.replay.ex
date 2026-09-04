defmodule Mix.Tasks.Responder.Replay do
  @moduledoc """
  Queues or inspects a private Slack replay.

      MIX_ENV=prod mix responder.replay slack SOURCE_INPUT_REF REQUEST_REF \
        --config /absolute/responder.yaml --operator SLACK_USER_ID \
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
    switches = [config: :string, operator: :string, action_ref: :string]

    with {:ok, options, positional} <- Support.parse(arguments, switches, [2, 3]),
         {:ok, operation} <- operation(positional, options) do
      operation
      |> Support.with_repo()
      |> print_result()
    else
      {:error, reason} -> Support.fail("operator replay", reason)
    end
  end

  defp operation(["slack", source_input_ref, request_ref], options) do
    with {:ok, configuration} <- Support.configuration(options, true),
         :ok <- Support.install_configuration(configuration),
         {:ok, actor_ref} <- Support.authorized_actor(configuration, options),
         {:ok, action_ref} <- Support.required_option(options, :action_ref) do
      {:ok,
       fn ->
         SlackReplay.enqueue(source_input_ref, request_ref,
           action_ref: action_ref,
           actor_ref: actor_ref
         )
       end}
    end
  end

  defp operation(["show", replay_input_ref], options) do
    if Keyword.keys(options) -- [:config] == [] do
      with {:ok, configuration} <- Support.configuration(options),
           :ok <- Support.install_configuration(configuration) do
        {:ok, fn -> SlackReplay.fetch(replay_input_ref) end}
      end
    else
      {:error, :invalid_arguments}
    end
  end

  defp operation(_invalid, _options), do: {:error, :invalid_arguments}

  defp print_result({:ok, outcome}), do: Support.print(outcome)
  defp print_result({:error, reason}), do: Support.fail("operator replay", reason)
end
