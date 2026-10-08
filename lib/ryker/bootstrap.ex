defmodule Ryker.Bootstrap do
  @moduledoc """
  Deployment connections and credentials, not product settings.

  Parsing performs no database, filesystem or network operations. Integrations
  are enabled by durable settings, never by the presence of a credential. Error
  messages name the input without echoing connection strings or secret values.
  """
  alias Ryker.Crypto

  # Crash reports print a struct with inspect; the database URL carries its
  # password and the credential key opens every saved credential.
  @derive {Inspect, except: [:repo, :credential_key]}
  defstruct [
    :repo,
    :control_plane,
    :control_public_url,
    :cloudflare_access,
    :worker_gateway,
    :github_listener,
    :github_public_url,
    :webhook_listener,
    :webhook_public_url,
    :storage_root,
    :credential_key,
    :log_level
  ]

  @type t :: %__MODULE__{}

  @machine_secrets [state_tools: "RYKER_STATE_TOOLS_TOKEN"]
  @loopback [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
  @worker_files [
    cacertfile: "RYKER_WORKER_CA_FILE",
    ca_keyfile: "RYKER_WORKER_CA_KEY_FILE",
    certfile: "RYKER_WORKER_CERT_FILE",
    keyfile: "RYKER_WORKER_KEY_FILE"
  ]

  @doc """
  Reads the installation's bootstrap from its environment: the database URL
  and pool, the console, worker, GitHub and webhook listeners and their public
  addresses, the state directory, the credential key and the log level.
  Raises with the variable's name, never its value, for one missing or
  malformed.
  """
  def load!(env \\ &System.fetch_env/1) do
    :ok = optional_services!(env)
    control_plane = control_listener!(env)

    control_public_url =
      public_url!(env, "RYKER_CONTROL_PUBLIC_URL", "http://127.0.0.1:#{control_plane.port}")

    %__MODULE__{
      repo: [url: database_url!(env), pool_size: integer!(env, "POOL_SIZE", 10, 1..200)],
      control_plane: control_plane,
      # Where a person opens the console, for the links Ryker posts, such as
      # the weekly report's. Compose publishes the console's port on the host,
      # so the address Ryker listens on is not always the one people use.
      control_public_url: control_public_url,
      cloudflare_access: cloudflare_access!(env, control_public_url),
      worker_gateway: worker_gateway!(env),
      github_listener: listener!(env, "RYKER_GITHUB", 4319, :network),
      github_public_url:
        public_url!(env, "RYKER_GITHUB_PUBLIC_URL", "http://127.0.0.1:4319/v1/github"),
      webhook_listener: listener!(env, "RYKER_WEBHOOK", 4320, :network),
      webhook_public_url: public_url!(env, "RYKER_WEBHOOK_PUBLIC_URL", "http://127.0.0.1:4320"),
      storage_root: storage_root!(env),
      credential_key: credential_key!(env),
      log_level: log_level!(env)
    }
  end

  @doc """
  A machine secret by kind (`:state_tools`, the token that signs state-tool
  bindings), read from its variable; raises when it is missing or shorter
  than 16 bytes.
  """
  def secret!(kind, env \\ &System.fetch_env/1),
    do: required_secret!(env, Keyword.fetch!(@machine_secrets, kind))

  @doc """
  Where Ryker keeps its files (`RYKER_STATE_DIR`, `/var/lib/ryker` unless
  set); raises for a path it cannot use.
  """
  def storage_root!(env \\ &System.fetch_env/1),
    do: env |> value!("RYKER_STATE_DIR", "/var/lib/ryker") |> path!("RYKER_STATE_DIR")

  @doc """
  The 32-byte key that seals workspace checkpoints (`RYKER_CHECKPOINT_KEY`,
  base64); raises when it is missing or not 32 bytes.
  """
  def checkpoint_key!(env \\ &System.fetch_env/1), do: key!(env, "RYKER_CHECKPOINT_KEY")

  defp credential_key!(env), do: key!(env, "RYKER_CREDENTIAL_KEY")

  # Both keys are exactly 32 bytes, base64-encoded; the failure names the
  # variable and never quotes the value.
  defp key!(env, name) do
    encoded = required_secret!(env, name)

    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 -> key
      _ -> invalid!(name, "must be base64 for exactly 32 bytes")
    end
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
  #
  # On the container network the console admits one peer besides its own
  # loopback: the address published traffic arrives from (Docker's gateway for
  # the network). Every other container on it, such as the boxes the worker's
  # Docker daemon runs model work in, is refused (2026-10-04 review).
  #
  # Published traffic all arrives from that gateway, so the console cannot tell
  # who sent it, and it has no sign-in of its own: the host address it is
  # published on (RYKER_CONTROL_BIND) is loopback, or anyone who could reach
  # the host, a box included, could open it (2026-10-04 review).
  defp control_listener!(env) do
    if value!(env, "RYKER_CONTAINER", "false") == "true" do
      unless address!(env, "RYKER_CONTROL_BIND") in @loopback do
        invalid!(
          "RYKER_CONTROL_BIND",
          "must be loopback; publish the console through Tailscale Serve, a Cloudflare tunnel or an SSH tunnel"
        )
      end

      env
      |> listener!("RYKER_CONTROL", 4321, :network)
      |> Map.put(:access, {:network, address!(env, "RYKER_CONTROL_PEER")})
    else
      env
      |> listener!("RYKER_CONTROL", 4321, :loopback)
      |> Map.put(:access, :loopback)
    end
  end

  defp address!(env, name) do
    case :inet.parse_strict_address(String.to_charlist(value!(env, name))) do
      {:ok, address} -> address
      {:error, _reason} -> invalid!(name, "must be an IP address")
    end
  end

  @doc """
  Internal — the worker gateway's listener and TLS files, or nil when no
  `RYKER_WORKER_*` variable is set. Any one of them means the gateway is
  wanted, and it needs all of them: an address without its TLS material was
  once validated and then dropped, leaving a listener nobody started. The
  world eval serves a gateway from this alone.
  """
  def worker_gateway!(env \\ &System.fetch_env/1) do
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

  # Cloudflare Access in front of the console (`Ryker.ControlPlane.CloudflareAccess`): the team
  # whose keys sign its tokens and the application's audience tag, both or neither. Access serves
  # the address people open, so that address is HTTPS.
  defp cloudflare_access!(env, control_public_url) do
    team = optional!(env, "RYKER_CLOUDFLARE_ACCESS_TEAM_DOMAIN")
    audience = optional!(env, "RYKER_CLOUDFLARE_ACCESS_AUD")

    cond do
      is_nil(team) and is_nil(audience) ->
        nil

      is_nil(team) or is_nil(audience) ->
        invalid!(
          "RYKER_CLOUDFLARE_ACCESS_TEAM_DOMAIN",
          "and RYKER_CLOUDFLARE_ACCESS_AUD go together"
        )

      not Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,62}\.cloudflareaccess\.com\z/, team) ->
        invalid!("RYKER_CLOUDFLARE_ACCESS_TEAM_DOMAIN", "must be <team>.cloudflareaccess.com")

      not Crypto.sha256_hex?(audience) ->
        invalid!("RYKER_CLOUDFLARE_ACCESS_AUD", "must be the application's audience tag")

      not String.starts_with?(control_public_url, "https://") ->
        invalid!("RYKER_CONTROL_PUBLIC_URL", "must be the HTTPS address Cloudflare Access serves")

      true ->
        %{team_domain: team, audience: audience}
    end
  end

  # An optional value; Compose passes an unset variable as an empty one.
  defp optional!(env, name) do
    case env.(name) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: validate_text!(value, name)

      _unset ->
        nil
    end
  end

  defp public_url!(env, name, default) do
    value = value!(env, name, default)
    uri = URI.parse(value)
    loopback = uri.host in ["127.0.0.1", "localhost", "::1"]

    unless (uri.scheme == "https" or (uri.scheme == "http" and loopback)) and
             is_binary(uri.host) and uri.host != "" and
             Enum.all?([uri.userinfo, uri.query, uri.fragment], &is_nil/1) and
             uri.port in 1..65_535 do
      invalid!(
        name,
        "must be HTTPS, or loopback HTTP, without credentials, query or fragment"
      )
    end

    String.trim_trailing(value, "/")
  end

  defp path!(value, name) do
    if Path.type(value) != :absolute, do: invalid!(name, "must be an absolute path")
    value
  end

  # Optional services are read where they are used (`Ryker.Embeddings`,
  # `Ryker.Transcription`, `Ryker.BundledCoop`). A value that cannot work
  # refuses the boot here, instead of turning its service off without a word.
  # Compose passes an unset one as empty.
  defp optional_services!(env) do
    for name <- ~w(RYKER_EMBEDDINGS_URL RYKER_WHISPER_URL RYKER_WHISPER_DETECT_URL),
        value = optional(env, name),
        do: service_url!(value, name)

    for name <- ~w(RYKER_BUNDLED_COOP_WORKER_ID RYKER_BUNDLED_COOP_WORKSPACE),
        value = optional(env, name),
        not Regex.match?(~r/\A[A-Za-z0-9._:-]{1,128}\z/, value),
        do: invalid!(name, "must be letters, digits, '.', '_', ':' and '-'")

    if shared = optional(env, "RYKER_BUNDLED_COOP_SHARED"),
      do: path!(shared, "RYKER_BUNDLED_COOP_SHARED")

    if languages = optional(env, "RYKER_VOICE_LANGUAGES") do
      codes = String.split(languages, [",", " "], trim: true)

      unless Enum.all?(codes, &Regex.match?(~r/\A[a-z]{2,3}\z/i, &1)) do
        invalid!("RYKER_VOICE_LANGUAGES", "must list two- or three-letter language codes")
      end
    end

    :ok
  end

  defp optional(env, name) do
    case env.(name) do
      {:ok, ""} -> nil
      {:ok, value} -> validate_text!(value, name)
      :error -> nil
    end
  end

  defp service_url!(value, name) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        value

      _invalid ->
        invalid!(name, "must be an HTTP or HTTPS address without credentials")
    end
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
