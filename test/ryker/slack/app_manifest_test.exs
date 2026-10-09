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

  # Ryker read the event that says it was removed from a channel, but the app
  # never subscribed to it, so a removed Ryker still showed as in the channel
  # and kept posting there until Slack refused (2026-10-04 review).
  test "the shipped Slack app hears when Ryker joins or leaves a channel" do
    {:ok, manifest} = @manifest_path |> File.read!() |> YamlElixir.read_from_string()
    events = get_in(manifest, ["settings", "event_subscriptions", "bot_events"])

    assert "member_joined_channel" in events
    assert "member_left_channel" in events
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

  # The manifest asked for canvases:write, which nothing in Ryker uses: a
  # workspace admin approving the app granted it write access to canvases for
  # no reason (docs audit, 2026-09-26). The manifest asks for exactly the
  # scopes connecting Slack verifies, and that list holds none Ryker never uses.
  test "the shipped Slack app asks for exactly the scopes Ryker verifies and uses" do
    assert Enum.sort(bot_scopes!()) == Enum.sort(Ryker.IntegrationSetup.slack_scopes())
    refute "canvases:write" in bot_scopes!()
  end

  defp bot_scopes! do
    {:ok, manifest} = @manifest_path |> File.read!() |> YamlElixir.read_from_string()
    get_in(manifest, ["oauth_config", "scopes", "bot"])
  end

  # The Messages tab's "Production health" posted, in the person's own name,
  # "Reconcile our declared production topology with fresh live evidence and
  # report healthy, degraded, and unverified layers." (Slack as Andrew,
  # 2026-10-09). A suggested prompt is what a person would ask.
  test "suggested prompts read as questions a person would ask" do
    {:ok, manifest} = @manifest_path |> File.read!() |> YamlElixir.read_from_string()
    agent = get_in(manifest, ["features", "agent_view"])

    for %{"message" => message} <- agent["suggested_prompts"] do
      assert message =~ "?"
      refute message =~ ~r/topology|reconcile|operator decision/i
    end

    refute agent["agent_description"] =~ ~r/topology|host-validated/i
  end
end
