defmodule Ryker.ControlPlane.RepositorySettingsEditorTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.RepositorySettingsEditor

  @repository %{
    ref: "acme-api",
    github_issue_actions: false,
    github_issue_actions_ready: false,
    github_issue_triage: false,
    github_triage_labels: false,
    github_ci_repair: :off,
    settings_revision: 1
  }

  # Review of the 2026-11-19 production form repair: the save's conflict
  # already contains the latest values. Waiting for a parent redraw let
  # "Use saved settings" restore the old choices and repeat the conflict.
  test "conflict recovery uses the current saved choices before any parent refresh" do
    current = %{@repository | github_triage_labels: true, settings_revision: 2}
    snapshot = %{installation: %{revision: 2}, repositories: [current]}
    socket = editor(fn _, _ -> {:error, {:settings_conflict, snapshot}} end)

    {:noreply, socket} =
      RepositorySettingsEditor.handle_event(
        "save",
        %{"enabled" => "true", "labels" => "false"},
        socket
      )

    assert socket.assigns.draft == %{"enabled" => "true", "labels" => "false"}
    assert socket.assigns.conflict
    {:noreply, socket} = RepositorySettingsEditor.handle_event("reset", %{}, socket)
    assert socket.assigns.draft == %{"enabled" => "false", "labels" => "true"}
    assert socket.assigns.expected_revision == 2
    refute socket.assigns.dirty
    refute socket.assigns.conflict
  end

  test "a repository removed during a save cannot be reset into an editable form" do
    snapshot = %{installation: %{revision: 2}, repositories: []}
    socket = editor(fn _, _ -> {:error, {:settings_conflict, snapshot}} end)

    {:noreply, socket} =
      RepositorySettingsEditor.handle_event(
        "save",
        %{"enabled" => "true", "labels" => "false"},
        socket
      )

    assert socket.assigns.error ==
             "This repository is no longer added. Your choices have not been saved."

    {:noreply, reset} = RepositorySettingsEditor.handle_event("reset", %{}, socket)
    assert reset.assigns.conflict
    assert reset.assigns.draft == socket.assigns.draft
    refute is_map(reset.assigns.current_values)
  end

  test "saving tells the parent to refresh while keeping the result in the section" do
    current = %{@repository | github_issue_triage: true, settings_revision: 2}
    snapshot = %{installation: %{revision: 2}, repositories: [current]}
    socket = editor(fn _, _ -> {:ok, snapshot} end)

    {:noreply, socket} =
      RepositorySettingsEditor.handle_event(
        "save",
        %{"enabled" => "true", "labels" => "false"},
        socket
      )

    assert_receive :repository_settings_saved
    assert socket.assigns.saved
    refute socket.assigns.dirty
    assert socket.assigns.expected_revision == 2
    assert socket.assigns.draft == %{"enabled" => "true", "labels" => "false"}
  end

  defp editor(save) do
    assigns = %{
      id: "repository-issue-triage-acme-api",
      card_id: "repository-issue-triage",
      section: :issue_triage,
      repository: @repository,
      ref: "acme-api",
      save: save
    }

    {:ok, socket} =
      RepositorySettingsEditor.update(
        assigns,
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      )

    socket
  end
end
