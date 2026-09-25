defmodule Ryker.IntegrationSetupTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.ControlPlane.Integrations
  alias Ryker.{Credentials, Episodes, IntegrationSetup, Settings}
  alias Ryker.Emisar.Connections
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.GitHub.{Access, Binding}
  alias Ryker.Settings.Environment
  alias Ryker.Work.Custody

  @actor "control-plane:local"
  @scopes ~w(
    app_mentions:read assistant:write bookmarks:read canvases:write channels:history
    channels:join channels:manage channels:read chat:write commands files:read files:write
    groups:history groups:read groups:write im:history im:read mpim:read pins:write
    reactions:read reactions:write usergroups:read users:read
  )

  def scopes, do: @scopes

  defmodule Requester do
    def request(client, method, path, body, headers) do
      send(self(), {:provider_request, client.base_url, method, path, body, headers})
      response_for(path)
    end

    defp response_for("/apps.connections.open"),
      do: response(%{"ok" => true, "url" => "wss://wss-primary.slack.com/link"})

    defp response_for("/auth.test") do
      {:ok,
       %{
         body: %{
           "bot_id" => "B0123456789",
           "ok" => true,
           "team" => "Acme",
           "team_id" => "T0123456789",
           "url" => "https://acme.slack.com/",
           "user" => "Ryker",
           "user_id" => "U0123456789"
         },
         headers: [{"x-oauth-scopes", Enum.join(Ryker.IntegrationSetupTest.scopes(), ",")}],
         status: 200
       }}
    end

    defp response_for("/bots.info?bot=B0123456789"),
      do: response(%{"bot" => %{"app_id" => "A0123456789", "name" => "Ryker"}, "ok" => true})

    defp response_for("/users.list?limit=200") do
      response(%{
        "members" => [
          %{
            "deleted" => false,
            "id" => "U2",
            "is_bot" => false,
            "profile" => %{"display_name" => "Zoe"}
          },
          %{
            "deleted" => false,
            "id" => "U1",
            "is_bot" => false,
            "profile" => %{"real_name" => "Ada"}
          },
          %{"deleted" => false, "id" => "B1", "is_bot" => true}
        ],
        "ok" => true
      })
    end

    defp response_for("/app"), do: response(%{"id" => 1234, "slug" => "ryker-test"})

    defp response_for("/users/ryker-test%5Bbot%5D"),
      do: response(%{"id" => 4321, "login" => "ryker-test[bot]"})

    defp response_for("/users/ada"), do: response(%{"id" => 7, "login" => "ada"})

    defp response_for("/app/installations?per_page=100") do
      response([
        %{
          "account" => %{"id" => 99, "login" => "Acme", "type" => "Organization"},
          "id" => 41
        }
      ])
    end

    defp response_for("/app/installations/41/access_tokens") do
      {:ok,
       %{
         body: %{
           "permissions" => %{
             "actions" => "write",
             "contents" => "write",
             "issues" => "read",
             "pull_requests" => "write"
           },
           "token" => "installation-token"
         },
         headers: [],
         status: 201
       }}
    end

    defp response_for("/installation/repositories?per_page=100") do
      response(%{
        "repositories" => [
          %{
            "default_branch" => "main",
            "full_name" => "acme/widget",
            "id" => 501,
            "private" => true
          }
        ]
      })
    end

    defp response_for("/api/mcp/rpc") do
      response(%{
        "jsonrpc" => "2.0",
        "result" => %{
          "account" => %{"id" => "account-acme", "name" => "Acme production"},
          "capabilities" => %{}
        }
      })
    end

    defp response(body), do: {:ok, %{body: body, headers: [], status: 200}}
  end

  defmodule OtherAccountRequester do
    def request(_client, :post, "/api/mcp/rpc", _body, _headers) do
      {:ok,
       %{
         body: %{
           "jsonrpc" => "2.0",
           "result" => %{
             "account" => %{"id" => "account-other", "name" => "Other account"},
             "capabilities" => %{}
           }
         },
         headers: [],
         status: 200
       }}
    end
  end

  setup do
    {:ok, _snapshot} = Settings.initialize(@actor)
    :ok
  end

  test "Slack setup derives identity, stores tokens once, and lists operators by name" do
    params = %{
      "app_token" => "xapp-this-is-a-long-app-token",
      "bot_token" => "xoxb-this-is-a-long-bot-token"
    }

    assert {:ok, result} = IntegrationSetup.connect_slack(params, requester: Requester)
    assert result.status == :connected
    assert result.identity.workspace_name == "Acme"
    assert result.identity.bot_name == "Ryker"
    refute inspect(result) =~ params["app_token"]
    refute inspect(result) =~ params["bot_token"]

    snapshot = Settings.fetch!()
    assert snapshot.slack.workspace_ref == "T0123456789"
    assert snapshot.slack.bot_ref == "A0123456789"
    assert snapshot.slack.bot_user_ref == "U0123456789"
    assert snapshot.slack.enabled == false
    assert Credentials.status(:slack_app, "primary").verification_status == :verified
    assert Credentials.status(:slack_bot, "primary").verification_status == :verified

    assert {:ok, [%{id: "U1", name: "Ada"}, %{id: "U2", name: "Zoe"}]} =
             IntegrationSetup.slack_members(requester: Requester)
  end

  test "GitHub setup verifies the App and reveals only the new webhook secret" do
    key = :public_key.generate_key({:rsa, 2_048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    assert {:ok, result} =
             IntegrationSetup.connect_github(
               %{
                 "api_url" => "https://api.github.com",
                 "app_id" => "1234",
                 "private_key" => pem
               },
               requester: Requester
             )

    assert result.app_slug == "ryker-test"
    assert result.actor_login == "ryker-test[bot]"
    assert is_binary(result.webhook_secret)
    refute inspect(Settings.fetch!()) =~ pem
    assert Settings.fetch!().github.bot_actor_id == 4_321
    assert Settings.fetch!().github.bot_login == "ryker-test[bot]"
    assert Credentials.status(:github_private_key, "primary").verification_status == :verified
    assert Credentials.status(:github_webhook, "primary").verification_status == :verified
  end

  test "repository import records only actions granted to the GitHub App" do
    key = :public_key.generate_key({:rsa, 2_048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    assert {:ok, _result} =
             IntegrationSetup.connect_github(
               %{
                 "api_url" => "https://api.github.com",
                 "app_id" => "1234",
                 "private_key" => pem
               },
               requester: Requester
             )

    assert {:ok, [repository]} = IntegrationSetup.github_repositories(requester: Requester)
    assert repository.permissions["pull_requests"] == "write"

    assert {:ok, %{added: ["acme/widget"], failed: []}} =
             IntegrationSetup.import_github_repositories([repository], requester: Requester)

    binding = hd(Settings.fetch!().github_bindings)
    assert binding.granted_permissions["issues"] == "read"

    assert binding.action_grants ==
             ~w(read review open_pull_request update_ryker_branch rerun_ci cancel_ci approve merge)
  end

  # Importing used to create a one-repository group per repository and route
  # nothing to it, so every channel had to be pointed at each group by hand.
  # An imported repository now joins the default environment, which Chat and
  # every conversation without its own setting use: it is usable at once, and
  # the first repository stays the one work changes.
  test "importing a repository puts it in the default environment" do
    connect_github!()
    assert {:ok, [repository]} = IntegrationSetup.github_repositories(requester: Requester)

    assert {:ok, %{added: ["acme/widget"]}} =
             IntegrationSetup.import_github_repositories([repository], requester: Requester)

    assert [%Environment{ref: "default", display_name: "Default", is_default: true} = default] =
             Settings.fetch!().environments

    assert Environment.repository_refs(default) == ["acme-widget"]

    assert {:ok, %{added: ["acme/gadget"]}} =
             IntegrationSetup.import_github_repositories([github_repository("acme/gadget", 502)])

    assert [default] = Settings.fetch!().environments
    assert Environment.repository_refs(default) == ["acme-widget", "acme-gadget"]

    # An operator's own default takes later imports.
    {:ok, _snapshot} =
      Settings.put_environment(
        %{ref: "production", display_name: "Production", is_default: true},
        Settings.fetch!().installation.revision,
        @actor
      )

    assert {:ok, %{added: ["acme/tool"]}} =
             IntegrationSetup.import_github_repositories([github_repository("acme/tool", 503)])

    assert %Environment{ref: "production"} = production = Environment.default(Settings.fetch!())
    assert Environment.repository_refs(production) == ["acme-tool"]

    assert Settings.fetch!().environments
           |> Enum.find(&(&1.ref == "default"))
           |> Environment.repository_refs() == ["acme-widget", "acme-gadget"]
  end

  test "installation events refresh permissions and auto-add with verified identities" do
    key = :public_key.generate_key({:rsa, 2_048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    assert {:ok, _result} =
             IntegrationSetup.connect_github(
               %{
                 "api_url" => "https://api.github.com",
                 "app_id" => "1234",
                 "private_key" => pem
               },
               requester: Requester
             )

    assert {:ok, [repository]} = IntegrationSetup.github_repositories(requester: Requester)

    assert {:ok, %{added: ["acme/widget"]}} =
             IntegrationSetup.import_github_repositories([repository], requester: Requester)

    snapshot = Settings.fetch!()

    assert {:ok, _snapshot} =
             Settings.save_github(
               %{enabled: true, auto_add_repositories: true},
               snapshot.installation.revision,
               @actor
             )

    binding = hd(Settings.fetch!().github_bindings)

    assert {:ok, trusted} =
             Binding.new(%{
               action_grants: binding.action_grants,
               installation_id: binding.installation_id,
               name: binding.name,
               repository_full_name: repository.full_name,
               repository_id: binding.repository_id,
               ryker_actor_id: binding.ryker_actor_id,
               secret: String.duplicate("s", 32)
             })

    assert {:ok, []} =
             Access.apply(
               "installation",
               %{
                 "action" => "new_permissions_accepted",
                 "installation" => %{
                   "id" => 41,
                   "permissions" => %{
                     "contents" => "read",
                     "issues" => "write",
                     "pull_requests" => "read"
                   }
                 }
               },
               %{binding.name => trusted}
             )

    refreshed = hd(Settings.fetch!().github_bindings)
    assert refreshed.granted_permissions["issues"] == "write"
    assert refreshed.action_grants == ~w(read issues)

    assert {:ok, []} =
             Access.apply(
               "installation_repositories",
               %{
                 "action" => "added",
                 "installation" => %{
                   "account" => %{"id" => 99, "login" => "Acme"},
                   "id" => 41,
                   "permissions" => %{
                     "contents" => "write",
                     "pull_requests" => "write"
                   }
                 },
                 "repositories_added" => [
                   %{
                     "default_branch" => "main",
                     "full_name" => "acme/new-repository",
                     "id" => 502,
                     "private" => true
                   }
                 ]
               },
               %{binding.name => trusted}
             )

    added = Enum.find(Settings.fetch!().github_bindings, &(&1.repository_id == 502))
    assert added.ryker_actor_id == 4_321

    # A repository the App was just given joins the default environment, as an
    # imported one does.
    assert Settings.fetch!() |> Environment.default() |> Environment.repository_refs() == [
             "acme-widget",
             "acme-new-repository"
           ]
  end

  test "Emisar and webhook credentials are verified without entering durable settings" do
    token = "emisar-token-that-is-long-enough"

    assert {:ok,
            %{
              ref: "production",
              account_ref: "account-acme",
              account_label: "Acme production",
              status: :connected
            }} =
             IntegrationSetup.connect_emisar(
               %{
                 "ref" => "production",
                 "display_name" => "Production approvals",
                 "rpc_url" => "https://emisar.example/api/mcp/rpc",
                 "token" => token
               },
               requester: Requester
             )

    refute inspect(Settings.fetch!()) =~ token

    assert Enum.find(
             Settings.fetch!().emisar_connections,
             &(&1.ref == "production")
           ).monitoring_enabled

    assert {:ok, _snapshot} = IntegrationSetup.disable_emisar_monitoring("production")

    refute Enum.find(
             Settings.fetch!().emisar_connections,
             &(&1.ref == "production")
           ).monitoring_enabled

    assert {:ok, _snapshot} = IntegrationSetup.enable_emisar_monitoring("production")

    assert Enum.find(
             Settings.fetch!().emisar_connections,
             &(&1.ref == "production")
           ).monitoring_enabled

    assert {:ok, %{ref: "production", status: :rotated}} =
             IntegrationSetup.rotate_emisar(
               "production",
               "replacement-emisar-token-long-enough",
               requester: Requester
             )

    assert {:error, :emisar_account_mismatch} =
             IntegrationSetup.rotate_emisar(
               "production",
               "wrong-account-token-long-enough",
               requester: OtherAccountRequester
             )

    assert {:ok, _snapshot} = IntegrationSetup.disable_emisar("production")

    refute Enum.find(Settings.fetch!().emisar_connections, &(&1.ref == "production")).enabled_for_new_work

    assert {:ok, _snapshot} = IntegrationSetup.enable_emisar("production")

    assert Enum.find(Settings.fetch!().emisar_connections, &(&1.ref == "production")).enabled_for_new_work

    assert {:ok, _snapshot} =
             IntegrationSetup.rename_emisar("production", "Production controls")

    assert Enum.find(Settings.fetch!().emisar_connections, &(&1.ref == "production")).display_name ==
             "Production controls"

    assert {:ok, _snapshot} = IntegrationSetup.delete_emisar("production")
    assert Credentials.status(:emisar, "production").status == :missing
    assert Enum.all?(Settings.fetch!().environments, &is_nil(&1.emisar_connection_ref))

    assert {:ok, %{name: "alerts", secret: generated}} =
             IntegrationSetup.create_webhook_credential("alerts")

    assert byte_size(generated) >= 32

    assert {:ok, %{name: "alerts", status: :deleted}} =
             IntegrationSetup.delete_webhook_credential("alerts")
  end

  test "Emisar derives internal identity and the visible account name from verification" do
    token = "emisar-token-that-is-long-enough"

    assert {:ok,
            %{
              ref: "account-" <> _digest,
              account_ref: "account-acme",
              account_label: "Acme production",
              status: :connected
            }} =
             IntegrationSetup.connect_emisar(
               %{
                 "rpc_url" => "https://emisar.example/api/mcp/rpc",
                 "token" => token
               },
               requester: Requester
             )

    [connection] = Settings.fetch!().emisar_connections
    assert connection.display_name == "Acme production"
    assert connection.ref =~ ~r/\Aaccount-[a-f0-9]{16}\z/
  end

  # Connecting an account once saved it with approval monitoring off and no
  # route, so a fresh connection did nothing until someone found two more
  # switches. The first account now serves every environment that has none,
  # and a default environment is made for Chat when there is none, so work
  # that starts right after connecting can record an approval Ryker watches.
  test "the first Emisar account serves every environment without one" do
    put_payments!()

    assert {:ok, %{ref: ref, status: :connected, environments: environments}} =
             IntegrationSetup.connect_emisar(
               %{
                 "rpc_url" => "https://emisar.example/api/mcp/rpc",
                 "token" => "emisar-token-that-is-long-enough"
               },
               requester: Requester
             )

    assert environments == ["default", "payments"]
    snapshot = Settings.fetch!()
    assert [%{monitoring_enabled: true, enabled_for_new_work: true}] = snapshot.emisar_connections
    assert %Environment{ref: "default"} = Environment.default(snapshot)

    for environment <- ["payments", "default"] do
      assert {:ok, %{connection_ref: ^ref}} = Connections.resolve(snapshot, environment)
    end

    assert pin_work!("channel", "payments").emisar_connection_ref == ref
    assert pin_work!("chat", "default").emisar_connection_ref == ref

    # The setup and integrations pages read the same settings.
    assert %{status: :ready, state: {:on, "Connected"}} =
             Integrations.emisar(%{snapshot: snapshot})
  end

  test "connecting another account never takes over an environment that has one" do
    put_payments!()

    assert {:ok, %{ref: first}} =
             IntegrationSetup.connect_emisar(
               %{
                 "rpc_url" => "https://emisar.example/api/mcp/rpc",
                 "token" => "emisar-token-that-is-long-enough"
               },
               requester: Requester
             )

    {:ok, _snapshot} =
      Settings.put_environment(
        %{ref: "staging", display_name: "Staging"},
        Settings.fetch!().installation.revision,
        @actor
      )

    assert {:ok, %{ref: second, environments: []}} =
             IntegrationSetup.connect_emisar(
               %{
                 "rpc_url" => "https://emisar.example/api/mcp/rpc",
                 "token" => "other-emisar-token-long-enough"
               },
               requester: OtherAccountRequester
             )

    assert second != first
    snapshot = Settings.fetch!()

    assert Map.new(snapshot.environments, &{&1.ref, &1.emisar_connection_ref}) == %{
             "default" => first,
             "payments" => first,
             "staging" => nil
           }

    assert Enum.find(snapshot.emisar_connections, &(&1.ref == second)).monitoring_enabled
  end

  # "Remove account" takes the account off the environments that use it. It is
  # refused, before anything changes, while a task session or an approval
  # still names the account.
  test "removing an account takes it off its environments, and never an account work still names" do
    put_payments!()

    assert {:ok, %{ref: ref}} =
             IntegrationSetup.connect_emisar(
               %{
                 "rpc_url" => "https://emisar.example/api/mcp/rpc",
                 "token" => "emisar-token-that-is-long-enough"
               },
               requester: Requester
             )

    assert pin_work!("pinned", "payments").emisar_connection_ref == ref

    assert {:error, {:invalid_settings, [ref: {:referenced, %{sessions: 1}}]}} =
             IntegrationSetup.delete_emisar(ref)

    assert Enum.all?(Settings.fetch!().environments, &(&1.emisar_connection_ref == ref))
    assert Credentials.status(:emisar, ref).status == :configured

    Repo.update_all(
      from(session in Ryker.Work.Session, where: session.emisar_connection_ref == ^ref),
      set: [cleanup_status: :discarded, discarded_at: DateTime.utc_now()]
    )

    assert {:ok, snapshot} = IntegrationSetup.delete_emisar(ref)
    assert snapshot.emisar_connections == []
    assert Enum.all?(snapshot.environments, &is_nil(&1.emisar_connection_ref))
    assert Credentials.status(:emisar, ref).status == :missing
  end

  defp put_payments! do
    snapshot = Settings.fetch!()

    {:ok, snapshot} =
      Settings.put_repository(
        %{ref: "payments", display_name: "acme/payments"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, snapshot} =
      Settings.put_environment(
        %{ref: "payments", display_name: "Payments", repositories: ["payments"]},
        snapshot.installation.revision,
        @actor
      )

    snapshot
  end

  defp connect_github! do
    key = :public_key.generate_key({:rsa, 2_048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    assert {:ok, _result} =
             IntegrationSetup.connect_github(
               %{
                 "api_url" => "https://api.github.com",
                 "app_id" => "1234",
                 "private_key" => pem
               },
               requester: Requester
             )
  end

  defp github_repository(full_name, repository_id) do
    %{
      default_branch: "main",
      full_name: full_name,
      installation_id: 41,
      permissions: %{"contents" => "write", "pull_requests" => "write"},
      repository_id: repository_id
    }
  end

  defp pin_work!(key, environment_ref) do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "integration-setup:#{key}",
                 native_input_id: "source:integration-setup:#{key}",
                 payload: %{"text" => "Restart the payments worker."},
                 turn_ref: "turn:integration-setup:#{key}"
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(
               episode_id,
               "test-policy",
               String.duplicate("d", 64),
               nil,
               nil,
               nil,
               nil,
               environment_ref
             )

    session
  end
end
