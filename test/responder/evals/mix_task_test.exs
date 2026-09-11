defmodule Responder.Evals.MixTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Responder.Eval
  alias Responder.Evals.{AdmissionCase, WorkCase, WorldCase}

  test "offline pack commands emit every sanitized case without a model" do
    assert_pack("admission-pack", AdmissionCase)
    assert_pack("work-pack", WorkCase)
    assert_pack("world-pack", WorldCase)
  end

  test "live commands fail closed on unknown arguments and unconfigured authority" do
    # Nothing reaches a model before the local arguments and the dedicated
    # evaluation authority have both been resolved.
    assert_raise Mix.Error, ~r/admission eval failed: :invalid_arguments/, fn ->
      Eval.run(["admission", "--config", "/tmp/responder.yaml"])
    end

    assert_raise Mix.Error, ~r/work eval failed: :invalid_arguments/, fn ->
      Eval.run(["work", "extra"])
    end

    assert_raise Mix.Error, ~r/world eval failed: :invalid_arguments/, fn ->
      Eval.run(["world", "--unknown", "value"])
    end

    assert_raise Mix.Error, ~r/world eval failed: :invalid_arguments/, fn ->
      Eval.run(["world", "--results", "relative.json"])
    end

    assert_raise Mix.Error, ~r/admission eval failed: :model_eval_policies_not_configured/, fn ->
      Eval.run(["admission"])
    end

    assert_raise Mix.Error, ~r/usage: mix responder.eval/, fn ->
      Eval.run(["unknown"])
    end
  end

  test "a failed world observation stops later model calls but accounts for the whole plan" do
    # A failed observation now preserves its DB; another model must not run
    # against that failed case's surviving custody or get counted as completed.
    parent = self()
    plan = Enum.map(1..3, &%{scenario_id: "retained-world", lane: :candidate, repeat_index: &1})

    reports =
      Eval.run_world_plan(
        plan,
        fn observation ->
          send(parent, {:model_called, observation.repeat_index})

          Map.put(
            observation,
            :status,
            if(observation.repeat_index == 1, do: :passed, else: :failed)
          )
        end,
        fn observation, stopped ->
          observation |> Map.put(:status, :unrun) |> Map.put(:stopped_after, stopped.repeat_index)
        end
      )

    assert Enum.map(reports, & &1.status) == [:passed, :failed, :unrun]
    assert List.last(reports).stopped_after == 2
    assert_received {:model_called, 1}
    assert_received {:model_called, 2}
    refute_received {:model_called, 3}
  end

  test "an unrun observation also prevents further model calls in the preserved database" do
    parent = self()

    reports =
      Eval.run_world_plan(
        [1, 2],
        fn index ->
          send(parent, {:model_called, index})
          %{status: :unrun}
        end,
        fn index, _stopped -> %{status: :unrun, skipped: index} end
      )

    assert [%{status: :unrun}, %{status: :unrun, skipped: 2}] = reports
    assert_received {:model_called, 1}
    refute_received {:model_called, 2}
  end

  defp assert_pack(command, case_module) do
    assert {:ok, cases} = case_module.all()

    documents =
      capture_io(fn -> Eval.run([command]) end)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert length(documents) == length(cases)

    assert Enum.all?(documents, fn document ->
             is_map(document) and
               is_binary(document["eval_id"] || get_in(document, ["scenario", "id"]))
           end)
  end
end
