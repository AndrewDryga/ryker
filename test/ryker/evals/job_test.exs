defmodule Ryker.Evals.JobTest do
  use ExUnit.Case, async: false
  alias Ryker.CoopFleet.JobSpec
  alias Ryker.Evals.{Job, WorldSource}

  setup do
    for {name, value} <- %{
          "RYKER_EVAL_SOCKET" => "/var/lib/ryker/eval-coop/control.sock",
          "RYKER_EVAL_JUDGE_TARGET" => "codex:fixture/low@eval",
          "RYKER_EVAL_WORLD_TARGET" => "codex:fixture/high@eval",
          "RYKER_EVAL_BASELINE_TARGET" => "codex:baseline/high@eval"
        } do
      previous = System.get_env(name)
      System.put_env(name, value)

      on_exit(fn ->
        if previous, do: System.put_env(name, previous), else: System.delete_env(name)
      end)
    end

    :ok
  end

  test "eval jobs need no database or copied digest and always have empty authority" do
    assert {:ok, selection} = Job.world()

    for template <- Map.values(selection) do
      assert {:ok, job, digest} = Job.bind(template, "eval:unique")
      assert job["job_ref"] == "eval:unique"
      assert job["source"] == nil
      assert job["companions"] == []
      assert job["repository_read_only"]
      refute job["project_env"]
      refute job["project_mcp"]
      assert JobSpec.digest(job) == {:ok, digest}
      refute digest == template.digest
    end

    assert Job.socket() == {:ok, "/var/lib/ryker/eval-coop/control.sock"}
  end

  test "models may be shared by lanes; a baseline is optional" do
    System.put_env("RYKER_EVAL_WORLD_TARGET", System.fetch_env!("RYKER_EVAL_JUDGE_TARGET"))
    System.delete_env("RYKER_EVAL_BASELINE_TARGET")
    assert {:ok, %{baseline: nil}} = Job.world()
  end

  test "changing a template's execution authority is refused even with a recomputed digest" do
    {:ok, template} = Job.new(:learning, "codex:fixture/high@eval")

    for {field, value} <- [
          {"repository_read_only", false},
          {"project_env", true},
          {"source", %{}}
        ] do
      document = Map.put(template.document, field, value)

      changed = %{
        template
        | document: document,
          digest: Ryker.CanonicalJSON.worker_digest(document)
      }

      assert Job.bind(changed, "eval:ref") == {:error, :invalid_model_eval_job}
    end

    assert Job.bind(%{template | digest: String.duplicate("a", 64)}, "eval:ref") ==
             {:error, :invalid_model_eval_job}
  end

  # rivals-engineering-task-offer could never pass while eval Work had no repository: Work
  # rightly asked for one instead of offering the task. A world job may now read the scenario's
  # own staged checkout, and nothing else.
  test "a world job reads only a staged scenario checkout, and read-only" do
    {:ok, world} = Job.new(:world, "codex:fixture/high@eval")
    {:ok, learning} = Job.new(:learning, "codex:fixture/high@eval")

    source =
      WorldSource.source(
        "tenant-rivals-scraper",
        String.duplicate("1", 40),
        String.duplicate("2", 40),
        ~U[2026-08-21 02:21:46Z]
      )

    assert {:ok, sourced} = Job.with_source(world, source)
    assert {:ok, job, _digest} = Job.bind(sourced, "eval:rivals")
    assert job["source"] == source
    assert job["repository_read_only"]

    assert Job.with_source(learning, source) == {:error, :invalid_model_eval_job}

    assert Job.with_source(world, %{source | "github_repository" => "AndrewDryga/ryker"}) ==
             {:error, :invalid_model_eval_job}
  end

  test "missing or malformed target and socket configuration fails closed" do
    System.delete_env("RYKER_EVAL_JUDGE_TARGET")
    assert Job.world() == {:error, :model_eval_targets_not_configured}

    for target <- [nil, "", "a b", "\n", "x\0y", String.duplicate("x", 257)] do
      assert Job.new(:judge, target) == {:error, :invalid_model_eval_target}
    end

    System.delete_env("RYKER_EVAL_SOCKET")
    assert Job.socket() == {:error, :model_eval_socket_not_configured}
    System.put_env("RYKER_EVAL_SOCKET", "relative/control.sock")
    assert Job.socket() == {:error, :model_eval_socket_must_be_absolute}
  end
end
