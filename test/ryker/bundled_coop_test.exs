defmodule Ryker.BundledCoopTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  import Ryker.TestHelpers, only: [digest: 1, eventually: 1]
  alias Ryker.BundledCoop
  alias Ryker.CoopFleet.{ControlPlane, EnrollmentToken, Worker}
  alias Ryker.Settings

  @actor "control-plane:local"
  @digest String.duplicate("a", 64)

  setup do
    shared =
      Path.join(System.tmp_dir!(), "ryker-enrollment-#{System.unique_integer([:positive])}")

    File.mkdir_p!(shared)

    previous =
      for {name, value} <- [
            {"RYKER_BUNDLED_COOP_SHARED", shared},
            {"RYKER_BUNDLED_COOP_WORKER_ID", "ryker-compose"},
            {"RYKER_BUNDLED_COOP_WORKSPACE", "ryker-compose"}
          ] do
        previous = System.get_env(name)
        System.put_env(name, value)
        {name, previous}
      end

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      File.rm_rf!(shared)
    end)

    %{shared: shared, token: Path.join(shared, "enrollment-token")}
  end

  test "installation selects the worker workspace without policies or checkouts", %{
    shared: shared,
    token: token
  } do
    assert BundledCoop.distribution?()
    assert :ok = BundledCoop.prepare_distribution!()
    assert Settings.fetch!().work.workspace_ref == "ryker-compose"
    refute Map.has_key?(Settings.fetch!(), :policy_bindings)
    assert File.ls!(shared) == ["enrollment-token"]
    assert Bitwise.band(File.stat!(token).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(shared).mode, 0o777) == 0o700

    revision = Settings.fetch!().installation.revision
    original = File.read!(token)
    assert :ok = BundledCoop.prepare_distribution!()
    assert File.read!(token) == original
    assert Settings.fetch!().installation.revision == revision
    assert Repo.aggregate(EnrollmentToken, :count) == 1
  end

  test "readiness requires the exact current worker and real protocol support" do
    assert :ok = BundledCoop.prepare_distribution!()
    refute BundledCoop.ready?()
    authorize!()
    refute BundledCoop.ready?()
    advertise!()
    assert BundledCoop.ready?()

    for attributes <- [
          [workspace_ref: "other"],
          [protocol_version: "1"],
          [capabilities: [%{"name" => "controller-tools", "version" => "2"}]],
          [last_seen_at: DateTime.add(DateTime.utc_now(), -61, :second)],
          [state: :offline],
          [capacity: %{"state" => "eligible", "session_slots_free" => 0}]
        ] do
      update_worker!(attributes)
      refute BundledCoop.ready?(), inspect(attributes)
      advertise!()
    end
  end

  test "an expired or consumed token is replaced and the replacement stays stable", %{
    token: token
  } do
    assert :ok = BundledCoop.prepare_distribution!()

    for attributes <- [
          [expires_at: DateTime.add(Repo.now!(), -1, :second)],
          [consumed_at: Repo.now!(), certificate_sha256: @digest]
        ] do
      original = File.read!(token)
      record = Repo.get_by!(EnrollmentToken, token_sha256: hash(original))

      Repo.update_all(from(token in EnrollmentToken, where: token.id == ^record.id),
        set: attributes
      )

      assert :ok = BundledCoop.ensure_enrollment_file!()
      replacement = File.read!(token)
      refute replacement == original
      assert :ok = BundledCoop.ensure_enrollment_file!()
      assert File.read!(token) == replacement
      assert Repo.get!(EnrollmentToken, record.id)
    end
  end

  test "a token for a different worker or workspace is never reused", %{token: token} do
    assert :ok = BundledCoop.prepare_distribution!()

    for attributes <- [[worker_id: "other"], [workspace_ref: "other"]] do
      original = File.read!(token)
      digest = hash(original)

      Repo.update_all(from(token in EnrollmentToken, where: token.token_sha256 == ^digest),
        set: attributes
      )

      assert :ok = BundledCoop.ensure_enrollment_file!()
      refute File.read!(token) == original
    end
  end

  test "a persisted identity retires a spare token without deleting enrollment history",
       %{shared: shared, token: token} do
    assert :ok = BundledCoop.prepare_distribution!()
    enrollment = Repo.get_by!(EnrollmentToken, token_sha256: hash(File.read!(token)))
    marker = Path.join(shared, "enrolled")
    File.touch!(marker)
    assert :ok = BundledCoop.ensure_enrollment_file!()
    refute File.exists?(token)

    assert DateTime.compare(Repo.get!(EnrollmentToken, enrollment.id).expires_at, Repo.now!()) !=
             :gt

    assert :ok = BundledCoop.ensure_enrollment_file!()
    assert Repo.aggregate(EnrollmentToken, :count) == 1

    File.rm!(marker)
    assert :ok = BundledCoop.ensure_enrollment_file!()
    assert Repo.aggregate(EnrollmentToken, :count) == 2
    assert File.exists?(token)
  end

  test "a revoked worker cannot get another enrollment token", %{token: token} do
    assert :ok = BundledCoop.prepare_distribution!()
    authorize!()
    update_worker!(state: :revoked, revoked_at: Repo.now!(), revoked_by: @actor)
    assert :ok = BundledCoop.ensure_enrollment_file!()
    refute File.exists?(token)
    assert Repo.aggregate(EnrollmentToken, :count) == 1
  end

  test "nonprivate, oversized and symlink token files fail closed", %{
    shared: shared,
    token: token
  } do
    assert :ok = BundledCoop.prepare_distribution!()
    File.chmod!(token, 0o644)
    assert_raise RuntimeError, fn -> BundledCoop.ensure_enrollment_file!() end
    File.chmod!(token, 0o600)
    File.write!(token, String.duplicate("x", 130))
    assert_raise RuntimeError, fn -> BundledCoop.ensure_enrollment_file!() end
    File.rm!(token)
    target = Path.join(shared, "untouched")
    File.write!(target, String.duplicate("y", 43))
    File.ln_s!(target, token)
    assert_raise RuntimeError, fn -> BundledCoop.ensure_enrollment_file!() end
    assert File.read!(target) == String.duplicate("y", 43)
    assert Repo.aggregate(EnrollmentToken, :count) == 1
  end

  test "the reconciler repairs missing token delivery without waiting for certificate expiry",
       %{token: token} do
    assert :ok = BundledCoop.prepare_distribution!()
    File.rm!(token)
    start_supervised!({BundledCoop.Reconciler, name: :bundled_identity_test, interval_ms: 10})
    assert eventually(fn -> File.exists?(token) end)
    assert Repo.aggregate(EnrollmentToken, :count) == 2
  end

  defp authorize! do
    assert {:ok, _worker} =
             ControlPlane.authorize_worker("ryker-compose", "ryker-compose", @digest)
  end

  defp advertise! do
    update_worker!(
      workspace_ref: "ryker-compose",
      protocol_version: "2",
      capabilities: [%{"name" => "controller-tools", "version" => "1"}],
      capacity: %{
        "state" => "eligible",
        "session_slots_free" => 4,
        "session_slots_total" => 4,
        "turn_slots_free" => 4,
        "turn_slots_total" => 4,
        "workspace_slots_free" => 2,
        "workspace_slots_total" => 2
      },
      last_seen_at: DateTime.utc_now(),
      state: :eligible
    )
  end

  defp update_worker!(attributes) do
    Repo.update_all(from(worker in Worker, where: worker.id == "ryker-compose"),
      set: attributes
    )
  end

  defp hash(token), do: digest(token)
end
