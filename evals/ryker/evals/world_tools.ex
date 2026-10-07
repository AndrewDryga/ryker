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
    fabricated = WorldCase.fabricated_tools(scenario)
    all = fixed ++ fabricated
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
        callback = if fabricated == [], do: nil, else: tool_callback(cassette, fabricated)

        state_tools =
          configured
          |> Map.put(:additional_tools, fabricated)
          |> Map.put(:additional_call, callback)
          |> Map.put(:answer_authorizer, WorldCase.answer_authorizer(scenario))

        catalog = %{
          "servers" => [%{"name" => "controller-tools", "tools" => all}],
          "version" => 1
        }

        {:ok,
         %{
           catalog: catalog,
           catalog_sha256: CanonicalJSON.digest(catalog),
           source_and_action_tools: fabricated,
           state_tools: state_tools,
           tool_names: names
         }}

      true ->
        {:error, :model_world_tool_name_conflict}
    end
  end

  def prepare(_configured, _scenario, _cassette),
    do: {:error, :model_world_state_tools_not_configured}

  defp tool_options(configured), do: [capabilities: configured.capabilities]

  defp valid_tool?(%{"description" => description, "inputSchema" => %{}, "name" => name})
       when is_binary(description) and is_binary(name),
       do: true

  defp valid_tool?(_tool), do: false

  # The scenario's recorded world answers its own tools; anything else is refused.
  defp tool_callback(cassette, fabricated) do
    names = MapSet.new(fabricated, & &1["name"])

    fn name, arguments, _binding ->
      if MapSet.member?(names, name),
        do: WorldCassette.call(cassette, name, arguments),
        else: {:error, %{"code" => "unknown_model_world_tool"}}
    end
  end
end
