defmodule Ryker.IntegrationSetupTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.ControlPlane.{IntegrationErrors, Integrations}
  alias Ryker.{Credentials, Episodes, IntegrationSetup, Repo, Settings}
  alias Ryker.Emisar.Connections
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.GitHub.{Access, Auth, Binding, Router}
  alias Ryker.Settings.Environment
  alias Ryker.Slack.Names
  alias Ryker.TestSupport.EmisarMCP
  alias Ryker.Work.Custody

  @actor "control-plane:local"
  @scopes ~w(
    app_mentions:read assistant:write bookmarks:read channels:history
    channels:join channels:manage channels:read chat:write commands files:read files:write
    groups:history groups:read groups:write im:history im:read mpim:read pins:write
    reactions:read reactions:write usergroups:read users:read
  )

  def scopes, do: @scopes

  defmodule Requester do
    def request(client, method, path, body, headers) do
      send(self(), {:provider_request, client.base_url, method, path, body, headers})
      {:ok, token} = client.token_provider.()

      if path == "/api/mcp/rpc",
        do: EmisarMCP.answer(body, token),
        else: response_for(path, token)
    end

    # Like GitHub: the App's own token answers only /app endpoints, and
    # /users needs an installation's token. The live GitHub repair failed on
    # 2026-09-26 with "did not return the App's bot account" for a valid key,
    # because the bot account was read with the App's token, which this
    # double used to accept.
    defp response_for("/users/" <> _login, token) when token != "installation-token",
      do: {:ok, %{body: %{"message" => "Bad credentials"}, headers: [], status: 401}}

    defp response_for(path, _token), do: response_for(path)

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
            "profile" => %{"display_name" => "Zoe"},
            "team_id" => "T0123456789"
          },
          %{
            "deleted" => false,
            "id" => "U1",
            "is_bot" => false,
            "profile" => %{"real_name" => "Ada"},
            "team_id" => "T0123456789"
          },
          %{"deleted" => false, "id" => "B1", "is_bot" => true},
          # Slack lists Slackbot as a member that is not a bot, and a workflow
          # or app user the same way, marked only as an app user.
          %{
            "deleted" => false,
            "id" => "USLACKBOT",
            "is_bot" => false,
            "name" => "slackbot",
            "profile" => %{"real_name" => "Slackbot"}
          },
          %{
            "deleted" => false,
            "id" => "U9",
            "is_app_user" => true,
            "is_bot" => false,
            "profile" => %{"real_name" => "Deploy workflow"}
          }
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

    defp response_for("/installation/repositories?per_page=100&page=1") do
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

    defp response(body), do: {:ok, %{body: body, headers: [], status: 200}}
  end

  # An organization with more repositories than GitHub lists on one page, as theblitzapp has:
  # GitHub lists a hundred at a time and says how many there are in all.
  defmodule PagedRepositoriesRequester do
    alias Ryker.IntegrationSetupTest.Requester

    def request(_client, :get, "/installation/repositories?per_page=100&page=1", _body, _headers),
      do:
        page(
          Enum.map(1..100, &repository("acme/quiet-#{&1}", 1_000 + &1, "2026-01-01T00:00:00Z"))
        )

    def request(_client, :get, "/installation/repositories?per_page=100&page=2", _body, _headers),
      do:
        page([
          repository("acme/recent", 2_001, "2026-09-30T09:00:00Z"),
          repository("acme/retired", 2_002, "2026-10-03T09:00:00Z", true),
          repository("acme/busy", 2_003, "2026-10-02T09:00:00Z")
        ])

    def request(client, method, path, body, headers),
      do: Requester.request(client, method, path, body, headers)

    defp repository(full_name, id, pushed_at, archived \\ false),
      do: %{
        "archived" => archived,
        "default_branch" => "main",
        "full_name" => full_name,
        "id" => id,
        "private" => true,
        "pushed_at" => pushed_at
      }

    defp page(repositories),
      do:
        {:ok,
         %{
           body: %{"repositories" => repositories, "total_count" => 103},
           headers: [],
           status: 200
         }}
  end

  # Slack listing a workspace's people a page at a time, as it does: a page may hold fewer
  # people than the limit while more pages follow.
  defmodule PagedMembersRequester do
    def request(_client, :get, "/users.list?limit=200", _body, _headers),
      do: page([person("U2", "Zoe")], "page-2")

    def request(_client, :get, "/users.list?limit=200&cursor=page-2", _body, _headers),
      do:
        page(
          [person("U3", "Bea"), %{"deleted" => true, "id" => "U9", "is_bot" => false}],
          "page-3"
        )

    def request(_client, :get, "/users.list?limit=200&cursor=page-3", _body, _headers),
      do: page([person("U1", "Ada")], "")

    defp person(id, name),
      do: %{
        "deleted" => false,
        "id" => id,
        "is_bot" => false,
        "profile" => %{"real_name" => name}
      }

    defp page(members, cursor) do
      {:ok,
       %{
         body: %{
           "members" => members,
           "ok" => true,
           "response_metadata" => %{"next_cursor" => cursor}
         },
         headers: [],
         status: 200
       }}
    end
  end

  # Slack turning one page away for a moment, as it does for a large workspace read quickly.
  defmodule LimitedMembersRequester do
    def request(_client, :get, "/users.list?limit=200", _body, _headers) do
      if Process.get(:limited_once) do
        PagedMembersRequester.request(nil, :get, "/users.list?limit=200", nil, [])
      else
        Process.put(:limited_once, true)

        {:ok,
         %{
           body: %{"ok" => false, "error" => "ratelimited"},
           headers: [{"retry-after", "2"}],
           status: 429
         }}
      end
    end

    def request(client, method, path, body, headers),
      do: PagedMembersRequester.request(client, method, path, body, headers)
  end

  # Slack answering for tokens of another workspace.
  defmodule OtherWorkspaceRequester do
    def request(client, :post, "/auth.test", body, headers) do
      {:ok, response} = Requester.request(client, :post, "/auth.test", body, headers)
      {:ok, %{response | body: %{response.body | "team_id" => "T9999999999", "team" => "Other"}}}
    end

    def request(client, method, path, body, headers),
      do: Requester.request(client, method, path, body, headers)
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

  # Andrew, 2026-10-01, setting up the tenant workspace: "not all people shown here … some orgs
  # have hundreds of people". Choose people read only Slack's first page of members, and Slack
  # often returns fewer than the limit on a page while more pages follow, so most of a large
  # workspace was never offered.
  test "Choose people offers everyone in the workspace, page after page" do
    assert {:ok, _credential} =
             Credentials.put(:slack_bot, "primary", "xoxb-this-is-a-long-bot-token", @actor)

    assert {:ok, members} = IntegrationSetup.slack_members(requester: PagedMembersRequester)
    assert Enum.map(members, & &1.name) == ["Ada", "Bea", "Zoe"]
  end

  # Reading every page of a large workspace quickly meets Slack's rate limit; the page it turned
  # away is asked again after the wait Slack names, instead of failing the whole list.
  test "Choose people waits out Slack's rate limit instead of failing" do
    assert {:ok, _credential} =
             Credentials.put(:slack_bot, "primary", "xoxb-this-is-a-long-bot-token", @actor)

    parent = self()

    assert {:ok, members} =
             IntegrationSetup.slack_members(
               requester: LimitedMembersRequester,
               sleep: fn milliseconds -> send(parent, {:waited, milliseconds}) end
             )

    assert Enum.map(members, & &1.name) == ["Ada", "Bea", "Zoe"]
    assert_received {:waited, 2_000}
  end

  # Andrew chose himself on Integrations › Slack on 2026-09-26 and the list
  # then read "Slack user U0BHTNFCW6S": Choose people had every member's name
  # in hand from users.list, while the name cache went on to ask Slack for
  # each chosen person, one every 1.6 seconds, after the page was drawn.
  test "the people Choose people lists are known by name at once, without asking Slack for each" do
    parent = self()

    start_supervised!(
      {Names,
       workspace: "T0123456789",
       fetch: fn ref ->
         send(parent, {:name_lookup, ref})
         {:ok, "someone else"}
       end}
    )

    tokens = %{
      "app_token" => "xapp-this-is-a-long-app-token",
      "bot_token" => "xoxb-this-is-a-long-bot-token"
    }

    assert {:ok, _connected} = IntegrationSetup.connect_slack(tokens, requester: Requester)
    assert {:ok, _members} = IntegrationSetup.slack_members(requester: Requester)

    assert Names.name("T0123456789", "U1") == "@Ada"
    assert Names.name("T0123456789", "U2") == "@Zoe"
    assert :ok = GenServer.call(Names, :refresh)
    refute_received {:name_lookup, _ref}
  end

  # Manual testing, 2026-09-26: tokens pasted into each other's boxes were
  # told only that the app token "does not look right", and nothing said the
  # bot token was the right one in the wrong place.
  test "Slack tokens pasted into each other's boxes are named as swapped, before any request" do
    swapped = %{
      "app_token" => "xoxb-this-is-a-long-bot-token",
      "bot_token" => "xapp-this-is-a-long-app-token"
    }

    assert IntegrationSetup.connect_slack(swapped, requester: Requester) ==
             {:error, {:invalid_credential, :swapped_tokens}}

    refute_received {:provider_request, _url, _method, _path, _body, _headers}

    assert IntegrationErrors.message({:invalid_credential, :swapped_tokens}) ==
             "The two tokens are swapped: the app token starts with xapp- and the bot token " <>
               "with xoxb-. Paste each in its own box, then verify again."
  end

  test "new tokens for the workspace Slack works in keep it on; another workspace's switch it off" do
    # Replacing the tokens saved Slack as off every time, so a working Slack
    # stopped reading and replying until someone chose the same people again.
    # The people who manage Ryker are the workspace's people: tokens for the
    # same workspace change nobody, and only another workspace's tokens need
    # them chosen again, from that workspace.
    tokens = %{
      "app_token" => "xapp-this-is-a-long-app-token",
      "bot_token" => "xoxb-this-is-a-long-bot-token"
    }

    {:ok, _result} = IntegrationSetup.connect_slack(tokens, requester: Requester)
    refute Settings.fetch!().slack.enabled

    {:ok, _snapshot} =
      Settings.save_slack(
        %{enabled: true, operators: ["U1"]},
        Settings.fetch!().installation.revision,
        @actor
      )

    replaced = %{tokens | "bot_token" => "xoxb-this-is-a-replaced-bot-token"}

    assert {:ok, %{enabled: true}} =
             IntegrationSetup.connect_slack(replaced, requester: Requester)

    assert %{enabled: true, operators: ["U1"], workspace_ref: "T0123456789"} =
             Settings.fetch!().slack

    assert {:ok, %{enabled: false}} =
             IntegrationSetup.connect_slack(replaced, requester: OtherWorkspaceRequester)

    assert %{enabled: false, workspace_ref: "T9999999999"} = Settings.fetch!().slack

    # Slack that was never switched on stays off when its tokens are replaced.
    {:ok, _result} = IntegrationSetup.connect_slack(replaced, requester: OtherWorkspaceRequester)
    refute Settings.fetch!().slack.enabled
  end

  test "Choose people offers the people in the workspace, never Slackbot or an app" do
    # QA, 2026-09-25: the list of people who could manage Ryker offered
    # Slackbot, which Slack marks as a member that is not a bot.
    {:ok, _result} =
      IntegrationSetup.connect_slack(
        %{
          "app_token" => "xapp-this-is-a-long-app-token",
          "bot_token" => "xoxb-this-is-a-long-bot-token"
        },
        requester: Requester
      )

    {:ok, members} = IntegrationSetup.slack_members(requester: Requester)
    assert Enum.map(members, & &1.name) == ["Ada", "Zoe"]
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

  # A five-character webhook signing secret was accepted and stored on
  # 2026-09-25, and from then on no settings change reached the running
  # system: a signed route needs thirty-two bytes, and the worker server
  # refuses a secret too short to redact from its output, so every assembly
  # failed until the credential was deleted. A secret nothing can use is
  # refused where it is typed; an empty field still makes a strong one.
  test "a signing secret too short for a signed route is refused before it is stored" do
    assert {:error, :webhook_secret_too_short} =
             IntegrationSetup.create_webhook_credential("grafana", "short")

    assert {:error, :webhook_secret_too_short} =
             IntegrationSetup.create_webhook_credential("grafana", String.duplicate("s", 31))

    assert Credentials.status(:webhook, "grafana").status == :missing

    key = :public_key.generate_key({:rsa, 2_048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    assert {:error, :webhook_secret_too_short} =
             IntegrationSetup.connect_github(
               %{"app_id" => "1234", "private_key" => pem, "webhook_secret" => "short"},
               requester: Requester
             )

    assert Credentials.status(:github_webhook, "primary").status == :missing
    assert Credentials.status(:github_private_key, "primary").status == :missing

    long_enough = String.duplicate("s", 32)

    assert {:ok, %{secret: ^long_enough}} =
             IntegrationSetup.create_webhook_credential("grafana", long_enough)
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
  # Andrew, 2026-10-03, on blitz's Add repositories: "those ar enot all repos, we have more than
  # 100 and also we should order them somehow by activity and hide archived ones?" GitHub lists a
  # hundred repositories a page, and the picker read only the first page, alphabetically, archived
  # ones included.
  test "the picker offers every repository the App reaches, most recently active first, never an archived one" do
    connect_github!()

    assert {:ok, repositories} =
             IntegrationSetup.github_repositories(requester: PagedRepositoriesRequester)

    names = Enum.map(repositories, & &1.full_name)
    assert length(names) == 102
    assert Enum.take(names, 2) == ["acme/busy", "acme/recent"]
    assert "acme/quiet-100" in names
    refute "acme/retired" in names
  end

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

  # On 2026-09-26 Andrew added AndrewDryga/AndrewDryga and
  # AndrewDryga/andrewdryga.github.com in one go. Only the first got its
  # GitHub binding and joined Default; the second was saved half-way and sat
  # "Waiting to start", and GitHub itself stayed off ("Add a repository to
  # start") with two repositories added.
  test "repositories added together are each bound, all in Default, and GitHub is on" do
    connect_github!()

    repositories = [
      %{github_repository("AndrewDryga/AndrewDryga", 601) | default_branch: "main"},
      %{github_repository("AndrewDryga/andrewdryga.github.com", 602) | default_branch: "master"}
    ]

    assert {:ok, %{added: added, failed: []}} =
             IntegrationSetup.import_github_repositories(repositories, requester: Requester)

    assert Enum.sort(added) == ["AndrewDryga/AndrewDryga", "AndrewDryga/andrewdryga.github.com"]

    snapshot = Settings.fetch!()

    assert snapshot.github_bindings |> Enum.map(& &1.repository_ref) |> Enum.sort() ==
             ["andrewdryga-andrewdryga", "andrewdryga-andrewdryga-github-com"]

    assert [%Environment{ref: "default"} = default] = snapshot.environments

    assert Environment.repository_refs(default) ==
             ["andrewdryga-andrewdryga", "andrewdryga-andrewdryga-github-com"]

    assert snapshot.github.enabled
  end

  # The live state on 2026-09-26: AndrewDryga/AndrewDryga went in whole,
  # AndrewDryga/andrewdryga.github.com was saved without its GitHub binding or
  # a place in Default, and GitHub stayed off ("Add a repository to start")
  # with two repositories added. Both sat "Waiting to start", and the picker
  # listed the half-saved one as already added, so nothing could finish it.
  test "a repository saved half-way is finished by adding it again, and GitHub is switched on" do
    connect_github!()

    assert {:ok, %{added: ["acme/widget"]}} =
             IntegrationSetup.import_github_repositories([github_repository("acme/widget", 501)])

    {:ok, _snapshot} =
      Settings.save_github(%{enabled: false}, Settings.fetch!().installation.revision, @actor)

    {:ok, _snapshot} =
      Settings.put_repository(
        %{
          ref: "acme-site",
          display_name: "acme/site",
          github_repository: "acme/site",
          base_branch: "master"
        },
        Settings.fetch!().installation.revision,
        @actor
      )

    assert {:ok, %{added: ["acme/site"], already_present: [], failed: []}} =
             IntegrationSetup.import_github_repositories([github_repository("acme/site", 602)])

    snapshot = Settings.fetch!()

    assert snapshot.github_bindings |> Enum.map(& &1.repository_ref) |> Enum.sort() ==
             ["acme-site", "acme-widget"]

    assert [%Environment{ref: "default"} = default] = snapshot.environments
    assert Environment.repository_refs(default) == ["acme-widget", "acme-site"]
    assert snapshot.github.enabled
  end

  # Its row offered only Retry setup, which stopped again at "GitHub binding
  # is missing" every time (AndrewDryga/andrewdryga.github.com, 2026-09-26).
  test "a repository whose adding stopped half-way is added again from what the App reaches" do
    connect_github!()

    {:ok, _snapshot} =
      Settings.put_repository(
        %{
          ref: "acme-site",
          display_name: "acme/site",
          github_repository: "acme/site",
          onboarding_state: :blocked,
          onboarding_error: "GitHub binding is missing."
        },
        Settings.fetch!().installation.revision,
        @actor
      )

    assert {:error, {:github_repository_unreachable, "acme/site"}} =
             IntegrationSetup.add_github_repository_again("acme-site", [
               github_repository("acme/other", 601)
             ])

    assert {:ok, %{added: ["acme/site"], failed: []}} =
             IntegrationSetup.add_github_repository_again("acme-site", [
               github_repository("acme/other", 601),
               github_repository("acme/site", 602)
             ])

    snapshot = Settings.fetch!()
    assert [%{repository_ref: "acme-site", repository_id: 602}] = snapshot.github_bindings
    assert [default] = snapshot.environments
    assert Environment.repository_refs(default) == ["acme-site"]

    # Its setup, stopped for want of the binding, starts over.
    assert [%{onboarding_state: :pending, onboarding_error: nil}] = snapshot.repositories

    assert {:error, :repository_not_found} =
             IntegrationSetup.add_github_repository_again("missing", [])
  end

  # Andrew, 2026-09-27: "how do I remove repositories?!" Nothing could: a
  # saved repository is refused deletion while an environment or its GitHub
  # binding names it, and nothing took those away.
  test "removing a repository takes it out of everything that names it, and its requests stay" do
    connect_github!()

    assert {:ok, %{added: ["acme/widget", "acme/gadget", "acme/tool"]}} =
             IntegrationSetup.import_github_repositories([
               github_repository("acme/widget", 501),
               github_repository("acme/gadget", 502),
               github_repository("acme/tool", 503)
             ])

    # acme-widget is Default's default; acme-gadget is only read there.
    {:ok, _snapshot} =
      Settings.put_environment(
        %{
          ref: "default",
          repositories: ["acme-widget", "acme-gadget", "acme-tool"],
          access: %{"acme-gadget" => :read_only}
        },
        Settings.fetch!().installation.revision,
        @actor
      )

    for {name, repositories} <- [
          {"deploys", ["acme-widget", "acme-gadget"]},
          {"widget-deploys", ["acme-widget"]}
        ] do
      {:ok, _snapshot} =
        Settings.put_webhook_source(
          %{
            name: name,
            adapter_kind: :universal,
            auth_kind: :hmac_sha256,
            secret_name: name,
            destination_transport: "slack",
            destination_conversation_ref: "slack:T0123456789:C0123456789",
            environment_ref: "default",
            publication_lifecycle: %{
              "environments" => ["production"],
              "kinds" => ["deployment"],
              "repositories" => repositories,
              "targets" => ["widget"]
            }
          },
          Settings.fetch!().installation.revision,
          @actor
        )
    end

    storage = Path.join(System.tmp_dir!(), "ryker-remove-#{System.unique_integer([:positive])}")
    mirror = Path.join([storage, "coop-source-mirrors", "acme-widget.git"])
    other = Path.join([storage, "coop-source-mirrors", "acme-gadget.git"])
    Enum.each([mirror, other], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf!(storage) end)

    session = pin_repository_work!("widget", "acme-widget")

    assert {:ok, %{repository: %{github_repository: "acme/widget"}}} =
             IntegrationSetup.remove_repository("acme-widget", storage_root: storage)

    snapshot = Settings.fetch!()
    assert Enum.map(snapshot.repositories, & &1.ref) == ["acme-gadget", "acme-tool"]

    assert snapshot.github_bindings |> Enum.map(& &1.repository_ref) |> Enum.sort() == [
             "acme-gadget",
             "acme-tool"
           ]

    # The read-only repository does not become the default; the next one
    # work may change does, and what each may do stays as it was.
    assert [default] = snapshot.environments

    assert Enum.map(default.repositories, &{&1.repository_ref, &1.access}) == [
             {"acme-tool", :read_write},
             {"acme-gadget", :read_only}
           ]

    sources = Map.new(snapshot.webhook_sources, &{&1.name, &1.publication_lifecycle})
    assert sources["deploys"]["repositories"] == ["acme-gadget"]
    assert sources["widget-deploys"] == nil

    # The mirror Ryker kept of it goes; what Ryker did in it stays.
    refute File.exists?(mirror)
    assert File.exists?(other)
    assert %{repository_ref: "acme-widget"} = Repo.reload!(session)

    assert {:error, :repository_not_found} =
             IntegrationSetup.remove_repository("acme-widget", storage_root: storage)

    # An environment left with nothing work could change is refused, and
    # nothing is removed.
    assert {:error, {:environment_left_read_only, "Default"}} =
             IntegrationSetup.remove_repository("acme-tool", storage_root: storage)

    assert Enum.map(Settings.fetch!().repositories, & &1.ref) == ["acme-gadget", "acme-tool"]
  end

  test "the picker offers a repository that was saved without its GitHub binding" do
    connect_github!()

    {:ok, _snapshot} =
      Settings.put_repository(
        %{
          ref: "acme-widget",
          display_name: "acme/widget",
          github_repository: "acme/widget",
          base_branch: "main"
        },
        Settings.fetch!().installation.revision,
        @actor
      )

    assert {:ok, [%{full_name: "acme/widget", already_present: false}]} =
             IntegrationSetup.github_repositories(requester: Requester)
  end

  # Andrew, 2026-10-03, showing the App's Recent Deliveries: ping and
  # installation.created both failed, "errors on setup". Verifying the App left
  # GitHub off until a repository was added, so nothing listened while the App
  # was installed. Verifying now switches it on, and with no repository added
  # yet the listener still answers GitHub.
  test "a verified App with no repository yet is on and answers GitHub" do
    connect_github!()

    snapshot = Settings.fetch!()
    assert snapshot.github.enabled
    assert snapshot.github_bindings == []

    for {event, payload} <- [
          {"ping", %{"zen" => "Keep it logically awesome.", "hook_id" => 1}},
          {"installation",
           %{
             "action" => "created",
             "installation" => %{"id" => 41, "account" => %{"login" => "Acme"}}
           }}
        ] do
      conn = github_event(event, payload, %{})
      assert conn.status == 200, "#{event} answered #{conn.status}: #{conn.resp_body}"
    end
  end

  # "Add new repositories automatically" never added anything: GitHub names a
  # repository the App was just given only in an installation_repositories
  # event, and no binding names that repository yet, so the router answered
  # "ignored" before the event could reach Access.
  test "a repository the App is given is added through GitHub's own event when auto-add is on" do
    connect_github!()
    assert {:ok, [repository]} = IntegrationSetup.github_repositories(requester: Requester)

    assert {:ok, %{added: ["acme/widget"]}} =
             IntegrationSetup.import_github_repositories([repository], requester: Requester)

    {:ok, _snapshot} =
      Settings.save_github(
        %{enabled: true, auto_add_repositories: true},
        Settings.fetch!().installation.revision,
        @actor
      )

    binding = hd(Settings.fetch!().github_bindings)

    assert {:ok, trusted} =
             Binding.new(%{
               action_grants: binding.action_grants,
               installation_id: binding.installation_id,
               name: binding.name,
               repository_full_name: "acme/widget",
               repository_id: binding.repository_id,
               ryker_actor_id: binding.ryker_actor_id,
               secret: String.duplicate("s", 32)
             })

    conn =
      github_event(
        "installation_repositories",
        %{
          "action" => "added",
          "installation" => %{
            "account" => %{"id" => 99, "login" => "Acme"},
            "id" => 41,
            "permissions" => %{"contents" => "write", "pull_requests" => "write"}
          },
          "repositories_added" => [
            %{
              "default_branch" => "main",
              "full_name" => "acme/gizmo",
              "id" => 777,
              "private" => true
            }
          ],
          "repositories_removed" => []
        },
        %{binding.name => trusted}
      )

    assert conn.status == 202, conn.resp_body
    assert Enum.any?(Settings.fetch!().repositories, &(&1.github_repository == "acme/gizmo"))
    assert Enum.any?(Settings.fetch!().github_bindings, &(&1.repository_id == 777))
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
              account_ref: "key-" <> _fingerprint,
              account_label: "emisar.example",
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

    assert {:error, {:emisar_verification_failed, :token_refused}} =
             IntegrationSetup.rotate_emisar(
               "production",
               "refused-replacement-token-long-enough",
               requester: Requester
             )

    assert Credentials.status(:emisar, "production").status == :configured

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

  # Found live 2026-09-27: Andrew's new Emisar key, which emisar.dev showed as
  # "Agent connected", was refused with "Emisar did not say which account this
  # token belongs to". Emisar's handshake names the server, never the account
  # behind a key, and Ryker's double answered with an account Emisar never
  # sends, so no real key could ever connect. A key proves itself by listing
  # the agent tools, and the connection is known by the key's fingerprint.
  test "an Emisar key connects under Emisar's address, since Emisar never names the account" do
    token = "emisar-token-that-is-long-enough"

    assert {:ok,
            %{
              ref: "account-" <> _digest,
              account_ref: "key-" <> _fingerprint,
              account_label: "emisar.example",
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
    assert connection.display_name == "emisar.example"
    assert connection.ref =~ ~r/\Aaccount-[a-f0-9]{16}\z/
    refute inspect(Settings.fetch!()) =~ token
  end

  test "an Emisar key Emisar refuses says so, and nothing is saved" do
    assert {:error, {:emisar_verification_failed, :token_refused}} =
             IntegrationSetup.connect_emisar(
               %{
                 "rpc_url" => "https://emisar.example/api/mcp/rpc",
                 "token" => "refused-emisar-token-long-enough"
               },
               requester: Requester
             )

    assert Settings.fetch!().emisar_connections == []
  end

  test "a key that cannot run agent tools says which key to make" do
    assert {:error, {:emisar_verification_failed, :wrong_key_kind}} =
             IntegrationSetup.connect_emisar(
               %{
                 "rpc_url" => "https://emisar.example/api/mcp/rpc",
                 "token" => "audit-emisar-token-long-enough"
               },
               requester: Requester
             )

    assert Settings.fetch!().emisar_connections == []
  end

  test "the same Emisar key connected twice says it is already connected" do
    params = %{
      "rpc_url" => "https://emisar.example/api/mcp/rpc",
      "token" => "emisar-token-that-is-long-enough"
    }

    assert {:ok, %{ref: ref}} = IntegrationSetup.connect_emisar(params, requester: Requester)

    assert {:error, {:emisar_key_already_connected, "emisar.example"}} =
             IntegrationSetup.connect_emisar(params, requester: Requester)

    assert [%{ref: ^ref}] = Settings.fetch!().emisar_connections
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

    # The setup and integrations pages read the same settings, with nothing
    # left out of the running system.
    assert %{status: :on, state: {:on, "Connected"}} =
             Integrations.emisar(%{snapshot: snapshot, readiness: %{left_out: %{}}})
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
               requester: Requester
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

  # One signed GitHub event, through the router the listener runs.
  defp github_event(event, payload, bindings) do
    secret = String.duplicate("s", 32)
    body = Jason.encode!(payload)

    Plug.Test.conn(:post, "/v1/github", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-github-event", event)
    |> Plug.Conn.put_req_header("x-github-delivery", "delivery-" <> Ecto.UUID.generate())
    |> Plug.Conn.put_req_header("x-hub-signature-256", Auth.signature(secret, body))
    |> Router.call(
      Router.init(
        bindings: bindings,
        bot_login: "ryker-test",
        repository_access: fn _binding, _payload -> :ok end,
        secret: secret
      )
    )
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

  defp pin_repository_work!(key, repository_ref) do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "integration-setup:#{key}",
                 native_input_id: "source:integration-setup:#{key}",
                 payload: %{"text" => "Why is the widget build red?"},
                 turn_ref: "turn:integration-setup:#{key}"
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(
               episode_id,
               "test-policy",
               String.duplicate("d", 64),
               repository_ref
             )

    session
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
