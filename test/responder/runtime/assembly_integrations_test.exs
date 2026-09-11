defmodule Responder.Runtime.AssemblyIntegrationsTest do
  use Responder.DataCase, async: false

  alias Responder.{Bootstrap, Settings}
  alias Responder.Runtime.Assembly

  @actor "control-plane:local"
  @digest String.duplicate("a", 64)
  @lab_conversation "control-plane:lab:6f1a0f38-0b74-4f77-9f20-7a0c1e2d3b44"
  @alert_secret "alertmanager-signing-secret-long-enough"
  @deploy_secret "deployment-bearer-token-long-enough"

  setup do
    System.put_env("RESPONDER_STATE_TOOLS_TOKEN", "state-tools-token-for-tests")
    System.put_env("ALERTMANAGER_WEBHOOK_SECRET", @alert_secret)
    System.put_env("DEPLOYMENT_WEBHOOK_SECRET", @deploy_secret)

    on_exit(fn ->
      Enum.each(
        ~w(RESPONDER_STATE_TOOLS_TOKEN ALERTMANAGER_WEBHOOK_SECRET DEPLOYMENT_WEBHOOK_SECRET),
        &System.delete_env/1
      )
    end)

    execution = Application.get_env(:responder, :execution)
    Application.put_env(:responder, :execution, :fleet)
    on_exit(fn -> Application.put_env(:responder, :execution, execution) end)

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

  test "a source naming a credential the deployment never registered assembles nothing" do
    settings = installation!()

    assert {:error, {:settings_not_applicable, reason}} =
             Assembly.build(
               %{bootstrap() | webhook_secret_names: ["DEPLOYMENT_WEBHOOK_SECRET"]},
               settings
             )

    assert reason =~ "not registered for this deployment"
  end

  test "a GitHub connection saved for another app is a mismatch, not a quiet non-start" do
    # Silently not starting GitHub reads like "not configured yet". The saved
    # bindings must stay exactly as they are and the operator must be told.
    settings = installation!()

    {:ok, saved} =
      Settings.save_github(
        %{enabled: true, app_id: 12_345},
        settings.installation.revision,
        @actor
      )

    assert {:error, {:settings_not_applicable, reason}} =
             Assembly.build(%{bootstrap() | github_app_id: 999}, saved)

    assert reason =~ "different app"

    assert {:error, {:settings_not_applicable, missing}} =
             Assembly.build(%{bootstrap() | github_app_id: nil}, saved)

    assert missing =~ "GITHUB_APP_ID is not supplied"
    assert Settings.fetch!().github.app_id == 12_345
  end

  defp installation! do
    {:ok, _} = Settings.initialize(@actor)
    {:ok, _} = Settings.put_repository(%{ref: "responder"}, 1, @actor)

    {:ok, saved} =
      Settings.put_policy_binding(
        %{
          purpose: :conversational,
          scope_kind: :repository,
          scope_ref: "responder",
          policy_name: "responder-conversation-v1",
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
          scope_ref: "responder",
          policy_name: "responder-contributor-v1",
          policy_digest: String.duplicate("b", 64),
          verified_by: :import
        },
        saved.installation.revision,
        @actor
      )

    {:ok, saved} =
      Settings.put_webhook_source(
        source("alerts", :hmac_sha256, "ALERTMANAGER_WEBHOOK_SECRET"),
        saved.installation.revision,
        @actor
      )

    {:ok, saved} =
      Settings.put_webhook_source(
        source("deploys", :bearer, "DEPLOYMENT_WEBHOOK_SECRET"),
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
      context_ref: "responder"
    }
  end

  defp bootstrap do
    %Bootstrap{
      repo: [url: "ecto://responder@localhost/responder", pool_size: 2],
      control_plane: %{ip: {127, 0, 0, 1}, port: 4321},
      state_tools: %{ip: {127, 0, 0, 1}, port: 4318},
      worker_gateway: nil,
      github_listener: %{ip: {127, 0, 0, 1}, port: 4319},
      webhook_listener: %{ip: {127, 0, 0, 1}, port: 4320},
      storage_root: "/tmp/responder-assembly-test",
      github_api_url: "https://api.github.com",
      github_app_id: nil,
      emisar_rpc_url: "https://emisar.dev/api/mcp/rpc",
      log_level: :warning,
      webhook_secret_names: ["ALERTMANAGER_WEBHOOK_SECRET", "DEPLOYMENT_WEBHOOK_SECRET"]
    }
  end
end
