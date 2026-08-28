defmodule Responder.Webhooks.Server do
  @moduledoc """
  Optional Bandit listener for the universal webhook boundary.

  No listener starts unless `:responder, :webhooks` is configured explicitly.
  """

  alias Responder.Webhooks.{Route, Router}

  @default_ip {127, 0, 0, 1}
  @fields [:ip, :port, :routes]

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    options = options!(configuration)

    Bandit.child_spec(
      ip: options.ip,
      plug: {Router, routes: options.routes},
      port: options.port,
      startup_log: false
    )
    |> Map.put(:id, __MODULE__)
  end

  @doc false
  @spec options!(keyword() | map()) :: %{
          ip: :inet.ip_address(),
          port: pos_integer(),
          routes: map()
        }
  def options!(configuration) do
    configuration = normalize_configuration!(configuration)
    port = Map.fetch!(configuration, :port)
    ip = Map.get(configuration, :ip, @default_ip)
    routes = configuration |> Map.fetch!(:routes) |> normalize_routes!()

    unless valid_port?(port), do: raise(ArgumentError, "webhook port must be between 1 and 65535")
    unless valid_ip?(ip), do: raise(ArgumentError, "webhook IP must be an IPv4 or IPv6 tuple")

    %{ip: ip, port: port, routes: routes}
  end

  defp normalize_configuration!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration) do
      configuration |> Map.new() |> normalize_configuration!()
    else
      raise ArgumentError, "webhook server configuration must use unique known fields"
    end
  end

  defp normalize_configuration!(%{} = configuration) do
    keys = Map.keys(configuration)

    if Enum.sort(keys -- @fields) == [] and :port in keys and :routes in keys,
      do: configuration,
      else:
        raise(
          ArgumentError,
          "webhook server configuration must include only port, IP, and routes"
        )
  end

  defp normalize_configuration!(_configuration) do
    raise ArgumentError, "webhook server configuration must be a map or keyword list"
  end

  defp normalize_routes!(routes) when is_map(routes) and map_size(routes) > 0 do
    Map.new(routes, fn
      {name, %Route{} = route} when is_binary(name) ->
        if route.name == name,
          do: {name, route},
          else: raise(ArgumentError, "webhook route key and configured name must match")

      {name, attributes} when is_binary(name) and is_map(attributes) ->
        case attributes |> Map.put_new(:name, name) |> Route.new() do
          {:ok, route} ->
            {name, route}

          {:error, reason} ->
            raise ArgumentError, "invalid webhook route #{inspect(name)}: #{inspect(reason)}"
        end

      {name, _attributes} ->
        raise ArgumentError, "invalid webhook route name or configuration: #{inspect(name)}"
    end)
  end

  defp normalize_routes!(_routes),
    do: raise(ArgumentError, "at least one webhook route is required")

  defp valid_port?(port), do: is_integer(port) and port >= 1 and port <= 65_535

  defp valid_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 4,
    do: valid_ip_parts?(ip, 255)

  defp valid_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 8,
    do: valid_ip_parts?(ip, 65_535)

  defp valid_ip?(_ip), do: false

  defp valid_ip_parts?(ip, maximum) do
    ip |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= maximum))
  end
end
