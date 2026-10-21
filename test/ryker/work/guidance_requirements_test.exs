defmodule Ryker.Work.GuidanceRequirementsTest do
  use ExUnit.Case, async: true
  alias Ryker.Work.{Final, GuidanceRequirements}

  test "model-written requirements and result details use the tool schema's character limits" do
    # Valid non-ASCII prose must not make every final invalid because its
    # UTF-8 bytes outnumber its characters.
    requirement = requirement()
    assert GuidanceRequirements.valid_context?([requirement])

    refute GuidanceRequirements.valid_context?([
             %{requirement | "description" => String.duplicate("界", 1001)}
           ])

    refute GuidanceRequirements.valid_context?([
             put_in(requirement, ["result", "detail"], String.duplicate("界", 2001))
           ])
  end

  test "non-applicable outputs retain their audit without forcing an unrelated notification" do
    requirement = requirement()

    candidate = %{
      "delivery" => "none",
      "message" => nil,
      "decision_reason" => "The current event does not require a rollout review.",
      "outcome" => %{
        "state" => "complete",
        "record_refs" => ["record:result", "record:evidence"],
        "artifact_refs" => []
      }
    }

    assert {:ok, final} = Final.parse(candidate)
    assert GuidanceRequirements.violations([requirement], final) == []
  end

  defp requirement do
    %{
      "description" => String.duplicate("界", 600),
      "guidance_ref" => "behavior:guidance",
      "requirement_ref" => "requirement:output",
      "revision" => 1,
      "result" => %{
        "guidance_ref" => "behavior:guidance",
        "requirement_ref" => "requirement:output",
        "revision" => 1,
        "record_ref" => "record:result",
        "evidence_refs" => ["record:evidence"],
        "status" => "not_applicable",
        "detail" => String.duplicate("界", 1600)
      }
    }
  end
end
