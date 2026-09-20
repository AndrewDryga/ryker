defmodule Ryker.Runtime.AssemblyIntegrationsTest do
  use Ryker.DataCase, async: false

  alias Ryker.{Bootstrap, Credentials, Settings}
  alias Ryker.Emisar.ApprovalRuntime
  alias Ryker.Runtime.Assembly

  @actor "control-plane:local"
  @digest String.duplicate("a", 64)
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
    assert routes["alerts"].auth == {:hmac_sha256, @alert_secret}
    assert routes["deploys"].auth == {:bearer, @deploy_secret}
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

  test "a source whose encrypted credential is missing assembles nothing" do
    settings = installation!()

    assert {:ok, :ok} = Credentials.delete(:webhook, "alerts", @actor)

    assert {:error, {:settings_not_applicable, reason}} =
             Assembly.build(bootstrap(), settings)

    assert reason =~ "alerts"
  end

  test "an enabled GitHub connection without encrypted credentials is a visible refusal" do
    settings = installation!()

    {:ok, saved} =
      Settings.save_github(
        %{enabled: true, app_id: 12_345},
        settings.installation.revision,
        @actor
      )

    assert {:error, {:settings_not_applicable, missing}} = Assembly.build(bootstrap(), saved)
    assert missing == "github_private_key credential primary is not configured"
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
    {:ok, _} = Settings.put_repository(%{ref: "ryker"}, 1, @actor)

    {:ok, saved} =
      Settings.put_policy_binding(
        %{
          purpose: :conversational,
          scope_kind: :repository,
          scope_ref: "ryker",
          policy_name: "ryker-conversation-v1",
          policy_digest: @digest,
          verified_by: :import
        },
        2,
        @actor
      )

    {:ok, saved} =
      Settings.put_policy_binding(
        %{
          purpose: :contributor,
          scope_kind: :repository,
          scope_ref: "ryker",
          policy_name: "ryker-contributor-v1",
          policy_digest: String.duplicate("b", 64),
          verified_by: :import
        },
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
      context_ref: "ryker"
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
