defmodule Ryker.Slack.AppManifest do
  @moduledoc """
  The Slack app manifest Ryker ships (`priv/slack/app-manifest.yaml`): the
  app and its bot, the `/ryker` command, the message shortcut, the Agent view,
  every bot scope connecting Slack verifies (`Ryker.IntegrationSetup.slack_scopes/0`)
  and every event the gateway reads, all over Socket Mode. Integrations › Slack
  shows it to copy while someone creates the app.
  """

  @path Path.expand("../../../priv/slack/app-manifest.yaml", __DIR__)
  @external_resource @path
  @text File.read!(@path)

  @doc "The manifest as Slack's Create New App › From a manifest takes it, in YAML."
  @spec text() :: String.t()
  def text, do: @text

  @doc """
  The address that opens Slack's Create New App with this manifest filled in,
  as Slack documents it ("Sharing manifests": `new_app=1&manifest_yaml=`, the
  YAML URL-encoded).
  """
  @spec create_url() :: String.t()
  def create_url do
    "https://api.slack.com/apps?new_app=1&manifest_yaml=" <>
      URI.encode(@text, &URI.char_unreserved?/1)
  end
end
