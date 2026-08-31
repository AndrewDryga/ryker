defmodule Responder.Evals.OperatorTaskTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Responder.Eval

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Mix.Shell.Process.flush()

    on_exit(fn ->
      Mix.Shell.Process.flush()
      Mix.shell(previous_shell)
    end)

    :ok
  end

  test "admission-pack exports every recorded judgment without a model or runtime" do
    Eval.run(["admission-pack"])

    documents = collect_info([])
    assert length(documents) == 12

    decoded = Enum.map(documents, &Jason.decode!/1)
    assert Enum.any?(decoded, &(&1["eval_id"] == "human_thread_reply_continues_existing_episode"))
    assert Enum.all?(decoded, &(&1["schema"]["title"] == "Responder admission decision"))
  end

  test "work-pack exports the universal Work prompt corpus without a model or runtime" do
    Eval.run(["work-pack"])

    documents = collect_info([])
    assert length(documents) == 3

    decoded = Enum.map(documents, &Jason.decode!/1)
    assert Enum.any?(decoded, &(&1["eval_id"] == "github_and_slack_remain_platform_adapters"))
    assert Enum.all?(decoded, &(&1["schema"]["title"] == "Responder episode result"))
  end

  test "world-pack exports every versioned scenario with its exact tool catalog" do
    Eval.run(["world-pack"])

    documents = collect_info([]) |> Enum.map(&Jason.decode!/1)

    assert MapSet.new(documents, &get_in(&1, ["scenario", "id"])) ==
             MapSet.new([
               "airflow-verification-arms-wait",
               "application-errors-follow-the-current-signal",
               "artifact-delivery-survives-work-handoff",
               "concurrent-human-feedback-serializes",
               "confirmed-guidance-becomes-memory",
               "creative-request-needs-no-fake-evidence",
               "current-uptime-check-uses-fresh-source",
               "github-pr-review-remains-in-thread",
               "grafana-firing-resolved-stays-in-cycle",
               "material-rollout-choice-asks-once",
               "noisy-context-keeps-current-request",
               "ordinary-thread-question-gets-natural-answer",
               "rivals-engineering-task-offer",
               "terraform-run-update-stays-in-one-session",
               "universal-webhook-unknown-payload",
               "va1-health-review-repairs-and-finishes",
               "weekly-health-review-offers-schedule",
               "worker-loss-reconciles-frozen-turn"
             ])

    document =
      Enum.find(
        documents,
        &(get_in(&1, ["scenario", "id"]) == "va1-health-review-repairs-and-finishes")
      )

    assert document["scenario"]["id"] == "va1-health-review-repairs-and-finishes"
    assert "model-world" in document["scenario"]["tags"]
    assert document["tool_catalog_sha256"] =~ ~r/\A[0-9a-f]{64}\z/

    assert Enum.any?(document["tool_catalog"]["servers"], fn server ->
             server["name"] == "responder-state" and
               Enum.any?(server["tools"], &(&1["name"] == "request_input"))
           end)

    schedule_document =
      Enum.find(
        documents,
        &(get_in(&1, ["scenario", "id"]) == "weekly-health-review-offers-schedule")
      )

    assert Enum.any?(schedule_document["tool_catalog"]["servers"], fn server ->
             server["name"] == "responder-state" and
               Enum.any?(server["tools"], &(&1["name"] == "propose_automation"))
           end)
  end

  test "the operator command refuses ambiguous invocation before starting Coop" do
    assert_raise Mix.Error, ~r/usage: mix responder.eval/, fn -> Eval.run([]) end

    assert_raise Mix.Error, ~r/invalid_arguments/, fn ->
      Eval.run(["admission", "--config", "relative.yaml", "unexpected"])
    end
  end

  test "the model release gate includes the fabricated product world" do
    makefile = File.read!(Path.expand("../../../Makefile", __DIR__))

    assert makefile =~
             ~r/^model-release-check:.*\beval-world\b/m,
           "model-release-check must execute the interactive fabricated-world product lane"

    assert makefile =~ ~r/^eval-world-smoke:.*\n(?:\t.*\n)*?\t.*--tag smoke --repeat 1/m
    assert makefile =~ ~r/^eval-world:.*\n(?:\t.*\n)*?\t.*--repeat 3 --paired-baseline/m
  end

  test "the deterministic replay gate executes versioned scenario host replays" do
    makefile = File.read!(Path.expand("../../../Makefile", __DIR__))

    assert makefile =~
             ~r/^eval-host-replay:\n(?:\t.*\n)*?\t.*world_runner_test\.exs/m,
           "eval-host-replay must execute the scenario-owned host replay driver"

    assert makefile =~ "world_concurrency_test.exs"
    assert makefile =~ "world_coverage_test.exs"
  end

  test "live evals refuse to inherit the production admission policy" do
    root =
      Path.join(
        System.tmp_dir!(),
        "responder-eval-authority-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    config_path = Path.join(root, "responder.yaml")

    File.write!(config_path, """
    version: 1
    mode: component
    host_ref: responder-eval-test
    coop:
      socket: #{Path.join(root, "coop.sock")}
      receive_timeout_ms: 100
    repositories: {}
    admission:
      policy:
        name: production-admission
        digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    work: {}
    """)

    for kind <- ["admission", "work", "world"] do
      arguments =
        if kind == "world",
          do: [kind, "--config", config_path, "--results", Path.join(root, "world.json")],
          else: [kind, "--config", config_path]

      assert_raise Mix.Error, ~r/model_eval_policies_not_configured/, fn ->
        Eval.run(arguments)
      end
    end
  end

  test "live commands fail with typed local configuration errors without reaching a model" do
    root =
      Path.join(System.tmp_dir!(), "responder-eval-command-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    config_path = Path.join(root, "responder.yaml")
    results_path = Path.join(root, "world-results.json")
    socket_path = Path.join(root, "coop-does-not-exist.sock")

    File.write!(config_path, """
    version: 1
    mode: component
    host_ref: responder-eval-test
    coop:
      socket: #{socket_path}
      receive_timeout_ms: 100
    repositories: {}
    admission:
      policy:
        name: admission-read
        digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    model_evals:
      socket: #{Path.join(root, "eval-coop-does-not-exist.sock")}
      no_tools_policy:
        name: responder-eval-no-tools-v1
        digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      world_policy:
        name: responder-eval-world-v1
        digest: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    work: {}
    """)

    assert_raise Mix.Error, ~r/12 admission model eval\(s\) failed/, fn ->
      Eval.run(["admission", "--config", config_path])
    end

    assert_raise Mix.Error, ~r/3 work model eval\(s\) failed/, fn ->
      Eval.run(["work", "--config", config_path])
    end

    assert_raise Mix.Error, ~r/model-world qualification failed/, fn ->
      Eval.run(["world", "--config", config_path, "--results", results_path])
    end

    world_report = results_path |> File.read!() |> Jason.decode!()
    assert world_report["version"] == 2
    refute world_report["summary"]["passed?"]
    assert length(world_report["results"]) == 54
    assert Enum.all?(world_report["results"], &(&1["status"] == "unrun"))

    assert_raise Mix.Error, ~r/model-world qualification failed/, fn ->
      Eval.run([
        "world",
        "--config",
        config_path,
        "--results",
        results_path,
        "--case",
        "ordinary-thread-question-gets-natural-answer",
        "--repeat",
        "1"
      ])
    end

    selected_report = results_path |> File.read!() |> Jason.decode!()
    assert [selected] = selected_report["results"]
    assert selected["scenario_id"] == "ordinary-thread-question-gets-natural-answer"
    assert selected["repeat_index"] == 1

    assert_raise Mix.Error, ~r/world_baseline_policy_not_configured/, fn ->
      Eval.run([
        "world",
        "--config",
        config_path,
        "--results",
        results_path,
        "--paired-baseline"
      ])
    end

    assert_raise Mix.Error, ~r/invalid_arguments/, fn ->
      Eval.run([
        "world",
        "--config",
        config_path,
        "--results",
        results_path,
        "--repeat",
        "0"
      ])
    end

    assert_raise Mix.Error, ~r/invalid_arguments/, fn ->
      Eval.run([
        "world",
        "--config",
        config_path,
        "--results",
        results_path,
        "--case",
        "ordinary-thread-question-gets-natural-answer",
        "--tag",
        "smoke"
      ])
    end

    assert_raise Mix.Error, ~r/invalid_arguments/, fn ->
      Eval.run([
        "world",
        "--config",
        config_path,
        "--config",
        config_path,
        "--results",
        results_path
      ])
    end

    assert File.exists?(results_path)
  end

  defp collect_info(messages) do
    receive do
      {:mix_shell, :info, [message]} -> collect_info([message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end
end
