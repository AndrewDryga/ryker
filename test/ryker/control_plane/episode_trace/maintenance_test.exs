defmodule Ryker.ControlPlane.EpisodeTrace.MaintenanceTest do
  use Ryker.DataCase, async: true

  alias Ryker.ControlPlane.EpisodeTrace.Maintenance
  alias Ryker.Settings
  alias Ryker.Work.Session

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
