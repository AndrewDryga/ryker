defmodule Ryker.IntegrationSetup do
  @moduledoc """
  Guided connection setup for Slack, GitHub, Emisar, and webhook sources.

  Secrets are accepted once, verified against their provider, then handed to
  encrypted custody. Returned documents contain identities and status only.
  """

  alias Ryker.Credentials
  alias Ryker.Delivery.JSONClient
  alias Ryker.Emisar.Approvals
  alias Ryker.GitHub.AppJWT
  alias Ryker.Settings
  alias Ryker.Settings.{EmisarConnection, Environment}

  @actor "control-plane:local"
  @slack_scopes ~w(
    app_mentions:read assistant:write bookmarks:read canvases:write channels:history
    channels:join channels:manage channels:read chat:write commands files:read files:write
    groups:history groups:read groups:write im:history im:read mpim:read pins:write
    reactions:read reactions:write usergroups:read users:read
  )

  @spec connect_slack(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def connect_slack(params, options \\ []) when is_map(params) do
    app_token = text(params, "app_token")
    bot_token = text(params, "bot_token")

    with :ok <- prefix(app_token, "xapp-", :app_token),
         :ok <- prefix(bot_token, "xoxb-", :bot_token),
         {:ok, app_http} <- slack_http(app_token, options),
         {:ok, %{body: %{"ok" => true, "url" => socket_url}, status: 200}} <-
           request(app_http, :post, "/apps.connections.open", %{}, [], options),
         true <- String.starts_with?(socket_url, "wss://"),
         {:ok, bot_http} <- slack_http(bot_token, options),
         {:ok, auth_response} <- request(bot_http, :post, "/auth.test", %{}, [], options),
         {:ok, identity} <- slack_identity(auth_response, bot_http, options),
         :ok <- required_slack_scopes(auth_response.headers),
         {:ok, _app} <- Credentials.put(:slack_app, "primary", app_token, @actor),
         {:ok, _bot} <- Credentials.put(:slack_bot, "primary", bot_token, @actor),
         {:ok, snapshot} <- save_slack_identity(identity),
         {:ok, _app} <- Credentials.verify(:slack_app, "primary", :verified, @actor),
         {:ok, _bot} <- Credentials.verify(:slack_bot, "primary", :verified, @actor) do
      {:ok,
       %{
         identity: identity,
         settings_revision: snapshot.installation.revision,
         socket_mode: :verified,
         status: :connected
       }}
    else
      false -> {:error, {:slack_verification_failed, :socket_mode}}
      {:ok, %{body: %{"error" => error}}} -> {:error, {:slack_verification_failed, error}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:slack_verification_failed, :response}}
    end
  end

  @spec slack_members(keyword()) :: {:ok, [map()]} | {:error, term()}
  def slack_members(options \\ []) do
    with {:ok, token} <- Credentials.fetch(:slack_bot, "primary"),
         {:ok, http} <- slack_http(token, options),
         {:ok, %{body: %{"members" => members, "ok" => true}, status: 200}} <-
           request(http, :get, "/users.list?limit=200", nil, [], options) do
      {:ok,
       members
       |> Enum.filter(&human_slack_member?/1)
       |> Enum.map(&slack_member/1)
       |> Enum.sort_by(&String.downcase(&1.name))}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:slack_verification_failed, :members}}
    end
  end

  @spec connect_github(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def connect_github(params, options \\ []) when is_map(params) do
    app_id = integer(params, "app_id")
    private_key = text(params, "private_key")
    api_url = text(params, "api_url", "https://api.github.com")
    webhook_secret = optional_text(params, "webhook_secret", generate_secret())

    with {:ok, signer} <- AppJWT.new(app_id, private_key),
         {:ok, app_http} <- github_app_http(signer, api_url, options),
         {:ok, %{body: app, status: 200}} <- request(app_http, :get, "/app", nil, [], options),
         :ok <- exact_app(app, app_id),
         {:ok, actor} <- github_actor(app_http, app["slug"], options),
         {:ok, _key} <-
           Credentials.put(:github_private_key, "primary", private_key, @actor),
         {:ok, _secret} <-
           Credentials.put(:github_webhook, "primary", webhook_secret, @actor),
         {:ok, snapshot} <- save_github_identity(app, actor, api_url),
         {:ok, _key} <-
           Credentials.verify(:github_private_key, "primary", :verified, @actor),
         {:ok, _secret} <- Credentials.verify(:github_webhook, "primary", :verified, @actor) do
      {:ok,
       %{
         app_id: app["id"],
         app_slug: app["slug"],
         actor_id: actor["id"],
         actor_login: actor["login"],
         settings_revision: snapshot.installation.revision,
         status: :connected,
         webhook_secret: webhook_secret
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:github_verification_failed, :response}}
    end
  end

  @spec github_repositories(keyword()) :: {:ok, [map()]} | {:error, term()}
  def github_repositories(options \\ []) do
    with {:ok, snapshot} <- Settings.fetch(),
         app_id when is_integer(app_id) <- snapshot.github.app_id,
         {:ok, pem} <- Credentials.fetch(:github_private_key, "primary"),
         {:ok, signer} <- AppJWT.new(app_id, pem),
         {:ok, app_http} <- github_app_http(signer, snapshot.github.api_url, options),
         {:ok, %{body: installations, status: 200}} <-
           request(app_http, :get, "/app/installations?per_page=100", nil, [], options),
         true <- is_list(installations) do
      repositories_for_installations(
        installations,
        app_http,
        snapshot.github.api_url,
        options
      )
      |> case do
        {:ok, repositories} ->
          known = MapSet.new(snapshot.repositories, & &1.github_repository)

          {:ok,
           repositories
           |> Enum.map(fn repository ->
             repository
             |> Map.put(:already_present, MapSet.member?(known, repository.full_name))
           end)
           |> Enum.sort_by(&String.downcase(&1.full_name))}

        {:error, _reason} = error ->
          error
      end
    else
      nil -> {:error, {:github_verification_failed, :app_not_connected}}
      false -> {:error, {:github_verification_failed, :installations}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:github_verification_failed, :installations}}
    end
  end

  defp repositories_for_installations(installations, app_http, api_url, options) do
    Enum.reduce_while(installations, {:ok, []}, fn installation, {:ok, repositories} ->
      case installation_repositories(app_http, api_url, installation, options) do
        {:ok, found} -> {:cont, {:ok, repositories ++ found}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec import_github_repositories([map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def import_github_repositories(repositories, options \\ []) when is_list(repositories) do
    with {:ok, snapshot} <- Settings.fetch(),
         {:ok, ryker_actor_id} <- import_actor_id(snapshot, options) do
      {added, present, failed} =
        Enum.reduce(repositories, {[], [], []}, fn repository, totals ->
          import_repository(repository, ryker_actor_id, totals)
        end)

      if added != [] or Keyword.has_key?(options, :auto_add_repositories) do
        latest = Settings.fetch!()

        _ =
          Settings.save_github(
            %{
              enabled: true,
              auto_add_repositories:
                Keyword.get(
                  options,
                  :auto_add_repositories,
                  latest.github.auto_add_repositories
                )
            },
            latest.installation.revision,
            @actor
          )
      end

      {:ok,
       %{
         added: Enum.reverse(added),
         already_present: Enum.reverse(present),
         failed: Enum.reverse(failed)
       }}
    end
  end

  @doc """
  Verifies an Emisar account and makes it usable at once.

  Connecting is the operator saying "use this account for approvals", so the
  account is watched for approval decisions from the start. The first account
  also serves every environment that has none, and a default environment is
  made for Chat when there is none: a connection that waited for two more
  switches did nothing. A later account changes no environment.
  """
  @spec connect_emisar(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def connect_emisar(params, options \\ []) when is_map(params) do
    requested_ref = text(params, "ref", "")
    token = text(params, "token")
    rpc_url = text(params, "rpc_url", "https://emisar.dev/api/mcp/rpc")

    with :ok <- nonempty(token, :token),
         {:ok, identity} <- verify_emisar(token, rpc_url, options),
         ref <- emisar_connection_ref(requested_ref, identity.account_ref),
         display_name <- optional_text(params, "display_name", identity.account_label),
         :ok <- connection_ref(ref),
         :ok <- bounded_text(display_name, 1, 120, :display_name),
         {:ok, _credential} <- Credentials.put(:emisar, ref, token, @actor),
         {:ok, _snapshot} <-
           Settings.put_emisar_connection(
             %{
               ref: ref,
               display_name: display_name,
               rpc_url: rpc_url,
               account_ref: identity.account_ref,
               account_label: identity.account_label,
               enabled_for_new_work: true,
               monitoring_enabled: true,
               verified_at: DateTime.utc_now()
             },
             Settings.fetch!().installation.revision,
             @actor
           ),
         {:ok, _credential} <- Credentials.verify(:emisar, ref, :verified, @actor),
         {:ok, _watched_again} <- Approvals.token_replaced(ref),
         {:ok, snapshot} <- serve_environments(ref) do
      {:ok,
       %{
         ref: ref,
         account_ref: identity.account_ref,
         account_label: identity.account_label,
         environments:
           for(
             environment <- snapshot.environments,
             environment.emisar_connection_ref == ref,
             do: environment.ref
           ),
         rpc_url: rpc_url,
         settings_revision: snapshot.installation.revision,
         status: :connected
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:emisar_verification_failed, :response}}
    end
  end

  # The account work may use belongs to its environment
  # (`Ryker.Emisar.Connections`). Only the installation's first account is
  # placed anywhere automatically: connecting never moves an environment an
  # operator already gave an account, and a second account starts with none.
  # An account lets a task record an approval that Ryker then only reads; what
  # the model may run in Emisar is still Emisar's decision.
  defp serve_environments(ref, attempts \\ 3) do
    snapshot = Settings.fetch!()

    if Enum.map(snapshot.emisar_connections, & &1.ref) == [ref] do
      case assign_first_account(snapshot, ref) do
        {:error, {:settings_conflict, _current}} when attempts > 1 ->
          serve_environments(ref, attempts - 1)

        result ->
          result
      end
    else
      {:ok, snapshot}
    end
  end

  defp assign_first_account(snapshot, ref) do
    with {:ok, snapshot, _default} <- ensure_default_environment(snapshot) do
      snapshot.environments
      |> Enum.filter(&is_nil(&1.emisar_connection_ref))
      |> set_emisar_account(ref, snapshot)
    end
  end

  # Chat and every conversation without its own setting work in the default
  # environment; when none is chosen, Ryker makes "Default" the default.
  defp ensure_default_environment(snapshot) do
    case Environment.default(snapshot) do
      %Environment{} = environment ->
        {:ok, snapshot, environment}

      nil ->
        attributes =
          case Environment.find(snapshot, :ref, "default") do
            nil -> %{ref: "default", display_name: "Default", is_default: true}
            _existing -> %{ref: "default", is_default: true}
          end

        with {:ok, saved} <-
               Settings.put_environment(attributes, snapshot.installation.revision, @actor) do
          {:ok, saved, Environment.default(saved)}
        end
    end
  end

  # An imported repository joins the default environment after the ones
  # already there, so the repository its work changes stays the first.
  defp join_default_environment(repository_ref) do
    with {:ok, snapshot, environment} <- ensure_default_environment(Settings.fetch!()) do
      refs = Environment.repository_refs(environment)

      if repository_ref in refs,
        do: {:ok, snapshot},
        else:
          Settings.put_environment(
            %{ref: environment.ref, repositories: refs ++ [repository_ref]},
            snapshot.installation.revision,
            @actor
          )
    end
  end

  @spec rotate_emisar(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rotate_emisar(ref, token, options \\ []) when is_binary(ref) and is_binary(token) do
    snapshot = Settings.fetch!()

    with connection when not is_nil(connection) <-
           Enum.find(snapshot.emisar_connections, &(&1.ref == ref)),
         {:ok, identity} <- verify_emisar(token, connection.rpc_url, options),
         true <- identity.account_ref == connection.account_ref,
         {:ok, _credential} <- Credentials.put(:emisar, ref, token, @actor),
         {:ok, _credential} <- Credentials.verify(:emisar, ref, :verified, @actor),
         {:ok, _watched_again} <- Approvals.token_replaced(ref) do
      {:ok, %{ref: ref, status: :rotated}}
    else
      nil -> {:error, :connection_not_found}
      false -> {:error, :emisar_account_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @spec create_webhook_credential(String.t(), String.t() | nil) ::
          {:ok, %{name: String.t(), secret: String.t()}} | {:error, term()}
  def create_webhook_credential(name, supplied \\ nil) do
    secret =
      if is_binary(supplied) and String.trim(supplied) != "",
        do: supplied,
        else: generate_secret()

    with {:ok, _metadata} <- Credentials.put(:webhook, name, secret, @actor),
         {:ok, _metadata} <- Credentials.verify(:webhook, name, :verified, @actor) do
      {:ok, %{name: name, secret: secret}}
    end
  end

  @spec disconnect(:slack | :github) :: {:ok, map()} | {:error, term()}
  def disconnect(kind) when kind in [:slack, :github] do
    snapshot = Settings.fetch!()

    with {:ok, _snapshot} <- disable(kind, snapshot),
         :ok <- delete_connection_credentials(kind) do
      {:ok, %{status: :disconnected, kind: kind}}
    end
  end

  def disable_emisar(ref) when is_binary(ref) do
    set_emisar_new_work(ref, false)
  end

  def enable_emisar(ref) when is_binary(ref) do
    set_emisar_new_work(ref, true)
  end

  def disable_emisar_monitoring(ref) when is_binary(ref) do
    set_emisar_monitoring(ref, false)
  end

  def enable_emisar_monitoring(ref) when is_binary(ref) do
    set_emisar_monitoring(ref, true)
  end

  def rename_emisar(ref, display_name) when is_binary(ref) and is_binary(display_name) do
    snapshot = Settings.fetch!()

    case Enum.find(snapshot.emisar_connections, &(&1.ref == ref)) do
      nil ->
        {:error, :connection_not_found}

      connection ->
        Settings.put_emisar_connection(
          %{
            ref: ref,
            display_name: display_name,
            enabled_for_new_work: connection.enabled_for_new_work,
            monitoring_enabled: connection.monitoring_enabled
          },
          snapshot.installation.revision,
          @actor
        )
    end
  end

  defp set_emisar_new_work(ref, enabled) do
    snapshot = Settings.fetch!()

    case Enum.find(snapshot.emisar_connections, &(&1.ref == ref)) do
      nil ->
        {:error, :connection_not_found}

      connection ->
        Settings.put_emisar_connection(
          %{
            ref: ref,
            enabled_for_new_work: enabled,
            monitoring_enabled: connection.monitoring_enabled
          },
          snapshot.installation.revision,
          @actor
        )
    end
  end

  defp set_emisar_monitoring(ref, enabled) do
    snapshot = Settings.fetch!()

    case Enum.find(snapshot.emisar_connections, &(&1.ref == ref)) do
      nil ->
        {:error, :connection_not_found}

      connection ->
        Settings.put_emisar_connection(
          %{
            ref: ref,
            enabled_for_new_work: connection.enabled_for_new_work,
            monitoring_enabled: enabled
          },
          snapshot.installation.revision,
          @actor
        )
    end
  end

  @doc """
  Removes an account and takes it off the environments that use it, as
  "Remove account" says. An account that a task session or an approval still
  names is refused before anything changes, so a refused removal never leaves
  an environment without its account.
  """
  def delete_emisar(ref) when is_binary(ref) do
    snapshot = Settings.fetch!()

    case Enum.find(snapshot.emisar_connections, &(&1.ref == ref)) do
      nil ->
        {:error, :connection_not_found}

      connection ->
        {using, others} =
          Enum.split_with(snapshot.environments, &(&1.emisar_connection_ref == ref))

        released = Enum.map(using, &%{&1 | emisar_connection_ref: nil})

        with :ok <- unreferenced(connection, %{snapshot | environments: others ++ released}),
             {:ok, snapshot} <- set_emisar_account(using, nil, snapshot) do
          Settings.delete_emisar_connection(ref, snapshot.installation.revision, @actor)
        end
    end
  end

  defp unreferenced(connection, snapshot) do
    case EmisarConnection.deletable(connection, snapshot) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_settings, reason}}
    end
  end

  defp set_emisar_account(environments, connection_ref, snapshot) do
    Enum.reduce_while(environments, {:ok, snapshot}, fn environment, {:ok, current} ->
      case Settings.put_environment(
             %{ref: environment.ref, emisar_connection_ref: connection_ref},
             current.installation.revision,
             @actor
           ) do
        {:ok, saved} -> {:cont, {:ok, saved}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec retry_github_onboarding(String.t()) :: {:ok, map()} | {:error, term()}
  def retry_github_onboarding(ref) when is_binary(ref) do
    snapshot = Settings.fetch!()

    case Enum.find(snapshot.repositories, &(&1.ref == ref)) do
      nil ->
        {:error, :repository_not_found}

      %{github_access: :available} ->
        Settings.put_repository(
          %{ref: ref, onboarding_state: :pending, onboarding_error: nil},
          snapshot.installation.revision,
          @actor
        )

      _repository ->
        {:error, :github_access_unavailable}
    end
  end

  @spec delete_webhook_credential(String.t()) :: {:ok, map()} | {:error, term()}
  def delete_webhook_credential(name) when is_binary(name) do
    if Enum.any?(Settings.fetch!().webhook_sources, &(&1.secret_name == name)) do
      {:error, :credential_in_use}
    else
      with {:ok, :ok} <- Credentials.delete(:webhook, name, @actor) do
        {:ok, %{name: name, status: :deleted}}
      end
    end
  end

  defp slack_identity(%{body: %{"ok" => true} = auth, status: 200}, bot_http, options) do
    bot_id = auth["bot_id"]

    with true <- is_binary(auth["team_id"]),
         true <- is_binary(auth["user_id"]),
         true <- is_binary(bot_id),
         {:ok, %{body: %{"bot" => bot, "ok" => true}, status: 200}} <-
           request(
             bot_http,
             :get,
             "/bots.info?" <> URI.encode_query(bot: bot_id),
             nil,
             [],
             options
           ),
         true <- is_binary(bot["app_id"]) do
      {:ok,
       %{
         app_id: bot["app_id"],
         bot_name: bot["name"] || auth["user"],
         bot_user_id: auth["user_id"],
         workspace_id: auth["team_id"],
         workspace_name: auth["team"],
         workspace_url: normalize_slack_url(auth["url"])
       }}
    else
      false -> {:error, {:slack_verification_failed, :identity}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:slack_verification_failed, :identity}}
    end
  end

  defp slack_identity(_response, _http, _options),
    do: {:error, {:slack_verification_failed, :auth}}

  defp required_slack_scopes(headers) do
    granted =
      Enum.find_value(headers, "", fn {name, value} ->
        if String.downcase(name) == "x-oauth-scopes", do: value
      end)
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    case @slack_scopes -- granted do
      [] -> :ok
      missing -> {:error, {:slack_missing_scopes, missing}}
    end
  end

  defp save_slack_identity(identity) do
    snapshot = Settings.fetch!()

    Settings.save_slack(
      %{
        enabled: false,
        workspace_ref: identity.workspace_id,
        workspace_url: identity.workspace_url,
        workspace_name: identity.workspace_name,
        bot_ref: identity.app_id,
        bot_user_ref: identity.bot_user_id,
        bot_name: identity.bot_name
      },
      snapshot.installation.revision,
      @actor
    )
  end

  defp save_github_identity(app, actor, api_url) do
    snapshot = Settings.fetch!()

    Settings.save_github(
      %{
        enabled: false,
        app_id: app["id"],
        app_slug: app["slug"],
        api_url: api_url,
        bot_actor_id: actor["id"],
        bot_login: actor["login"]
      },
      snapshot.installation.revision,
      @actor
    )
  end

  defp import_actor_id(snapshot, options) do
    case Keyword.get(options, :ryker_actor_id) || snapshot.github.bot_actor_id do
      actor_id when is_integer(actor_id) and actor_id > 0 ->
        {:ok, actor_id}

      _missing ->
        with app_id when is_integer(app_id) <- snapshot.github.app_id,
             {:ok, pem} <- Credentials.fetch(:github_private_key, "primary"),
             {:ok, signer} <- AppJWT.new(app_id, pem),
             {:ok, app_http} <- github_app_http(signer, snapshot.github.api_url, options),
             {:ok, actor} <- github_actor(app_http, snapshot.github.app_slug, options) do
          {:ok, actor["id"]}
        else
          nil -> {:error, {:github_verification_failed, :app_not_connected}}
          {:error, _reason} = error -> error
          _invalid -> {:error, {:github_verification_failed, :actor}}
        end
    end
  end

  defp disable(:slack, snapshot),
    do: Settings.save_slack(%{enabled: false}, snapshot.installation.revision, @actor)

  defp disable(:github, snapshot),
    do: Settings.save_github(%{enabled: false}, snapshot.installation.revision, @actor)

  defp delete_connection_credentials(:slack) do
    with {:ok, :ok} <- Credentials.delete(:slack_app, "primary", @actor),
         {:ok, :ok} <- Credentials.delete(:slack_bot, "primary", @actor),
         do: :ok
  end

  defp delete_connection_credentials(:github) do
    with {:ok, :ok} <- Credentials.delete(:github_private_key, "primary", @actor),
         {:ok, :ok} <- Credentials.delete(:github_webhook, "primary", @actor),
         do: :ok
  end

  defp verify_emisar(token, rpc_url, options) do
    with {:ok, origin, path} <- rpc_endpoint(rpc_url),
         {:ok, http} <- json_http(origin, token, options),
         {:ok, %{body: %{"result" => result}, status: 200}} <-
           request(
             http,
             :post,
             path,
             %{
               "id" => "ryker-account-identity",
               "jsonrpc" => "2.0",
               "method" => "initialize",
               "params" => %{
                 "capabilities" => %{},
                 "clientInfo" => %{"name" => "ryker", "version" => "1"},
                 "protocolVersion" => "2025-11-25"
               }
             },
             [],
             options
           ),
         %{"account" => %{"id" => account_ref} = account} <- result,
         :ok <- bounded_text(account_ref, 1, 256, :account_ref),
         account_label when is_binary(account_label) <- account["name"] || account_ref do
      {:ok, %{account_ref: account_ref, account_label: account_label}}
    else
      {:error, _reason} = error -> error
      _missing -> {:error, {:emisar_verification_failed, :account_identity_unavailable}}
    end
  end

  defp installation_repositories(app_http, api_url, installation, options) do
    with id when is_integer(id) <- installation["id"],
         {:ok, %{body: %{"token" => token} = access, status: 201}} <-
           request(app_http, :post, "/app/installations/#{id}/access_tokens", %{}, [], options),
         {:ok, installation_http} <- json_http(api_url, token, options),
         {:ok, %{body: %{"repositories" => repositories}, status: 200}} <-
           request(
             installation_http,
             :get,
             "/installation/repositories?per_page=100",
             nil,
             [],
             options
           ),
         true <- is_list(repositories) do
      {:ok,
       Enum.map(repositories, fn repository ->
         %{
           default_branch: repository["default_branch"] || "main",
           full_name: repository["full_name"],
           installation_account: get_in(installation, ["account", "login"]),
           installation_account_id: get_in(installation, ["account", "id"]),
           installation_id: id,
           permissions: access["permissions"] || installation["permissions"] || %{},
           private: repository["private"] == true,
           repository_id: repository["id"]
         }
       end)}
    else
      false -> {:error, {:github_verification_failed, :repositories}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:github_verification_failed, :repositories}}
    end
  end

  defp import_repository(repository, ryker_actor_id, {added, present, failed}) do
    full_name = repository_value(repository, :full_name)
    existing = Enum.find(Settings.fetch!().repositories, &(&1.github_repository == full_name))

    if existing do
      {added, [full_name | present], failed}
    else
      case persist_repository(repository, ryker_actor_id) do
        :ok ->
          {[full_name | added], present, failed}

        {:error, reason} ->
          {added, present, [%{repository: full_name, reason: reason} | failed]}
      end
    end
  rescue
    _error ->
      name = repository_value(repository, :full_name) || "unknown"
      {added, present, [%{repository: name, reason: :invalid_repository} | failed]}
  end

  defp persist_repository(repository, ryker_actor_id) do
    full_name = repository_value(repository, :full_name)
    ref = repository_ref(full_name)

    with {:ok, snapshot} <- Settings.fetch(),
         {:ok, _snapshot} <-
           Settings.put_repository(
             %{
               ref: ref,
               display_name: full_name,
               github_repository: full_name,
               base_branch: repository_value(repository, :default_branch)
             },
             snapshot.installation.revision,
             @actor
           ),
         {:ok, snapshot} <- Settings.fetch(),
         {:ok, _snapshot} <-
           Settings.put_github_binding(
             %{
               name: ref,
               repository_ref: ref,
               installation_id: repository_value(repository, :installation_id),
               repository_id: repository_value(repository, :repository_id),
               ryker_actor_id: ryker_actor_id,
               action_grants: github_action_grants(repository_value(repository, :permissions)),
               granted_permissions:
                 normalize_github_permissions(repository_value(repository, :permissions))
             },
             snapshot.installation.revision,
             @actor
           ),
         {:ok, _snapshot} <- join_default_environment(ref) do
      :ok
    end
  end

  @doc false
  def github_action_grants(permissions) do
    permissions = normalize_github_permissions(permissions)

    ["read"]
    |> maybe_grant(write?(permissions, "pull_requests"), "review")
    |> maybe_grant(
      write?(permissions, "contents") and write?(permissions, "pull_requests"),
      "open_pull_request"
    )
    |> maybe_grant(
      write?(permissions, "contents") and write?(permissions, "pull_requests"),
      "update_ryker_branch"
    )
    |> maybe_grant(write?(permissions, "actions"), "rerun_ci")
    |> maybe_grant(write?(permissions, "actions"), "cancel_ci")
    |> maybe_grant(write?(permissions, "issues"), "issues")
    |> maybe_grant(write?(permissions, "pull_requests"), "approve")
    |> maybe_grant(
      write?(permissions, "contents") and write?(permissions, "pull_requests"),
      "merge"
    )
  end

  defp normalize_github_permissions(permissions) when is_map(permissions) do
    permissions
    |> Enum.flat_map(fn
      {name, level} when is_binary(name) and level in ["read", "write", "admin"] ->
        [{name, level}]

      _invalid ->
        []
    end)
    |> Map.new()
  end

  defp normalize_github_permissions(_permissions), do: %{}

  defp write?(permissions, name), do: permissions[name] in ["write", "admin"]
  defp maybe_grant(grants, true, grant), do: grants ++ [grant]
  defp maybe_grant(grants, false, _grant), do: grants

  defp github_actor(http, slug, options) when is_binary(slug),
    do: github_user(http, slug <> "[bot]", options)

  defp github_actor(_http, _slug, _options),
    do: {:error, {:github_verification_failed, :actor}}

  defp github_user(http, login, options) do
    path = "/users/" <> URI.encode(login, &URI.char_unreserved?/1)

    case request(http, :get, path, nil, [], options) do
      {:ok, %{body: %{"id" => id, "login" => found} = user, status: 200}}
      when is_integer(id) and is_binary(found) ->
        {:ok, user}

      {:ok, %{status: 404}} ->
        {:error, {:github_verification_failed, :operator_not_found}}

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error, {:github_verification_failed, :actor}}
    end
  end

  defp exact_app(%{"id" => id, "slug" => slug}, expected)
       when is_integer(id) and id == expected and is_binary(slug) and slug != "",
       do: :ok

  defp exact_app(_app, _expected), do: {:error, {:github_verification_failed, :app_id_mismatch}}

  defp slack_http(token, options) do
    json_http(Ryker.Defaults.fetch!(:slack).api_url, token, options)
  end

  defp github_app_http(signer, api_url, options) do
    with {:ok, token} <- AppJWT.token(signer), do: json_http(api_url, token, options)
  end

  defp json_http(base_url, token, options) do
    JSONClient.new(%{
      base_url: base_url,
      finch: Keyword.get(options, :finch, Ryker.CoopFinch),
      receive_timeout: Keyword.get(options, :receive_timeout, 30_000),
      token_provider: fn -> {:ok, token} end
    })
  end

  defp request(client, method, path, body, headers, options) do
    Keyword.get(options, :requester, JSONClient).request(client, method, path, body, headers)
  end

  defp rpc_endpoint(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, path: path, userinfo: nil, query: nil, fragment: nil} =
          uri
      when is_binary(host) and host != "" and is_binary(path) and path != "" ->
        origin = URI.to_string(%{uri | path: nil}) |> String.trim_trailing("/")
        {:ok, origin, path}

      _invalid ->
        {:error, {:emisar_verification_failed, :rpc_url}}
    end
  end

  defp human_slack_member?(%{"deleted" => false, "id" => id, "is_bot" => false})
       when is_binary(id),
       do: true

  defp human_slack_member?(_member), do: false

  defp slack_member(member) do
    profile = member["profile"] || %{}

    name =
      Enum.find(
        [profile["display_name"], profile["real_name"], member["real_name"], member["name"]],
        &(is_binary(&1) and String.trim(&1) != "")
      )

    %{id: member["id"], name: name || member["id"]}
  end

  defp normalize_slack_url(value) when is_binary(value), do: String.trim_trailing(value, "/")
  defp normalize_slack_url(_value), do: nil

  defp prefix(value, prefix, field) do
    if is_binary(value) and byte_size(value) in 16..4_096 and String.starts_with?(value, prefix),
      do: :ok,
      else: {:error, {:invalid_credential, field}}
  end

  defp nonempty(value, field) do
    if is_binary(value) and byte_size(value) in 16..16_384 and String.trim(value) != "",
      do: :ok,
      else: {:error, {:invalid_credential, field}}
  end

  defp connection_ref(value) do
    if is_binary(value) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, value),
      do: :ok,
      else: {:error, {:invalid_credential, :ref}}
  end

  defp emisar_connection_ref("", account_ref) do
    digest = :crypto.hash(:sha256, account_ref) |> Base.encode16(case: :lower)
    "account-" <> binary_part(digest, 0, 16)
  end

  defp emisar_connection_ref(ref, _account_ref), do: ref

  defp bounded_text(value, minimum, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in minimum..maximum and
         String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_credential, field}}
  end

  defp text(params, key, default \\ nil) do
    case Map.get(params, key, default) do
      value when is_binary(value) -> String.trim(value)
      _invalid -> default
    end
  end

  defp optional_text(params, key, default) do
    case text(params, key, default) do
      value when is_binary(value) and value != "" -> value
      _empty -> default
    end
  end

  defp integer(params, key) do
    case Integer.parse(text(params, key, "")) do
      {value, ""} when value > 0 -> value
      _invalid -> nil
    end
  end

  defp repository_value(repository, key) when is_map(repository) do
    Map.get(repository, key) || Map.get(repository, Atom.to_string(key))
  end

  defp repository_ref(full_name) do
    normalized =
      full_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "-")
      |> String.trim("-")

    normalized =
      if Regex.match?(~r/\A[a-z]/, normalized), do: normalized, else: "repo-" <> normalized

    if byte_size(normalized) <= 63 do
      normalized
    else
      digest =
        :crypto.hash(:sha256, full_name) |> Base.encode16(case: :lower) |> String.slice(0, 8)

      String.slice(normalized, 0, 54) <> "-" <> digest
    end
  end

  defp generate_secret, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end
