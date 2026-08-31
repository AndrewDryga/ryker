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
    assert prepared["input_artifact_refs"] == []
    assert byte_size(Submission.fingerprint(prepared)) == 64

    artifact_ref = "artifact:input:" <> String.duplicate("a", 64)

    assert {:ok, with_artifact} =
             Submission.new(
               valid["context"],
               valid["prompt"],
               valid["output_schema"],
               valid["contract_version"],
               [artifact_ref]
             )

    assert with_artifact["input_artifact_refs"] == [artifact_ref]

    legacy = Map.delete(prepared, "input_artifact_refs")
    assert {:ok, upgraded} = Submission.prepare(legacy)
    assert upgraded["input_artifact_refs"] == []

    assert Submission.new(
             valid["context"],
             valid["prompt"],
             valid["output_schema"],
             valid["contract_version"],
             [artifact_ref, artifact_ref]
           ) == {:error, {:invalid_work_submission, :input_artifact_refs}}

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

    assert Submission.new(
             valid["context"],
             valid["prompt"],
             valid["output_schema"],
             valid["contract_version"],
             :invalid
           ) == {:error, {:invalid_work_submission, :input_artifact_refs}}
  end
end
