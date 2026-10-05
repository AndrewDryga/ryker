defmodule Ryker.IntegrationSetup do
  @moduledoc """
  Guided connection setup for Slack, GitHub, Emisar, and webhook sources.

  Secrets are accepted once, verified against their provider, then handed to
  encrypted custody. Returned documents contain identities and status only.
  """

  require Logger

  alias Ryker.{Bootstrap, Credentials}
  alias Ryker.ControlPlane.Actor
  alias Ryker.CoopFleet.ManagedSources
  alias Ryker.Delivery.JSONClient
  alias Ryker.Emisar.Approvals
  alias Ryker.GitHub.AppJWT
  alias Ryker.Settings
  alias Ryker.Settings.{EmisarConnection, Environment}
  alias Ryker.Slack.Names

  @minimum_signing_secret_bytes 32
  # 200 people a page: room for a workspace of ten thousand.
  @slack_member_pages 50
  @slack_rate_waits 10
  @slack_scopes ~w(
    app_mentions:read assistant:write bookmarks:read channels:history
    channels:join channels:manage channels:read chat:write commands files:read files:write
    groups:history groups:read groups:write im:history im:read mpim:read pins:write
    reactions:read reactions:write usergroups:read users:read
  )

  @doc "The Slack bot scopes connecting verifies; the shipped app manifest asks for exactly these."
  @spec slack_scopes() :: [String.t()]
  def slack_scopes, do: @slack_scopes

  @spec connect_slack(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def connect_slack(params, options \\ []) when is_map(params) do
    app_token = text(params, "app_token")
    bot_token = text(params, "bot_token")

    with :ok <- not_swapped(app_token, bot_token),
         :ok <- prefix(app_token, "xapp-", :app_token),
         :ok <- prefix(bot_token, "xoxb-", :bot_token),
         {:ok, app_http} <- slack_http(app_token, options),
         {:ok, %{body: %{"ok" => true, "url" => socket_url}, status: 200}} <-
           request(app_http, :post, "/apps.connections.open", %{}, [], options),
         true <- String.starts_with?(socket_url, "wss://"),
         {:ok, bot_http} <- slack_http(bot_token, options),
         {:ok, auth_response} <- request(bot_http, :post, "/auth.test", %{}, [], options),
         {:ok, identity} <- slack_identity(auth_response, bot_http, options),
         :ok <- required_slack_scopes(auth_response.headers),
         {:ok, _app} <- Credentials.put(:slack_app, "primary", app_token, Actor.ref()),
         {:ok, _bot} <- Credentials.put(:slack_bot, "primary", bot_token, Actor.ref()),
         {:ok, snapshot} <- save_slack_identity(identity),
         {:ok, _app} <- Credentials.verify(:slack_app, "primary", :verified, Actor.ref()),
         {:ok, _bot} <- Credentials.verify(:slack_bot, "primary", :verified, Actor.ref()) do
      {:ok,
       %{
         enabled: snapshot.slack.enabled,
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

  @doc """
  The people of the workspace, by name, for choosing who can manage Ryker.

  Their names go to the name cache as well: every page that shows one of them
  afterwards reads the name at once instead of asking Slack for each (on
  2026-09-26 the person just chosen read "Slack user U0BHTNFCW6S").
  """
  @spec slack_members(keyword()) :: {:ok, [map()]} | {:error, term()}
  def slack_members(options \\ []) do
    with {:ok, token} <- Credentials.fetch(:slack_bot, "primary"),
         {:ok, http} <- slack_http(token, options),
         {:ok, members} <-
           slack_member_pages(http, options, nil, [], {@slack_member_pages, @slack_rate_waits}) do
      people = Enum.filter(members, &human_slack_member?/1)

      :ok =
        people
        |> Enum.flat_map(&known_name/1)
        |> Names.remember()

      {:ok, people |> Enum.map(&slack_member/1) |> Enum.sort_by(&String.downcase(&1.name))}
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

    with {:ok, webhook_secret} <- signing_secret(params["webhook_secret"]),
         {:ok, signer} <- AppJWT.new(app_id, private_key),
         {:ok, app_http} <- github_app_http(signer, api_url, options),
         {:ok, %{body: app, status: 200}} <- request(app_http, :get, "/app", nil, [], options),
         :ok <- exact_app(app, app_id),
         {:ok, actor} <- github_actor(app_http, api_url, app["slug"], options),
         {:ok, _key} <-
           Credentials.put(:github_private_key, "primary", private_key, Actor.ref()),
         {:ok, _secret} <-
           Credentials.put(:github_webhook, "primary", webhook_secret, Actor.ref()),
         {:ok, snapshot} <- save_github_identity(app, actor, api_url),
         {:ok, _key} <-
           Credentials.verify(:github_private_key, "primary", :verified, Actor.ref()),
         {:ok, _secret} <- Credentials.verify(:github_webhook, "primary", :verified, Actor.ref()) do
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
          known = set_up_repositories(snapshot)

          # Most recently pushed first, so the ones in use lead a long list; by name
          # among those pushed at the same moment, or never.
          {:ok,
           repositories
           |> Enum.map(fn repository ->
             repository
             |> Map.put(:already_present, MapSet.member?(known, repository.full_name))
           end)
           |> Enum.sort_by(&String.downcase(&1.full_name))
           |> Enum.sort_by(&(&1.pushed_at || ""), :desc)}

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

  # A repository saved without its GitHub binding is not set up, so the picker
  # offers it again and adding it finishes it.
  defp set_up_repositories(snapshot) do
    bound = MapSet.new(snapshot.github_bindings, & &1.repository_ref)

    for repository <- snapshot.repositories,
        MapSet.member?(bound, repository.ref),
        into: MapSet.new(),
        do: repository.github_repository
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

      with :ok <- switch_github_on(added, options) do
        {:ok,
         %{
           added: Enum.reverse(added),
           already_present: Enum.reverse(present),
           failed: Enum.reverse(failed)
         }}
      end
    end
  end

  # Adding a repository keeps GitHub on (verifying the App switched it on)
  # and saves the auto-add choice. The save used to be
  # ignored: on 2026-09-26 it did not happen, and GitHub read "Add a repository
  # to start" with two repositories added. It is written against the current
  # settings, and a refusal is the import's answer.
  defp switch_github_on(added, options) do
    if added != [] or Keyword.has_key?(options, :auto_add_repositories) do
      auto_add =
        Keyword.get_lazy(options, :auto_add_repositories, fn ->
          Settings.fetch!().github.auto_add_repositories
        end)

      case Settings.save_github(
             %{enabled: true, auto_add_repositories: auto_add},
             :current,
             Actor.ref()
           ) do
        {:ok, _snapshot} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "GitHub was not switched on after adding repositories: #{inspect(reason)}"
          )

          {:error, {:github_not_switched_on, reason}}
      end
    else
      :ok
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
         :ok <- not_connected(identity.account_ref),
         ref <- emisar_connection_ref(requested_ref, identity.account_ref),
         display_name <- optional_text(params, "display_name", identity.account_label),
         :ok <- connection_ref(ref),
         :ok <- bounded_text(display_name, 1, 120, :display_name),
         {:ok, _credential} <- Credentials.put(:emisar, ref, token, Actor.ref()),
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
             Actor.ref()
           ),
         {:ok, _credential} <- Credentials.verify(:emisar, ref, :verified, Actor.ref()),
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
               Settings.put_environment(attributes, snapshot.installation.revision, Actor.ref()) do
          {:ok, saved, Environment.default(saved)}
        end
    end
  end

  @spec rotate_emisar(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rotate_emisar(ref, token, options \\ []) when is_binary(ref) and is_binary(token) do
    snapshot = Settings.fetch!()

    # Emisar cannot say whose key this is, so the replacement proves only that
    # it works; the connection keeps its identity, which approvals are pinned to.
    with connection when not is_nil(connection) <-
           Enum.find(snapshot.emisar_connections, &(&1.ref == ref)),
         {:ok, _identity} <- verify_emisar(token, connection.rpc_url, options),
         {:ok, _credential} <- Credentials.put(:emisar, ref, token, Actor.ref()),
         {:ok, _credential} <- Credentials.verify(:emisar, ref, :verified, Actor.ref()),
         {:ok, _watched_again} <- Approvals.token_replaced(ref) do
      {:ok, %{ref: ref, status: :rotated}}
    else
      nil -> {:error, :connection_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec create_webhook_credential(String.t(), String.t() | nil) ::
          {:ok, %{name: String.t(), secret: String.t()}} | {:error, term()}
  def create_webhook_credential(name, supplied \\ nil) do
    with {:ok, secret} <- signing_secret(supplied),
         {:ok, _metadata} <- Credentials.put(:webhook, name, secret, Actor.ref()),
         {:ok, _metadata} <- Credentials.verify(:webhook, name, :verified, Actor.ref()) do
      {:ok, %{name: name, secret: secret}}
    end
  end

  # A signed route needs at least this much secret, so a shorter one could
  # never verify a delivery; storing one stopped every later settings apply.
  # An empty field makes a strong one.
  defp signing_secret(supplied) when is_binary(supplied) do
    case String.trim(supplied) do
      "" -> {:ok, generate_secret()}
      secret when byte_size(secret) >= @minimum_signing_secret_bytes -> {:ok, secret}
      _short -> {:error, :webhook_secret_too_short}
    end
  end

  defp signing_secret(_absent), do: {:ok, generate_secret()}

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
          Actor.ref()
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
          Actor.ref()
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
          Actor.ref()
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
          Settings.delete_emisar_connection(ref, snapshot.installation.revision, Actor.ref())
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
             Actor.ref()
           ) do
        {:ok, saved} -> {:cont, {:ok, saved}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Whether Ryker's reviews may approve pull requests in repository `ref`. Off
  until someone turns it on: where branch protection counts the Ryker App's
  review, one of its approvals can stand in for a person's.
  """
  @spec allow_github_approvals(String.t(), boolean()) :: {:ok, map()} | {:error, term()}
  def allow_github_approvals(ref, allowed?) when is_binary(ref) and is_boolean(allowed?) do
    snapshot = Settings.fetch!()

    case Enum.find(snapshot.github_bindings, &(&1.repository_ref == ref)) do
      nil ->
        {:error, :repository_not_found}

      binding ->
        Settings.put_github_binding(
          %{name: binding.name, approvals_allowed: allowed?},
          snapshot.installation.revision,
          Actor.ref()
        )
    end
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
          Actor.ref()
        )

      _repository ->
        {:error, :github_access_unavailable}
    end
  end

  @doc """
  Finishes adding a repository whose import stopped before its GitHub
  binding was saved, the way the picker adds it: from the repositories the
  GitHub App reaches (`discovered`, as `github_repositories/1` lists them).
  AndrewDryga/andrewdryga.github.com was left that way on 2026-09-26, and its
  row offered only a Retry that could never work.
  """
  @spec add_github_repository_again(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def add_github_repository_again(ref, discovered) when is_binary(ref) and is_list(discovered) do
    case Enum.find(Settings.fetch!().repositories, &(&1.ref == ref)) do
      %{github_repository: name} when is_binary(name) ->
        case Enum.find(discovered, &(&1.full_name == name)) do
          nil -> {:error, {:github_repository_unreachable, name}}
          repository -> import_github_repositories([repository])
        end

      _missing_or_not_from_github ->
        {:error, :repository_not_found}
    end
  end

  @doc """
  Removes an added repository in one change: it leaves every environment and
  every webhook's deployment reports, and its GitHub binding goes with it;
  then the mirror Ryker keeps of it for workers' jobs is deleted. A setup
  that is running stops at its next step (`Ryker.GitHub.Onboarding`).
  Requests made in it stay, and adding it again later starts it over. The
  Coop workers are not touched: each fetches its own copy for a job.

  Andrew, 2026-09-27: "how do I remove repositories?!" Nothing could.
  """
  @spec remove_repository(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def remove_repository(ref, options \\ []) when is_binary(ref) do
    case Settings.atomically(fn -> remove_saved_repository(ref) end) do
      {:ok, removed} ->
        storage_root = Keyword.get_lazy(options, :storage_root, &Bootstrap.storage_root!/0)
        :ok = ManagedSources.remove_mirror(storage_root, ref)
        {:ok, removed}

      {:error, _reason} = error ->
        error
    end
  end

  defp remove_saved_repository(ref) do
    snapshot = Settings.fetch!()

    with %{} = repository <-
           Enum.find(snapshot.repositories, &(&1.ref == ref)) || {:error, :repository_not_found},
         {:ok, _snapshot} <- leave_environments(snapshot, ref),
         {:ok, _snapshot} <- leave_deployment_reports(snapshot, ref),
         {:ok, _snapshot} <- drop_github_bindings(snapshot, ref),
         {:ok, snapshot} <- Settings.delete_repository(ref, :current, Actor.ref()) do
      {:ok, %{repository: repository, snapshot: snapshot}}
    end
  end

  # An environment's default repository is the one work changes, so it has to
  # be read and write: when the removed one was the default, the next read and
  # write repository takes its place. An environment left with only read-only
  # repositories would have nothing work could change, so that is refused
  # and names it; making another repository there read and write first is
  # the person's choice, never Ryker's.
  defp leave_environments(snapshot, ref) do
    snapshot.environments
    |> Enum.filter(&(ref in Environment.repository_refs(&1)))
    |> each_write(&leave_environment(&1, ref))
  end

  defp leave_environment(environment, ref) do
    remaining = Enum.reject(environment.repositories, &(&1.repository_ref == ref))

    case Enum.split_with(remaining, &(&1.access == :read_write)) do
      {[], [_read_only | _rest]} ->
        {:error, {:environment_left_read_only, environment.display_name}}

      {writable, _read_only} ->
        refs = Enum.map(remaining, & &1.repository_ref)

        refs =
          case writable do
            [%{repository_ref: default} | _rest] -> [default | List.delete(refs, default)]
            [] -> refs
          end

        Settings.put_environment(
          %{ref: environment.ref, repositories: refs},
          :current,
          Actor.ref()
        )
    end
  end

  # A deployment report that names only this repository could report nothing
  # afterwards, so it goes; the source keeps receiving its events.
  defp leave_deployment_reports(snapshot, ref) do
    snapshot.webhook_sources
    |> Enum.filter(&(ref in ((&1.publication_lifecycle || %{})["repositories"] || [])))
    |> each_write(fn source ->
      remaining = source.publication_lifecycle["repositories"] -- [ref]

      lifecycle =
        if remaining == [],
          do: nil,
          else: Map.put(source.publication_lifecycle, "repositories", remaining)

      Settings.put_webhook_source(
        %{name: source.name, publication_lifecycle: lifecycle},
        :current,
        Actor.ref()
      )
    end)
  end

  defp drop_github_bindings(snapshot, ref) do
    snapshot.github_bindings
    |> Enum.filter(&(&1.repository_ref == ref))
    |> each_write(&Settings.delete_github_binding(&1.name, :current, Actor.ref()))
  end

  defp each_write(items, write) do
    Enum.reduce_while(items, {:ok, nil}, fn item, _result ->
      case write.(item) do
        {:ok, snapshot} -> {:cont, {:ok, snapshot}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec delete_webhook_credential(String.t()) :: {:ok, map()} | {:error, term()}
  def delete_webhook_credential(name) when is_binary(name) do
    if Enum.any?(Settings.fetch!().webhook_sources, &(&1.secret_name == name)) do
      {:error, :credential_in_use}
    else
      with {:ok, :ok} <- Credentials.delete(:webhook, name, Actor.ref()) do
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

  # The people who manage Ryker are the people of one workspace. New tokens
  # for the workspace Slack already works in change none of them, so Slack
  # stays as it was; until 2026-09-26 every replacement switched it off until
  # someone chose the same people again. Tokens for another workspace, or a
  # first connection, leave Slack off until someone there is chosen.
  defp save_slack_identity(identity) do
    snapshot = Settings.fetch!()

    Settings.save_slack(
      %{
        enabled: snapshot.slack.enabled and snapshot.slack.workspace_ref == identity.workspace_id,
        workspace_ref: identity.workspace_id,
        workspace_url: identity.workspace_url,
        workspace_name: identity.workspace_name,
        bot_ref: identity.app_id,
        bot_user_ref: identity.bot_user_id,
        bot_name: identity.bot_name
      },
      snapshot.installation.revision,
      Actor.ref()
    )
  end

  # Verifying the App switches GitHub on, so Ryker answers GitHub's events from
  # then on. Before a repository was added nothing listened, and every delivery
  # GitHub made while the App was being set up failed (Andrew, 2026-10-03,
  # showing a failed ping and installation.created: "errors on setup").
  defp save_github_identity(app, actor, api_url) do
    snapshot = Settings.fetch!()

    Settings.save_github(
      %{
        enabled: true,
        app_id: app["id"],
        app_slug: app["slug"],
        api_url: api_url,
        bot_actor_id: actor["id"],
        bot_login: actor["login"]
      },
      snapshot.installation.revision,
      Actor.ref()
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
             {:ok, actor} <-
               github_actor(app_http, snapshot.github.api_url, snapshot.github.app_slug, options) do
          {:ok, actor["id"]}
        else
          nil -> {:error, {:github_verification_failed, :app_not_connected}}
          {:error, _reason} = error -> error
          _invalid -> {:error, {:github_verification_failed, :actor}}
        end
    end
  end

  defp disable(:slack, snapshot),
    do: Settings.save_slack(%{enabled: false}, snapshot.installation.revision, Actor.ref())

  defp disable(:github, snapshot),
    do: Settings.save_github(%{enabled: false}, snapshot.installation.revision, Actor.ref())

  defp delete_connection_credentials(:slack) do
    with {:ok, :ok} <- Credentials.delete(:slack_app, "primary", Actor.ref()),
         {:ok, :ok} <- Credentials.delete(:slack_bot, "primary", Actor.ref()),
         do: :ok
  end

  defp delete_connection_credentials(:github) do
    with {:ok, :ok} <- Credentials.delete(:github_private_key, "primary", Actor.ref()),
         {:ok, :ok} <- Credentials.delete(:github_webhook, "primary", Actor.ref()),
         do: :ok
  end

  # Emisar's handshake names the server, never the account behind a key, and
  # nothing else in its protocol does. A key proves itself by listing the agent
  # tools, which only an agent key may do; the connection is known by the key's
  # fingerprint and named after Emisar's address. Ryker once required an
  # account Emisar never sends, so no real key could connect (2026-09-27).
  # Emisar is reached the way its tools reach it (`:emisar_requester`), so a page that connects
  # an account can be driven in tests against Emisar's recorded answers.
  defp verify_emisar(token, rpc_url, options) do
    options =
      Keyword.put_new(
        options,
        :requester,
        Application.get_env(:ryker, :emisar_requester, JSONClient)
      )

    with {:ok, origin, path} <- rpc_endpoint(rpc_url),
         {:ok, http} <- json_http(origin, token, options),
         {:ok, %{"serverInfo" => %{}}} <-
           emisar_call(http, path, "initialize", emisar_handshake(), options),
         {:ok, %{"tools" => tools}} when is_list(tools) <-
           emisar_call(http, path, "tools/list", %{}, options) do
      {:ok, %{account_ref: key_fingerprint(token), account_label: URI.parse(rpc_url).host}}
    else
      {:error, _reason} = error -> error
      _unexpected -> {:error, {:emisar_verification_failed, :response}}
    end
  end

  defp emisar_handshake do
    %{
      "capabilities" => %{},
      "clientInfo" => %{"name" => "ryker", "version" => "1"},
      "protocolVersion" => "2025-11-25"
    }
  end

  defp emisar_call(http, path, method, params, options) do
    body = %{
      "id" => "ryker-" <> method,
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params
    }

    case request(http, :post, path, body, [], options) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, {:emisar_verification_failed, :token_refused}}

      {:ok, %{body: %{"error" => %{"code" => -32_002}}}} ->
        {:error, {:emisar_verification_failed, :wrong_key_kind}}

      {:ok, _unexpected} ->
        {:error, {:emisar_verification_failed, :response}}

      {:error, _reason} = error ->
        error
    end
  end

  defp key_fingerprint(token),
    do: "key-" <> binary_part(Base.encode16(:crypto.hash(:sha256, token), case: :lower), 0, 32)

  defp not_connected(account_ref) do
    case Enum.find(Settings.fetch!().emisar_connections, &(&1.account_ref == account_ref)) do
      nil -> :ok
      connection -> {:error, {:emisar_key_already_connected, connection.display_name}}
    end
  end

  # An archived repository takes no new work, so it is never offered.
  defp installation_repositories(app_http, api_url, installation, options) do
    with id when is_integer(id) <- installation["id"],
         {:ok, %{body: %{"token" => token} = access, status: 201}} <-
           request(app_http, :post, "/app/installations/#{id}/access_tokens", %{}, [], options),
         {:ok, installation_http} <- json_http(api_url, token, options),
         {:ok, repositories} <- repository_pages(installation_http, options, 1, []) do
      {:ok,
       repositories
       |> Enum.reject(&(&1["archived"] == true))
       |> Enum.map(fn repository ->
         %{
           default_branch: repository["default_branch"] || "main",
           full_name: repository["full_name"],
           installation_account: get_in(installation, ["account", "login"]),
           installation_account_id: get_in(installation, ["account", "id"]),
           installation_id: id,
           permissions: access["permissions"] || installation["permissions"] || %{},
           private: repository["private"] == true,
           pushed_at: repository["pushed_at"],
           repository_id: repository["id"]
         }
       end)}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:github_verification_failed, :repositories}}
    end
  end

  # GitHub lists an installation's repositories a hundred a page and says how
  # many there are; every page is read. Reading the first only offered a hundred
  # of tenantcorp's (Andrew, 2026-10-03: "those ar enot all repos, we have more
  # than 100"). A page that fails fails the list rather than leaving some out.
  @repository_page 100
  @repository_pages 100

  defp repository_pages(_http, _options, page, read) when page > @repository_pages,
    do: {:ok, read}

  defp repository_pages(http, options, page, read) do
    path = "/installation/repositories?per_page=#{@repository_page}&page=#{page}"

    case request(http, :get, path, nil, [], options) do
      {:ok, %{body: %{"repositories" => repositories} = body, status: 200}}
      when is_list(repositories) ->
        read = read ++ repositories

        if length(repositories) < @repository_page or length(read) >= total(body, read),
          do: {:ok, read},
          else: repository_pages(http, options, page + 1, read)

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error, {:github_verification_failed, :repositories}}
    end
  end

  defp total(%{"total_count" => total}, _read) when is_integer(total), do: total
  defp total(_body, read), do: length(read) + 1

  defp import_repository(repository, ryker_actor_id, {added, present, failed}) do
    full_name = repository_value(repository, :full_name)
    snapshot = Settings.fetch!()
    existing = Enum.find(snapshot.repositories, &(&1.github_repository == full_name))

    if existing && Enum.any?(snapshot.github_bindings, &(&1.repository_ref == existing.ref)) do
      {added, [full_name | present], failed}
    else
      case persist_repository(repository, ryker_actor_id, existing) do
        :ok ->
          {[full_name | added], present, failed}

        {:error, reason} ->
          Logger.warning("repository #{full_name} was not added: #{inspect(reason)}")
          {added, present, [%{repository: full_name, reason: reason} | failed]}
      end
    end
  rescue
    error ->
      name = repository_value(repository, :full_name) || "unknown"
      Logger.warning("repository #{name} was not added: #{Exception.message(error)}")
      {added, present, [%{repository: name, reason: :invalid_repository} | failed]}
  end

  # The repository, its GitHub binding and its place in the default
  # environment are one change: they commit together or not at all. Saved
  # one by one, a failure between them left AndrewDryga/andrewdryga.github.com
  # saved without a binding on 2026-09-26, "Waiting to start" for good. A
  # repository saved half-way before is finished here instead of added again.
  defp persist_repository(repository, ryker_actor_id, existing) do
    full_name = repository_value(repository, :full_name)
    ref = if existing, do: existing.ref, else: repository_ref(full_name)

    Settings.atomically(fn ->
      with {:ok, _snapshot} <- put_imported_repository(existing, ref, repository),
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
               :current,
               Actor.ref()
             ),
           do: {:ok, :added}
    end)
    |> case do
      {:ok, _snapshot} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp put_imported_repository(nil, ref, repository) do
    full_name = repository_value(repository, :full_name)

    Settings.put_repository(
      %{
        ref: ref,
        display_name: full_name,
        github_repository: full_name,
        base_branch: repository_value(repository, :default_branch)
      },
      :current,
      Actor.ref()
    )
  end

  # A repository saved half-way could never be set up ("GitHub binding is
  # missing"), so finishing it starts its setup over. Kept as it was, it read
  # "Setup stopped" after Add it again finished it (2026-09-27).
  defp put_imported_repository(_existing, ref, _repository),
    do:
      Settings.put_repository(
        %{ref: ref, onboarding_state: :pending, onboarding_error: nil},
        :current,
        Actor.ref()
      )

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

  # GitHub answers the App's own token only on /app endpoints: a /users
  # lookup with it is 401 Bad credentials, which failed every GitHub setup and
  # repair from 2026-09-20 as "did not return the App's bot account" (found
  # repairing the live install on 2026-09-26). The bot account is read with
  # one installation's token instead.
  defp github_actor(app_http, api_url, slug, options) when is_binary(slug) do
    with {:ok, installation_http} <- any_installation_http(app_http, api_url, options),
         do: github_user(installation_http, slug <> "[bot]", options)
  end

  defp github_actor(_app_http, _api_url, _slug, _options),
    do: {:error, {:github_verification_failed, :actor}}

  defp any_installation_http(app_http, api_url, options) do
    case request(app_http, :get, "/app/installations?per_page=100", nil, [], options) do
      {:ok, %{body: [%{"id" => id} | _installations], status: 200}} when is_integer(id) ->
        installation_token_http(app_http, api_url, id, options)

      {:ok, %{body: [], status: 200}} ->
        {:error, {:github_verification_failed, :app_not_installed}}

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error, {:github_verification_failed, :installations}}
    end
  end

  defp installation_token_http(app_http, api_url, id, options) do
    path = "/app/installations/#{id}/access_tokens"

    case request(app_http, :post, path, %{}, [], options) do
      {:ok, %{body: %{"token" => token}, status: 201}} when is_binary(token) ->
        json_http(api_url, token, options)

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error, {:github_verification_failed, :actor}}
    end
  end

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

  # Slack lists Slackbot and workflow or app users as members that are not
  # bots; none of them is a person who could manage Ryker.
  # Slack lists a workspace's members a page at a time, and a page may hold fewer than the limit
  # while more follow. Reading only the first page offered a fraction of a large workspace
  # (Andrew, 2026-10-01: "some orgs have hundreds of people"), so every page is read, and a
  # page that fails fails the list rather than leaving people out of it.
  # Reading every page of a large workspace quickly meets Slack's rate limit: the page it turns
  # away is asked again after the wait Slack names, a bounded number of times.
  defp slack_member_pages(_http, _options, _cursor, _members, {0, _waits}),
    do: {:error, {:slack_verification_failed, :members}}

  defp slack_member_pages(http, options, cursor, members, {pages_left, waits}) do
    path =
      if cursor,
        do: "/users.list?limit=200&cursor=" <> URI.encode_www_form(cursor),
        else: "/users.list?limit=200"

    case request(http, :get, path, nil, [], options) do
      {:ok, %{body: %{"members" => page, "ok" => true} = body, status: 200}} when is_list(page) ->
        case get_in(body, ["response_metadata", "next_cursor"]) do
          next when is_binary(next) and next != "" ->
            slack_member_pages(http, options, next, [page | members], {pages_left - 1, waits})

          _last ->
            {:ok, [page | members] |> Enum.reverse() |> Enum.concat()}
        end

      {:ok, %{status: 429} = limited} when waits > 0 ->
        Keyword.get(options, :sleep, &Process.sleep/1).(retry_after(limited) * 1_000)
        slack_member_pages(http, options, cursor, members, {pages_left, waits - 1})

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error, {:slack_verification_failed, :members}}
    end
  end

  # Slack names its wait in seconds; a missing or odd one waits a second, a long one at most 30.
  defp retry_after(%{headers: headers}) when is_list(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      String.downcase(to_string(name)) == "retry-after" && Integer.parse(to_string(value))
    end)
    |> case do
      {seconds, ""} -> seconds |> max(1) |> min(30)
      _missing_or_odd -> 1
    end
  end

  defp retry_after(_response), do: 1

  defp human_slack_member?(%{"id" => "USLACKBOT"}), do: false
  defp human_slack_member?(%{"is_app_user" => true}), do: false

  defp human_slack_member?(%{"deleted" => false, "id" => id, "is_bot" => false})
       when is_binary(id),
       do: true

  defp human_slack_member?(_member), do: false

  defp slack_member(member), do: %{id: member["id"], name: member_name(member) || "Slack user"}

  defp known_name(%{"id" => id, "team_id" => workspace} = member) when is_binary(workspace) do
    case member_name(member) do
      nil -> []
      name -> [{workspace, id, name}]
    end
  end

  defp known_name(_member), do: []

  defp member_name(member) do
    profile = member["profile"] || %{}

    Enum.find(
      [profile["display_name"], profile["real_name"], member["real_name"], member["name"]],
      &(is_binary(&1) and String.trim(&1) != "")
    )
  end

  defp normalize_slack_url(value) when is_binary(value), do: String.trim_trailing(value, "/")
  defp normalize_slack_url(_value), do: nil

  # Each token pasted into the other's box: both are right, just misplaced.
  defp not_swapped("xoxb-" <> _app_token, "xapp-" <> _bot_token),
    do: {:error, {:invalid_credential, :swapped_tokens}}

  defp not_swapped(_app_token, _bot_token), do: :ok

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
