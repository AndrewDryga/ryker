defmodule Responder.Work.SubmissionTest do
  use ExUnit.Case, async: true

  alias Responder.Work.Submission

  test "a frozen submission rejects malformed or unbounded request bodies" do
    valid = %{
      "contract_version" => "work-final-v1",
      "context" => %{"request" => "inspect this"},
      "output_schema" => %{"type" => "object"},
      "prompt" => "Handle this request."
    }

    assert {:ok, prepared} =
             Submission.new(
               valid["context"],
               valid["prompt"],
               valid["output_schema"],
               valid["contract_version"]
             )

    assert Submission.prepare(prepared) == {:ok, prepared}
    assert byte_size(Submission.fingerprint(prepared)) == 64

    cases = [
      {nil, valid["prompt"], valid["output_schema"], valid["contract_version"], :context},
      {valid["context"], " ", valid["output_schema"], valid["contract_version"], :prompt},
      {valid["context"], <<255>>, valid["output_schema"], valid["contract_version"], :prompt},
      {valid["context"], valid["prompt"], [], valid["contract_version"], :output_schema},
      {valid["context"], valid["prompt"], %{"bad" => <<255>>}, valid["contract_version"],
       :output_schema},
      {valid["context"], valid["prompt"], valid["output_schema"], " ", :contract_version}
    ]

    Enum.each(cases, fn {context, prompt, schema, version, field} ->
      assert Submission.new(context, prompt, schema, version) ==
               {:error, {:invalid_work_submission, field}}
    end)

    assert Submission.prepare(%{}) == {:error, {:invalid_work_submission, :fields}}
    assert Submission.prepare(:invalid) == {:error, {:invalid_work_submission, :fields}}
  end
end
