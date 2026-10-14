defmodule Ryker.CiWorkflowTest do
  # CI ran the full gate, `make check`, as one job: a median 38.5 minutes in
  # October 2026, one serial test VM for 15 to 20 of them and the retention
  # simulation alone for 13 to 18 more. It now runs the gate's parts as jobs of
  # their own. A part added to `make check` and to no job would pass every pull
  # request unseen, and a partition no job runs would leave a quarter of the
  # serial test files untested.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "CI runs every part of the full gate" do
    makefile = read!("Makefile")

    ci =
      for {_name, job} <- jobs(),
          %{"run" => run} <- job["steps"],
          "make " <> arguments <- String.split(run, "\n"),
          target <- targets(arguments),
          into: MapSet.new(),
          do: target

    gate = makefile |> recipe("check") |> made() |> expand(makefile)
    missing = MapSet.difference(gate, expand(ci, makefile))

    assert MapSet.size(gate) > 10
    assert missing == MapSet.new(), "make check runs #{inspect(missing)}, which no CI job runs"
  end

  test "CI runs the suite in every partition" do
    tests = jobs()["tests"]
    [step] = Enum.filter(tests["steps"], &get_in(&1, ["env", "RYKER_TEST_PARTITION"]))

    assert step["run"] =~ "make elixir-partitions"

    assert tests["strategy"]["matrix"]["partition"] ==
             Enum.to_list(0..step["env"]["RYKER_TEST_PARTITIONS"])
  end

  defp jobs do
    ".github/workflows/ci.yml" |> read!() |> YamlElixir.read_from_string!() |> Map.fetch!("jobs")
  end

  # Every target a set of targets runs: each one, its prerequisites and the
  # targets its recipe hands to $(MAKE), all the way down.
  defp expand(targets, makefile) do
    Enum.reduce(targets, MapSet.new(), fn target, seen ->
      if MapSet.member?(seen, target) do
        seen
      else
        children = prerequisites(makefile, target) ++ made(recipe(makefile, target))
        MapSet.union(seen, expand(children, makefile) |> MapSet.put(target))
      end
    end)
  end

  defp prerequisites(makefile, target) do
    case Regex.run(~r/^#{Regex.escape(target)}:([^=\n]*)$/m, makefile, capture: :all_but_first) do
      [names] -> names |> String.split() |> Enum.reject(&(&1 == "|"))
      nil -> []
    end
  end

  defp made(recipe) do
    recipe
    |> String.replace("\\\n", " ")
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(line, "$(MAKE)", parts: 2) do
        [_before, arguments] -> targets(arguments)
        [_no_make] -> []
      end
    end)
  end

  # The words of a make command line that name targets, not flags or variables.
  defp targets(arguments) do
    arguments
    |> String.split()
    |> Enum.reject(&(String.starts_with?(&1, "-") or String.contains?(&1, "=")))
  end

  # The recipe for one target: its rule line to the next blank line, or nothing
  # for a target with no rule of its own.
  defp recipe(makefile, target) do
    case String.split(makefile, "\n#{target}:", parts: 2) do
      [_before, after_rule] -> after_rule |> String.split("\n\n", parts: 2) |> hd()
      [_no_rule] -> ""
    end
  end

  defp read!(relative), do: File.read!(Path.join(@root, relative))
end
