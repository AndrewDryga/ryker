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

  @spec inert_call(GenServer.server(), String.t(), map()) :: {:error, map()}
  def inert_call(server, tool, arguments),
    do: GenServer.call(server, {:inert_call, tool, arguments})

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
      arguments_sha256: sha256(CanonicalJSON.encode!(arguments)),
      tool: tool
    }

    case matching_rule(state.rules, tool, arguments) do
      nil ->
        reply = {:error, %{"code" => "unmatched_fabricated_tool_call"}}
        recorded = call |> Map.put(:outcome, :unmatched) |> Map.put(:result, result(reply))
        {:reply, reply, %{state | calls: [recorded | state.calls]}}

      {id, rule} ->
        {reply, outcome, next_rule} = next_response(rule)
        rules = Map.put(state.rules, id, next_rule)

        recorded = call |> Map.put(:outcome, outcome) |> Map.put(:result, result(reply))
        {:reply, reply, %{state | calls: [recorded | state.calls], rules: rules}}
    end
  end

  def handle_call({:inert_call, tool, arguments}, _from, state)
      when is_binary(tool) and is_map(arguments) do
    reply = {:error, %{"code" => "model_world_external_tool_disabled"}}

    call = %{
      arguments: Evidence.sanitize(arguments),
      arguments_sha256: sha256(CanonicalJSON.encode!(arguments)),
      outcome: :inert,
      result: %{"error" => "model_world_external_tool_disabled"},
      tool: tool
    }

    {:reply, reply, %{state | calls: [call | state.calls]}}
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

  defp result({:ok, value}), do: Evidence.sanitize(value)
  defp result({:error, value}), do: Evidence.sanitize(%{"error" => value})

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
