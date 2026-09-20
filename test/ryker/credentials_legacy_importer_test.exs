defmodule Ryker.Credentials.LegacyImporterTest do
  use Ryker.DataCase, async: false

  alias Ryker.Credentials
  alias Ryker.Credentials.LegacyImporter
  alias Ryker.Settings

  @actor "control-plane:local"

  setup do
    {:ok, _snapshot} = Settings.initialize(@actor)
    :ok
  end

  test "explicit import moves legacy credentials and endpoint metadata exactly once" do
    environment = %{
      "EMISAR_API_TOKEN" => "legacy-emisar-token-long-enough",
      "EMISAR_RPC_URL" => "https://emisar.example/api/mcp/rpc",
      "GITHUB_APP_ID" => "1234",
      "GITHUB_API_URL" => "https://github.example/api/v3",
      "GITHUB_WEBHOOK_SECRET" => "legacy-webhook-secret-long-enough",
      "RYKER_WEBHOOK_SECRET_NAMES" => "ALERTS_SIGNING_KEY",
      "ALERTS_SIGNING_KEY" => "legacy-alerts-secret-long-enough",
      "SLACK_APP_TOKEN" => "xapp-legacy-token-long-enough",
      "SLACK_BOT_TOKEN" => "xoxb-legacy-token-long-enough"
    }

    env = &Map.fetch(environment, &1)

    assert {:ok, first} = LegacyImporter.run(env)
    assert first.conflicts == []

    assert first.invalid == [
             %{name: "EMISAR_API_TOKEN", reason: :verified_account_reconnect_required}
           ]

    assert "SLACK_BOT_TOKEN" in first.imported
    refute "EMISAR_RPC_URL" in first.imported
    assert {:ok, "xoxb-legacy-token-long-enough"} = Credentials.fetch(:slack_bot, "primary")

    assert {:ok, "legacy-alerts-secret-long-enough"} =
             Credentials.fetch(:webhook, "alerts_signing_key")

    refute inspect(Settings.fetch!()) =~ "legacy-emisar-token"

    assert {:ok, second} = LegacyImporter.run(env)
    assert second.imported == []
    assert second.conflicts == []

    assert second.invalid == [
             %{name: "EMISAR_API_TOKEN", reason: :verified_account_reconnect_required}
           ]

    assert "SLACK_BOT_TOKEN" in second.present
    refute "EMISAR_RPC_URL" in second.present
  end

  test "a different existing credential is a conflict and is never replaced" do
    assert {:ok, _metadata} =
             Credentials.put(:slack_bot, "primary", "current-token-long-enough", @actor)

    env = fn
      "SLACK_BOT_TOKEN" -> {:ok, "different-token-long-enough"}
      _name -> :error
    end

    assert {:ok, result} = LegacyImporter.run(env)
    assert result.conflicts == ["SLACK_BOT_TOKEN"]
    assert {:ok, "current-token-long-enough"} = Credentials.fetch(:slack_bot, "primary")
  end
end
