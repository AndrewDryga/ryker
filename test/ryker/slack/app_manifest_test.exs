defmodule Ryker.Slack.AppManifestTest do
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

  test "the shipped Slack app can prove per-user Home visibility across all conversation kinds" do
    scopes = bot_scopes!()

    for scope <- ~w(channels:read groups:read im:read mpim:read) do
      assert scope in scopes
    end
  end

  # The manifest is the product's Slack identity. On 2026-09-13 it still named the
  # app Emisar (the infrastructure provider, not the product) while the code
  # posted pre-rename controls; this pins the registered identity to Ryker so
  # the name operators see, the command they type and the shortcut callback the
  # gateway decodes cannot drift apart again.
  test "the shipped Slack app is registered as Ryker with the commands the gateway decodes" do
    {:ok, manifest} = @manifest_path |> File.read!() |> YamlElixir.read_from_string()

    assert get_in(manifest, ["display_information", "name"]) == "Ryker"
    assert get_in(manifest, ["features", "bot_user", "display_name"]) == "Ryker"
    assert get_in(manifest, ["display_information", "background_color"]) == "#111315"
    assert [%{"command" => "/ryker"}] = get_in(manifest, ["features", "slash_commands"])

    assert [%{"callback_id" => "ryker_investigate_message"}] =
             get_in(manifest, ["features", "shortcuts"])

    refute get_in(manifest, ["display_information", "long_description"]) =~ "responder"
    assert get_in(manifest, ["display_information", "long_description"]) =~ "through Emisar"
  end

  defp bot_scopes! do
    {:ok, manifest} = @manifest_path |> File.read!() |> YamlElixir.read_from_string()
    get_in(manifest, ["oauth_config", "scopes", "bot"])
  end
end
