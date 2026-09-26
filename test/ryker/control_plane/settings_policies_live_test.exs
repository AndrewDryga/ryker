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

    assert has_element?(view, "#settings-policies button.settings-editor-add", "Add policy")

    view |> element("#settings-policies button.settings-editor-add") |> render_click()

    refute has_element?(view, "input[name=policy_digest]")
    assert has_element?(view, "#settings-policies-policy_name option[value='standard-v1']")

    bind!(view, "conversational", "standard-v1")

    assert [binding] = Settings.fetch!().policy_bindings
    assert binding.policy_name == "standard-v1"
    assert binding.policy_digest == @standard
    assert binding.authority_digest == @authority
    assert binding.verified_by == :worker
    assert binding.verified_worker_ref == "worker-one"

    assert has_element?(view, "#settings-policies .entity-row .state-word[data-tone=on]", "Ready")
    assert has_element?(view, "#settings-policies .entity-meta", "Offered by 1 worker")

    # The pinned version is support evidence: folded under Details, not in the row.
    refute has_element?(view, "#settings-policies .entity-meta", @standard)
    assert has_element?(view, "#settings-policies details.settings-row-details dd", @standard)
  end

  test "a policy row says where it applies and what it may do, with the worker's names folded away" do
    # Andrew, 2026-09-25: rows read "Policy ryker-repo-emisar-standard", the
    # worker's own name for its rulebook, which nobody reading the page could
    # place. A row names the kind of work and says where it applies, what it
    # may do when that is known, and who offers it; the names support needs
    # stay under Details.
    installation!()

    enroll!("worker-one", %{
      "contributor-v1" => @contributor,
      "ryker-learning" => @rotated,
      "standard-v1" => @standard
    })

    {:ok, view, _html} = open()
    bind!(view, "contributor", "contributor-v1")
    bind!(view, "standard", "standard-v1")

    # A task writes, and the host refuses to start one on a session that
    # cannot, so a task's policy can change code whoever wrote it.
    assert row_meta(view, "Contributor work") ==
             "Only in emisar · Can change code · Offered by 1 worker"

    # What a policy of a worker you run yourself allows otherwise, its
    # advertisement does not say, so the row does not guess.
    assert row_meta(view, "Standard work") == "Only in emisar · Offered by 1 worker"

    # The bundled worker writes every policy except a task's read-only.
    bundled_worker!()
    {:ok, view, _html} = open()
    bind!(view, "learning", "ryker-learning", {"installation", ""})

    assert row_meta(view, "Learning") == "Everywhere · Read only · Offered by 1 worker"

    for name <- ~w(contributor-v1 standard-v1 ryker-learning) do
      refute has_element?(view, "#settings-policies .entity-name", name)
      refute has_element?(view, "#settings-policies .entity-meta", name)
      assert has_element?(view, "#settings-policies details.settings-row-details dd", name)
    end
  end

  test "an environment's policy is added for one of its repositories, and its row names both" do
    # Since 2026-09-25 work in an environment may change any of its
    # repositories, so an environment binds its policies per repository. The
    # form had no way to say which one: a policy from a worker you run yourself
    # could not be added to an environment at all, and two of its rows for one
    # kind of work read exactly alike.
    snapshot = installation!()

    {:ok, snapshot} =
      Settings.put_repository(
        %{ref: "docs", base_branch: "main"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, _snapshot} =
      Settings.put_environment(
        %{ref: "production", display_name: "Production", repositories: ["emisar", "docs"]},
        snapshot.installation.revision,
        @actor
      )

    enroll!("worker-one", %{"contributor-v1" => @contributor})
    {:ok, view, _html} = open()
    view |> element("#settings-policies button.settings-editor-add") |> render_click()

    assert has_element?(
             view,
             "#settings-policies-repository_ref option[value=docs]",
             "docs"
           )

    view
    |> form("#settings-policies-form", %{
      "purpose" => "contributor",
      "scope_kind" => "environment",
      "scope_ref" => "production",
      "repository_ref" => "docs",
      "policy_name" => "contributor-v1"
    })
    |> render_submit()

    assert [%{scope_kind: :environment, scope_ref: "production", repository_ref: "docs"}] =
             Settings.fetch!().policy_bindings

    assert row_meta(view, "Contributor work") ==
             "Only in docs in the Production environment · Can change code · Offered by 1 worker"
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

    assert has_element?(
             rotated_view,
             "#settings-policies .state-word[data-tone=warn]",
             "Changed on the workers"
           )

    assert [%{policy_digest: @standard}] = Settings.fetch!().policy_bindings

    worker |> Ecto.Changeset.change(policy_digests: %{}) |> Repo.update!()
    {:ok, withdrawn_view, _html} = open()

    assert has_element?(
             withdrawn_view,
             "#settings-policies .state-word[data-tone=warn]",
             "Unavailable"
           )

    assert has_element?(
             withdrawn_view,
             "#settings-policies .entity-text",
             "No connected worker offers this policy"
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

    view |> element("#settings-policies button.settings-editor-add") |> render_click()

    refute has_element?(view, "#settings-policies-policy_name option[value='standard-v1']")
    assert has_element?(view, "#settings-policies-policy_name option[value='contributor-v1']")
  end

  defp open, do: live(build_conn() |> Map.put(:host, "localhost"), "/settings/advanced")

  # The facts line of the one row named for a kind of work, as a reader sees it.
  defp row_meta(view, name) do
    [row] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#settings-policies .entity-row")
      |> Enum.filter(
        &(&1 |> LazyHTML.query(".entity-name") |> LazyHTML.text() |> String.trim() == name)
      )

    row |> LazyHTML.query(".entity-meta") |> LazyHTML.text() |> String.split() |> Enum.join(" ")
  end

  # The Compose distribution names its bundled worker's root; the rest of the
  # test runs as that installation.
  defp bundled_worker! do
    previous = System.get_env("RYKER_BUNDLED_COOP_ROOT")
    System.put_env("RYKER_BUNDLED_COOP_ROOT", System.tmp_dir!())

    on_exit(fn ->
      if previous,
        do: System.put_env("RYKER_BUNDLED_COOP_ROOT", previous),
        else: System.delete_env("RYKER_BUNDLED_COOP_ROOT")
    end)
  end

  defp bind!(view, purpose, policy_name, {scope_kind, scope_ref} \\ {"repository", "emisar"}) do
    # Add opens the form and, pressed again, closes it.
    unless has_element?(view, "#settings-policies-form") do
      view |> element("#settings-policies button.settings-editor-add") |> render_click()
    end

    view
    |> form("#settings-policies-form", %{
      "purpose" => purpose,
      "scope_kind" => scope_kind,
      "scope_ref" => scope_ref,
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
