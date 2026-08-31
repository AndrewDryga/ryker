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

  test "live commands fail closed before loading configuration without one exact path" do
    assert_raise Mix.Error, ~r/admission eval failed: :invalid_arguments/, fn ->
      Eval.run(["admission"])
    end

    assert_raise Mix.Error, ~r/work eval failed: :invalid_arguments/, fn ->
      Eval.run(["work", "--config", ""])
    end

    assert_raise Mix.Error, ~r/world eval failed: :invalid_arguments/, fn ->
      Eval.run(["world", "--unknown", "config.yaml"])
    end

    assert_raise Mix.Error, ~r/world eval failed: :invalid_arguments/, fn ->
      Eval.run(["world", "--config", "/tmp/config.yaml", "--results", "relative.json"])
    end

    assert_raise Mix.Error, ~r/usage: mix responder.eval/, fn ->
      Eval.run(["unknown"])
    end
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
