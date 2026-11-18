defmodule Ryker.Settings.IssueTriageTest do
  use Ryker.DataCase, async: false
  alias Ryker.Settings

  test "triage and label permission are separate and scoped to one repository" do
    actor = "control-plane:local"
    {:ok, settings} = Settings.initialize(actor)

    {:ok, settings} =
      Settings.put_repository(
        %{ref: "widget", github_repository: "acme/widget"},
        settings.installation.revision,
        actor
      )

    {:ok, settings} =
      Settings.put_repository(
        %{ref: "other", github_repository: "acme/other"},
        settings.installation.revision,
        actor
      )

    assert Enum.all?(
             settings.repositories,
             &(not &1.github_issue_triage and not &1.github_triage_labels)
           )

    {:ok, settings} =
      Settings.put_repository(
        %{ref: "widget", github_issue_triage: true},
        settings.installation.revision,
        actor
      )

    widget = Enum.find(settings.repositories, &(&1.ref == "widget"))
    assert widget.github_issue_triage
    refute widget.github_triage_labels

    {:ok, settings} =
      Settings.put_repository(
        %{ref: "widget", github_triage_labels: true},
        settings.installation.revision,
        actor
      )

    {:ok, settings} =
      Settings.put_repository(
        %{ref: "widget", github_issue_triage: false},
        settings.installation.revision,
        actor
      )

    widget = Enum.find(settings.repositories, &(&1.ref == "widget"))
    refute widget.github_issue_triage
    assert widget.github_triage_labels
    other = Enum.find(settings.repositories, &(&1.ref == "other"))
    refute other.github_issue_triage
    refute other.github_triage_labels
  end
end
