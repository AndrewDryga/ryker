defmodule Ryker.BundledCoopTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.BundledCoop
  alias Ryker.CoopFleet.{ControlPlane, Worker}
  alias Ryker.Settings

  @actor "control-plane:local"
  @digest String.duplicate("a", 64)
  @authority String.duplicate("b", 64)

  test "a clean distribution initializes settings and installs every default policy" do
    configure_distribution_root!()

    assert :ok = BundledCoop.prepare_distribution!()
    assert {:ok, _snapshot} = Settings.fetch()

    policy_file =
      File.read!(Path.join(System.fetch_env!("RYKER_BUNDLED_COOP_ROOT"), "session-policies.yaml"))

    for policy <-
          ~w(ryker-admission ryker-chat ryker-incident ryker-learning ryker-schedule-governed ryker-schedule-read-only) do
      assert policy_file =~ "  #{policy}:"
    end

    assert {:ok, _worker} =
             ControlPlane.authorize_worker("ryker-compose", "ryker-compose", @digest)

    names =
      ~w(ryker-admission ryker-chat ryker-incident ryker-learning ryker-schedule-governed ryker-schedule-read-only)

    advertise_policies!(names)

    assert :ok = BundledCoop.configure("ryker-compose")
    assert BundledCoop.ready?()

    snapshot = Settings.fetch!()
    assert snapshot.work.workspace_ref == "ryker-compose"

    assert MapSet.new(
             for binding <- snapshot.policy_bindings,
                 binding.scope_kind == :installation,
                 do: binding.purpose
           ) ==
             MapSet.new([
               :admission,
               :conversational,
               :incident,
               :learning,
               :schedule_governed,
               :schedule_read_only
             ])
  end

  test "the authenticated bundled worker selects its workspace and pins every ordinary policy" do
    configured_repository!()

    assert {:ok, _worker} =
             ControlPlane.authorize_worker("ryker-compose", "ryker-compose", @digest)

    names =
      ~w(
        ryker-admission ryker-chat ryker-incident ryker-learning ryker-schedule-governed
        ryker-schedule-read-only ryker-repo-app-conversation ryker-repo-app-contributor
        ryker-repo-app-deep ryker-repo-app-schedule ryker-repo-app-standard
      )

    advertise_policies!(names)

    assert :ok = BundledCoop.configure("ryker-compose")

    snapshot = Settings.fetch!()
    assert snapshot.work.workspace_ref == "ryker-compose"
    # Six installation policies and five for the repository.
    assert length(snapshot.policy_bindings) == 11

    assert Enum.any?(snapshot.policy_bindings, fn binding ->
             binding.purpose == :admission and binding.scope_kind == :installation and
               binding.policy_name == "ryker-admission" and binding.policy_digest == @digest
           end)

    assert Enum.any?(snapshot.policy_bindings, fn binding ->
             binding.purpose == :contributor and binding.scope_kind == :repository and
               binding.scope_ref == "app" and
               binding.policy_name == "ryker-repo-app-contributor"
           end)

    # A one-repository environment runs on its repository's policies.
    refute Enum.any?(snapshot.policy_bindings, &(&1.scope_kind == :environment))
  end

  # Coop mounts read-only repositories only for a policy that declares them, so
  # an environment with several repositories needs policies of its own: its
  # first repository writable (for confirmed tasks only) and every other one
  # mounted read-only under its ref, the name the Work executor checks.
  test "an environment with several repositories gets its own policies mounting the rest read-only" do
    {root, _shared} = configure_distribution_root!()
    assert :ok = BundledCoop.prepare_distribution!()
    snapshot = Settings.fetch!()

    snapshot =
      Enum.reduce(~w(app lib docs), snapshot, fn ref, current ->
        {:ok, saved} = Settings.put_repository(%{ref: ref}, current.installation.revision, @actor)
        saved
      end)

    {:ok, _snapshot} =
      Settings.put_environment(
        %{ref: "platform", display_name: "Platform", repositories: ["app", "lib", "docs"]},
        snapshot.installation.revision,
        @actor
      )

    # Nothing is written for an environment until every repository in it exists
    # on the worker.
    materialize!(root, "app")
    materialize!(root, "lib")
    assert :ok = BundledCoop.sync_policies()
    refute Map.has_key?(read_policies!(root), "ryker-env-platform-conversation")

    materialize!(root, "docs")
    assert :ok = BundledCoop.sync_policies()
    policies = read_policies!(root)

    for suffix <- ~w(conversation standard deep contributor) do
      policy = Map.fetch!(policies, "ryker-env-platform-#{suffix}")
      assert policy["repository"] == Path.join([root, "repositories", "app"])

      assert policy["companions"] == [
               %{"name" => "lib", "repository" => Path.join([root, "repositories", "lib"])},
               %{"name" => "docs", "repository" => Path.join([root, "repositories", "docs"])}
             ]
    end

    assert authority(policies["ryker-env-platform-conversation"]) ==
             authority(policies["ryker-env-platform-standard"])

    assert authority(policies["ryker-env-platform-conversation"]) ==
             authority(policies["ryker-env-platform-deep"])

    refute Map.get(policies["ryker-env-platform-contributor"], "repository_read_only", false)

    assert {:ok, _worker} =
             ControlPlane.authorize_worker("ryker-compose", "ryker-compose", @digest)

    advertise_policies!(
      ~w(ryker-admission ryker-chat ryker-incident ryker-learning ryker-schedule-governed
        ryker-schedule-read-only) ++
        for(
          suffix <- ~w(conversation standard deep contributor),
          do: "ryker-env-platform-#{suffix}"
        )
    )

    assert :ok = BundledCoop.configure("ryker-compose")

    assert Settings.fetch!().policy_bindings
           |> Enum.filter(&(&1.scope_kind == :environment))
           |> Enum.map(&{&1.purpose, &1.scope_ref, &1.policy_name})
           |> Enum.sort() ==
             [
               {:conversational, "platform", "ryker-env-platform-conversation"},
               {:standard, "platform", "ryker-env-platform-standard"},
               {:deep, "platform", "ryker-env-platform-deep"},
               {:contributor, "platform", "ryker-env-platform-contributor"}
             ]
             |> Enum.sort()

    assert BundledCoop.policy?("ryker-env-platform-deep")
  end

  # A Work profile requires its conversation, standard and deep policies to
  # share one Coop authority digest, and Coop hashes `repository_read_only`
  # into it. The bundled standard and deep policies were writable while the
  # conversation policy was read-only, so no bundled repository could ever form
  # a Work profile, and a deeper model would have been permission to write.
  test "a bundled repository's conversation, standard and deep policies share one read-only authority" do
    {root, _shared} = configure_distribution_root!()
    assert :ok = BundledCoop.prepare_distribution!()
    snapshot = Settings.fetch!()

    {:ok, _snapshot} =
      Settings.put_repository(%{ref: "app"}, snapshot.installation.revision, @actor)

    materialize!(root, "app")
    assert :ok = BundledCoop.sync_policies()
    policies = read_policies!(root)

    for suffix <- ~w(standard deep) do
      assert authority(policies["ryker-repo-app-#{suffix}"]) ==
               authority(policies["ryker-repo-app-conversation"]),
             suffix
    end

    assert policies["ryker-repo-app-conversation"]["repository_read_only"] == true
    refute Map.get(policies["ryker-repo-app-contributor"], "repository_read_only", false)
  end

  test "distribution setup creates private seed policies and an enrollment file" do
    configured_repository!()
    {root, shared} = configure_distribution_root!()

    assert :ok = BundledCoop.ensure_distribution!()
    assert File.dir?(Path.join(root, "seed/.git"))
    assert File.read!(Path.join(root, "session-policies.yaml")) =~ "ryker-admission"

    assert File.stat!(Path.join(root, "session-policies.yaml")).mode |> Bitwise.band(0o777) ==
             0o600

    assert byte_size(File.read!(Path.join(shared, "enrollment-token"))) >= 32

    occurred_at = ~U[2026-09-20 04:20:00.000000Z]
    assert :ok = BundledCoop.request_materialization("app", occurred_at)

    assert Enum.find(Settings.fetch!().repositories, &(&1.ref == "app")).last_github_event_at ==
             occurred_at

    assert :ok =
             BundledCoop.request_materialization(
               "app",
               DateTime.add(occurred_at, -1, :second)
             )

    assert Enum.find(Settings.fetch!().repositories, &(&1.ref == "app")).last_github_event_at ==
             occurred_at
  end

  test "each kind of work runs on the model saved for it, and a change applies without a restart" do
    # The model used to come from one environment variable no page showed, for
    # every kind of work at once; changing it meant editing the container and
    # restarting Ryker.
    {root, _shared} = configure_distribution_root!()
    assert :ok = BundledCoop.prepare_distribution!()
    policy_file = Path.join(root, "session-policies.yaml")

    assert policy_targets(policy_file) == %{
             "ryker-admission" => "codex:gpt-5.6-sol/medium@default",
             "ryker-chat" => "codex:gpt-5.6-terra/medium@default",
             "ryker-incident" => "codex:gpt-5.6-sol/medium@default",
             "ryker-learning" => "codex:gpt-5.6-sol/medium@default",
             "ryker-schedule-governed" => "codex:gpt-5.6-sol/medium@default",
             "ryker-schedule-read-only" => "codex:gpt-5.6-sol/medium@default"
           }

    start_supervised!(
      {BundledCoop.Reconciler, name: :bundled_model_reconciler, interval_ms: 60_000}
    )

    snapshot = Settings.fetch!()

    {:ok, _snapshot} =
      Settings.save_work(
        %{learning_model: "codex:gpt-5.6-luna/high@default"},
        snapshot.installation.revision,
        @actor
      )

    assert eventually(fn ->
             policy_targets(policy_file)["ryker-learning"] == "codex:gpt-5.6-luna/high@default"
           end)

    # Only learning changed.
    assert policy_targets(policy_file)["ryker-admission"] == "codex:gpt-5.6-sol/medium@default"
    assert policy_targets(policy_file)["ryker-chat"] == "codex:gpt-5.6-terra/medium@default"
  end

  test "a restart writes the saved models before any setting changes" do
    # Only installation and a later settings save wrote the policy file, so a
    # release that changed which model a kind of work runs on reached the
    # worker only when someone happened to save Settings.
    {root, _shared} = configure_distribution_root!()
    assert :ok = BundledCoop.prepare_distribution!()
    policy_file = Path.join(root, "session-policies.yaml")
    snapshot = Settings.fetch!()

    {:ok, _snapshot} =
      Settings.save_work(
        %{routing_model: "codex:gpt-5.6-terra/low@default"},
        snapshot.installation.revision,
        @actor
      )

    assert policy_targets(policy_file)["ryker-admission"] == "codex:gpt-5.6-sol/medium@default"

    start_supervised!(
      {BundledCoop.Reconciler, name: :bundled_restart_reconciler, interval_ms: 60_000}
    )

    assert eventually(fn ->
             policy_targets(policy_file)["ryker-admission"] == "codex:gpt-5.6-terra/low@default"
           end)
  end

  test "the bundled learning policy makes the isolated sessions background learning requires" do
    # Coop grants a session the project environment and project MCP servers
    # unless its policy says project_env: false and project_mcp: false. The
    # generated ryker-learning policy never said so, the learner refused every
    # session the bundled worker created for it, and background learning never
    # once ran on the Compose install: seven batches retried every hour for up
    # to four days (2026-09-21 to 09-24) while 25 messages waited.
    {root, _shared} = configure_distribution_root!()
    assert :ok = BundledCoop.prepare_distribution!()

    policies =
      root
      |> Path.join("session-policies.yaml")
      |> YamlElixir.read_from_file!()
      |> Map.fetch!("policies")

    learning = Map.fetch!(policies, "ryker-learning")
    assert learning["project_env"] == false
    assert learning["project_mcp"] == false
    assert learning["repository_read_only"] == true
    refute Map.has_key?(learning, "companions")

    # Only learning sends retained messages to a session it must isolate.
    assert Map.get(policies["ryker-chat"], "project_env", true)
  end

  test "an expired bundled identity gets one stable replacement enrollment token" do
    {:ok, _snapshot} = Settings.initialize(@actor)
    {_root, shared} = configure_distribution_root!()

    assert :ok = BundledCoop.ensure_distribution!()
    original = File.read!(Path.join(shared, "enrollment-token"))

    File.touch!(Path.join(shared, "enrolled"))
    File.rm!(Path.join(shared, "enrollment-token"))
    assert :ok = BundledCoop.ensure_enrollment_file!()
    refute File.exists?(Path.join(shared, "enrollment-token"))

    File.rm!(Path.join(shared, "enrolled"))
    assert :ok = BundledCoop.ensure_enrollment_file!()
    replacement = File.read!(Path.join(shared, "enrollment-token"))
    refute replacement == original

    assert :ok = BundledCoop.ensure_enrollment_file!()
    assert File.read!(Path.join(shared, "enrollment-token")) == replacement
  end

  defp configured_repository! do
    {:ok, snapshot} = Settings.initialize(@actor)

    {:ok, snapshot} =
      Settings.put_repository(
        %{ref: "app", display_name: "acme/app", github_repository: "acme/app"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, _snapshot} =
      Settings.put_environment(
        %{ref: "app", display_name: "acme/app", repositories: ["app"], is_default: true},
        snapshot.installation.revision,
        @actor
      )
  end

  defp materialize!(root, ref) do
    checkout = Path.join([root, "repositories", ref])
    File.mkdir_p!(checkout)

    for arguments <- [
          ["init", "--quiet"],
          [
            "-c",
            "user.email=ryker@localhost",
            "-c",
            "user.name=Ryker",
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "Initialize #{ref}"
          ]
        ] do
      {_output, 0} = System.cmd("git", arguments, cd: checkout, stderr_to_stdout: true)
    end
  end

  defp read_policies!(root) do
    root
    |> Path.join("session-policies.yaml")
    |> YamlElixir.read_from_file!()
    |> Map.fetch!("policies")
  end

  # The fields Coop hashes into a policy's authority digest; the model is not one.
  defp authority(policy) do
    Map.take(
      policy,
      ~w(repository companions repository_read_only project_env project_mcp egress)
    )
  end

  defp configure_distribution_root! do
    root =
      Path.join(System.tmp_dir!(), "ryker-bundled-coop-#{System.unique_integer([:positive])}")

    shared = root <> "-shared"
    previous_root = System.get_env("RYKER_BUNDLED_COOP_ROOT")
    previous_shared = System.get_env("RYKER_BUNDLED_COOP_SHARED")
    System.put_env("RYKER_BUNDLED_COOP_ROOT", root)
    System.put_env("RYKER_BUNDLED_COOP_SHARED", shared)

    on_exit(fn ->
      restore_env("RYKER_BUNDLED_COOP_ROOT", previous_root)
      restore_env("RYKER_BUNDLED_COOP_SHARED", previous_shared)
      File.rm_rf!(root)
      File.rm_rf!(shared)
    end)

    {root, shared}
  end

  defp advertise_policies!(names) do
    digests = Map.new(names, &{&1, @digest})
    authorities = Map.new(names, &{&1, @authority})

    Repo.update_all(
      from(worker in Worker, where: worker.id == "ryker-compose"),
      set: [
        capabilities: [%{"name" => "responder-state", "version" => "1"}],
        capacity: %{
          "session_slots_free" => 4,
          "session_slots_total" => 4,
          "state" => "eligible",
          "turn_slots_free" => 4,
          "turn_slots_total" => 4,
          "workspace_slots_free" => 3,
          "workspace_slots_total" => 3
        },
        last_seen_at: DateTime.utc_now(),
        policy_digests: digests,
        policy_authority_digests: authorities,
        state: :eligible
      ]
    )
  end

  defp policy_targets(path) do
    ~r/^  ([a-z0-9-]+):\n(?:    .*\n)*?    target: "([^"]+)"/m
    |> Regex.scan(File.read!(path), capture: :all_but_first)
    |> Map.new(fn [name, target] -> {name, target} end)
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
