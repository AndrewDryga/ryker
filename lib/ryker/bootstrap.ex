defmodule Ryker.Bootstrap do
  @moduledoc """
  Deployment connections and credentials, not product settings.

  Parsing performs no database, filesystem or network operations. Integrations
  are enabled by durable settings, never by the presence of a credential. Error
  messages name the input without echoing connection strings or secret values.
  """

  @derive {Inspect, except: [:repo]}
  defstruct [
    :repo,
    :control_plane,
    :state_tools,
    :worker_gateway,
    :github_listener,
    :github_public_url,
    :webhook_listener,
    :webhook_public_url,
    :storage_root,
    :credential_key,
    :log_level
  ]

  @machine_secrets [
    checkpoint: "RYKER_CHECKPOINT_KEY",
    state_tools: "RYKER_STATE_TOOLS_TOKEN"
  ]
  @loopback [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
  @worker_files [
    cacertfile: "RYKER_WORKER_CA_FILE",
    ca_keyfile: "RYKER_WORKER_CA_KEY_FILE",
    certfile: "RYKER_WORKER_CERT_FILE",
    keyfile: "RYKER_WORKER_KEY_FILE"
  ]

  def load!(env \\ &System.fetch_env/1) do
    %__MODULE__{
      repo: [url: database_url!(env), pool_size: integer!(env, "POOL_SIZE", 10, 1..200)],
      control_plane: control_listener!(env),
      state_tools: listener!(env, "RYKER_STATE_TOOLS", 4318, :loopback),
      worker_gateway: worker_gateway!(env),
      github_listener: listener!(env, "RYKER_GITHUB", 4319, :network),
      github_public_url:
        public_url!(env, "RYKER_GITHUB_PUBLIC_URL", "http://127.0.0.1:4319/v1/github"),
      webhook_listener: listener!(env, "RYKER_WEBHOOK", 4320, :network),
      webhook_public_url: public_url!(env, "RYKER_WEBHOOK_PUBLIC_URL", "http://127.0.0.1:4320"),
      storage_root:
        env |> value!("RYKER_STATE_DIR", "/var/lib/ryker") |> path!("RYKER_STATE_DIR"),
      credential_key: credential_key!(env),
      log_level: log_level!(env)
    }
  end

  def secret!(kind, env \\ &System.fetch_env/1),
    do: required_secret!(env, Keyword.fetch!(@machine_secrets, kind))

  def checkpoint_key!(env \\ &System.fetch_env/1) do
    name = "RYKER_CHECKPOINT_KEY"
    encoded = required_secret!(env, name)

    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 -> key
      _ -> invalid!(name, "must be base64 for exactly 32 bytes")
    end
  end

  def credential_key!(env \\ &System.fetch_env/1) do
    name = "RYKER_CREDENTIAL_KEY"
    encoded = required_secret!(env, name)

    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 -> key
      _ -> invalid!(name, "must be base64 for exactly 32 bytes")
    end
  end

  def scan_secrets!(%__MODULE__{}, env \\ &System.fetch_env/1) do
    @machine_secrets
    |> Enum.flat_map(fn {_kind, name} ->
      case env.(name) do
        :error -> []
        {:ok, value} -> [validate_secret!(value, name, 8)]
      end
    end)
    |> Enum.uniq()
  end

  defp database_url!(env) do
    value = value!(env, "DATABASE_URL")
    uri = URI.parse(value)

    unless uri.scheme in ["ecto", "postgres", "postgresql"] and
             is_binary(uri.host) and uri.host != "" and
             is_binary(uri.path) and byte_size(uri.path) > 1 and is_nil(uri.fragment),
           do: invalid!("DATABASE_URL", "must identify a PostgreSQL database")

    value
  end

  defp listener!(env, prefix, default_port, access) do
    name = prefix <> "_IP"
    value = value!(env, name, "127.0.0.1")

    ip =
      case :inet.parse_address(String.to_charlist(value)) do
        {:ok, ip} -> ip
        _ -> invalid!(name, "must be an IP address")
      end

    if access == :loopback and ip not in @loopback,
      do: invalid!(name, "must be loopback")

    %{ip: ip, port: integer!(env, prefix <> "_PORT", default_port, 1..65_535)}
  end

  # The published Compose port is loopback-only by default, while the process
  # must listen on the container interface for Docker's port forwarding to
  # reach it. Host-native runs retain the stricter loopback-only contract.
  defp control_listener!(env) do
    access = if value!(env, "RYKER_CONTAINER", "false") == "true", do: :network, else: :loopback

    env
    |> listener!("RYKER_CONTROL", 4321, access)
    |> Map.put(:access, access)
  end

  # Any RYKER_WORKER_* variable means the operator wants the gateway, and the
  # gateway needs all of them: an address without the TLS material used to be
  # validated and then silently dropped, leaving a listener nobody started.
  defp worker_gateway!(env) do
    names = [
      "RYKER_WORKER_IP",
      "RYKER_WORKER_PORT",
      "RYKER_WORKER_PUBLIC_URL" | Keyword.values(@worker_files)
    ]

    listener = listener!(env, "RYKER_WORKER", 4322, :network)

    if Enum.any?(names, &(env.(&1) != :error)) do
      files =
        Map.new(@worker_files, fn {field, name} -> {field, env |> value!(name) |> path!(name)} end)

      files
      |> Map.merge(listener)
      |> Map.put(:public_url, https_url!(env, "RYKER_WORKER_PUBLIC_URL", nil, :origin))
    end
  end

  defp https_url!(env, name, default, kind) do
    value = value!(env, name, default)
    uri = URI.parse(value)

    unless uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
             Enum.all?([uri.userinfo, uri.query, uri.fragment], &is_nil/1) and
             uri.port in 1..65_535 and (kind == :path or uri.path in [nil, "", "/"]),
           do: invalid!(name, "must be an HTTPS #{kind} without credentials, query or fragment")

    String.trim_trailing(value, "/")
  end

  defp public_url!(env, name, default) do
    value = value!(env, name, default)
    uri = URI.parse(value)
    loopback = uri.host in ["127.0.0.1", "localhost", "::1"]

    unless (uri.scheme == "https" or (uri.scheme == "http" and loopback)) and
             is_binary(uri.host) and uri.host != "" and
             Enum.all?([uri.userinfo, uri.query, uri.fragment], &is_nil/1) and
             uri.port in 1..65_535,
           do:
             invalid!(
               name,
               "must be HTTPS, or loopback HTTP, without credentials, query or fragment"
             )

    String.trim_trailing(value, "/")
  end

  defp path!(value, name) do
    if Path.type(value) != :absolute, do: invalid!(name, "must be an absolute path")
    value
  end

  defp log_level!(env) do
    value = value!(env, "LOG_LEVEL", "info")

    case value do
      "debug" -> :debug
      "info" -> :info
      "notice" -> :notice
      "warning" -> :warning
      "error" -> :error
      _ -> invalid!("LOG_LEVEL", "must be debug, info, notice, warning or error")
    end
  end

  defp integer!(env, name, default, range) do
    env |> value!(name, Integer.to_string(default)) |> parse_integer!(name, range)
  end

  defp parse_integer!(value, name, %{first: minimum, last: maximum}) do
    case Integer.parse(validate_text!(value, name)) do
      {integer, ""} when integer >= minimum and integer <= maximum -> integer
      _ -> invalid!(name, "must be an integer in #{minimum}..#{maximum}")
    end
  end

  defp value!(env, name, default \\ nil) do
    case env.(name) do
      {:ok, value} -> validate_text!(value, name)
      :error when not is_nil(default) -> default
      :error -> invalid!(name, "is required")
    end
  end

  defp validate_text!(value, name) do
    unless is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value) and
             String.trim(value) != "" and not String.contains?(value, [<<0>>, "\n", "\r"]),
           do: invalid!(name, "must be a bounded nonblank value")

    value
  end

  defp required_secret!(env, name) do
    case read_secret(env, name, 16) do
      {:ok, secret} -> secret
      {:error, {:environment_variable_missing, _}} -> invalid!(name, "is required")
      {:error, _} -> invalid!(name, "contains invalid credential material")
    end
  end

  defp read_secret(env, name, minimum) do
    case env.(name) do
      :error ->
        {:error, {:environment_variable_missing, name}}

      {:ok, value} ->
        if valid_secret?(value, minimum),
          do: {:ok, value},
          else: {:error, {:invalid_environment_secret, name}}
    end
  end

  defp validate_secret!(value, name, minimum) do
    if valid_secret?(value, minimum),
      do: value,
      else: invalid!(name, "contains invalid credential material")
  end

  defp valid_secret?(value, minimum) do
    is_binary(value) and byte_size(value) in minimum..4_096 and String.valid?(value) and
      not String.contains?(value, <<0>>) and untrimmed?(value)
  end

  # A credential copied with its surrounding whitespace fails at the provider
  # with the same answer a wrong one gets, while presence checks call it
  # configured. A PEM-armored key is the one secret that ends in a newline by
  # construction.
  defp untrimmed?("-----BEGIN " <> _rest = pem),
    do: String.trim(pem) == String.trim_trailing(pem, "\n")

  defp untrimmed?(value), do: String.trim(value) == value

  defp invalid!(name, reason), do: raise(ArgumentError, "#{name} #{reason}")
end
