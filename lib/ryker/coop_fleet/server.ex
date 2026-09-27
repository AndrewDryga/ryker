defmodule Ryker.CoopFleet.Server do
  @moduledoc """
  Mutual-TLS HTTPS listener for outbound Coop worker polls.
  """

  alias Ryker.CoopFleet.Router
  alias Ryker.Options

  @fields [
    :body_root,
    :cacertfile,
    :ca_keyfile,
    :certificate_ttl_seconds,
    :certfile,
    :checkpoint_key,
    :checkpoint_secrets,
    :ip,
    :keyfile,
    :port,
    :public_url,
    :state_tools
  ]

  @spec child_spec(map() | keyword()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    options = options!(configuration)

    Bandit.child_spec(
      certfile: options.certfile,
      ip: options.ip,
      keyfile: options.keyfile,
      plug: {Router, router_options(options)},
      port: options.port,
      scheme: :https,
      startup_log: false,
      thousand_island_options: [
        transport_options: [
          cacertfile: options.cacertfile,
          fail_if_no_peer_cert: false,
          verify: :verify_peer,
          versions: [:"tlsv1.3"]
        ]
      ]
    )
    |> Map.put(:id, __MODULE__)
  end

  @spec options!(map() | keyword()) :: map()
  def options!(configuration) do
    configuration = normalize!(configuration)
    ip = Map.get(configuration, :ip, {127, 0, 0, 1})
    port = Map.fetch!(configuration, :port)

    validate_ip!(ip)
    validate_port!(port)
    validate_certificate_files!(configuration)

    certificate_ttl_seconds = Map.get(configuration, :certificate_ttl_seconds, 24 * 60 * 60)

    unless is_integer(certificate_ttl_seconds) and certificate_ttl_seconds in 300..604_800,
      do:
        raise(
          ArgumentError,
          "Coop worker certificate lifetime must be between 300 and 604800 seconds"
        )

    validate_public_url!(Map.get(configuration, :public_url))
    validate_state_tools!(Map.get(configuration, :state_tools))
    validate_checkpoint_custody!(configuration)

    unless is_binary(configuration.body_root) and
             Path.type(configuration.body_root) == :absolute,
           do: raise(ArgumentError, "Coop worker body root must be an absolute path")

    configuration
    |> Map.put(:certificate_ttl_seconds, certificate_ttl_seconds)
    |> Map.put(:ip, ip)
  end

  defp validate_ip!(ip) do
    unless valid_ip?(ip), do: raise(ArgumentError, "Coop worker gateway IP is invalid")
  end

  defp validate_port!(port) do
    unless is_integer(port) and port in 1..65_535,
      do: raise(ArgumentError, "Coop worker gateway port must be between 1 and 65535")
  end

  defp validate_certificate_files!(configuration) do
    for field <- [:cacertfile, :ca_keyfile, :certfile, :keyfile] do
      path = Map.fetch!(configuration, field)

      unless is_binary(path) and Path.type(path) == :absolute and File.regular?(path),
        do: raise(ArgumentError, "Coop worker gateway #{field} must be an existing absolute file")
    end
  end

  defp normalize!(configuration) do
    required = [
      :body_root,
      :cacertfile,
      :ca_keyfile,
      :certfile,
      :checkpoint_key,
      :checkpoint_secrets,
      :keyfile,
      :port
    ]

    Options.normalize!(configuration, @fields, required,
      list: "Coop worker gateway configuration must use unique fields",
      map: "Coop worker gateway configuration is incomplete",
      other: "Coop worker gateway configuration must be a map"
    )
  end

  defp valid_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 4,
    do: ip |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= 255))

  defp valid_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 8,
    do: ip |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= 65_535))

  defp valid_ip?(_ip), do: false

  defp router_options(options) do
    [
      enrollment_authority: %{
        cacertfile: options.cacertfile,
        ca_keyfile: options.ca_keyfile,
        certificate_ttl_seconds: options.certificate_ttl_seconds
      }
    ]
    |> Keyword.put(:checkpoint_key, options.checkpoint_key)
    |> Keyword.put(:checkpoint_secrets, options.checkpoint_secrets)
    |> Keyword.put(:body_root, options.body_root)
    |> maybe_put(:state_tools, Map.get(options, :state_tools))
  end

  defp validate_checkpoint_custody!(%{checkpoint_key: key, checkpoint_secrets: secrets}) do
    unless is_binary(key) and byte_size(key) == 32 and is_list(secrets) and
             Enum.all?(secrets, &(is_binary(&1) and byte_size(&1) >= 8)),
           do: raise(ArgumentError, "Coop worker checkpoint custody configuration is invalid")
  end

  defp validate_checkpoint_custody!(_configuration),
    do: raise(ArgumentError, "Coop worker checkpoint custody configuration is incomplete")

  defp validate_public_url!(nil), do: :ok

  defp validate_public_url!(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, path: path, query: nil, fragment: nil, userinfo: nil}
      when is_binary(host) and host != "" and path in [nil, "", "/"] ->
        :ok

      _invalid ->
        raise ArgumentError, "Coop worker gateway public_url must be an HTTPS origin"
    end
  end

  defp validate_state_tools!(nil), do: :ok

  defp validate_state_tools!(%{capabilities: capabilities} = options) do
    router_options =
      [token: String.duplicate("t", 32), capabilities: capabilities]
      |> maybe_put(:additional_tools, Map.get(options, :additional_tools))
      |> maybe_put(:additional_call, Map.get(options, :additional_call))
      |> maybe_put(:answer_authorizer, Map.get(options, :answer_authorizer))

    _validated = Ryker.StateTools.Router.init(router_options)
    :ok
  end

  defp validate_state_tools!(_options),
    do: raise(ArgumentError, "Coop worker gateway state-tools options are invalid")

  defp maybe_put(values, _key, nil), do: values
  defp maybe_put(values, key, value), do: Keyword.put(values, key, value)
end
