defmodule Ryker.Runtime.AssemblyIntegrationsTest do
  use Ryker.DataCase, async: false

  alias Ryker.{Bootstrap, Credentials, Settings}
  alias Ryker.Emisar.ApprovalRuntime
  alias Ryker.Runtime.Assembly

  @actor "control-plane:local"
  @lab_conversation "control-plane:lab:6f1a0f38-0b74-4f77-9f20-7a0c1e2d3b44"
  @alert_secret "alertmanager-signing-secret-long-enough"
  @deploy_secret "deployment-bearer-token-long-enough"

  setup do
    System.put_env("RYKER_STATE_TOOLS_TOKEN", "state-tools-token-for-tests")

    on_exit(fn ->
      System.delete_env("RYKER_STATE_TOOLS_TOKEN")
    end)

    execution = Application.get_env(:ryker, :execution)
    Application.put_env(:ryker, :execution, :fleet)
    on_exit(fn -> Application.put_env(:ryker, :execution, execution) end)

    :ok
  end

  test "each source authenticates with its own credential and a disabled one is not routed" do
    # One source's credential must never authenticate another's events: the
    # route carries the exact deployment secret its own name registered.
    settings = installation!()

    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    routes = configuration[:webhooks].routes

    assert Map.keys(routes) |> Enum.sort() == ["alerts", "deploys"]
    assert routes["alerts"].auth == {:hmac_sha256, Ryker.Secret.new(@alert_secret)}
    assert routes["deploys"].auth == {:bearer, Ryker.Secret.new(@deploy_secret)}
    refute elem(routes["alerts"].auth, 1) == elem(routes["deploys"].auth, 1)
    assert routes["alerts"].max_clock_skew_seconds == 300
    assert routes["alerts"].work_profile

    {:ok, disabled} =
      Settings.put_webhook_source(
        %{name: "alerts", enabled: false},
        settings.installation.revision,
        @actor
      )

    assert {:ok, reduced} = Assembly.build(bootstrap(), disabled)
    assert Map.keys(reduced[:webhooks].routes) == ["deploys"]
  end

  test "a source whose encrypted credential is missing is left out, and the others still run" do
    # It refused the whole configuration until 2026-09-26, so one deleted
    # credential kept every newer setting from applying. The source is named
    # with why instead, for the webhooks page and Advanced to show.
    settings = installation!()

    assert :ok = Credentials.delete(:webhook, "alerts", @actor)

    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    assert configuration.integrations_left_out == %{webhooks: %{"alerts" => :credential_missing}}
    assert Map.keys(configuration[:webhooks].routes) == ["deploys"]
  end

  test "an enabled GitHub connection without encrypted credentials is left out and named" do
    # It refused every setting until 2026-09-26. It stays visible: GitHub is
    # named with the missing credential, and the rest of the settings apply.
    settings = installation!()

    {:ok, saved} =
      Settings.save_github(
        %{enabled: true, app_id: 12_345},
        settings.installation.revision,
        @actor
      )

    assert {:ok, configuration} = Assembly.build(bootstrap(), saved)
    assert configuration[:github] == nil
    assert configuration.integrations_left_out == %{github: :private_key_missing}
    assert configuration[:webhooks]
    assert Settings.fetch!().github.app_id == 12_345
  end

  test "an enabled approval monitor assembles into options its own runtime accepts" do
    # Assembly merged the whole defaults map, including the HTTP client's
    # receive_timeout_ms, into the approval runtime's options. That runtime
    # refuses a field it does not know, so every installation with Emisar
    # enabled failed to assemble and the release came up with no settings
    # applied at all — found in production during the settings cutover.
    settings = installation!()

    assert {:ok, _credential} =
             Credentials.put(:emisar, "production", "emisar-token-long-enough", @actor)

    {:ok, saved} =
      Settings.put_emisar_connection(
        %{
          ref: "production",
          display_name: "Production approvals",
          rpc_url: "https://emisar.dev/api/mcp/rpc",
          account_ref: "account-production",
          account_label: "Production",
          enabled_for_new_work: true,
          monitoring_enabled: true,
          verified_at: ~U[2026-09-19 12:00:00.000000Z]
        },
        settings.installation.revision,
        @actor
      )

    assert {:ok, configuration} = Assembly.build(bootstrap(), saved)
    assert %{} = configuration[:emisar]

    # The runtime is the authority on its own option set: it raises on an
    # unknown field, so building its child spec is the assertion.
    assert %{start: {_module, _function, _arguments}} =
             configuration[:emisar].connections |> hd() |> ApprovalRuntime.child_spec()
  end

  defp installation! do
    {:ok, _} = Settings.initialize(@actor)
    {:ok, _} = Credentials.put(:webhook, "alerts", @alert_secret, @actor)
    {:ok, _} = Credentials.put(:webhook, "deploys", @deploy_secret, @actor)

    {:ok, saved} =
      Settings.put_repository(
        %{
          ref: "ryker",
          github_repository: "acme/ryker",
          source_commit: String.duplicate("a", 40)
        },
        1,
        @actor
      )

    {:ok, saved} =
      Settings.put_github_binding(
        %{
          name: "ryker",
          repository_ref: "ryker",
          installation_id: 1001,
          repository_id: 2001,
          ryker_actor_id: 3001
        },
        saved.installation.revision,
        @actor
      )

    {:ok, saved} =
      Settings.put_environment(
        %{ref: "ryker", display_name: "Ryker", repositories: ["ryker"]},
        saved.installation.revision,
        @actor
      )

    {:ok, saved} =
      Settings.put_webhook_source(
        source("alerts", :hmac_sha256, "alerts"),
        saved.installation.revision,
        @actor
      )

    {:ok, saved} =
      Settings.put_webhook_source(
        source("deploys", :bearer, "deploys"),
        saved.installation.revision,
        @actor
      )

    saved
  end

  defp source(name, auth_kind, secret_name) do
    %{
      name: name,
      adapter_kind: :universal,
      auth_kind: auth_kind,
      secret_name: secret_name,
      destination_transport: "control_plane",
      destination_conversation_ref: @lab_conversation,
      destination_thread_ref: @lab_conversation,
      environment_ref: "ryker"
    }
  end

  defp bootstrap do
    %Bootstrap{
      repo: [url: "ecto://ryker@localhost/ryker", pool_size: 2],
      control_plane: %{ip: {127, 0, 0, 1}, port: 4321},
      state_tools: %{ip: {127, 0, 0, 1}, port: 4318},
      worker_gateway: nil,
      github_listener: %{ip: {127, 0, 0, 1}, port: 4319},
      github_public_url: "http://127.0.0.1:4319/v1/github",
      webhook_listener: %{ip: {127, 0, 0, 1}, port: 4320},
      webhook_public_url: "http://127.0.0.1:4320",
      storage_root: "/tmp/ryker-assembly-test",
      credential_key: :binary.copy(<<73>>, 32),
      log_level: :warning
    }
  end
end
