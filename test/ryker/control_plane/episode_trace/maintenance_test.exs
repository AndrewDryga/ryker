defmodule Ryker.ControlPlane.EpisodeTrace.MaintenanceTest do
  use Ryker.DataCase, async: false
  alias Ryker.ControlPlane.EpisodeTrace.Maintenance
  alias Ryker.Settings
  alias Ryker.Work.Session

  test "cleanup explains a verified removal once and keeps timestamps in its evidence" do
    session = cleanup_session(:discarded, %{"dirty" => false, "unmerged" => false})
    assert [step] = Maintenance.steps([session])

    assert step.summary ==
             "The worker session was closed and the temporary working copy was removed after checking it held no uncommitted changes and no unmerged commits."

    assert Enum.any?(step.details, &(&1.label == "Closed"))
    assert Enum.any?(step.details, &(&1.label == "Cleanup finished"))
  end

  test "protected changes name their recorded branch without a second story" do
    session =
      cleanup_session(:retained, %{
        "dirty" => true,
        "unmerged" => false,
        "branch" => "fix/readiness"
      })

    session = %{session | retained_reason: "dirty"}
    assert [step] = Maintenance.steps([session])

    assert step.summary ==
             "The working copy cannot be removed because it has uncommitted changes on branch fix/readiness."
  end

  test "a cleanup retry leads with its recorded error and scheduled time" do
    session = %{
      cleanup_session(:discard_pending, %{})
      | cleanup_last_error_code: "coop_worker_command_timeout",
        cleanup_next_attempt_at: ~U[2026-10-11 12:05:00.000000Z],
        cleanup_attempt_count: 2
    }

    assert [step] = Maintenance.steps([session])

    assert step.summary ==
             "There was an error during cleanup: the worker did not answer in time. Retry is scheduled at 12:05 UTC."

    assert %{label: "Tries", value: "2"} in step.details
    assert Enum.any?(step.details, &(&1.label == "Step"))
  end

  # A read-only copy of an already published draft PR said its commits had
  # "never published" because Git only reported unmerged (manual QA, 2026-10-11).
  # Neither an unmerged flag nor acceptance of a removal plan proves publication.
  test "retained unmerged commits are not described as never published" do
    session = cleanup_session(:retained, %{"dirty" => false, "unmerged" => true})
    session = %{session | retained_reason: "unpublished_unmerged"}
    assert [step] = Maintenance.steps([session])
    assert step.summary =~ "unmerged commits"
    refute step.summary =~ "never published"
    refute step.summary =~ "until the work is published"
    assert %{label: "Unmerged commits", value: "Yes"} in step.details
  end

  test "a removal plan's accepted unmerged commits do not prove they were published" do
    session =
      cleanup_session(:discarded, %{
        "dirty" => false,
        "unmerged" => true,
        "accepted_unmerged" => true
      })

    assert [step] = Maintenance.steps([session])
    refute step.summary =~ "work was published"
    assert step.summary =~ "unmerged commits"
    assert %{label: "Unmerged commits", value: "Yes, accepted for removal"} in step.details
  end

  test "accepted dirty or incomplete cleanup evidence never claims a clean working copy" do
    for workspace <- [%{"dirty" => true, "unmerged" => true}, %{}] do
      assert [step] = Maintenance.steps([cleanup_session(:discarded, workspace)])
      refute step.summary =~ "no uncommitted changes"
      refute step.summary =~ "no unpublished commits"
    end

    assert [step] = Maintenance.steps([cleanup_session(:discarded, %{})])
    assert %{label: "Uncommitted changes", value: "Unknown"} in step.details
    assert %{label: "Unmerged commits", value: "Unknown"} in step.details
  end

  defp cleanup_session(status, workspace) do
    %Session{
      id: Ecto.UUID.generate(),
      generation: 1,
      coop_session_id: "coop-session-cleanup",
      cleanup_status: status,
      closed_at: ~U[2026-10-11 12:00:00.000000Z],
      discarded_at: ~U[2026-10-11 12:01:00.000000Z],
      updated_at: ~U[2026-10-11 12:01:00.000000Z],
      cleanup_receipt: %{"kind" => "discarded", "remote_state" => "discarded"},
      discard_plan: %{"workspace" => workspace}
    }
  end

  # The card a closed worker session leaves named its repository by its ref,
  # where every other page uses the name GitHub gives it (2026-10-04 review).
  test "a closed worker session names its repository the way GitHub does" do
    {:ok, snapshot} = Settings.initialize("control-plane:local")

    {:ok, _snapshot} =
      Settings.put_repository(
        %{ref: "acme-api", display_name: "acme/api", github_repository: "acme/api"},
        snapshot.installation.revision,
        "control-plane:local"
      )

    session = %Session{
      id: Ecto.UUID.generate(),
      generation: 1,
      coop_session_id: "coop-session-1",
      repository_ref: "acme-api",
      cleanup_status: :grace,
      closed_at: ~U[2026-10-06 09:00:00.000000Z],
      updated_at: ~U[2026-10-06 09:00:00.000000Z]
    }

    assert [step] = Maintenance.steps([session])
    assert step.summary =~ "Ryker closed acme/api's worker session"
    assert %{label: "Repository", value: "acme/api"} in step.details
  end
end
