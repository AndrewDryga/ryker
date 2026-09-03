defmodule Responder.Slack.AppManifestTest do
  use ExUnit.Case, async: true

  @manifest_path "deploy/slack-app-manifest.yaml"

  test "the shipped Slack app can list configured channel bookmarks" do
    # Both production apps returned missing_scope when the bookmark capability was
    # exercised, leaving a model-visible tool that could never succeed.
    assert "bookmarks:read" in bot_scopes!()
  end

  test "the shipped Slack app can observe passive emoji feedback on its replies" do
    {:ok, manifest} = @manifest_path |> File.read!() |> YamlElixir.read_from_string()

    assert "reactions:read" in bot_scopes!()

    events = get_in(manifest, ["settings", "event_subscriptions", "bot_events"])
    assert "reaction_added" in events
    assert "reaction_removed" in events
  end

  defp bot_scopes! do
    {:ok, manifest} = @manifest_path |> File.read!() |> YamlElixir.read_from_string()
    get_in(manifest, ["oauth_config", "scopes", "bot"])
  end
end
