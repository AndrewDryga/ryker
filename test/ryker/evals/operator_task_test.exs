defmodule Ryker.Evals.OperatorTaskTest do
  use Ryker.DataCase, async: false

  alias Mix.Tasks.Ryker.Eval
  alias Ryker.Settings

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
    assert length(documents) == 14

    decoded = Enum.map(documents, &Jason.decode!/1)
    assert Enum.any?(decoded, &(&1["eval_id"] == "human_thread_reply_continues_existing_episode"))
    assert Enum.any?(decoded, &(&1["eval_id"] == "direct_question_selects_conversational_work"))
    assert Enum.any?(decoded, &(&1["eval_id"] == "broad_health_assessment_selects_deep_work"))
    assert Enum.all?(decoded, &(&1["schema"]["title"] == "Ryker admission decision"))
  end

  test "work-pack exports the universal Work prompt corpus without a model or runtime" do
    Eval.run(["work-pack"])

    documents = collect_info([])
    assert length(documents) == 12

    decoded = Enum.map(documents, &Jason.decode!/1)
    assert Enum.any?(decoded, &(&1["eval_id"] == "github_and_slack_remain_platform_adapters"))
    assert Enum.all?(decoded, &(&1["schema"]["title"] == "Ryker episode result"))
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
               "explicit-operator-incident-offer",
               "github-pr-review-remains-in-thread",
               "grafana-firing-resolved-stays-in-cycle",
               "material-rollout-choice-asks-once",
               "missing-project-answer-is-remembered",
               "missing-project-answer-unblocks-blocked-checks",
               "missing-project-candidates-need-one-question",
               "missing-project-denied-access-asks-about-access",
               "missing-project-discovery-failure-stays-honest",
               "missing-project-discovery-proves-one-target",
               "missing-project-empty-discovery-still-asks",
               "missing-project-many-candidates-narrow-first",
               "missing-project-review-asks-for-context",
               "noisy-context-keeps-current-request",
               "one-outage-two-channels-joins-one-episode",
               "ordinary-thread-question-gets-natural-answer",
               "similar-alert-different-environment-stays-separate",
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
    assert_raise Mix.Error, ~r/usage: mix ryker.eval/, fn -> Eval.run([]) end

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

  test "the parallel repository gate gives host replay a disposable database" do
    # `make check` runs host replay beside the full Elixir suite. Sharing
    # ryker_test made four world cases reject their supposedly disposable
    # database before exercising any host behaviour.
    makefile = File.read!(Path.expand("../../../Makefile", __DIR__))

    assert makefile =~
             ~r/^eval-host-replay:\n\tRYKER_TEST_ISOLATED=1 scripts\/elixir-test\.sh/m,
           "eval-host-replay must not share the full Elixir suite's database"
  end

  test "live evals refuse to inherit a reviewed production authority" do
    # The eval must not be able to acquire the installation's admission grant by
    # naming it; isolation is checked against the database it is pointed at.
    environment(%{
      "RYKER_EVAL_SOCKET" => "/tmp/ryker-eval-does-not-exist.sock",
      "RYKER_EVAL_NO_TOOLS_POLICY" => "ryker-admission-v1",
      "RYKER_EVAL_NO_TOOLS_POLICY_DIGEST" => String.duplicate("a", 64),
      "RYKER_EVAL_WORLD_POLICY" => "ryker-eval-world-v1",
      "RYKER_EVAL_WORLD_POLICY_DIGEST" => String.duplicate("c", 64)
    })

    {:ok, _} = Settings.initialize("control-plane:local")

    {:ok, _} =
      Settings.put_policy_binding(
        %{
          purpose: :admission,
          scope_kind: :installation,
          scope_ref: "",
          policy_name: "ryker-admission-v1",
          policy_digest: String.duplicate("a", 64),
          verified_by: :import
        },
        1,
        "control-plane:local"
      )

    for kind <- ["admission", "work"] do
      assert_raise Mix.Error, ~r/model_eval_reuses_production_authority/, fn ->
        Eval.run([kind])
      end
    end
  end

  test "live eval commands refuse missing authority and malformed arguments locally" do
    root =
      Path.join(System.tmp_dir!(), "ryker-eval-command-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    results_path = Path.join(root, "world-results.json")

    for kind <- ["admission", "work"] do
      assert_raise Mix.Error, ~r/model_eval_policies_not_configured/, fn -> Eval.run([kind]) end
    end

    assert_raise Mix.Error, ~r/model_eval_policies_not_configured/, fn ->
      Eval.run(["world", "--results", results_path])
    end

    # A configuration path is no longer an argument any eval command accepts.
    assert_raise Mix.Error, ~r/invalid_arguments/, fn ->
      Eval.run(["admission", "--config", Path.join(root, "ryker.yaml")])
    end

    assert_raise Mix.Error, ~r/invalid_arguments/, fn ->
      Eval.run(["world", "--results", results_path, "--repeat", "0"])
    end

    assert_raise Mix.Error, ~r/invalid_arguments/, fn ->
      Eval.run([
        "world",
        "--results",
        results_path,
        "--case",
        "ordinary-thread-question-gets-natural-answer",
        "--tag",
        "smoke"
      ])
    end

    assert_raise Mix.Error, ~r/invalid_arguments/, fn ->
      Eval.run(["world", "--results", results_path, "--results", results_path])
    end
  end

  defp collect_info(messages) do
    receive do
      {:mix_shell, :info, [message]} -> collect_info([message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end

  defp environment(values) do
    Enum.each(values, fn {name, value} -> put_variable(name, value) end)
    :ok
  end

  defp put_variable(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)
    on_exit(fn -> restore_variable(name, previous) end)
  end

  defp restore_variable(name, nil), do: System.delete_env(name)
  defp restore_variable(name, previous), do: System.put_env(name, previous)
end
