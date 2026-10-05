defmodule Ryker.ControlPlane.SettingsWorkerJobsLiveTest do
  use Ryker.DataCase, async: false

  import Ryker.TestHelpers, only: [digest: 1]

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection, SettingsCommands, SettingsView}
  alias Ryker.CoopFleet.Worker
  alias Ryker.Settings

  @endpoint Endpoint
  @actor "control-plane:local"

  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub,
       live_view: [signing_salt: "settings-worker-jobs-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    {:ok, _snapshot} = Settings.initialize(@actor)
    :ok
  end

  test "workers need no policy advertisements to appear in the install selector" do
    enroll!("first", "fleet-main", :eligible)
    enroll!("second", "fleet-main", :busy)
    enroll!("revoked", "retired", :revoked)

    assert {:ok, %{worker_installs: [%{ref: "fleet-main", workers: 2, eligible: 1}]}} =
             SettingsView.fetch()

    {:ok, view, _html} = live(build_conn() |> Map.put(:host, "localhost"), "/settings/advanced")
    assert has_element?(view, "#settings-work-workspace_ref option[value=fleet-main]")
    refute has_element?(view, "#settings-work-workspace_ref option[value=retired]")
    refute has_element?(view, "#settings-policies")
  end

  test "retired policy forms cannot mutate settings through direct events" do
    revision = Settings.fetch!().installation.revision

    assert {:error, {:invalid_settings, [{:section, :unknown}]}} =
             SettingsCommands.put_item(:policies, %{"policy_name" => "anything"}, revision)

    assert {:error, {:invalid_settings, [{:section, :unknown}]}} =
             SettingsCommands.delete_item(:policies, "anything", revision)

    assert Settings.fetch!().installation.revision == revision
  end

  defp enroll!(id, workspace, state) do
    Repo.insert!(%Worker{
      id: id,
      certificate_sha256: digest(id),
      last_seen_at: DateTime.utc_now(),
      revoked_at: if(state == :revoked, do: DateTime.utc_now()),
      revoked_by: if(state == :revoked, do: @actor),
      state: state,
      workspace_ref: workspace
    })
  end
end
