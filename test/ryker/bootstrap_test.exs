defmodule Ryker.BootstrapTest do
  use ExUnit.Case, async: true

  alias Ryker.Bootstrap

  @database "ecto://ryker:database-secret@localhost/ryker"

  test "a database-only bootstrap does not invent integrations, identities or keys" do
    settings = Bootstrap.load!(environment())

    assert settings.repo == [url: @database, pool_size: 10]
    assert settings.control_plane == %{ip: {127, 0, 0, 1}, port: 4321}
    assert settings.state_tools == %{ip: {127, 0, 0, 1}, port: 4318}
    assert settings.storage_root == "/var/lib/ryker"
    assert settings.worker_gateway == nil
    assert settings.github_app_id == nil
    assert settings.webhook_secret_names == []
    assert settings.log_level == :info
    refute Map.has_key?(settings, :host_ref)
    refute Map.has_key?(settings, :checkpoint_key)
    refute Map.has_key?(settings, :slack_enabled)
    refute inspect(settings) =~ "database-secret"
    assert settings == Bootstrap.load!(environment())
  end

  test "explicit bootstrap overrides are bounded and do not become product settings" do
    settings =
      Bootstrap.load!(
        environment(%{
          "POOL_SIZE" => "7",
          "RYKER_CONTROL_IP" => "::1",
          "RYKER_CONTROL_PORT" => "54321",
          "RYKER_STATE_DIR" => "/srv/ryker",
          "GITHUB_APP_ID" => "123",
          "GITHUB_API_URL" => "https://github.example/api/v3",
          "EMISAR_RPC_URL" => "https://emisar.example/private/rpc",
          "LOG_LEVEL" => "warning",
          "RYKER_WORK_CONCURRENCY" => "999",
          "RYKER_SLACK_ENABLED" => "true"
        })
      )

    assert settings.repo[:pool_size] == 7
    assert settings.control_plane == %{ip: {0, 0, 0, 0, 0, 0, 0, 1}, port: 54_321}
    assert settings.storage_root == "/srv/ryker"
    assert settings.github_app_id == 123
    assert settings.github_api_url == "https://github.example/api/v3"
    assert settings.emisar_rpc_url == "https://emisar.example/private/rpc"
    assert settings.log_level == :warning
    refute Map.has_key?(settings, :work)
    refute Map.has_key?(settings, :slack_enabled)
  end

  test "invalid explicit bootstrap inputs identify the variable without echoing its value" do
    invalid = [
      {"DATABASE_URL", ""},
      {"DATABASE_URL", "postgres://private-secret@example/"},
      {"POOL_SIZE", "0"},
      {"POOL_SIZE", "20junk"},
      {"RYKER_CONTROL_IP", "0.0.0.0"},
      {"RYKER_CONTROL_PORT", "65536"},
      {"RYKER_STATE_TOOLS_IP", "192.0.2.1"},
      {"RYKER_STATE_DIR", "relative/private-secret"},
      {"GITHUB_APP_ID", "-5"},
      {"GITHUB_API_URL", "https://private-secret@example.com/api/v3"},
      {"EMISAR_RPC_URL", "https://example.com/rpc?token=private-secret"},
      {"EMISAR_RPC_URL", "http://example.com/rpc"},
      {"LOG_LEVEL", "private-secret"}
    ]

    for {name, value} <- invalid do
      error = assert_raise ArgumentError, fn -> Bootstrap.load!(environment(%{name => value})) end
      assert error.message =~ name
      refute error.message =~ "private-secret"
    end

    assert_raise ArgumentError, ~r/DATABASE_URL/, fn -> Bootstrap.load!(&Map.fetch(%{}, &1)) end
  end

  test "worker TLS configuration is explicit and cannot partially enable a listener" do
    transport = %{
      "RYKER_WORKER_PUBLIC_URL" => "https://ryker.example:4322",
      "RYKER_WORKER_CA_FILE" => "/run/credentials/ca.pem",
      "RYKER_WORKER_CA_KEY_FILE" => "/run/credentials/ca-key.pem",
      "RYKER_WORKER_CERT_FILE" => "/run/credentials/server.pem",
      "RYKER_WORKER_KEY_FILE" => "/run/credentials/server-key.pem"
    }

    settings = Bootstrap.load!(environment(transport))
    assert settings.worker_gateway.public_url == "https://ryker.example:4322"
    assert settings.worker_gateway.cacertfile == transport["RYKER_WORKER_CA_FILE"]
    assert settings.worker_gateway.port == 4322
    refute Map.has_key?(settings.worker_gateway, :checkpoint_key)

    assert_raise ArgumentError, ~r/RYKER_WORKER_CA_KEY_FILE/, fn ->
      transport
      |> Map.delete("RYKER_WORKER_CA_KEY_FILE")
      |> environment()
      |> Bootstrap.load!()
    end

    assert_raise ArgumentError, ~r/RYKER_WORKER_PUBLIC_URL/, fn ->
      transport
      |> Map.put("RYKER_WORKER_PUBLIC_URL", "https://example.com/not-an-origin")
      |> environment()
      |> Bootstrap.load!()
    end
  end

  test "token providers read the exact fixed credential lazily and never enumerate the environment" do
    parent = self()
    settings = Bootstrap.load!(environment())

    provider =
      Bootstrap.token_provider(:slack_bot, fn name ->
        send(parent, {:credential_read, name})
        {:ok, "slack-token"}
      end)

    refute_received {:credential_read, _}
    assert provider.() == {:ok, "slack-token"}
    assert_received {:credential_read, "SLACK_BOT_TOKEN"}
    assert provider.() == {:ok, "slack-token"}
    assert_received {:credential_read, "SLACK_BOT_TOKEN"}
    assert settings.worker_gateway == nil

    missing = Bootstrap.token_provider(:slack_bot, fn _ -> :error end)
    assert missing.() == {:error, {:environment_variable_missing, "SLACK_BOT_TOKEN"}}
    malformed = Bootstrap.token_provider(:slack_bot, fn _ -> {:ok, ""} end)
    assert malformed.() == {:error, {:invalid_environment_secret, "SLACK_BOT_TOKEN"}}
  end

  test "checkpoint custody preserves the injected key and never generates a replacement" do
    key = :binary.copy(<<42>>, 32)
    env = environment(%{"RYKER_CHECKPOINT_KEY" => Base.encode64(key)})
    assert Bootstrap.checkpoint_key!(env) == key
    assert Bootstrap.checkpoint_key!(env) == key

    for value <- [nil, "", Base.encode64("short"), "private-secret"] do
      env = if value, do: environment(%{"RYKER_CHECKPOINT_KEY" => value}), else: environment()
      error = assert_raise ArgumentError, fn -> Bootstrap.checkpoint_key!(env) end
      assert error.message =~ "RYKER_CHECKPOINT_KEY"
      refute error.message =~ "private-secret"
    end
  end

  test "custom webhook credentials require exact deployment registration" do
    env =
      environment(%{
        "RYKER_WEBHOOK_SECRET_NAMES" => "ALERTS_SIGNING_KEY,DEPLOY_SIGNING_KEY",
        "ALERTS_SIGNING_KEY" => "alerts-signing-secret",
        "DEPLOY_SIGNING_KEY" => "deploy-signing-secret",
        "UNREGISTERED_SECRET" => "must-not-read-this-secret"
      })

    settings = Bootstrap.load!(env)
    assert settings.webhook_secret_names == ["ALERTS_SIGNING_KEY", "DEPLOY_SIGNING_KEY"]

    assert Bootstrap.webhook_secret!(settings, "ALERTS_SIGNING_KEY", env) ==
             "alerts-signing-secret"

    assert_raise ArgumentError, ~r/not registered/, fn ->
      Bootstrap.webhook_secret!(settings, "UNREGISTERED_SECRET", fn _ ->
        flunk("must not read")
      end)
    end

    for names <- ["", "A,A", "A,,B", "DATABASE_URL", "bad-name"] do
      assert_raise ArgumentError, ~r/RYKER_WEBHOOK_SECRET_NAMES/, fn ->
        Bootstrap.load!(environment(%{"RYKER_WEBHOOK_SECRET_NAMES" => names}))
      end
    end
  end

  test "secret scanning only includes configured service credentials and registered source secrets" do
    env =
      environment(%{
        "SLACK_BOT_TOKEN" => "configured-slack-token",
        "RYKER_WEBHOOK_SECRET_NAMES" => "ALERTS_SIGNING_KEY",
        "ALERTS_SIGNING_KEY" => "configured-alerts-key",
        "UNRELATED_PRIVATE_KEY" => "not-application-custody"
      })

    settings = Bootstrap.load!(env)

    assert Bootstrap.scan_secrets!(settings, env) == [
             "configured-slack-token",
             "configured-alerts-key"
           ]
  end

  defp environment(extra \\ %{}) do
    values = Map.put(extra, "DATABASE_URL", Map.get(extra, "DATABASE_URL", @database))
    &Map.fetch(values, &1)
  end
end
