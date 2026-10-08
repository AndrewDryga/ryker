defmodule Ryker.Webhooks.Server do
  @moduledoc """
  Optional Bandit listener for the authenticated webhook boundary.

  No listener starts unless `:ryker, :webhooks` is configured explicitly.
  """
  alias Ryker.Options
  alias Ryker.Webhooks.{Route, Router}

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

    unless is_integer(port) and port in 1..65_535,
      do: raise(ArgumentError, "webhook port must be between 1 and 65535")

    unless :inet.is_ip_address(ip),
      do: raise(ArgumentError, "webhook IP must be an IPv4 or IPv6 tuple")

    %{ip: ip, port: port, routes: routes}
  end

  defp normalize_configuration!(configuration) do
    Options.normalize!(configuration, @fields, [:port, :routes],
      list: "webhook server configuration must use unique known fields",
      map: "webhook server configuration must include only port, IP, and routes",
      other: "webhook server configuration must be a map or keyword list"
    )
  end

  defp normalize_routes!(routes) when is_map(routes) and map_size(routes) > 0 do
    Map.new(routes, fn
      {name, %Route{} = route} when is_binary(name) ->
        if route.name == name,
          do: {name, route},
          else: raise(ArgumentError, "webhook route key and configured name must match")

      {name, attributes} when is_binary(name) and is_map(attributes) ->
        case Route.new(Map.put_new(attributes, :name, name)) do
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
end
