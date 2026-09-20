defmodule Ryker.ControlPlane.SettingsPoliciesLiveTest do
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.CoopFleet.Worker
  alias Ryker.Settings

  @endpoint Endpoint
  @actor "control-plane:local"
  @authority String.duplicate("a", 64)
  @standard String.duplicate("b", 64)
  @contributor String.duplicate("c", 64)
  @rotated String.duplicate("d", 64)
  @workspace "fleet-main"

  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.ControlPlane.PubSub,
       live_view: [signing_salt: "settings-policies-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    :ok
  end

  test "a policy pin is copied from the fleet advertisement, never typed into the form" do
    installation!()
    enroll!("worker-one", %{"standard-v1" => @standard, "contributor-v1" => @contributor})
    {:ok, view, _html} = open()

    assert has_element?(
             view,
             "#settings-policies > button.settings-editor-add",
             "+ Add execution policy"
           )

    view |> element("#settings-policies > button.settings-editor-add") |> render_click()

    refute has_element?(view, "input[name=policy_digest]")
    assert has_element?(view, "#settings-policies-policy_name option[value='standard-v1']")

    bind!(view, "conversational", "standard-v1")

    assert [binding] = Settings.fetch!().policy_bindings
    assert binding.policy_name == "standard-v1"
    assert binding.policy_digest == @standard
    assert binding.authority_digest == @authority
    assert binding.verified_by == :worker
    assert binding.verified_worker_ref == "worker-one"

    assert has_element?(
             view,
             ".settings-row-status[data-tone=verified]",
             "advertised by 1 worker"
           )
  end

  test "a policy the fleet stopped advertising is unavailable and is never repointed" do
    # Repointing the pin at whatever the fleet advertises now would silently
    # change the authority an already-running session was admitted under.
    installation!()
    worker = enroll!("worker-one", %{"standard-v1" => @standard})
    {:ok, view, _html} = open()
    bind!(view, "conversational", "standard-v1")

    worker
    |> Ecto.Changeset.change(policy_digests: %{"standard-v1" => @rotated})
    |> Repo.update!()

    {:ok, rotated_view, _html} = open()

    assert has_element?(rotated_view, ".settings-row-status[data-tone=changed]")
    assert [%{policy_digest: @standard}] = Settings.fetch!().policy_bindings

    worker |> Ecto.Changeset.change(policy_digests: %{}) |> Repo.update!()
    {:ok, withdrawn_view, _html} = open()

    assert has_element?(
             withdrawn_view,
             ".settings-row-status[data-tone=unavailable]",
             "no enrolled worker advertises"
           )

    assert [%{policy_digest: @standard}] = Settings.fetch!().policy_bindings
  end

  test "a policy no worker advertises cannot be bound, form or no form" do
    # The select only offers advertised names, but a socket message is not a
    # form: the refusal has to live on the write path, not in the markup.
    installation!()
    enroll!("worker-one", %{"standard-v1" => @standard})
    revision = Settings.fetch!().installation.revision

    assert {:error, {:invalid_settings, [{:policy_name, :policy_unavailable}]}} =
             Actions.callbacks().put_settings_item.(
               :policies,
               %{
                 "purpose" => "conversational",
                 "scope_kind" => "repository",
                 "scope_ref" => "emisar",
                 "policy_name" => "privileged-v9"
               },
               revision
             )

    assert Settings.fetch!().policy_bindings == []
    assert Settings.fetch!().installation.revision == revision
  end

  test "revoking a worker withdraws exactly the advertisements it made" do
    installation!()
    revoked = enroll!("worker-one", %{"standard-v1" => @standard})
    enroll!("worker-two", %{"contributor-v1" => @contributor})

    revoked
    |> Ecto.Changeset.change(state: :revoked, revoked_at: DateTime.utc_now(), revoked_by: @actor)
    |> Repo.update!()

    {:ok, view, _html} = open()

    view |> element("#settings-policies > button.settings-editor-add") |> render_click()

    refute has_element?(view, "#settings-policies-policy_name option[value='standard-v1']")
    assert has_element?(view, "#settings-policies-policy_name option[value='contributor-v1']")
  end

  defp open, do: live(build_conn() |> Map.put(:host, "localhost"), "/settings/system")

  defp bind!(view, purpose, policy_name) do
    if has_element?(view, "#settings-policies > button.settings-editor-add") do
      view |> element("#settings-policies > button.settings-editor-add") |> render_click()
    end

    view
    |> form("#settings-policies-form", %{
      "purpose" => purpose,
      "scope_kind" => "repository",
      "scope_ref" => "emisar",
      "policy_name" => policy_name
    })
    |> render_submit()
  end

  # One enrolled workspace, one repository and the workspace selection that
  # makes the fleet's advertisements the ones this installation can choose from.
  defp installation! do
    {:ok, %{installation: %{revision: revision}}} = Settings.initialize(@actor)

    {:ok, %{installation: %{revision: revision}}} =
      Settings.put_repository(%{ref: "emisar", base_branch: "main"}, revision, @actor)

    {:ok, snapshot} = Settings.save_work(%{workspace_ref: @workspace}, revision, @actor)
    snapshot
  end

  defp enroll!(id, policy_digests) do
    Repo.insert!(%Worker{
      capabilities: [%{"name" => "responder-state", "version" => "1"}],
      capacity: %{"state" => "eligible"},
      certificate_sha256: :crypto.hash(:sha256, id) |> Base.encode16(case: :lower),
      id: id,
      last_seen_at: DateTime.utc_now(),
      policy_authority_digests: Map.new(policy_digests, fn {name, _} -> {name, @authority} end),
      policy_digests: policy_digests,
      repositories: [%{"ref" => "emisar", "revision" => "commit:1"}],
      state: :eligible,
      workspace_ref: @workspace
    })
  end
end
