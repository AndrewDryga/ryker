defmodule Ryker.BootstrapTest do
  use ExUnit.Case, async: true

  alias Ryker.Bootstrap

  @database "ecto://ryker:database-secret@localhost/ryker"

  test "bootstrap contains host topology and root custody, never integration settings" do
    settings = Bootstrap.load!(environment())

    assert settings.repo == [url: @database, pool_size: 10]
    assert settings.control_plane == %{access: :loopback, ip: {127, 0, 0, 1}, port: 4321}
    assert settings.state_tools == %{ip: {127, 0, 0, 1}, port: 4318}
    assert settings.storage_root == "/var/lib/ryker"
    assert settings.worker_gateway == nil
    assert settings.github_public_url == "http://127.0.0.1:4319/v1/github"
    assert settings.webhook_public_url == "http://127.0.0.1:4320"
    assert byte_size(settings.credential_key) == 32
    assert settings.log_level == :info
    refute Map.has_key?(settings, :host_ref)
    refute Map.has_key?(settings, :checkpoint_key)
    refute Map.has_key?(settings, :slack_enabled)
    refute inspect(settings) =~ "database-secret"
    assert settings == Bootstrap.load!(environment())
  end

  test "explicit host overrides are bounded and retired integration variables are ignored" do
    settings =
      Bootstrap.load!(
        environment(%{
          "POOL_SIZE" => "7",
          "RYKER_CONTROL_IP" => "::1",
          "RYKER_CONTROL_PORT" => "54321",
          "RYKER_STATE_DIR" => "/srv/ryker",
          "RYKER_GITHUB_PUBLIC_URL" => "https://ryker.example/hooks/github",
          "RYKER_WEBHOOK_PUBLIC_URL" => "https://ryker.example/hooks",
          "GITHUB_APP_ID" => "123",
          "SLACK_BOT_TOKEN" => "retired-and-ignored",
          "LOG_LEVEL" => "warning",
          "RYKER_WORK_CONCURRENCY" => "999",
          "RYKER_SLACK_ENABLED" => "true"
        })
      )

    assert settings.repo[:pool_size] == 7

    assert settings.control_plane == %{
             access: :loopback,
             ip: {0, 0, 0, 0, 0, 0, 0, 1},
             port: 54_321
           }

    assert settings.storage_root == "/srv/ryker"
    assert settings.github_public_url == "https://ryker.example/hooks/github"
    assert settings.webhook_public_url == "https://ryker.example/hooks"
    assert settings.log_level == :warning
    refute Map.has_key?(settings, :work)
    refute Map.has_key?(settings, :slack_enabled)
  end

  test "container topology binds the control plane to its network interface explicitly" do
    settings =
      Bootstrap.load!(
        environment(%{
          "RYKER_CONTAINER" => "true",
          "RYKER_CONTROL_IP" => "0.0.0.0"
        })
      )

    assert settings.control_plane == %{access: :network, ip: {0, 0, 0, 0}, port: 4321}
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
      {"RYKER_GITHUB_PUBLIC_URL", "https://private-secret@example.com/hooks"},
      {"RYKER_WEBHOOK_PUBLIC_URL", "http://example.com/private-secret"},
      {"RYKER_CREDENTIAL_KEY", "private-secret"},
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

  test "a worker listener address alone cannot half-enable the gateway" do
    # RYKER_WORKER_IP or RYKER_WORKER_PORT without the public URL and the four
    # TLS files used to validate cleanly and then be dropped on the floor: the
    # gateway simply did not start, and the only sign was Work reporting the
    # gateway unavailable much later. A listener the operator addressed is a
    # listener they meant to run.
    for {name, value} <- [{"RYKER_WORKER_IP", "0.0.0.0"}, {"RYKER_WORKER_PORT", "4323"}] do
      error = assert_raise ArgumentError, fn -> Bootstrap.load!(environment(%{name => value})) end
      assert error.message =~ ~r/RYKER_WORKER_.* is required/
    end
  end

  test "machine credentials reject surrounding whitespace" do
    for value <- ["state-tools-token\n", " state-tools-token", "state-tools-token \t"] do
      assert_raise ArgumentError, ~r/RYKER_STATE_TOOLS_TOKEN/, fn ->
        Bootstrap.secret!(:state_tools, environment(%{"RYKER_STATE_TOOLS_TOKEN" => value}))
      end
    end
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

  test "secret scanning contains only machine credentials and ignores retired integration values" do
    env =
      environment(%{
        "RYKER_CHECKPOINT_KEY" => "checkpoint-key-material",
        "RYKER_STATE_TOOLS_TOKEN" => "state-tools-token-material",
        "SLACK_BOT_TOKEN" => "retired-slack-token",
        "UNRELATED_PRIVATE_KEY" => "not-application-custody"
      })

    settings = Bootstrap.load!(env)

    assert Bootstrap.scan_secrets!(settings, env) == [
             "checkpoint-key-material",
             "state-tools-token-material"
           ]
  end

  defp environment(extra \\ %{}) do
    values =
      extra
      |> Map.put_new("DATABASE_URL", @database)
      |> Map.put_new("RYKER_CREDENTIAL_KEY", Base.encode64(:binary.copy(<<7>>, 32)))

    &Map.fetch(values, &1)
  end
end
