defmodule Responder.CoopFleet.WorkspaceCheckpointTest do
  use ExUnit.Case, async: true

  alias Responder.CoopFleet.CheckpointCrypto
  alias Responder.CoopFleet.WorkspaceCheckpoint
  alias Responder.CoopFleet.WorkspaceCheckpointBundle
  alias Responder.Fixtures.WorkspaceCheckpoint, as: WorkspaceCheckpointFixture

  @fixture Path.expand("../../../testdata/protocol/workspace-checkpoint-v1.json", __DIR__)
  @bundle_manifest_fixture Path.expand(
                             "../../../testdata/protocol/workspace-checkpoint-bundle-v1.manifest.json",
                             __DIR__
                           )

  test "the shared checkpoint binds portable task and workspace identity" do
    assert {:ok, checkpoint} = @fixture |> File.read!() |> WorkspaceCheckpoint.decode()
    assert checkpoint["session_ref"] == "session-1"
    assert checkpoint["placement_generation"] == 1
    assert checkpoint["task"]["queue_id"] == String.duplicate("4", 32)
    assert checkpoint["task"]["task_id"] == String.duplicate("5", 32)
    assert checkpoint["task"]["subtasks"] == [true, false]
    assert checkpoint["bundle"]["media_type"] == WorkspaceCheckpoint.bundle_media_type()
    assert checkpoint["bundle"]["byte_size"] == 16_384
  end

  test "unknown, unbounded, and inconsistent checkpoint state fails closed" do
    fixture = @fixture |> File.read!() |> Jason.decode!()

    invalid = [
      Map.put(fixture, "worker_path", "/private/workspace"),
      Map.put(fixture, "version", 2),
      put_in(fixture, ["bundle", "byte_size"], WorkspaceCheckpoint.maximum_bundle_bytes() + 1),
      put_in(fixture, ["task", "subtasks"], List.duplicate(false, 65)),
      update_in(fixture, ["gate"], &Map.delete(&1, "receipt_ref")),
      Map.put(fixture, "gate", %{"status" => "not_run", "receipt_ref" => "gate:unexpected"})
    ]

    assert Enum.all?(invalid, &match?({:error, _reason}, WorkspaceCheckpoint.validate(&1)))
  end

  test "checkpoint identity accepts ordinary Git branches and rejects unsafe metadata" do
    fixture = @fixture |> File.read!() |> Jason.decode!()

    for branch <- ["main", "feature/checkpoint-restore", "release/v1.2.3"] do
      assert {:ok, %{"branch_ref" => ^branch}} =
               fixture |> Map.put("branch_ref", branch) |> WorkspaceCheckpoint.validate()
    end

    invalid = [
      {put_in(fixture, ["task", "queue_id"], "not-a-queue"), :task},
      {put_in(fixture, ["task", "subtasks"], [true, "false"]), :task},
      {put_in(fixture, ["gate", "status"], "unknown"), :gate},
      {put_in(fixture, ["bundle", "media_type"], "application/x-tar"), :bundle},
      {Map.put(fixture, "created_at", "2026-08-29T12:00:00+01:00"), :created_at}
    ]

    for {value, field} <- invalid do
      assert {:error, {:invalid_workspace_checkpoint, ^field}} =
               WorkspaceCheckpoint.validate(value)
    end

    for branch <- ["@", "-hidden", ".hidden", "bad..branch", "bad@{branch", "bad.lock"] do
      assert {:error, {:invalid_workspace_checkpoint, :branch_ref}} =
               fixture |> Map.put("branch_ref", branch) |> WorkspaceCheckpoint.validate()
    end

    assert {:error, {:invalid_workspace_checkpoint, :json}} =
             WorkspaceCheckpoint.decode("not-json")

    assert {:error, {:invalid_workspace_checkpoint, :document}} =
             WorkspaceCheckpoint.decode(String.duplicate("x", 1_048_577))

    for {field, value, reason} <- [
          {"placement_generation", 0, :placement_generation},
          {"checkpoint_ref", "$unsafe", :checkpoint_ref},
          {"base_revision", "not-a-revision", :base_revision},
          {"candidate_tree_sha256", "not-a-digest", :candidate_tree_sha256},
          {"task", nil, :task},
          {"gate", nil, :gate},
          {"bundle", nil, :bundle},
          {"created_at", nil, :created_at}
        ] do
      assert {:error, {:invalid_workspace_checkpoint, ^reason}} =
               fixture |> Map.put(field, value) |> WorkspaceCheckpoint.validate()
    end

    assert {:error, {:invalid_workspace_checkpoint, :document}} =
             WorkspaceCheckpoint.validate("not-a-checkpoint")
  end

  test "the shared bundle manifest binds every portable byte" do
    assert {:ok, manifest} =
             @bundle_manifest_fixture
             |> File.read!()
             |> WorkspaceCheckpoint.decode_bundle_manifest()

    assert manifest["checkpoint_ref"] == "checkpoint:session-1:g1:1"
    assert manifest["tracked_patch"]["entry"] == "workspace.patch"
    assert [%{"path_bytes" => "notes/plan.md"}] = manifest["untracked_files"]
    assert manifest["task_projection"]["task_id"] == String.duplicate("5", 32)
    assert length(manifest["task_projection"]["files"]) == 2
    assert manifest["gate_receipt"]["entry"] == "gate/receipt.json"
  end

  test "bundle manifest rejects ambiguous or unsafe entries" do
    manifest = @bundle_manifest_fixture |> File.read!() |> Jason.decode!()

    invalid = [
      Map.put(manifest, "extra", true),
      put_in(manifest, ["task_projection", "files", Access.at(0), "entry"], "untracked/000000"),
      put_in(
        manifest,
        ["untracked_files", Access.at(0), "path_b64"],
        Base.encode64("/tmp/escape")
      ),
      put_in(manifest, ["untracked_files", Access.at(0), "path_b64"], Base.encode64("../escape")),
      put_in(
        manifest,
        ["untracked_files", Access.at(0), "byte_size"],
        WorkspaceCheckpoint.maximum_bundle_bytes()
      )
    ]

    for value <- invalid do
      assert {:error, {:invalid_workspace_checkpoint_bundle, _reason}} =
               WorkspaceCheckpoint.validate_bundle_manifest(value)
    end
  end

  test "bundle manifest rejects crossed paths, invalid modes, and malformed documents" do
    manifest = @bundle_manifest_fixture |> File.read!() |> Jason.decode!()
    first_task_path = get_in(manifest, ["task_projection", "files", Access.at(0), "path_b64"])

    invalid = [
      put_in(manifest, ["untracked_files", Access.at(0), "mode"], 0o777),
      put_in(manifest, ["task_projection", "files", Access.at(1), "path_b64"], first_task_path),
      put_in(manifest, ["task_projection", "files"], []),
      put_in(manifest, ["gate_receipt", "byte_size"], 0),
      Map.put(manifest, "branch_ref", "refs/../escape"),
      Map.put(manifest, "branch_ref", nil)
    ]

    for value <- invalid do
      assert {:error, {:invalid_workspace_checkpoint_bundle, _reason}} =
               WorkspaceCheckpoint.validate_bundle_manifest(value)
    end

    assert {:error, {:invalid_workspace_checkpoint_bundle, :json}} =
             WorkspaceCheckpoint.decode_bundle_manifest("not-json")

    assert {:error, {:invalid_workspace_checkpoint_bundle, :document}} =
             WorkspaceCheckpoint.decode_bundle_manifest("")

    assert {:error, {:invalid_workspace_checkpoint_bundle, :document}} =
             WorkspaceCheckpoint.validate_bundle_manifest("not-a-manifest")

    for value <- [
          Map.put(manifest, "task_projection", nil),
          Map.put(manifest, "tracked_patch", nil),
          put_in(manifest, ["untracked_files", Access.at(0), "path_b64"], nil),
          put_in(manifest, ["untracked_files", Access.at(0)], nil)
        ] do
      assert {:error, {:invalid_workspace_checkpoint_bundle, _reason}} =
               WorkspaceCheckpoint.validate_bundle_manifest(value)
    end

    assert {:ok, %{"gate_receipt" => nil}} =
             manifest
             |> Map.put("gate_receipt", nil)
             |> WorkspaceCheckpoint.validate_bundle_manifest()
  end

  test "descriptor and manifest cannot be crossed" do
    assert {:ok, checkpoint} = @fixture |> File.read!() |> WorkspaceCheckpoint.decode()

    assert {:ok, manifest} =
             @bundle_manifest_fixture
             |> File.read!()
             |> WorkspaceCheckpoint.decode_bundle_manifest()

    assert :ok = WorkspaceCheckpoint.validate_pair(checkpoint, manifest)

    crossed_tree = Map.put(manifest, "candidate_tree_sha256", String.duplicate("a", 64))

    assert {:error, {:invalid_workspace_checkpoint_pair, :identity}} =
             WorkspaceCheckpoint.validate_pair(checkpoint, crossed_tree)

    crossed_task = put_in(manifest, ["task_projection", "task_id"], String.duplicate("b", 32))

    assert {:error, {:invalid_workspace_checkpoint_pair, :task}} =
             WorkspaceCheckpoint.validate_pair(checkpoint, crossed_task)

    assert {:error, {:invalid_workspace_checkpoint_pair, :gate}} =
             WorkspaceCheckpoint.validate_pair(checkpoint, Map.put(manifest, "gate_receipt", nil))

    not_run = Map.put(checkpoint, "gate", %{"status" => "not_run"})

    assert {:error, {:invalid_workspace_checkpoint_pair, :gate}} =
             WorkspaceCheckpoint.validate_pair(not_run, manifest)

    assert {:error, {:invalid_workspace_checkpoint_pair, :document}} =
             WorkspaceCheckpoint.validate_pair(Map.put(checkpoint, "task", 1), manifest)

    assert {:error, {:invalid_workspace_checkpoint_pair, :document}} =
             WorkspaceCheckpoint.validate_pair(checkpoint, "not-a-manifest")
  end

  test "the central bundle verifier rejects modified headers and credential-bearing members" do
    {checkpoint, bundle} = WorkspaceCheckpointFixture.build(%{session_ref: "session-1"})
    assert {:ok, _manifest} = WorkspaceCheckpointBundle.validate(checkpoint, bundle, [])
    assert {:ok, _manifest} = WorkspaceCheckpointBundle.validate(checkpoint, bundle)

    assert {:error, {:invalid_workspace_checkpoint_bundle, :identity}} =
             checkpoint
             |> put_in(["bundle", "sha256"], String.duplicate("0", 64))
             |> WorkspaceCheckpointBundle.validate(bundle)

    assert {:error, {:invalid_workspace_checkpoint, :version}} =
             checkpoint
             |> Map.put("version", 2)
             |> WorkspaceCheckpointBundle.validate(bundle)

    <<name::binary-size(100), _mode::binary-size(8), rest::binary>> = bundle
    changed_bundle = name <> "0000777\0" <> rest

    changed_checkpoint =
      checkpoint
      |> put_in(["bundle", "sha256"], digest(changed_bundle))
      |> put_in(["bundle", "byte_size"], byte_size(changed_bundle))

    assert {:error, {:invalid_workspace_checkpoint_bundle, :header}} =
             WorkspaceCheckpointBundle.validate(changed_checkpoint, changed_bundle, [])

    invalid_octal = name <> "zzzzzzz\0" <> rest

    assert {:error, {:invalid_workspace_checkpoint_bundle, :header}} =
             WorkspaceCheckpointBundle.validate(
               rebind_bundle(checkpoint, invalid_octal),
               invalid_octal,
               []
             )

    {secret_checkpoint, secret_bundle} =
      WorkspaceCheckpointFixture.build(%{
        session_ref: "session-1",
        task: "token=ghp_abcdefghijklmnopqrstuvwxyz123456\n"
      })

    assert {:error, {:invalid_workspace_checkpoint_bundle, :secret}} =
             WorkspaceCheckpointBundle.validate(secret_checkpoint, secret_bundle, [])

    assert {:error, {:invalid_workspace_checkpoint_bundle, :secret}} =
             WorkspaceCheckpointBundle.validate(checkpoint, bundle, ["Status: in_progress"])

    assert {:error, {:invalid_workspace_checkpoint_bundle, :secret}} =
             WorkspaceCheckpointBundle.validate(checkpoint, bundle, ["short"])

    assert {:error, {:invalid_workspace_checkpoint_bundle, :secret_configuration}} =
             WorkspaceCheckpointBundle.validate(checkpoint, bundle, :not_a_secret_list)

    malformed = "not-a-tar"

    malformed_checkpoint =
      checkpoint
      |> put_in(["bundle", "sha256"], digest(malformed))
      |> put_in(["bundle", "byte_size"], byte_size(malformed))

    assert {:error, {:invalid_workspace_checkpoint_bundle, :tar}} =
             WorkspaceCheckpointBundle.validate(malformed_checkpoint, malformed, [])

    changed_member =
      :binary.replace(bundle, "Status: in_progress\n", "Status: in_progresX\n")

    assert {:error, {:invalid_workspace_checkpoint_bundle, :members}} =
             WorkspaceCheckpointBundle.validate(
               rebind_bundle(checkpoint, changed_member),
               changed_member,
               []
             )

    invalid_terminator = binary_part(bundle, 0, byte_size(bundle) - 1) <> <<1>>

    assert {:error, {:invalid_workspace_checkpoint_bundle, :terminator}} =
             WorkspaceCheckpointBundle.validate(
               rebind_bundle(checkpoint, invalid_terminator),
               invalid_terminator,
               []
             )

    truncated_member = binary_part(bundle, 0, byte_size(bundle) - 1_535)

    assert {:error, {:invalid_workspace_checkpoint_bundle, :member_length}} =
             WorkspaceCheckpointBundle.validate(
               rebind_bundle(checkpoint, truncated_member),
               truncated_member,
               []
             )

    missing_manifest = rename_first_tar_member(bundle, "missing.json")

    assert {:error, {:invalid_workspace_checkpoint_bundle, :manifest}} =
             WorkspaceCheckpointBundle.validate(
               rebind_bundle(checkpoint, missing_manifest),
               missing_manifest,
               []
             )
  end

  test "checkpoint encryption binds the exact descriptor and rejects malformed keys" do
    {checkpoint, bundle} = WorkspaceCheckpointFixture.build(%{session_ref: "session-crypto"})
    key = :crypto.strong_rand_bytes(32)

    assert {:ok, sealed} = CheckpointCrypto.seal(key, checkpoint, bundle)

    assert {:ok, ^bundle} =
             CheckpointCrypto.open(
               key,
               checkpoint,
               sealed.ciphertext,
               sealed.encryption_nonce,
               sealed.encryption_tag,
               sealed.encryption_key_sha256
             )

    assert {:error, :workspace_checkpoint_decryption_failed} =
             CheckpointCrypto.open(
               :crypto.strong_rand_bytes(32),
               checkpoint,
               sealed.ciphertext,
               sealed.encryption_nonce,
               sealed.encryption_tag,
               sealed.encryption_key_sha256
             )

    assert {:error, :workspace_checkpoint_decryption_failed} =
             CheckpointCrypto.open(
               key,
               checkpoint,
               sealed.ciphertext,
               sealed.encryption_nonce,
               sealed.encryption_tag,
               "wrong-length"
             )

    assert {:error, :workspace_checkpoint_encryption_key_invalid} =
             CheckpointCrypto.seal("short", checkpoint, bundle)

    assert {:error, :workspace_checkpoint_decryption_failed} =
             CheckpointCrypto.open(
               "short",
               checkpoint,
               sealed.ciphertext,
               sealed.encryption_nonce,
               sealed.encryption_tag,
               sealed.encryption_key_sha256
             )
  end

  defp rebind_bundle(checkpoint, bundle) do
    checkpoint
    |> put_in(["bundle", "sha256"], digest(bundle))
    |> put_in(["bundle", "byte_size"], byte_size(bundle))
  end

  defp rename_first_tar_member(bundle, name) do
    <<header::binary-size(512), rest::binary>> = bundle
    name_field = name <> :binary.copy(<<0>>, 100 - byte_size(name))
    header = name_field <> binary_part(header, 100, 412)
    checksum_header = binary_part(header, 0, 148) <> "        " <> binary_part(header, 156, 356)
    checksum = checksum_header |> :binary.bin_to_list() |> Enum.sum()
    checksum_field = checksum |> Integer.to_string(8) |> String.pad_leading(6, "0")

    binary_part(header, 0, 148) <>
      checksum_field <> <<0, 32>> <> binary_part(header, 156, 356) <> rest
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
