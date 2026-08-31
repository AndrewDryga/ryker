defmodule Responder.Cutover.ManifestTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Responder.{CanonicalJSON, Cutover.Manifest}

  @cutover_at ~U[2026-08-30 12:00:00.000000Z]

  test "one reviewed manifest is created exclusively with owner-only permissions" do
    source = source_file!("sealed")
    destination = destination("sealed")

    assert {:ok, result} =
             Manifest.create(source, destination,
               cutover_at: @cutover_at,
               runner: runner(),
               sqlite3: "/usr/bin/sqlite3",
               workspace_ref: "slack:T123"
             )

    bytes = File.read!(destination)
    assert byte_size(bytes) == result.bytes
    assert :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) == result.sha256
    assert String.ends_with?(bytes, "\n")

    envelope = Jason.decode!(bytes)
    assert envelope["sha256"] == CanonicalJSON.digest(envelope["manifest"])
    assert envelope["manifest"]["items"] == []

    assert {:ok, stat} = File.stat(destination)
    assert band(stat.mode, 0o777) == 0o600

    assert Manifest.create(source, destination,
             cutover_at: @cutover_at,
             runner: runner(),
             sqlite3: "/usr/bin/sqlite3",
             workspace_ref: "slack:T123"
           ) == {:error, {:cutover_manifest_exists, destination}}
  end

  test "invalid destinations and failed inventories leave no review artifact" do
    source = source_file!("refused")
    destination = destination("refused")

    assert Manifest.create(source, "relative.json",
             cutover_at: @cutover_at,
             runner: runner(),
             sqlite3: "/usr/bin/sqlite3",
             workspace_ref: "slack:T123"
           ) == {:error, {:invalid_cutover_manifest, :path}}

    assert Manifest.create(source, destination,
             cutover_at: @cutover_at,
             runner: fn _executable, _arguments -> {"corrupt", 0} end,
             sqlite3: "/usr/bin/sqlite3",
             workspace_ref: "slack:T123"
           ) == {:error, :legacy_snapshot_integrity_failed}

    refute File.exists?(destination)
  end

  defp runner do
    fn _executable, arguments ->
      sql = List.last(arguments)

      cond do
        String.contains?(sql, "PRAGMA quick_check") -> {"ok\n", 0}
        String.contains?(sql, "FROM sqlite_schema") -> {schema_objects_json(), 0}
        String.contains?(sql, "FROM schema_version") -> {~s([{"version":90}]), 0}
        true -> {"[]", 0}
      end
    end
  end

  defp schema_objects_json do
    Path.expand("../../../testdata/cutover/go-schema-v90.objects.json.gz", __DIR__)
    |> File.read!()
    |> :zlib.gunzip()
  end

  defp source_file!(suffix) do
    path = destination("source-#{suffix}")
    File.write!(path, "frozen legacy snapshot")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp destination(suffix) do
    Path.join(
      System.tmp_dir!(),
      "responder-cutover-#{suffix}-#{System.unique_integer([:positive])}.json"
    )
  end
end
