defmodule Ryker.ControlPlane.SettingsPageTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.SettingsPage

  # "Install the App in another organization" always led to github.com, so an App on a GitHub
  # Enterprise server was sent to a page that does not know it (2026-10-04 review).
  test "the App is installed where its GitHub is" do
    assert SettingsPage.app_install_url("https://api.github.com", "ryker-app") ==
             "https://github.com/apps/ryker-app/installations/new"

    assert SettingsPage.app_install_url("https://github.example.com/api/v3", "ryker-app") ==
             "https://github.example.com/github-apps/ryker-app/installations/new"

    assert SettingsPage.app_install_url("https://github.example.com:8443/api/v3", "ryker-app") ==
             "https://github.example.com:8443/github-apps/ryker-app/installations/new"
  end
end
