defmodule Ryker.CoopFleet.JobSetupTest do
  use ExUnit.Case, async: true
  alias Ryker.CoopFleet.JobSetup

  defmodule Reader do
    @projects %{
      "gated" =>
        "subprojects: [infra]\ngate: ./run gate review\nreview:\n  env:\n    CI: \"1\"\n",
      "quoted" => ~s(gate: 'bash -lc "make test && make lint"'\n),
      "ungated" => "box:\n  env:\n    CI: \"1\"\n",
      "broken" => "gate: [unclosed\n",
      "configured" =>
        "gate: make test\nbox:\n  dockerfile: dev/Box.Dockerfile\n  compose: compose.test.yml\n  env:\n    PGHOST: episode-db\n    PGPORT: \"5432\"\n  egress: none\n  memory: 100g\n",
      "defaults" => "gate: make test\n",
      "missing-runtime" => "box:\n  compose: missing.yml\n",
      "runtime-unavailable" => "box:\n  compose: unavailable.yml\n",
      "invalid-path" => "box:\n  compose: ../outside.yml\n",
      "invalid-env" => "box:\n  env:\n    COOP_IMAGE: arbitrary\n",
      "services-disabled" => "box:\n  compose: missing.yml\n  auto_up: false\n",
      "empty-settings" => "box:\n  dockerfile:\n  compose:\n  env:\n  auto_up:\n  network:\n",
      "normalized" =>
        "box:\n  dockerfile: ./dev//tools/../Box.Dockerfile\n  compose: ./test/../compose.test.yml\n",
      "scalars" => "box:\n  env:\n    CI: true\n    PGPORT: 5432\n    RATE: 0.5\n"
    }

    def read(_binding, %{github_repository: "acme/" <> name}, ".agent/project.yaml", "abc") do
      case name do
        "missing" ->
          {:ok, :not_found}

        "refused" ->
          {:error, {:github_onboarding, :permission}}

        budget when budget in ~w(budget-small budget-large) ->
          count = if budget == "budget-small", do: 8, else: 9
          value = "x" <> String.duplicate("<>&\\u2028", 340) <> "x"
          values = Enum.map_join(1..count, "\n", &"    KEY#{&1}: \"#{value}\"")
          {:ok, "box:\n  env:\n" <> values <> "\n"}

        available ->
          {:ok, Map.fetch!(@projects, available)}
      end
    end

    def read(_binding, %{github_repository: "acme/" <> name}, path, "abc") do
      case {name, path} do
        {name, "dev/Box.Dockerfile"} when name in ~w(configured normalized) ->
          {:ok, "ARG COOP_BASE_IMAGE\nFROM ${COOP_BASE_IMAGE}\n"}

        {name, "compose.test.yml"} when name in ~w(configured normalized) ->
          {:ok, "services:\n  db:\n    image: postgres:18\n"}

        {"defaults", ".agent/Dockerfile"} ->
          {:ok, "FROM coop-box\n"}

        {"defaults", ".agent/compose.yml"} ->
          {:ok, "services:\n  db:\n    image: postgres:18\n"}

        {"runtime-unavailable", "unavailable.yml"} ->
          {:error, :timeout}

        _missing ->
          {:ok, :not_found}
      end
    end
  end

  defp resolve(name),
    do: JobSetup.resolve(%{name: "binding"}, %{github_repository: "acme/" <> name}, "abc", Reader)

  # Coop job-setup:2 runs only the check the job names: the trusted parent's `gate:` stopped
  # applying to remote reviews, so Ryker resolves it at the job's base commit and freezes it.
  test "a repository's gate becomes the job's check, split the way Coop splits it" do
    assert {:ok, %{"check" => %{"argv" => ["./run", "gate", "review"], "environment" => %{}}}} =
             resolve("gated")

    assert {:ok, %{"check" => %{"argv" => ["bash", "-lc", "make test && make lint"]}}} =
             resolve("quoted")
  end

  test "a missing gate means no check and malformed project settings are refused" do
    for name <- ~w(missing ungated) do
      assert {:ok, %{"check" => %{"argv" => [], "environment" => %{}}}} = resolve(name)
    end

    assert resolve("broken") ==
             {:error, {:coop_worker_project_setup_refused, ".agent/project.yaml", :invalid_yaml}}

    assert resolve("refused") == {:error, {:github_onboarding, :permission}}
  end

  test "project runtime freezes selected files and literal environment without repository policy" do
    assert {:ok, setup} = resolve("configured")

    assert setup == %{
             "check" => %{"argv" => ["make", "test"], "environment" => %{}},
             "runtime" => %{
               "version" => 1,
               "dockerfile" => "dev/Box.Dockerfile",
               "compose" => "compose.test.yml",
               "environment" => %{"PGHOST" => "episode-db", "PGPORT" => "5432"}
             }
           }

    assert {:ok, %{"runtime" => runtime}} = resolve("defaults")

    assert runtime == %{
             "version" => 1,
             "dockerfile" => ".agent/Dockerfile",
             "compose" => ".agent/compose.yml",
             "environment" => %{}
           }
  end

  test "a declared test stack cannot disappear or escape the repository silently" do
    assert resolve("missing-runtime") ==
             {:error, {:coop_worker_project_setup_refused, "missing.yml", :not_found}}

    assert resolve("invalid-path") ==
             {:error, {:coop_worker_project_setup_refused, "box.compose", :invalid_path}}

    assert resolve("invalid-env") ==
             {:error, {:coop_worker_project_setup_refused, "box.env", :invalid_environment}}

    assert resolve("runtime-unavailable") == {:error, :timeout}

    assert {:ok, setup} = resolve("services-disabled")

    assert setup["runtime"] == %{
             "version" => 1,
             "dockerfile" => "",
             "compose" => "",
             "environment" => %{}
           }
  end

  test "empty project options keep the same defaults as Coop's project parser" do
    assert {:ok, setup} = resolve("empty-settings")

    assert setup == %{
             "check" => %{"argv" => [], "environment" => %{}},
             "runtime" => %{
               "version" => 1,
               "dockerfile" => "",
               "compose" => "",
               "environment" => %{}
             }
           }
  end

  test "valid project path spellings become canonical selectors before they are frozen" do
    assert {:ok, %{"runtime" => runtime}} = resolve("normalized")

    assert runtime == %{
             "version" => 1,
             "dockerfile" => "dev/Box.Dockerfile",
             "compose" => "compose.test.yml",
             "environment" => %{}
           }
  end

  test "plain YAML numbers and booleans become literal environment strings" do
    assert {:ok, %{"runtime" => %{"environment" => environment}}} = resolve("scalars")
    assert environment == %{"CI" => "true", "PGPORT" => "5432", "RATE" => "0.5"}
  end

  test "project defaults exceeding the escaped relay budget name box.env before placement" do
    assert {:ok, %{"runtime" => %{"environment" => values}}} = resolve("budget-small")
    assert map_size(values) == 8

    assert resolve("budget-large") ==
             {:error, {:coop_worker_project_setup_refused, "box.env", :invalid_environment}}
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
      assert JobSetup.split(input) == expected, inspect(input)
    end
  end
end
