defmodule Ryker.Evals.WorldTools do
  @moduledoc false

  alias Ryker.CanonicalJSON
  alias Ryker.Evals.{WorldCase, WorldCassette}
  alias Ryker.StateTools.Tools

  @spec prepare(map(), WorldCase.t(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def prepare(%{capabilities: capabilities} = configured, %WorldCase{} = scenario, cassette)
      when is_list(capabilities) do
    fixed = Tools.list(tool_options(configured))
    scenario_fixed = WorldCase.state_tools(scenario)
    platform = Map.get(configured, :additional_tools) || []
    fabricated = WorldCase.fabricated_tools(scenario)
    all = fixed ++ platform ++ fabricated
    names = Enum.map(all, & &1["name"])

    cond do
      fixed != scenario_fixed ->
        {:error,
         {:model_world_state_tool_catalog_mismatch,
          %{
            configured: Enum.map(fixed, & &1["name"]),
            scenario: Enum.map(scenario_fixed, & &1["name"])
          }}}

      Enum.all?(all, &valid_tool?/1) and names == Enum.uniq(names) ->
        platform_names = MapSet.new(platform, & &1["name"])
        fabricated_names = MapSet.new(fabricated, & &1["name"])

        callback =
          if platform == [] and fabricated == [],
            do: nil,
            else: tool_callback(cassette, fabricated_names, platform_names)

        state_tools =
          configured
          |> Map.put(:additional_tools, platform ++ fabricated)
          |> Map.put(:additional_call, callback)
          |> Map.put(:answer_authorizer, WorldCase.answer_authorizer(scenario))

        catalog = %{
          "servers" => [%{"name" => "responder-state", "tools" => all}],
          "version" => 1
        }

        {:ok,
         %{
           catalog: catalog,
           catalog_sha256: CanonicalJSON.digest(catalog),
           source_and_action_tools: platform ++ fabricated,
           state_tools: state_tools,
           tool_names: names
         }}

      true ->
        {:error, :model_world_tool_name_conflict}
    end
  end

  def prepare(_configured, _scenario, _cassette),
    do: {:error, :model_world_state_tools_not_configured}

  defp tool_options(configured) do
    [capabilities: configured.capabilities]
    |> maybe_put(:emisar_rpc_url, Map.get(configured, :emisar_rpc_url))
  end

  defp valid_tool?(%{"description" => description, "inputSchema" => %{}, "name" => name})
       when is_binary(description) and is_binary(name),
       do: true

  defp valid_tool?(_tool), do: false

  defp tool_callback(cassette, fabricated_names, platform_names) do
    fn name, arguments, _binding ->
      cond do
        MapSet.member?(fabricated_names, name) ->
          WorldCassette.call(cassette, name, arguments)

        MapSet.member?(platform_names, name) ->
          WorldCassette.inert_call(cassette, name, arguments)

        true ->
          {:error, %{"code" => "unknown_model_world_tool"}}
      end
    end
  end

  defp maybe_put(values, _key, nil), do: values
  defp maybe_put(values, key, value), do: Keyword.put(values, key, value)
end
