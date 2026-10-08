defmodule Ryker.CoopFleet.WorkspaceCheckpointTest do
  use ExUnit.Case, async: true
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.CoopFleet.WorkspaceCheckpoint
  alias Ryker.CoopFleet.WorkspaceCheckpointBundle
  alias Ryker.Fixtures.WorkspaceCheckpoint, as: WorkspaceCheckpointFixture

  # Captured by Coop's CheckpointWorkspace (see the file's provenance): the descriptor and the
  # bundle whose first member is the manifest.
  @golden Path.expand("../../../testdata/protocol/workspace-checkpoint-v2.golden.json", __DIR__)

  test "a real Coop capture binds portable task and workspace identity" do
    assert {:ok, checkpoint} =
             golden_checkpoint() |> WorkspaceCheckpoint.validate()

    assert checkpoint["session_ref"] == "golden-source"
    assert checkpoint["placement_generation"] == 1
    assert checkpoint["task"]["queue_id"] == "496879b67bebf02daa4122cc972c06dd"
    assert checkpoint["task"]["task_id"] == "9b5bd23b93474c5c1b97adcc13c6b47c"
    assert checkpoint["task"]["subtasks"] == [false]
    assert checkpoint["bundle"]["media_type"] == WorkspaceCheckpoint.bundle_media_type()
    assert checkpoint["bundle"]["byte_size"] == 22_016
  end

  test "unknown, unbounded, and inconsistent checkpoint state fails closed" do
    fixture = golden_checkpoint()
    passed = %{"status" => "passed", "revision" => fixture["committed_revision"]}

    invalid = [
      Map.put(fixture, "worker_path", "/private/workspace"),
      Map.put(fixture, "version", 1),
      put_in(
        fixture,
        ["bundle", "media_type"],
        "application/vnd.coop.workspace-checkpoint.v1+tar"
      ),
      put_in(fixture, ["bundle", "byte_size"], WorkspaceCheckpoint.maximum_bundle_bytes() + 1),
      put_in(fixture, ["task", "subtasks"], List.duplicate(false, 65)),
      Map.put(fixture, "gate", passed),
      Map.put(fixture, "gate", %{"status" => "not_run", "receipt_ref" => "gate:unexpected"})
    ]

    assert Enum.all?(invalid, &match?({:error, _reason}, WorkspaceCheckpoint.validate(&1)))
  end

  test "checkpoint identity accepts ordinary Git branches and rejects unsafe metadata" do
    fixture = golden_checkpoint()

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
      assert fixture |> Map.put("branch_ref", branch) |> WorkspaceCheckpoint.validate() ==
               {:error, {:invalid_workspace_checkpoint, :branch_ref}}
    end

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

    assert WorkspaceCheckpoint.validate("not-a-checkpoint") ==
             {:error, {:invalid_workspace_checkpoint, :document}}
  end

  test "a real Coop bundle manifest binds every portable byte" do
    assert {:ok, manifest} = WorkspaceCheckpoint.decode_bundle_manifest(golden_manifest())

    assert manifest["checkpoint_ref"] == "checkpoint:392b2bfdb49fc4b488f43537c6989ae9"
    assert manifest["repository"]["entry"] == "repository.tar"
    assert [%{"path_bytes" => "notes.txt"}] = manifest["untracked_files"]
    assert manifest["task_projection"]["task_id"] == "9b5bd23b93474c5c1b97adcc13c6b47c"
    assert length(manifest["task_projection"]["files"]) == 7
    assert manifest["gate_receipt"] == nil
  end

  test "bundle manifest rejects ambiguous or unsafe entries" do
    manifest = Jason.decode!(golden_manifest())

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
               WorkspaceCheckpoint.decode_bundle_manifest(Jason.encode!(value))
    end
  end

  test "bundle manifest rejects crossed paths, invalid modes, and malformed documents" do
    manifest = Jason.decode!(golden_manifest())
    first_task_path = get_in(manifest, ["task_projection", "files", Access.at(0), "path_b64"])

    invalid = [
      put_in(manifest, ["untracked_files", Access.at(0), "mode"], 0o777),
      put_in(manifest, ["task_projection", "files", Access.at(1), "path_b64"], first_task_path),
      put_in(manifest, ["task_projection", "files"], []),
      Map.put(manifest, "gate_receipt", Map.put(gate_receipt(), "byte_size", 0)),
      Map.put(manifest, "branch_ref", "refs/../escape"),
      Map.put(manifest, "branch_ref", nil)
    ]

    for value <- invalid do
      assert {:error, {:invalid_workspace_checkpoint_bundle, _reason}} =
               WorkspaceCheckpoint.decode_bundle_manifest(Jason.encode!(value))
    end

    assert WorkspaceCheckpoint.decode_bundle_manifest("not-json") ==
             {:error, {:invalid_workspace_checkpoint_bundle, :json}}

    assert WorkspaceCheckpoint.decode_bundle_manifest("") ==
             {:error, {:invalid_workspace_checkpoint_bundle, :document}}

    assert WorkspaceCheckpoint.decode_bundle_manifest(Jason.encode!("not-a-manifest")) ==
             {:error, {:invalid_workspace_checkpoint_bundle, :document}}

    for value <- [
          Map.put(manifest, "task_projection", nil),
          Map.put(manifest, "repository", nil),
          put_in(manifest, ["untracked_files", Access.at(0), "path_b64"], nil),
          put_in(manifest, ["untracked_files", Access.at(0)], nil)
        ] do
      assert {:error, {:invalid_workspace_checkpoint_bundle, _reason}} =
               WorkspaceCheckpoint.decode_bundle_manifest(Jason.encode!(value))
    end

    assert {:ok, %{"gate_receipt" => %{"entry" => "gate/receipt.json"}}} =
             manifest
             |> Map.put("gate_receipt", gate_receipt())
             |> Jason.encode!()
             |> WorkspaceCheckpoint.decode_bundle_manifest()
  end

  test "descriptor and manifest cannot be crossed" do
    assert {:ok, checkpoint} = WorkspaceCheckpoint.validate(golden_checkpoint())
    assert {:ok, manifest} = WorkspaceCheckpoint.decode_bundle_manifest(golden_manifest())

    assert WorkspaceCheckpoint.validate_pair(checkpoint, manifest) == :ok

    crossed_tree = Map.put(manifest, "candidate_tree_sha256", String.duplicate("a", 64))

    assert WorkspaceCheckpoint.validate_pair(checkpoint, crossed_tree) ==
             {:error, {:invalid_workspace_checkpoint_pair, :identity}}

    crossed_task = put_in(manifest, ["task_projection", "task_id"], String.duplicate("b", 32))

    assert WorkspaceCheckpoint.validate_pair(checkpoint, crossed_task) ==
             {:error, {:invalid_workspace_checkpoint_pair, :task}}

    passed =
      Map.put(checkpoint, "gate", %{
        "status" => "passed",
        "revision" => checkpoint["committed_revision"],
        "receipt_ref" => "gate:golden"
      })

    with_receipt = Map.put(manifest, "gate_receipt", gate_receipt())
    assert WorkspaceCheckpoint.validate_pair(passed, with_receipt) == :ok

    assert WorkspaceCheckpoint.validate_pair(passed, manifest) ==
             {:error, {:invalid_workspace_checkpoint_pair, :gate}}

    assert WorkspaceCheckpoint.validate_pair(checkpoint, with_receipt) ==
             {:error, {:invalid_workspace_checkpoint_pair, :gate}}

    assert WorkspaceCheckpoint.validate_pair(Map.put(checkpoint, "task", 1), manifest) ==
             {:error, {:invalid_workspace_checkpoint_pair, :document}}

    assert WorkspaceCheckpoint.validate_pair(checkpoint, "not-a-manifest") ==
             {:error, {:invalid_workspace_checkpoint_pair, :document}}
  end

  test "the central bundle verifier rejects modified headers and credential-bearing members" do
    {checkpoint, bundle} = WorkspaceCheckpointFixture.build(%{session_ref: "session-1"})

    assert {:ok, _manifest} =
             WorkspaceCheckpointBundle.validate_stream(checkpoint, [bundle], Ryker.Secret.new([]))

    assert {:ok, _manifest} = WorkspaceCheckpointBundle.validate_stream(checkpoint, [bundle])

    assert checkpoint
           |> put_in(["bundle", "sha256"], String.duplicate("0", 64))
           |> WorkspaceCheckpointBundle.validate_stream([bundle]) ==
             {:error, {:invalid_workspace_checkpoint_bundle, :identity}}

    assert checkpoint
           |> Map.put("version", 3)
           |> WorkspaceCheckpointBundle.validate_stream([bundle]) ==
             {:error, {:invalid_workspace_checkpoint, :version}}

    <<name::binary-size(100), _mode::binary-size(8), rest::binary>> = bundle
    changed_bundle = name <> "0000777\0" <> rest

    changed_checkpoint =
      checkpoint
      |> put_in(["bundle", "sha256"], digest(changed_bundle))
      |> put_in(["bundle", "byte_size"], byte_size(changed_bundle))

    assert WorkspaceCheckpointBundle.validate_stream(
             changed_checkpoint,
             [changed_bundle],
             Ryker.Secret.new([])
           ) == {:error, {:invalid_workspace_checkpoint_bundle, :header}}

    invalid_octal = name <> "zzzzzzz\0" <> rest

    assert WorkspaceCheckpointBundle.validate_stream(
             rebind_bundle(checkpoint, invalid_octal),
             [invalid_octal],
             Ryker.Secret.new([])
           ) == {:error, {:invalid_workspace_checkpoint_bundle, :header}}

    {secret_checkpoint, secret_bundle} =
      WorkspaceCheckpointFixture.build(%{
        session_ref: "session-1",
        task: "token=ghp_abcdefghijklmnopqrstuvwxyz123456\n"
      })

    assert WorkspaceCheckpointBundle.validate_stream(
             secret_checkpoint,
             [secret_bundle],
             Ryker.Secret.new([])
           ) == {:error, {:invalid_workspace_checkpoint_bundle, :secret}}

    assert WorkspaceCheckpointBundle.validate_stream(
             checkpoint,
             [bundle],
             Ryker.Secret.new(["Status: in_progress"])
           ) == {:error, {:invalid_workspace_checkpoint_bundle, :secret}}

    assert WorkspaceCheckpointBundle.validate_stream(
             checkpoint,
             [bundle],
             Ryker.Secret.new(["short"])
           ) == {:error, {:invalid_workspace_checkpoint_bundle, :secret}}

    assert WorkspaceCheckpointBundle.validate_stream(checkpoint, [bundle], :not_a_secret_list) ==
             {:error, {:invalid_workspace_checkpoint_bundle, :secret_configuration}}

    malformed = "not-a-tar"

    malformed_checkpoint =
      checkpoint
      |> put_in(["bundle", "sha256"], digest(malformed))
      |> put_in(["bundle", "byte_size"], byte_size(malformed))

    assert WorkspaceCheckpointBundle.validate_stream(
             malformed_checkpoint,
             [malformed],
             Ryker.Secret.new([])
           ) == {:error, {:invalid_workspace_checkpoint_bundle, :tar}}

    changed_member =
      :binary.replace(bundle, "Status: in_progress\n", "Status: in_progresX\n")

    assert WorkspaceCheckpointBundle.validate_stream(
             rebind_bundle(checkpoint, changed_member),
             [changed_member],
             Ryker.Secret.new([])
           ) == {:error, {:invalid_workspace_checkpoint_bundle, :members}}

    invalid_terminator = binary_part(bundle, 0, byte_size(bundle) - 1) <> <<1>>

    assert WorkspaceCheckpointBundle.validate_stream(
             rebind_bundle(checkpoint, invalid_terminator),
             [invalid_terminator],
             Ryker.Secret.new([])
           ) == {:error, {:invalid_workspace_checkpoint_bundle, :terminator}}

    truncated_member = binary_part(bundle, 0, byte_size(bundle) - 1_535)

    assert WorkspaceCheckpointBundle.validate_stream(
             rebind_bundle(checkpoint, truncated_member),
             [truncated_member],
             Ryker.Secret.new([])
           ) == {:error, {:invalid_workspace_checkpoint_bundle, :member_length}}

    missing_manifest = rename_first_tar_member(bundle, "missing.json")

    assert WorkspaceCheckpointBundle.validate_stream(
             rebind_bundle(checkpoint, missing_manifest),
             [missing_manifest],
             Ryker.Secret.new([])
           ) == {:error, {:invalid_workspace_checkpoint_bundle, :manifest}}
  end

  defp golden_checkpoint, do: golden()["checkpoint"]

  defp golden_manifest do
    <<header::binary-size(512), rest::binary>> = Base.decode64!(golden()["bundle_base64"])
    "manifest.json" <> _name = header
    {size, ""} = header |> binary_part(124, 11) |> Integer.parse(8)
    binary_part(rest, 0, size)
  end

  defp golden, do: @golden |> File.read!() |> Jason.decode!()

  defp gate_receipt,
    do: %{"entry" => "gate/receipt.json", "sha256" => digest("receipt"), "byte_size" => 7}

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
end
