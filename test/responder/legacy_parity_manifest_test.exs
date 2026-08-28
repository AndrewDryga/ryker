defmodule Responder.LegacyParityManifestTest do
  use ExUnit.Case, async: true

  @manifest_path "docs/elixir-episode-kernel-go-parity.json"
  @targets MapSet.new([
             "automation_waits",
             "coop_runtime",
             "engineering_github",
             "episode_kernel",
             "final_protocol",
             "legacy_archive",
             "memory_recall",
             "slack_gateway",
             "source_ingress"
           ])

  test "every scoped legacy Go test has one replacement owner" do
    manifest = decode_manifest!()

    assert Map.keys(manifest) |> Enum.sort() ==
             [
               "files",
               "stage1_equivalents",
               "stage2_equivalents",
               "stage2_pending_model_evals",
               "version"
             ]

    assert manifest["version"] == 4

    paths = Enum.map(manifest["files"], & &1["path"])
    assert Enum.uniq(paths) == paths

    mapped =
      Enum.flat_map(manifest["files"], fn file ->
        assert Map.keys(file) |> Enum.sort() == ["groups", "path"]
        assert safe_go_test_path?(file["path"])
        assert File.regular?(file["path"])

        expected =
          Enum.flat_map(file["groups"], fn group ->
            assert Map.keys(group) |> Enum.sort() == ["target", "tests"]
            assert MapSet.member?(@targets, group["target"])
            assert group["tests"] != []

            Enum.map(group["tests"], &{&1, group["target"]})
          end)

        expected_names = Enum.map(expected, &elem(&1, 0))
        assert Enum.uniq(expected_names) == expected_names

        actual_names = go_tests(file["path"])
        assert diff(actual_names, expected_names) == %{unmapped: [], stale: []}

        Enum.map(expected, fn {name, target} ->
          {{file["path"], name}, target}
        end)
      end)
      |> Map.new()

    assert map_size(mapped) > 0

    stage1_equivalents = validate_equivalents(manifest["stage1_equivalents"], mapped)
    stage2_equivalents = validate_equivalents(manifest["stage2_equivalents"], mapped)

    pending_model_evals =
      validate_pending_model_evals(manifest["stage2_pending_model_evals"], mapped)

    kernel_owned =
      for {key, "episode_kernel"} <- mapped,
          into: MapSet.new(),
          do: key

    assert MapSet.difference(kernel_owned, MapSet.new(stage1_equivalents)) == MapSet.new()

    assert Enum.all?(stage2_equivalents, fn key -> mapped[key] == "source_ingress" end)
    assert Enum.uniq(stage2_equivalents) == stage2_equivalents

    pending_legacy_keys =
      pending_model_evals
      |> Enum.filter(&match?({:legacy, _key}, &1))
      |> Enum.map(fn {:legacy, key} -> key end)

    assert MapSet.disjoint?(MapSet.new(stage2_equivalents), MapSet.new(pending_legacy_keys))

    assert {:standalone, "human_thread_reply_continues_existing_episode"} in pending_model_evals
  end

  test "drift reports both unclassified and stale test names" do
    assert diff(["TestCurrent", "TestNew"], ["TestCurrent", "TestRemoved"]) == %{
             unmapped: ["TestNew"],
             stale: ["TestRemoved"]
           }
  end

  defp decode_manifest! do
    @manifest_path
    |> File.read!()
    |> Jason.decode!()
  end

  defp validate_equivalents(equivalents, mapped) do
    Enum.map(equivalents, fn equivalent ->
      assert Map.keys(equivalent) |> Enum.sort() ==
               ["go_file", "go_test", "replacement_file", "replacement_test"]

      key = {equivalent["go_file"], equivalent["go_test"]}
      assert Map.has_key?(mapped, key)
      assert File.regular?(equivalent["replacement_file"])

      replacement_test = equivalent["replacement_test"]

      if replacement_test != nil do
        assert is_binary(replacement_test) and replacement_test != ""
        assert File.read!(equivalent["replacement_file"]) =~ replacement_test
      end

      key
    end)
  end

  defp validate_pending_model_evals(evals, mapped) do
    Enum.map(evals, fn eval ->
      assert File.regular?(eval["context_fixture"])
      assert is_binary(eval["reason"]) and String.trim(eval["reason"]) != ""

      case Map.keys(eval) |> Enum.sort() do
        ["context_fixture", "go_file", "go_test", "reason"] ->
          key = {eval["go_file"], eval["go_test"]}
          assert mapped[key] == "source_ingress"
          {:legacy, key}

        ["context_fixture", "eval_id", "reason"] ->
          assert is_binary(eval["eval_id"]) and String.trim(eval["eval_id"]) != ""
          {:standalone, eval["eval_id"]}

        fields ->
          flunk("unsupported pending model eval fields: #{inspect(fields)}")
      end
    end)
  end

  defp go_tests(path) do
    ~r/^func (Test[A-Za-z0-9_]+)\(/m
    |> Regex.scan(File.read!(path), capture: :all_but_first)
    |> List.flatten()
    |> Enum.sort()
  end

  defp diff(actual, expected) do
    actual = MapSet.new(actual)
    expected = MapSet.new(expected)

    %{
      unmapped: actual |> MapSet.difference(expected) |> Enum.sort(),
      stale: expected |> MapSet.difference(actual) |> Enum.sort()
    }
  end

  defp safe_go_test_path?(path) do
    is_binary(path) and String.starts_with?(path, "internal/") and
      String.ends_with?(path, "_test.go") and not String.contains?(path, "..")
  end
end
