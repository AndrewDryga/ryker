defmodule Ryker.CoopFleet.JobCheckTest do
  use ExUnit.Case, async: true
  alias Ryker.CoopFleet.JobCheck

  defmodule Reader do
    def read(_binding, %{github_repository: "acme/" <> name}, ".agent/project.yaml", "abc") do
      case name do
        "gated" ->
          {:ok, "subprojects: [infra]\ngate: ./run gate review\nreview:\n  env:\n    CI: \"1\"\n"}

        "quoted" ->
          {:ok, ~s(gate: 'bash -lc "make test && make lint"'\n)}

        "ungated" ->
          {:ok, "box:\n  env:\n    CI: \"1\"\n"}

        "broken" ->
          {:ok, "gate: [unclosed\n"}

        "missing" ->
          {:ok, :not_found}

        "refused" ->
          {:error, {:github_onboarding, :permission}}
      end
    end
  end

  defp resolve(name),
    do: JobCheck.resolve(%{name: "binding"}, %{github_repository: "acme/" <> name}, "abc", Reader)

  # Coop job-setup:2 runs only the check the job names: the trusted parent's `gate:` stopped
  # applying to remote reviews, so Ryker resolves it at the job's base commit and freezes it.
  test "a repository's gate becomes the job's check, split the way Coop splits it" do
    assert {:ok, %{"argv" => ["./run", "gate", "review"], "environment" => %{}}} =
             resolve("gated")

    assert {:ok, %{"argv" => ["bash", "-lc", "make test && make lint"]}} = resolve("quoted")
  end

  test "no project file, no gate or an unreadable gate means no check" do
    for name <- ~w(missing ungated broken) do
      assert {:ok, %{"argv" => [], "environment" => %{}}} = resolve(name)
    end

    assert resolve("refused") == {:error, {:github_onboarding, :permission}}
  end

  # The same cases as Coop's TestShellSplit.
  test "splits a command like a shell without running one" do
    for {input, expected} <- [
          {"", []},
          {"   ", []},
          {"bar --baz", ["bar", "--baz"]},
          {~s(bash -lc "npm test && npm run lint"), ["bash", "-lc", "npm test && npm run lint"]},
          {"bash -lc 'a b'", ["bash", "-lc", "a b"]},
          {~S(a\ b), ["a b"]},
          {~s(a "b c" d), ["a", "b c", "d"]},
          {~s("a""b"), ["ab"]},
          {"''", [""]},
          {~s(a "b c), ["a", "b c"]},
          {"trail\\", ["trail\\"]}
        ] do
      assert JobCheck.split(input) == expected, inspect(input)
    end
  end
end
