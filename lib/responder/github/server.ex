defmodule Responder.GitHub.Server do
  @moduledoc """
  Optional Bandit listener for authenticated GitHub App webhooks.
  """

  alias Responder.GitHub.{Binding, Router}

  @default_ip {127, 0, 0, 1}
  @fields [:bindings, :ip, :port, :secret]

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    options = options!(configuration)

    Bandit.child_spec(
      ip: options.ip,
      plug: {Router, bindings: options.bindings, secret: options.secret},
      port: options.port,
      startup_log: false
    )
    |> Map.put(:id, __MODULE__)
  end

  @doc false
  @spec options!(keyword() | map()) :: %{
          bindings: %{String.t() => Binding.t()},
          ip: :inet.ip_address(),
          port: pos_integer(),
          secret: binary()
        }
  def options!(configuration) do
    configuration = normalize_configuration!(configuration)
    port = Map.fetch!(configuration, :port)
    ip = Map.get(configuration, :ip, @default_ip)
    bindings = configuration |> Map.fetch!(:bindings) |> normalize_bindings!()
    secret = Map.fetch!(configuration, :secret)

    unless valid_port?(port), do: raise(ArgumentError, "GitHub port must be between 1 and 65535")
    unless valid_ip?(ip), do: raise(ArgumentError, "GitHub IP must be an IPv4 or IPv6 tuple")
    unless valid_secret?(secret), do: raise(ArgumentError, "GitHub webhook secret is invalid")

    %{bindings: bindings, ip: ip, port: port, secret: secret}
  end

  defp normalize_configuration!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration) do
      configuration |> Map.new() |> normalize_configuration!()
    else
      raise ArgumentError, "GitHub server configuration must use unique known fields"
    end
  end

  defp normalize_configuration!(%{} = configuration) do
    keys = Map.keys(configuration)

    if Enum.sort(keys -- @fields) == [] and
         Enum.all?([:bindings, :port, :secret], &(&1 in keys)),
       do: configuration,
       else:
         raise(
           ArgumentError,
           "GitHub server configuration must include port, secret, and bindings"
         )
  end

  defp normalize_configuration!(_configuration),
    do: raise(ArgumentError, "GitHub server configuration must be a map or keyword list")

  defp normalize_bindings!(bindings) when is_map(bindings) and map_size(bindings) > 0 do
    Map.new(bindings, fn
      {name, %Binding{} = binding} when is_binary(name) ->
        if binding.name == name,
          do: {name, binding},
          else: raise(ArgumentError, "GitHub binding key and configured name must match")

      {name, attributes} when is_binary(name) and is_map(attributes) ->
        case attributes |> Map.put_new(:name, name) |> Binding.new() do
          {:ok, binding} ->
            {name, binding}

          {:error, reason} ->
            raise ArgumentError, "invalid GitHub binding #{inspect(name)}: #{inspect(reason)}"
        end

      {name, _attributes} ->
        raise ArgumentError, "invalid GitHub binding name or configuration: #{inspect(name)}"
    end)
  end

  defp normalize_bindings!(_bindings),
    do: raise(ArgumentError, "at least one GitHub binding is required")

  defp valid_port?(port), do: is_integer(port) and port >= 1 and port <= 65_535

  defp valid_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 4,
    do: valid_ip_parts?(ip, 255)

  defp valid_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 8,
    do: valid_ip_parts?(ip, 65_535)

  defp valid_ip?(_ip), do: false

  defp valid_ip_parts?(ip, maximum) do
    ip |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= maximum))
  end

  defp valid_secret?(secret), do: is_binary(secret) and byte_size(secret) in 32..1_024
end
