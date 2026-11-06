defmodule Ryker.IntegrationSetup.DiagnosticsTest do
  use Ryker.DataCase, async: false
  alias Ryker.{IntegrationSetup, Settings}

  @actor "control-plane:local"

  test "missing diagnostic connections are named before an alert needs them" do
    {:ok, snapshot} = Settings.initialize(@actor)

    {:ok, _snapshot} =
      Settings.put_environment(
        %{ref: "ops", display_name: "Operations", repositories: []},
        snapshot.installation.revision,
        @actor
      )

    assert {:ok, check} = IntegrationSetup.check_environment("ops")
    assert check.repositories == []
    assert check.emisar.status == :missing
    assert check.emisar.detail =~ "No Emisar account"
    assert check.next_step =~ "new conversation"
  end

  test "repository discovery and a fresh tool list state only the access they checked" do
    {:ok, snapshot} = Settings.initialize(@actor)

    {:ok, snapshot} =
      Settings.save_github(%{enabled: true, app_id: 1}, snapshot.installation.revision, @actor)

    {:ok, snapshot} =
      Settings.put_repository(
        %{ref: "api", display_name: "acme/api", github_repository: "acme/api"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, snapshot} =
      Settings.put_emisar_connection(
        %{
          ref: "ops",
          display_name: "Operations",
          rpc_url: "https://ops.example/api/mcp/rpc",
          account_ref: "ops",
          enabled_for_new_work: true,
          monitoring_enabled: false,
          verified_at: ~U[2026-11-01 00:00:00.000000Z]
        },
        snapshot.installation.revision,
        @actor
      )

    {:ok, _snapshot} =
      Settings.put_environment(
        %{
          ref: "ops",
          display_name: "Operations",
          repositories: ["api"],
          emisar_connection_ref: "ops"
        },
        snapshot.installation.revision,
        @actor
      )

    options = [
      github_repositories: fn -> {:ok, [%{full_name: "acme/api"}]} end,
      emisar_probe: fn pin ->
        assert pin.connection_ref == "ops"
        {:ok, %{tools: [%{"name" => "find_actions"}]}}
      end
    ]

    assert {:ok, check} = IntegrationSetup.check_environment("ops", options)
    assert [%{status: :available}] = check.repositories
    assert check.emisar.status == :available
    assert check.emisar.detail =~ "permissions"

    assert {:ok, unavailable} =
             IntegrationSetup.check_environment("ops",
               github_repositories: fn -> {:error, :denied} end,
               emisar_probe: fn _pin -> {:error, :key_refused} end
             )

    assert [%{status: :unavailable}] = unavailable.repositories
    assert unavailable.emisar.status == :unavailable
    refute inspect(unavailable) =~ "key_refused"
  end
end
