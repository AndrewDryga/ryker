defmodule Ryker.CoopFleet.WorkspaceCheckpointBundleTest do
  use ExUnit.Case, async: true
  alias Ryker.CoopFleet.WorkspaceCheckpointBundle, as: Bundle
  alias Ryker.Fixtures.WorkspaceCheckpoint, as: Fixture

  test "a real Coop v2 capture validates unchanged across transport chunk boundaries" do
    fixture =
      Path.expand("../../../testdata/protocol/workspace-checkpoint-v2.golden.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    bytes = Base.decode64!(fixture["bundle_base64"])

    for size <- [1, 511, 4096] do
      assert {:ok, manifest} = Bundle.validate_stream(fixture["checkpoint"], chunks(bytes, size))
      assert manifest["version"] == 2
      assert manifest["repository"]["entry"] == "repository.tar"
      assert length(manifest["untracked_files"]) == 1
    end
  end

  test "tar identity and members validate across every kind of chunk boundary" do
    {checkpoint, bytes} =
      Fixture.build(%{session_ref: "source", patch: :binary.copy("change", 100)})

    assert {:ok, expected} = Bundle.validate_stream(checkpoint, [bytes])

    for size <- [1, 7, 511, 512, 513, 1024, 4096] do
      assert {:ok, ^expected} = Bundle.validate_stream(checkpoint, chunks(bytes, size))
    end

    assert {:error, _} =
             Bundle.validate_stream(
               checkpoint,
               chunks(binary_part(bytes, 0, byte_size(bytes) - 1), 7)
             )

    assert {:error, _} = Bundle.validate_stream(checkpoint, [bytes, <<0>>])
    <<head::binary-size(2_000), value, rest::binary>> = bytes

    assert {:error, _} =
             Bundle.validate_stream(checkpoint, [head, <<Bitwise.bxor(value, 1)>>, rest])
  end

  test "literal and token secrets cannot hide at a chunk boundary or in binary content" do
    for secret <- [
          "configured-secret",
          "-----BEGIN PRIVATE KEY-----",
          "xoxb-" <> :binary.copy("A", 10),
          "ghp_" <> :binary.copy("B", 20),
          "AKIA" <> :binary.copy("C", 16),
          "emk-" <> :binary.copy("D", 10)
        ] do
      {checkpoint, bytes} =
        Fixture.build(%{session_ref: "source", patch: <<255>> <> " " <> secret})

      for size <- [1, 7, 64, 512, 4096] do
        assert Bundle.validate_stream(
                 checkpoint,
                 chunks(bytes, size),
                 Ryker.Secret.new(["configured-secret"])
               ) == {:error, {:invalid_workspace_checkpoint_bundle, :secret}}
      end
    end

    {checkpoint, bytes} =
      Fixture.build(%{session_ref: "source", patch: "ghp_" <> :binary.copy("A", 300_000) <> "!"})

    assert Bundle.validate_stream(checkpoint, chunks(bytes, 16_384)) ==
             {:error, {:invalid_workspace_checkpoint_bundle, :secret}}
  end

  test "similar strings without the required token boundaries remain ordinary code" do
    patch =
      "prefixghp_" <> :binary.copy("A", 30) <> " AKIA" <> :binary.copy("B", 17) <> " xoxb-short"

    {checkpoint, bytes} = Fixture.build(%{session_ref: "source", patch: patch})

    for size <- [1, 7, 64, 4096],
        do: assert(match?({:ok, _}, Bundle.validate_stream(checkpoint, chunks(bytes, size))))
  end

  test "a checkpoint larger than 64 MiB validates without retaining its members" do
    {checkpoint, bytes} =
      Fixture.build(%{
        session_ref: "source",
        patch: :binary.copy("diff line\n", 7 * 1_024 * 1_024)
      })

    assert byte_size(bytes) > 64 * 1_024 * 1_024
    assert {:ok, manifest} = Bundle.validate_stream(checkpoint, chunks(bytes, 256 * 1_024))
    assert manifest["repository"]["byte_size"] > 64 * 1_024 * 1_024
  end

  test "unsupported binary tar numbers return a refusal, never a decoder crash" do
    {checkpoint, bytes} = Fixture.build(%{session_ref: "source"})
    <<prefix::binary-size(124), _size::binary-size(12), rest::binary>> = bytes

    for field <- [<<255::96>>, <<128, 0::88>>, <<128, 1::1, 0::87>>, <<255, 0::88>>] do
      assert Bundle.validate_stream(checkpoint, [prefix <> field <> rest]) ==
               {:error, {:invalid_workspace_checkpoint_bundle, :header}}
    end
  end

  test "GNU large-file headers parse without allocating the declared member" do
    {checkpoint, bytes} = Fixture.build(%{session_ref: "source"})
    assert {:ok, manifest} = Bundle.validate_stream(checkpoint, [bytes])
    size = 8_589_934_592
    manifest = put_in(manifest, ["repository", "byte_size"], size)

    manifest =
      update_in(manifest, ["task_projection", "files"], fn files ->
        Enum.map(files, &Map.delete(&1, "path_bytes"))
      end)

    document = Jason.encode!(manifest)

    prefix =
      Fixture.tar_header("manifest.json", byte_size(document)) <>
        document <>
        :binary.copy(<<0>>, rem(512 - rem(byte_size(document), 512), 512)) <>
        Fixture.tar_header("repository.tar", size)

    checkpoint = put_in(checkpoint, ["bundle", "byte_size"], size + byte_size(prefix) + 2_048)

    assert Bundle.validate_stream(checkpoint, chunks(prefix, 7)) ==
             {:error, {:invalid_workspace_checkpoint_bundle, :member_length}}
  end

  defp chunks(bytes, size) do
    Stream.unfold(bytes, fn
      <<>> ->
        nil

      remaining ->
        count = min(size, byte_size(remaining))
        <<chunk::binary-size(count), rest::binary>> = remaining
        {chunk, rest}
    end)
  end
end
