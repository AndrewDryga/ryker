defmodule Ryker.GitHub.Server do
  @moduledoc """
  Optional Bandit listener for authenticated GitHub App webhooks.
  """
  alias Ryker.GitHub.{Binding, Confirmations, Router}
  alias Ryker.Options
  alias Ryker.Secret

  @default_ip {127, 0, 0, 1}
  @fields [:bindings, :bot_login, :confirmations, :ip, :port, :repository_access, :secret]

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    options = options!(configuration)

    Bandit.child_spec(
      ip: options.ip,
      plug: {Router, router_options(options)},
      port: options.port,
      startup_log: false
    )
    |> Map.put(:id, __MODULE__)
  end

  @doc """
  The `Ryker.GitHub.Router` options for normalized server options: what the
  listener serves, and what `Ryker.GitHub.DeliveryPoller` hands deliveries to.
  """
  @spec router_options(map()) :: keyword()
  def router_options(options) do
    router_options = [
      bindings: options.bindings,
      bot_login: options.bot_login,
      repository_access: options.repository_access,
      secret: options.secret
    ]

    if options.confirmations,
      do: Keyword.put(router_options, :confirmations, options.confirmations),
      else: router_options
  end

  @doc false
  @spec options!(keyword() | map()) :: %{
          bindings: %{String.t() => Binding.t()},
          bot_login: String.t(),
          confirmations: Confirmations.options() | nil,
          ip: :inet.ip_address(),
          port: pos_integer(),
          repository_access: (Binding.t(), map() -> :ok | {:error, term()}),
          secret: Secret.t()
        }
  def options!(configuration) do
    configuration = normalize_configuration!(configuration)
    port = Map.fetch!(configuration, :port)
    ip = Map.get(configuration, :ip, @default_ip)
    bindings = configuration |> Map.fetch!(:bindings) |> normalize_bindings!()
    bot_login = Map.fetch!(configuration, :bot_login)

    repository_access =
      Map.get(configuration, :repository_access, &unconfigured_repository_access/2)

    confirmations =
      case Map.get(configuration, :confirmations) do
        nil -> nil
        configured -> Confirmations.options!(configured)
      end

    secret = Map.fetch!(configuration, :secret)

    unless is_integer(port) and port in 1..65_535,
      do: raise(ArgumentError, "GitHub port must be between 1 and 65535")

    unless :inet.is_ip_address(ip),
      do: raise(ArgumentError, "GitHub IP must be an IPv4 or IPv6 tuple")

    unless valid_secret?(secret), do: raise(ArgumentError, "GitHub webhook secret is invalid")
    unless valid_bot_login?(bot_login), do: raise(ArgumentError, "GitHub bot login is invalid")

    unless is_function(repository_access, 2),
      do: raise(ArgumentError, "GitHub repository access checker is invalid")

    %{
      bindings: bindings,
      bot_login: bot_login,
      confirmations: confirmations,
      ip: ip,
      port: port,
      repository_access: repository_access,
      secret: secret
    }
  end

  defp normalize_configuration!(configuration) do
    Options.normalize!(configuration, @fields, [:bindings, :bot_login, :port, :secret],
      list: "GitHub server configuration must use unique known fields",
      map: "GitHub server configuration must include port, secret, and bindings",
      other: "GitHub server configuration must be a map or keyword list"
    )
  end

  # An empty map is a verified App with no repository added yet.
  defp normalize_bindings!(bindings) when is_map(bindings) do
    Map.new(bindings, fn
      {name, %Binding{} = binding} when is_binary(name) ->
        if binding.name == name,
          do: {name, binding},
          else: raise(ArgumentError, "GitHub binding key and configured name must match")

      {name, attributes} when is_binary(name) and is_map(attributes) ->
        case Binding.new(Map.put_new(attributes, :name, name)) do
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
    do: raise(ArgumentError, "GitHub bindings must be a map")

  defp valid_secret?(%Secret{value: secret}),
    do: is_binary(secret) and byte_size(secret) in 32..1_024

  defp valid_secret?(_unsealed), do: false

  defp valid_bot_login?(login),
    do: is_binary(login) and Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/, login)

  defp unconfigured_repository_access(_binding, _payload),
    do: {:error, {:github_repository_access_unavailable, :not_configured}}
end
