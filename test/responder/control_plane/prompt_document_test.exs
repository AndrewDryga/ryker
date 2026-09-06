defmodule Responder.ControlPlane.PromptDocumentTest do
  use ExUnit.Case, async: true
  alias Responder.ControlPlane.{InspectionRedactor, PromptDocument, RequestContextHTML}

  test "dotted JSON keys cannot impersonate a nested briefing source" do
    prompt = ~s({"work":{"operator_context.guidance":"ordinary field"}})

    html =
      prompt
      |> InspectionRedactor.artifact(preserve_format: true)
      |> PromptDocument.render()
      |> IO.iodata_to_binary()

    refute html =~ "Confirmed guidance"
    assert html |> LazyHTML.from_fragment() |> LazyHTML.query("code") |> LazyHTML.text() == prompt
  end

  test "the annotated prompt preserves every submitted byte and names each source" do
    # The old inspector prettified the request and never connected final text to its sources.
    prompt =
      ~s({"instructions":"Read only.\\nReport findings.", "work":{"operator_context":{"continuity":{"current":{"state":{"goal":"Check infrastructure health"}}}},"inputs":[{"text":"Check health"}]}})

    artifact = InspectionRedactor.artifact(prompt, preserve_format: true)
    assert artifact.text == prompt

    document =
      artifact |> PromptDocument.render() |> IO.iodata_to_binary() |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("code") |> LazyHTML.text() == prompt
    assert LazyHTML.query(document, ~s([data-source="$.instructions"])) |> Enum.count() == 1

    assert LazyHTML.query(document, ~s([data-source="$.work.operator_context.continuity"]))
           |> Enum.count() == 1

    assert LazyHTML.query(document, ~s([data-source="$.work.inputs"])) |> Enum.count() == 1
  end

  test "conversation recall is a compact situation and open questions, not nested empty fields" do
    context = %{
      "operator_context" => %{
        "continuity" => %{
          "current" => %{
            "repository_ref" => "emisar",
            "source_ref" => "continuity:83e18756",
            "state" => %{
              "active_topics" => ["Infrastructure health"],
              "decisions" => [],
              "goal" => "Check infrastructure health and flag issues",
              "open_loops" => ["Cloud project ID is needed."],
              "situation" =>
                "Two connected production runners report degraded cloud-init completion."
            }
          }
        }
      }
    }

    html =
      RequestContextHTML.assembly(InspectionRedactor.artifact(context), "$.work", "recall")
      |> IO.iodata_to_binary()

    assert html =~ "conversation-recall"
    assert html =~ "Two connected production runners"
    assert html =~ "Cloud project ID is needed."
    refute html =~ ">Decisions<"
    refute html =~ "context-field"
  end
end
