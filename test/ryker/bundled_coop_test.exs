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
    assert length(snapshot.policy_bindings) == 15

    assert Enum.any?(snapshot.policy_bindings, fn binding ->
             binding.purpose == :admission and binding.scope_kind == :installation and
               binding.policy_name == "ryker-admission" and binding.policy_digest == @digest
           end)

    assert Enum.any?(snapshot.policy_bindings, fn binding ->
             binding.purpose == :contributor and binding.scope_kind == :context and
               binding.scope_ref == "app-context" and
               binding.policy_name == "ryker-repo-app-contributor"
           end)
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

  test "an expired bundled identity gets one stable replacement enrollment token" do
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
      Settings.put_repository_context(
        %{
          display_name: "acme/app",
          parallel_goal_limit: 3,
          primary_repository_ref: "app",
          read_only_repository_refs: [],
          ref: "app-context"
        },
        snapshot.installation.revision,
        @actor
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

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
