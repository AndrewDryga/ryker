defmodule Ryker.GitHub.InstallationTokens do
  @moduledoc """
  Caches repository-scoped GitHub App installation tokens.

  GitHub installation credentials expire after one hour. Callers ask for a
  token by trusted binding name and fixed host purpose; the provider refreshes
  it before expiry and never accepts an installation, repository identifier,
  or permission set from event content.
  """

  use GenServer

  require Logger

  alias Ryker.Options
  alias Ryker.Secret

  @headers [
    {"accept", "application/vnd.github+json"},
    {"x-github-api-version", "2022-11-28"}
  ]
  @refresh_before_seconds 300
  @minimum_fallback_seconds 30
  @call_timeout_ms 65_000
  @maximum_id 9_223_372_036_854_775_807
  @purpose_permissions %{
    authorization: %{"metadata" => "read"},
    context: %{
      "actions" => "read",
      "checks" => "read",
      "contents" => "read",
      "issues" => "read",
      "pull_requests" => "read"
    },
    review: %{"contents" => "read", "pull_requests" => "write"},
    ci_rerun: %{"actions" => "write", "checks" => "read"},
    ci_cancel: %{"actions" => "write"},
    delivery: %{"issues" => "write", "pull_requests" => "write"},
    publication: %{
      "checks" => "read",
      "pull_requests" => "read",
      "statuses" => "read"
    },
    onboarding: %{
      "contents" => "write",
      "metadata" => "read",
      "pull_requests" => "write"
    },
    source_read: %{"contents" => "read"},
    worker_publication: %{"contents" => "write", "pull_requests" => "write"}
  }

  @type binding :: %{installation_id: pos_integer(), repository_id: pos_integer()}

  @spec start_link(map() | keyword()) :: GenServer.on_start()
  def start_link(configuration) do
    options = options!(configuration)

    case options.name do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @spec token(String.t(), atom()) :: {:ok, String.t()} | {:error, term()}
  def token(binding_name, purpose) when is_binary(binding_name),
    do: token(__MODULE__, binding_name, purpose)

  def token(_binding_name, _purpose),
    do: {:error, {:github_installation_token_unavailable, :binding}}

  @spec token(GenServer.server(), String.t(), atom()) :: {:ok, String.t()} | {:error, term()}
  def token(server, binding_name, purpose) when is_binary(binding_name) do
    with {:ok, permissions} <- purpose_permissions(purpose) do
      GenServer.call(
        server,
        {:token, binding_name, purpose, permissions},
        @call_timeout_ms
      )
    end
  catch
    :exit, reason -> {:error, {:github_installation_token_unavailable, reason}}
  end

  def token(_server, _binding_name, _purpose),
    do: {:error, {:github_installation_token_unavailable, :binding}}

  @doc "Mint a distinct repository-read token for one authorized worker source transfer."
  @spec fresh_source_token(String.t(), binding()) :: {:ok, map()} | {:error, term()}
  def fresh_source_token(binding_name, binding),
    do: fresh_source_token(__MODULE__, binding_name, binding)

  @spec fresh_source_token(GenServer.server(), String.t(), binding()) ::
          {:ok, map()} | {:error, term()}
  def fresh_source_token(server, binding_name, binding) do
    fresh_worker_token(server, binding_name, binding, :source_read)
  end

  @doc "Mint an uncached, single-repository write grant for one approved worker publication."
  def fresh_publication_token(server, binding_name, binding) do
    fresh_worker_token(server, binding_name, binding, :worker_publication)
  end

  defp fresh_worker_token(server, binding_name, binding, purpose) do
    if valid_binding?({binding_name, binding}),
      do:
        GenServer.call(
          server,
          {:fresh_worker_token, binding_name, binding, purpose},
          @call_timeout_ms
        ),
      else: unavailable(:binding)
  catch
    :exit, reason -> {:error, {:github_installation_token_unavailable, reason}}
  end

  @doc false
  @spec options!(map() | keyword()) :: map()
  def options!(configuration) do
    configuration = normalize_configuration!(configuration)
    bindings = Map.fetch!(configuration, :bindings)
    requester = Map.fetch!(configuration, :requester)
    clock = Map.get(configuration, :clock, &DateTime.utc_now/0)
    name = Map.get(configuration, :name, __MODULE__)

    validate_bindings!(bindings)
    validate_requester!(requester)
    validate_clock!(clock)
    validate_name!(name)

    %{
      app_http: Map.fetch!(configuration, :app_http),
      bindings: bindings,
      clock: clock,
      name: name,
      refresh_before_seconds:
        Map.get(configuration, :refresh_before_seconds, @refresh_before_seconds),
      requester: requester
    }
  end

  @impl GenServer
  def init(options), do: {:ok, Map.put(options, :tokens, %{})}

  @impl GenServer
  def handle_call({:token, binding_name, purpose, permissions}, _from, state) do
    case Map.fetch(state.bindings, binding_name) do
      {:ok, binding} -> token_for_binding(state, binding_name, binding, purpose, permissions)
      :error -> {:reply, {:error, {:github_installation_token_unavailable, :binding}}, state}
    end
  end

  @impl GenServer
  def handle_call({:fresh_worker_token, binding_name, binding, purpose}, _from, state)
      when purpose in [:source_read, :worker_publication] do
    with {:ok, ^binding} <- Map.fetch(state.bindings, binding_name),
         {:ok, now} <- current_time(state.clock),
         {:ok, token} <- mint(state, binding, Map.fetch!(@purpose_permissions, purpose), now) do
      {:reply, {:ok, token}, state}
    else
      :error -> {:reply, unavailable(:binding), state}
      {:ok, _changed_binding} -> {:reply, unavailable(:binding), state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp token_for_binding(state, binding_name, binding, purpose, permissions) do
    case current_time(state.clock) do
      {:ok, now} ->
        token_for_current_time(state, binding_name, binding, purpose, permissions, now)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp token_for_current_time(state, binding_name, binding, purpose, permissions, now) do
    cache_key = {binding_name, purpose, Ryker.CanonicalJSON.digest(permissions)}
    cached = Map.get(state.tokens, cache_key)

    if fresh?(cached, now, state.refresh_before_seconds) do
      {:reply, {:ok, Secret.reveal(cached.token)}, state}
    else
      refresh_token(state, cache_key, binding, permissions, cached, now)
    end
  end

  defp refresh_token(state, cache_key, binding, permissions, cached, now) do
    case mint(state, binding, permissions, now) do
      {:ok, token} ->
        # Cached sealed: a crash report prints this process's state.
        cached = %{token | token: Secret.new(token.token)}
        {:reply, {:ok, token.token}, put_in(state, [:tokens, cache_key], cached)}

      {:error, reason} ->
        if fresh?(cached, now, @minimum_fallback_seconds) do
          {:reply, {:ok, Secret.reveal(cached.token)}, state}
        else
          {:reply, {:error, reason}, state}
        end
    end
  end

  defp mint(state, binding, permissions, now) do
    path = "/app/installations/#{binding.installation_id}/access_tokens"

    document = %{
      "permissions" => permissions,
      "repository_ids" => [binding.repository_id]
    }

    case state.requester.request(state.app_http, :post, path, document, @headers) do
      {:ok, %{body: body, status: 201}} -> parse_token(body, now)
      {:ok, %{status: status}} when is_integer(status) -> unavailable({:http_status, status})
      {:ok, _response} -> unavailable(:response)
      {:error, reason} -> unavailable(reason)
      _invalid -> unavailable(:response)
    end
  rescue
    error -> raised(error)
  end

  defp parse_token(%{"expires_at" => expires_at, "token" => token}, now)
       when is_binary(expires_at) and is_binary(token) do
    with true <- valid_token?(token),
         {:ok, expiration, 0} <- DateTime.from_iso8601(expires_at),
         true <- DateTime.compare(expiration, now) == :gt do
      {:ok, %{expires_at: expiration, token: token}}
    else
      _invalid -> unavailable(:token_response)
    end
  end

  defp parse_token(_body, _now), do: unavailable(:token_response)

  defp fresh?(%{expires_at: expiration}, now, minimum_seconds) do
    DateTime.diff(expiration, now, :second) > minimum_seconds
  end

  defp fresh?(_cached, _now, _minimum_seconds), do: false

  defp current_time(clock) do
    case clock.() do
      %DateTime{} = now -> {:ok, now}
      _invalid -> unavailable(:clock)
    end
  rescue
    error -> raised(error)
  end

  defp unavailable(reason), do: {:error, {:github_installation_token_unavailable, reason}}

  # A raise's message can carry the request that failed, and this reason is
  # stored with whatever the token was for, so the reason names the class and
  # only the log keeps the message.
  defp raised(error) do
    Logger.warning(
      "GitHub installation token unavailable: " <> Exception.format_banner(:error, error)
    )

    unavailable({:raised, error.__struct__})
  end

  defp purpose_permissions(purpose) do
    case Map.fetch(@purpose_permissions, purpose) do
      {:ok, permissions} -> {:ok, permissions}
      :error -> unavailable(:purpose)
    end
  end

  defp valid_token?(token) do
    byte_size(token) in 1..4_096 and String.valid?(token) and
      :binary.match(token, <<0>>) == :nomatch and String.trim(token) != ""
  end

  defp valid_binding?({name, %{installation_id: installation_id, repository_id: repository_id}}) do
    is_binary(name) and name != "" and positive_id?(installation_id) and
      positive_id?(repository_id)
  end

  defp valid_binding?(_entry), do: false

  defp validate_bindings!(bindings) do
    unless is_map(bindings) and Enum.all?(bindings, &valid_binding?/1),
      do: raise(ArgumentError, "GitHub installation-token bindings are invalid")
  end

  defp validate_requester!(requester) do
    unless is_atom(requester) and function_exported?(requester, :request, 5),
      do: raise(ArgumentError, "GitHub installation-token requester is invalid")
  end

  defp validate_clock!(clock) do
    unless is_function(clock, 0),
      do: raise(ArgumentError, "GitHub installation-token clock is invalid")
  end

  defp validate_name!(name) do
    unless is_nil(name) or is_atom(name) or is_pid(name) or is_tuple(name),
      do: raise(ArgumentError, "GitHub installation-token server name is invalid")
  end

  defp positive_id?(value), do: is_integer(value) and value > 0 and value <= @maximum_id

  defp normalize_configuration!(configuration) do
    configuration =
      Options.normalize!(
        configuration,
        [:app_http, :bindings, :clock, :name, :refresh_before_seconds, :requester],
        [:app_http, :bindings, :requester],
        "GitHub installation-token configuration is invalid"
      )

    refresh = Map.get(configuration, :refresh_before_seconds, @refresh_before_seconds)

    unless is_integer(refresh) and refresh in 60..1_800,
      do: raise(ArgumentError, "GitHub installation-token refresh window is invalid")

    configuration
  end
end
