defmodule Ryker.Settings.ImportTest do
  use Ryker.DataCase, async: false

  alias Ryker.Bootstrap
  alias Ryker.Settings
  alias Ryker.Settings.Import
  alias Ryker.Slack.{ChannelConfiguration, ChannelSettingOverride}

  @actor Ryker.Settings.actor()
  @source Path.expand(
            "../../../testdata/configuration/retired-elixir-configuration.yaml",
            __DIR__
          )
  @bootstrap %Bootstrap{webhook_secret_names: ["GENERIC_WEBHOOK_SECRET"]}
  @workspace "T0000000000"

  defp plan!(path \\ @source, bootstrap \\ @bootstrap) do
    assert {:ok, plan} = Import.plan(path, bootstrap)
    plan
  end

  defp variant!(replacements) do
    document =
      Enum.reduce(replacements, File.read!(@source), fn {from, to}, document ->
        assert String.contains?(document, from), "fixture no longer contains #{inspect(from)}"
        String.replace(document, from, to)
      end)

    path =
      Path.join(System.tmp_dir!(), "ryker-import-#{System.unique_integer([:positive])}.yaml")

    File.write!(path, document)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp destinations(plan), do: Map.new(plan.settings, &{&1.destination, &1.value})
  defp settings(plan), do: Map.new(plan.settings, &{&1.setting, &1.destination})

  test "an unsupported key is named rather than ignored" do
    # A configuration this host never read is the most dangerous kind of silence:
    # the operator believes a setting is in force and nothing enforces it.
    path =
      variant!([{"  channel_prefix: ems", "  channel_prefix: ems\n  assistant_experience: true"}])

    assert Import.plan(path, @bootstrap) ==
             {:error,
              {:import_refused,
               [%{path: "slack.assistant_experience", reason: :is_not_a_supported_setting}]}}
  end

  test "a duplicated key is refused instead of resolved to one of its values" do
    path =
      variant!([{"  channel_prefix: ems", "  channel_prefix: ems\n  incident_private: false"}])

    assert Import.plan(path, @bootstrap) ==
             {:error,
              {:import_refused, [%{path: "configuration.slack", reason: :has_duplicate_keys}]}}
  end

  test "a malformed value is refused with the path and never the value" do
    path = variant!([{"  maximum_open_incidents: 10", "  maximum_open_incidents: 100000"}])

    assert {:error, {:import_refused, [refusal]}} = Import.plan(path, @bootstrap)

    assert refusal == %{
             path: "slack.maximum_open_incidents",
             reason: :must_be_an_integer_in_range
           }
  end

  test "every surviving setting names the exact row and column that will hold it" do
    settings = settings(plan!())

    assert settings["host_ref"] == nil
    assert settings["slack.identity.workspace_ref"] == "slack_settings.workspace_ref"
    assert settings["slack.operators"] == "slack_settings.operators"
    assert settings["slack.default_repository"] == "slack_settings.default_repository_ref"
    assert settings["work.workspace_ref"] == "work_settings.workspace_ref"

    assert settings["repositories.example.path"] ==
             "repository_settings[example].publication_checkout_path"

    assert settings["admission.policy"] == "policy_bindings[admission@installation:]"
    assert settings["slack.incident_policy"] == "policy_bindings[incident@installation:]"
    assert settings["learning.policy"] == "policy_bindings[learning@installation:]"

    assert settings["repositories.example.contributor_policy"] ==
             "policy_bindings[contributor@repository:example]"

    assert settings["webhooks.routes.universal.auth.secret_env"] ==
             "webhook_source_settings[universal].secret_name"

    assert plan!().writes == %{
             github_bindings: 0,
             policy_bindings: 10,
             repositories: 1,
             repository_contexts: 0,
             webhook_sources: 1
           }
  end

  test "the plan preserves unequal retention horizons instead of consolidating them" do
    # The old deployment kept conversation memory three times longer than the
    # rest. Collapsing that to one horizon would delete memory nobody asked to
    # delete, so the import carries each horizon across unchanged.
    destinations = destinations(plan!())

    assert destinations["retention_settings.operational_data_seconds"] == 2_592_000
    assert destinations["retention_settings.closed_work_seconds"] == 2_592_000
    assert destinations["retention_settings.episode_history_seconds"] == 2_592_000
    assert destinations["retention_settings.audit_data_seconds"] == 2_592_000
    assert destinations["retention_settings.conversation_memory_seconds"] == 7_776_000
  end

  # The retired document is immutable evidence of a real installation: its
  # credential names are the pre-rename contract the product read before
  # 2026-09-13. The plan must name each of them by that old name and
  # say which RYKER_* variable now carries it, so an operator following the
  # import can move the value; a plan that silently read the new name would
  # start with no checkpoint key and no state-tools token.
  test "every credential name the fixed contract renames appears as a deployment remap" do
    remap = Map.new(plan!().secret_remap, &{&1.setting, {&1.from, &1.to}})

    assert remap["emisar.token_env"] == {"EMISAR_API_KEY", "EMISAR_API_TOKEN"}
    assert remap["slack.bot_token_env"] == {"SLACK_BOT_TOKEN", "SLACK_BOT_TOKEN"}
    assert remap["slack.app_token_env"] == {"SLACK_APP_TOKEN", "SLACK_APP_TOKEN"}

    assert remap["state_tools.token_env"] ==
             {"RESPONDER_STATE_TOOLS_TOKEN", "RYKER_STATE_TOOLS_TOKEN"}

    assert remap["coop_worker_gateway.checkpoint_key_env"] ==
             {"RESPONDER_CHECKPOINT_KEY", "RYKER_CHECKPOINT_KEY"}

    assert remap["webhooks.routes.universal.auth.secret_env"] ==
             {"GENERIC_WEBHOOK_SECRET",
              "GENERIC_WEBHOOK_SECRET (registered in RYKER_WEBHOOK_SECRET_NAMES)"}
  end

  test "a custom webhook secret the deployment did not register is refused" do
    # A source whose secret is not in the deployment contract would start with no
    # verification at all, so the import refuses rather than warning.
    assert Import.plan(@source, %Bootstrap{webhook_secret_names: []}) ==
             {:error,
              {:import_refused,
               [
                 %{
                   path: "webhooks.routes.universal.auth.secret_env",
                   reason: :is_not_registered_in_ryker_webhook_secret_names
                 }
               ]}}
  end

  test "non-default tuning discloses the shipped value that replaces it" do
    tuning = Map.new(plan!().replaced_tuning, &{&1.setting, {&1.value, &1.shipped}})

    assert tuning["delivery.action_concurrency"] == {1, 2}
    assert tuning["delivery.message_concurrency"] == {2, 4}
    assert tuning["delivery.reaction_concurrency"] == {1, 2}
    assert tuning["slack.maximum_open_incidents"] == {10, 25}
    assert tuning["work.concurrency"] == {2, 4}

    # Values the document set to exactly what the code now ships have no semantic
    # difference to disclose.
    refute Map.has_key?(tuning, "learning.execution_timeout_seconds")
    refute Map.has_key?(tuning, "retention.poll_interval_ms")
    refute Map.has_key?(tuning, "emisar.poll_seconds")
  end

  test "a retired declaration is named with its value and its reason" do
    retired = Map.new(plan!().retired, &{&1.setting, &1.value})

    assert retired["mode"] == "component"
    assert retired["coop.socket"] == "/var/lib/responder/example/coop-component/control.sock"
    assert retired["work.execution"] == "fleet"

    assert retired["work.source_and_action_tools"] ==
             ~w(list_packs list_runners find_actions get_action run_action)

    assert retired["repositories.example.github_binding"] == "example-app"
    assert Enum.all?(plan!().retired, &(String.trim(&1.why) != ""))
  end

  test "moving admission and learning off the retired local socket is disclosed as a changed effect" do
    # The old document ran Work on the fleet but admission and learning through a
    # local Coop socket. Importing it silently would move two model lanes onto a
    # different worker with no operator ever being told.
    effects = Map.new(plan!().changed_effects, &{&1.setting, &1.detail})

    assert effects["mode"] =~ "admission"
    assert effects["mode"] =~ "learning"
    assert effects["control_plane.work_profile"] =~ "repository context"
  end

  test "each deployment input names the variable that now carries it" do
    deployment = Map.new(plan!().deployment, &{&1.variable, &1.value})

    # Values are the old installation's own and travel unchanged; only the
    # variable that carries each one is renamed.
    assert deployment["RYKER_CONTROL_PORT"] == 4321
    assert deployment["RYKER_WORKER_PUBLIC_URL"] == "https://responder-worker.example.net"
    assert deployment["RYKER_WORKER_CA_FILE"] == "/var/lib/responder/example/worker-ca.pem"
    assert deployment["EMISAR_RPC_URL"] == "https://emisar.dev/api/mcp/rpc"
    assert deployment["RYKER_WEBHOOK_PORT"] == 4320
    refute Map.has_key?(deployment, "GITHUB_APP_ID")
  end

  test "a work profile that does not match its context's reviewed policies is refused" do
    path =
      variant!([
        {"""
             class_policies:
               conversational:
                 policy: example-conversation-v2
                 policy_digest: c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0
                 authority_digest: a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0
               standard:
                 policy: example-standard-v1
                 policy_digest: 5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a
                 authority_digest: a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0
               deep:
                 policy: example-deep-v1
                 policy_digest: d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0
                 authority_digest: a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0
         """,
         """
             class_policies:
               conversational:
                 policy: example-conversation-v2
                 policy_digest: c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0
                 authority_digest: a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0
               standard:
                 policy: example-deep-v1
                 policy_digest: d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0
                 authority_digest: a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0
               deep:
                 policy: example-deep-v1
                 policy_digest: d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0
                 authority_digest: a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0
         """}
      ])

    assert {:error, {:import_refused, refusals}} = Import.plan(path, @bootstrap)

    assert %{reason: :does_not_match_the_reviewed_policies_of_its_context} =
             Enum.find(refusals, &(&1.path == "control_plane.work_profile"))
  end

  test "a dry run writes nothing at all" do
    assert %{status: :ready, receipt: nil} = plan!()
    assert Settings.fetch() == {:error, :settings_not_initialized}
    assert Repo.aggregate(Settings.ImportReceipt, :count) == 0
    assert Repo.aggregate(Settings.Edit, :count) == 0
  end

  test "the plan fingerprint does not depend on where the file happens to sit" do
    copy = variant!([{"version: 1", "version: 1"}])
    assert plan!(copy).plan_fingerprint == plan!().plan_fingerprint
    assert plan!(copy).source.fingerprint == plan!().source.fingerprint
  end

  test "the fixture still mirrors the workspace the participation tests rely on" do
    assert plan!().participation.workspace_ref == @workspace
  end

  # Applying -----------------------------------------------------------------------

  defp retained_history! do
    # A database that already ran the product. Creating a fresh identity here
    # would re-key every lease owner, publication branch and worker enrolment
    # derived from host_ref, which is why initialization refuses it outright.
    assert {:ok, _} =
             Ryker.Instructions.save(:global, "Existing operator guidance", 0, @actor)

    assert Settings.initialize(@actor) == {:error, :settings_import_required}
  end

  defp configuration!(channel_ref, participation, workspace_ref \\ @workspace) do
    Repo.insert!(%ChannelConfiguration{
      actor_ref: "U1111111111",
      alert_policy: :reply,
      channel_ref: channel_ref,
      id: Ecto.UUID.generate(),
      invite_user_group_refs: [],
      invite_user_refs: [],
      participation: participation,
      repository_ref: "example",
      revision: 3,
      saved_at: ~U[2026-09-01 00:00:00.000000Z],
      workspace_ref: workspace_ref
    })
  end

  defp override!(scope_kind, scope_ref, setting, value, workspace_ref \\ @workspace) do
    Repo.insert!(%ChannelSettingOverride{
      actor_ref: "U1111111111",
      event_ref: "Ev#{System.unique_integer([:positive])}",
      id: Ecto.UUID.generate(),
      inserted_at: ~U[2026-09-01 00:00:00.000000Z],
      revision: 1,
      scope_kind: scope_kind,
      scope_ref: scope_ref,
      setting: setting,
      updated_at: ~U[2026-09-01 00:00:00.000000Z],
      value: value,
      workspace_ref: workspace_ref
    })
  end

  defp apply!(path \\ @source, bootstrap \\ @bootstrap) do
    assert {:ok, outcome} = Import.apply_plan(path, bootstrap, @actor)
    outcome
  end

  defp effective(channel_ref) do
    Repo.get_by(ChannelConfiguration, workspace_ref: @workspace, channel_ref: channel_ref)
  end

  test "an import keeps the installation identity that existing custody is keyed under" do
    retained_history!()
    assert %{status: :applied, revision: revision} = apply!()
    assert {:ok, saved} = Settings.fetch()

    assert saved.installation.host_ref == "example-local-manual"
    assert saved.installation.revision == revision

    # Every lease owner Assembly derives is "<host_ref>:<lane>". Generating a new
    # identity would strand work, delivery and publication already keyed to these.
    for lane <- ~w(work admission delivery publication retention schedules learning) do
      assert "#{saved.installation.host_ref}:#{lane}" == "example-local-manual:#{lane}"
    end

    assert saved.retention.operational_data_seconds == 2_592_000
    assert saved.retention.conversation_memory_seconds == 7_776_000
    assert saved.slack.enabled
    assert saved.slack.workspace_ref == @workspace
    assert saved.slack.operators == ["U1111111111"]
    assert saved.slack.default_repository_ref == "example"
    assert saved.work.workspace_ref == "example-local-main"
    assert saved.learning.enabled
    assert saved.emisar.enabled
    refute saved.github.enabled
    refute saved.publication.enabled
    assert Enum.map(saved.repositories, & &1.ref) == ["example"]
    assert hd(saved.repositories).publication_checkout_path == "/srv/example"
    assert length(saved.policy_bindings) == 10
    assert Enum.all?(saved.policy_bindings, &(&1.verified_by == :import))
    assert Enum.map(saved.webhook_sources, & &1.name) == ["universal"]
    assert hd(saved.webhook_sources).secret_name == "GENERIC_WEBHOOK_SECRET"
    assert hd(saved.webhook_sources).context_ref == "example"

    # Retained history is not rewritten by the import.
    assert Ryker.Instructions.get(:global).text == "Existing operator guidance"
  end

  test "an identical rerun reports already applied and buys no second revision" do
    retained_history!()
    assert %{status: :applied, revision: revision, receipt_id: id} = apply!()

    assert Import.apply_plan(@source, @bootstrap, @actor) ==
             {:ok,
              %{
                status: :already_applied,
                revision: revision,
                plan: Import.document(elem(Import.plan(@source, @bootstrap), 1))
              }}

    assert Repo.aggregate(Settings.ImportReceipt, :count) == 1
    assert Repo.one(Settings.ImportReceipt).id == id
    assert Settings.fetch!().installation.revision == revision
  end

  test "a changed source refuses rather than replacing settings it already imported" do
    retained_history!()
    assert %{status: :applied} = apply!()

    changed = variant!([{"  channel_prefix: ems", "  channel_prefix: inc"}])

    assert Import.apply_plan(changed, @bootstrap, @actor) ==
             {:error, {:import_conflict, :source_changed}}

    assert Settings.fetch!().slack.channel_prefix == "ems"
  end

  test "a settings edit after the import turns a rerun into a conflict" do
    # The operator moved on and used the product. A rerun that overwrote those
    # edits would silently undo work nobody asked to undo.
    retained_history!()
    assert %{status: :applied, revision: revision} = apply!()
    assert {:ok, edited} = Settings.save_slack(%{channel_prefix: "inc"}, revision, @actor)

    assert Import.apply_plan(@source, @bootstrap, @actor) ==
             {:error, {:import_conflict, :target_edited}}

    assert Settings.fetch!().slack.channel_prefix == "inc"
    assert Settings.fetch!().installation.revision == edited.installation.revision
  end

  test "a failure part way through leaves no installation, settings or receipt behind" do
    # The typed write path is the final authority, so a plan can still meet a
    # refusal it did not predict. Half an import is worse than none.
    retained_history!()
    labels = Enum.map_join(1..100, "", &"\n          - label-#{&1}")

    path =
      variant!([
        {"      auth:\n        kind: hmac_sha256",
         "      adapter:\n        kind: grafana\n        group_by_labels:#{labels}\n" <>
           "      auth:\n        kind: hmac_sha256"}
      ])

    assert {:error, {:import_failed, {:invalid_settings, errors}}} =
             Import.apply_plan(path, @bootstrap, @actor)

    assert {:group_by_labels, _reason} = List.keyfind(errors, :group_by_labels, 0)
    assert Settings.fetch() == {:error, :settings_not_initialized}
    assert Repo.aggregate(Settings.ImportReceipt, :count) == 0
    assert Repo.aggregate(Settings.Edit, :count) == 0
    assert Repo.aggregate(Settings.Repository, :count) == 0
    assert Repo.aggregate(Settings.PolicyBinding, :count) == 0
  end

  test "the four retired participation layers keep the same effective value per channel" do
    # channel override > confirmed channel setup > workspace override > the
    # deployment watch list, reproduced with two stores instead of four.
    retained_history!()
    configuration!("C2222222222", :mentions)
    configuration!("C3333333333", :shadow)
    configuration!("C4444444444", nil)
    override!(:channel, "slack:#{@workspace}:C2222222222", :proactive, true)

    assert %{status: :applied} = apply!()

    assert Settings.fetch!().slack.default_participation == :mentions
    # Watch-listed with no row at all: the list is gone, so the value becomes its own.
    assert effective("C1111111111").participation == :proactive
    assert effective("C1111111111").actor_ref == nil
    assert effective("C1111111111").repository_ref == "example"
    # A channel override outranked the confirmed setup and still does.
    assert effective("C2222222222").participation == :proactive
    # A confirmed choice nobody overrode is untouched.
    assert effective("C3333333333").participation == :shadow
    assert effective("C3333333333").revision == 3
    # A channel that never chose keeps inheriting instead of copying the default.
    assert effective("C4444444444").participation == nil
  end

  test "a workspace-wide override becomes the installation default rather than a copy per channel" do
    retained_history!()
    configuration!("C3333333333", :shadow)
    override!(:workspace, @workspace, :proactive, true)

    assert %{status: :applied} = apply!()

    assert Settings.fetch!().slack.default_participation == :proactive
    # Already proactive through the workspace override and the watch list alike.
    assert effective("C1111111111") == nil
    assert effective("C3333333333").participation == :shadow
  end

  test "a retained override for another workspace is refused rather than folded into this one" do
    retained_history!()
    override!(:channel, "slack:T9999999999:C5555555555", :shadow, true, "T9999999999")

    assert {:error, {:import_refused, refusals}} = Import.plan(@source, @bootstrap)
    assert Enum.any?(refusals, &(&1.reason == :belongs_to_another_workspace))
    assert Settings.fetch() == {:error, :settings_not_initialized}
  end

  @github_section """
    maximum_open_incidents: 10

  github:
    api_url: https://api.github.com
    app_id: 12345
    private_key_env: GITHUB_APP_PRIVATE_KEY
    webhook_secret_env: GITHUB_WEBHOOK_SECRET
    ip: 127.0.0.1
    port: 4319
    bindings:
      example-app:
        repository: example
        installation_id: 1001
        repository_id: 2001
        responder_actor_id: 3001
        authorized_actor_ids:
          - 4001

  publication:
    branch_prefix: example
    state_dir: /var/lib/ryker/example/publications
    commit_name: Example Ryker
    commit_email: ryker@example.com
    secret_scan_env: []
  """

  test "a connected GitHub App imports its exact verified identities, not its names" do
    # Names are discoverable; installation, repository and actor identities are
    # the grant. Re-resolving them from a name would rebind someone else's repo.
    retained_history!()
    path = variant!([{"  maximum_open_incidents: 10\n", @github_section}])

    assert %{status: :applied} = apply!(path)
    assert {:ok, saved} = Settings.fetch()

    assert saved.github.enabled
    assert saved.github.app_id == 12_345
    assert [binding] = saved.github_bindings
    assert binding.name == "example-app"
    assert binding.repository_ref == "example"
    assert binding.installation_id == 1001
    assert binding.repository_id == 2001
    assert binding.ryker_actor_id == 3001
    assert binding.authorized_actor_ids == [4001]

    assert saved.publication.enabled
    assert saved.publication.branch_prefix == "example"
    assert saved.publication.commit_email == "ryker@example.com"

    # The repository named this binding all along; it is no longer a loose name.
    refute Enum.any?(
             Import.plan(path, @bootstrap) |> elem(1) |> Map.fetch!(:retired),
             &(&1.setting == "repositories.example.github_binding")
           )
  end

  test "a github binding that names a repository bound elsewhere is refused" do
    section = String.replace(@github_section, "    example-app:", "    other-app:")

    path = variant!([{"  maximum_open_incidents: 10\n", section}])

    assert {:error, {:import_refused, refusals}} = Import.plan(path, @bootstrap)

    assert %{reason: :does_not_name_this_binding} =
             Enum.find(refusals, &(&1.path == "github.bindings.other-app.repository"))
  end

  test "an existing installation is never replaced by an import that has no receipt" do
    assert {:ok, fresh} = Settings.initialize(@actor)

    assert Import.apply_plan(@source, @bootstrap, @actor) ==
             {:error, {:import_failed, :settings_already_initialized}}

    assert Settings.fetch!().installation.host_ref == fresh.installation.host_ref
    assert Repo.aggregate(Settings.ImportReceipt, :count) == 0
  end

  test "a scan secret the deployment did not register is refused and a registered one is remapped" do
    path =
      variant!([
        {"  checkpoint_secret_scan_env: []",
         "  checkpoint_secret_scan_env:\n    - EXTRA_SCAN_SECRET"}
      ])

    assert {:error, {:import_refused, refusals}} = Import.plan(path, @bootstrap)

    assert %{reason: :is_not_registered_in_ryker_webhook_secret_names} =
             Enum.find(refusals, &(&1.path == "coop_worker_gateway.checkpoint_secret_scan_env[]"))

    registered = %Bootstrap{
      webhook_secret_names: ["EXTRA_SCAN_SECRET", "GENERIC_WEBHOOK_SECRET"]
    }

    assert {:ok, plan} = Import.plan(path, registered)

    assert %{from: "EXTRA_SCAN_SECRET", to: to} =
             Enum.find(
               plan.secret_remap,
               &(&1.setting == "coop_worker_gateway.checkpoint_secret_scan_env[]")
             )

    assert to =~ "RYKER_WEBHOOK_SECRET_NAMES"
  end

  test "an isolated work topology is refused because product execution is fleet-only" do
    path = variant!([{"  execution: fleet", "  execution: direct"}])

    assert {:error, {:import_refused, refusals}} = Import.plan(path, @bootstrap)

    assert %{reason: :isolated_topology_is_not_a_product_setting} =
             Enum.find(refusals, &(&1.path == "work.execution"))
  end

  test "a rerun after the participation fold is still the same import, not a conflict" do
    # The fold rewrites the very rows the plan reads. If replanning saw its own
    # result as a difference, every retry of a half-finished cutover would look
    # like an operator edit and refuse.
    retained_history!()
    configuration!("C2222222222", :mentions)
    configuration!("C4444444444", nil)
    override!(:channel, "slack:#{@workspace}:C2222222222", :proactive, true)

    assert %{status: :applied, revision: revision} = apply!()
    assert {:ok, replanned} = Import.plan(@source, @bootstrap)
    assert replanned.status == :already_applied
    assert replanned.receipt.revision == revision

    assert Import.apply_plan(@source, @bootstrap, @actor) ==
             {:ok,
              %{status: :already_applied, revision: revision, plan: Import.document(replanned)}}
  end

  test "a Slack endpoint that is not the official one is refused, not quietly dropped" do
    # The endpoint ships with the code now. Importing a document that pointed
    # Slack elsewhere and saying nothing would move every call to the real API.
    path = variant!([{"  api_url: https://slack.com/api", "  api_url: https://slack.test/api"}])

    assert {:error, {:import_refused, refusals}} = Import.plan(path, @bootstrap)

    assert %{reason: :is_fixed_to_the_official_endpoint} =
             Enum.find(refusals, &(&1.path == "slack.api_url"))
  end

  test "a default repository that names a repository set is refused by name" do
    # The retired default could be any context; the saved default is a
    # repository. Silently accepting a set name would leave Slack unconfigurable.
    path =
      variant!([
        {"  default_repository: example", "  default_repository: platform"},
        {"admission:\n",
         "repository_sets:\n" <>
           "  platform:\n" <>
           "    primary_repository: example\n" <>
           "    read_only_repositories: []\n" <>
           "    conversation_policy:\n" <>
           "      name: example-conversation-v2\n" <>
           "      digest: #{String.duplicate("c0", 32)}\n" <>
           "      authority_digest: #{String.duplicate("a0", 32)}\n" <>
           "    contributor_policy:\n" <>
           "      name: example-contributor-v2\n" <>
           "      digest: #{String.duplicate("c7", 32)}\n" <>
           "      authority_digest: #{String.duplicate("b0", 32)}\n\n" <>
           "admission:\n"}
      ])

    assert {:error, {:import_refused, refusals}} = Import.plan(path, @bootstrap)

    assert %{reason: :must_name_a_repository_not_a_repository_set} =
             Enum.find(refusals, &(&1.path == "slack.default_repository"))
  end
end
