defmodule Ryker.StateTools.Server do
  @moduledoc """
  Optional loopback MCP listener for Ryker-owned episode state tools.
  """

  alias Ryker.StateTools.Router

  @default_ip {127, 0, 0, 1}
  @fields [
    :additional_call,
    :additional_tools,
    :answer_authorizer,
    :capabilities,
    :ip,
    :port,
    :token
  ]

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    options = options!(configuration)

    router_options =
      [token: options.token]
      |> Keyword.put(:capabilities, options.capabilities)
      |> maybe_put(:additional_tools, Map.get(options, :additional_tools))
      |> maybe_put(:additional_call, Map.get(options, :additional_call))
      |> maybe_put(:answer_authorizer, Map.get(options, :answer_authorizer))

    Bandit.child_spec(
      ip: options.ip,
      plug: {Router, router_options},
      port: options.port,
      startup_log: false
    )
    |> Map.put(:id, __MODULE__)
  end

  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    configuration = normalize!(configuration)
    ip = Map.get(configuration, :ip, @default_ip)
    port = Map.fetch!(configuration, :port)
    token = Map.fetch!(configuration, :token)
    capabilities = Map.get(configuration, :capabilities, [:event_waits, :publication, :schedules])

    unless loopback_ip?(ip), do: raise(ArgumentError, "state-tools IP must be loopback")

    unless is_integer(port) and port in 1..65_535,
      do: raise(ArgumentError, "state-tools port must be between 1 and 65535")

    router_options =
      [token: token, capabilities: capabilities]
      |> maybe_put(:additional_tools, Map.get(configuration, :additional_tools))
      |> maybe_put(:additional_call, Map.get(configuration, :additional_call))
      |> maybe_put(:answer_authorizer, Map.get(configuration, :answer_authorizer))

    _validated = Router.init(router_options)

    %{capabilities: capabilities, ip: ip, port: port, token: token}
    |> maybe_put(:additional_tools, Map.get(configuration, :additional_tools))
    |> maybe_put(:additional_call, Map.get(configuration, :additional_call))
    |> maybe_put(:answer_authorizer, Map.get(configuration, :answer_authorizer))
  end

  defp normalize!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration),
       do: configuration |> Map.new() |> normalize!(),
       else: raise(ArgumentError, "state-tools configuration must use unique known fields")
  end

  defp normalize!(%{} = configuration) do
    keys = Map.keys(configuration)

    if Enum.sort(keys -- @fields) == [] and :port in keys and :token in keys,
      do: configuration,
      else: raise(ArgumentError, "state-tools configuration must include port and token")
  end

  defp normalize!(_configuration),
    do: raise(ArgumentError, "state-tools configuration must be a map or keyword list")

  defp loopback_ip?({127, 0, 0, 1}), do: true
  defp loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_ip?(_ip), do: false

  defp maybe_put(values, _key, nil), do: values
  defp maybe_put(values, key, value) when is_list(values), do: Keyword.put(values, key, value)
  defp maybe_put(values, key, value) when is_map(values), do: Map.put(values, key, value)
end
