defmodule Ryker.GitHub.TaskAccessTest do
  use Ryker.DataCase, async: false
  alias Ryker.GitHub.{Binding, TaskAccess}
  alias Ryker.Ingress
  alias Ryker.Settings

  setup do
    {:ok, settings} = Settings.initialize("control-plane:local")

    {:ok, settings} =
      Settings.save_github(
        %{enabled: true, app_id: 12_345, app_slug: "ryker-test"},
        settings.installation.revision,
        "control-plane:local"
      )

    {:ok, binding} =
      Binding.new(
        name: "widget",
        repository_full_name: "acme/widget",
        repository_id: 99,
        installation_id: 41,
        ryker_actor_id: 4321
      )

    payload = %{
      "action" => "edited",
      "installation" => %{"id" => 41},
      "repository" => %{"id" => 99, "full_name" => "acme/widget"},
      "sender" => %{"id" => 7, "login" => "writer", "type" => "User"},
      "comment" => %{"body" => "Make a new PR to fix that"}
    }

    entry = %Ingress.Inbox.Entry{
      execution_mode: :live,
      source_kind: "github",
      source_ref: "widget",
      destination_transport: "github",
      actor_kind: :user,
      actor_ref: "github-user:7",
      content: %{"event_name" => "pull_request_review_comment", "payload" => payload}
    }

    policy = %{
      name: "widget-contributor",
      digest: String.duplicate("a", 64),
      repository_ref: "widget"
    }

    options = %{
      configuration: TaskAccess.authority_configuration(settings),
      bindings: %{"widget" => %{binding: binding, repository: "widget", policy: policy}},
      repository_access: fn ^binding, ^payload -> :ok end
    }

    %{entry: entry, options: options, policy: policy}
  end

  # A real authenticated review reply asked for a new PR; Work reached Prepare
  # a task three times, but runtime authorized only Slack and Chat (2026-11-06).
  test "a current human GitHub instruction can start its repository task", %{
    entry: entry,
    options: options,
    policy: policy
  } do
    assert TaskAccess.authorize(entry, "widget", options) == {:ok, policy}
  end

  test "removed write access and provider failures cannot start a task", %{
    entry: entry,
    options: options
  } do
    for reason <- [:actor_not_authorized, {:github_repository_access_unavailable, :timeout}] do
      changed = %{options | repository_access: fn _, _ -> {:error, reason} end}
      assert TaskAccess.authorize(entry, "widget", changed) == {:error, reason}
    end
  end

  test "another repository, actor or installation cannot inherit the request", %{
    entry: entry,
    options: options
  } do
    assert TaskAccess.authorize(entry, "other", options) ==
             {:error, :task_instruction_not_authorized}

    for changed <- [
          %{entry | actor_kind: :bot},
          %{entry | actor_ref: "github-user:8"},
          %{entry | execution_mode: :evaluation},
          put_in(entry.content["payload"]["installation"]["id"], 42)
        ] do
      assert TaskAccess.authorize(changed, "widget", options) ==
               {:error, :task_instruction_not_authorized}
    end
  end

  test "changed repository authority refuses the old runtime grant", %{
    entry: entry,
    options: options
  } do
    {:ok, _settings} =
      Settings.put_repository(
        %{ref: "new", github_repository: "acme/new"},
        Settings.fetch!().installation.revision,
        "control-plane:local"
      )

    assert TaskAccess.authorize(entry, "widget", options) ==
             {:error, :task_instruction_not_authorized}
  end
end
