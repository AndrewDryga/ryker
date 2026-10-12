defmodule Ryker.Evals.WorldCassette do
  @moduledoc """
  Deterministic external-source cassette for model-world evaluation.

  Rules match a tool and a recursive subset of important arguments. Calls may
  arrive in any sensible order, while each rule's own response sequence is
  preserved. Unmatched or exhausted calls fail closed and are always recorded.
  """
  use GenServer
  alias Ryker.CanonicalJSON
  alias Ryker.Evals.{Evidence, WorldCase, WorldMatch}

  @type reply :: {:ok, map()} | {:error, map()}

  @spec start_link(WorldCase.t()) :: GenServer.on_start()
  def start_link(%WorldCase{} = scenario), do: GenServer.start_link(__MODULE__, scenario)

  @spec call(GenServer.server(), String.t(), map()) :: reply()
  def call(server, tool, arguments), do: GenServer.call(server, {:call, tool, arguments})

  @spec calls(GenServer.server()) :: [map()]
  def calls(server), do: GenServer.call(server, :calls)

  @impl GenServer
  def init(%WorldCase{} = scenario) do
    rules = Map.new(scenario.world["tool_rules"], &{&1["id"], Map.put(&1, :offset, 0)})
    {:ok, %{calls: [], rules: rules}}
  end

  @impl GenServer
  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call({:call, tool, arguments}, _from, state)
      when is_binary(tool) and is_map(arguments) do
    call = %{
      arguments: Evidence.sanitize(arguments),
      arguments_sha256: CanonicalJSON.digest(arguments),
      tool: tool
    }

    case matching_rule(state.rules, tool, arguments) do
      nil ->
        reply = {:error, %{"code" => "unmatched_fabricated_tool_call"}}
        recorded = call |> Map.put(:outcome, :unmatched) |> Map.put(:result, result(reply))
        {:reply, reply, %{state | calls: [recorded | state.calls]}}

      {id, rule} ->
        {reply, outcome, next_rule} = next_response(rule)
        reply = interface(tool, arguments, reply, {id, rule.offset})
        rules = Map.put(state.rules, id, next_rule)

        recorded = call |> Map.put(:outcome, outcome) |> Map.put(:result, result(reply))
        {:reply, reply, %{state | calls: [recorded | state.calls], rules: rules}}
    end
  end

  def handle_call({:call, _tool, _arguments}, _from, state) do
    {:reply, {:error, %{"code" => "invalid_fabricated_tool_call"}}, state}
  end

  defp matching_rule(rules, tool, arguments) do
    rules
    |> Enum.filter(fn {_id, rule} ->
      rule["tool"] == tool and WorldMatch.matches?(rule["match"], arguments)
    end)
    |> Enum.sort_by(fn {id, _rule} -> id end)
    |> List.first()
  end

  defp next_response(%{:offset => offset, "responses" => responses} = rule)
       when offset < length(responses) do
    response = Enum.at(responses, offset)
    next_rule = %{rule | offset: offset + 1}

    case response do
      %{"kind" => "result", "value" => value} ->
        {{:ok, value}, :result, next_rule}

      %{"code" => code, "kind" => "error", "message" => message} ->
        {{:error, %{"code" => code, "message" => message}}, :error, next_rule}
    end
  end

  defp next_response(rule),
    do: {{:error, %{"code" => "rule_exhausted"}}, :exhausted, rule}

  # Emisar answers run_action with the operation and its runs, each run with
  # its link and its output inside. A world rule holds only the output, and a
  # turn that read all 148 alert rules from one had no link to cite (audit F01,
  # 2026-10-12), so the cassette answers in Emisar's envelope: the prompt has a
  # turn cite an Emisar result by its run_url.
  defp interface("run_action", arguments, {:ok, output}, call) do
    operation = "op_" <> binary_part(CanonicalJSON.digest(%{"call" => inspect(call)}), 0, 16)
    run = "run_" <> binary_part(CanonicalJSON.digest(%{"operation" => operation}), 0, 16)

    {:ok,
     %{
       "action_id" => arguments["action_id"],
       "ok" => true,
       "operation_id" => operation,
       "pack_ref" => arguments["pack_ref"],
       "runs" => [
         %{
           "action_id" => arguments["action_id"],
           "operation_id" => operation,
           "run_id" => run,
           "run_url" => "https://emisar.example/app/world/runs/#{run}",
           "status" => "succeeded",
           "structured_output" => output
         }
       ]
     }}
  end

  defp interface(_tool, _arguments, reply, _call), do: reply

  defp result({:ok, value}), do: Evidence.sanitize(value)
  defp result({:error, value}), do: Evidence.sanitize(%{"error" => value})
end
