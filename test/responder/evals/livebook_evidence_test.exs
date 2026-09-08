defmodule Responder.Evals.LivebookEvidenceTest do
  use ExUnit.Case, async: true

  @root "testdata/learning/livebook-intended-zero"

  test "the health qualification uses unchanged pre-report source bytes, not a fabricated parked deployment" do
    # The original health response ranked zero Livebook instances first without
    # establishing desired configuration. A later correct answer is evidence,
    # never a substitute for the repository source that the model must inspect.
    evidence = evidence()
    provenance = evidence["provenance"]

    assert provenance["pre_report_snapshot"]["commit"] ==
             "e9ceaaca495430826002d15c0abba2b0978008fa"

    assert provenance["pre_report_snapshot"]["occurred_at"] <
             provenance["original_acceptance_at"]

    assert length(provenance["files"]) == 3

    for file <- provenance["files"] do
      bytes = File.read!(Path.join([@root, "repository", file["path"]]))
      assert byte_size(bytes) == file["bytes"]
      assert digest(:sha256, bytes) == file["sha256"]
      assert digest(:sha, "blob #{byte_size(bytes)}\0" <> bytes) == file["git_blob_sha1"]
    end

    variables = File.read!(Path.join(@root, "repository/infra/variables.tf"))
    assert variables =~ ~r/variable "livebook_running" \{[^}]*default\s*=\s*true/s
    refute variables =~ ~r/variable "livebook_running" \{[^}]*default\s*=\s*false/s
  end

  test "the bundle preserves exact public source provenance and honestly withheld native outputs" do
    evidence = evidence()
    assert length(evidence["inputs"]) == 3
    assert length(evidence["public_responses"]) == 2

    for input <- evidence["inputs"] do
      assert digest(:sha256, input["content"]["text"]) == input["text_sha256"]
      assert input["source_item_ref"] =~ "control-plane-item:"
    end

    for response <- evidence["public_responses"] do
      assert digest(:sha256, response["message"]) == response["message_sha256"]
    end

    assert [first, second, third] = evidence["native_repository_reads"]
    assert Enum.all?([first, second, third], &(&1["kind"] == "tool.completed"))
    assert first["payload"]["output"]["truncated"]
    assert second["payload"]["output"]["truncated"]

    assert third["payload"]["output"]["formatted_output"] =~
             "count = var.livebook_enabled && var.livebook_running ? 1 : 0"
  end

  defp evidence, do: @root |> Path.join("evidence.json") |> File.read!() |> Jason.decode!()
  defp digest(algorithm, bytes), do: :crypto.hash(algorithm, bytes) |> Base.encode16(case: :lower)
end
