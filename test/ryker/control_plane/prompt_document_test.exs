defmodule Ryker.ControlPlane.PromptDocumentTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.{InspectionRedactor, PromptDocument, RequestContextHTML}

  test "Work history highlights the same message and summary components as routing" do
    # The actual nested Work bundle was unlabelled even though the same sources
    # in routing were individually inspectable.
    context =
      "testdata/control_plane/retained-work-conversation-context.json"
      |> File.read!()
      |> Jason.decode!()

    prompt = Jason.encode!(%{"work" => %{"conversation_context" => context}})

    document =
      prompt
      |> InspectionRedactor.artifact(preserve_format: true)
      |> PromptDocument.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    for {key, title} <- [
          {"messages", "Earlier messages"},
          {"channel_summary", "Channel summary"},
          {"thread_summary", "Thread summary"}
        ] do
      path = "$.work.conversation_context.bundle." <> key
      fragment = LazyHTML.query(document, ~s([data-source="#{path}"]))
      assert Enum.count(fragment) == 1
      assert LazyHTML.attribute(fragment, "data-source-title") == [title]
    end

    assert LazyHTML.query(document, "code") |> LazyHTML.text() == prompt
  end

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

  test "the prompt inspector maps logical components instead of whole JSON containers" do
    prompt =
      Jason.encode!(%{
        "instructions" => "Route carefully.",
        "context" => %{
          "input" => %{"content" => %{"text" => "Current question"}},
          "custom_instructions" => %{
            "global" => %{"text" => "Global text"},
            "channel" => %{"text" => "Channel text"}
          },
          "conversation_context" => %{
            "messages" => [%{"content" => %{"text" => "Earlier question"}}],
            "channel_summary" => %{"summary" => "Channel context"},
            "thread_summary" => %{"summary" => "Thread context"}
          },
          "conversation_observations" => [%{"text" => "Observed earlier"}],
          "conversation_knowledge" => [%{"text" => "Known earlier"}],
          "slack_addressing" => %{"audience" => "ambient"},
          "repository_source_kinds" => ["workspace"],
          "candidates" => [%{"digest" => %{"objective" => "Earlier work"}}],
          "allowed_actions" => ["reply"]
        }
      })

    document =
      prompt
      |> InspectionRedactor.artifact(preserve_format: true)
      |> PromptDocument.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    for {path, title} <- [
          {"$.instructions", "System prompt"},
          {"$.context.input", "Current message"},
          {"$.context.custom_instructions.global", "Global instructions"},
          {"$.context.custom_instructions.channel", "Channel instructions"},
          {"$.context.conversation_context.messages", "Earlier messages"},
          {"$.context.conversation_context.channel_summary", "Channel summary"},
          {"$.context.conversation_context.thread_summary", "Thread summary"},
          {"$.context.conversation_observations", "Conversation observations"},
          {"$.context.conversation_knowledge", "Conversation knowledge"},
          {"$.context.slack_addressing", "Slack addressing"},
          {"$.context.repository_source_kinds", "Repository sources"},
          {"$.context.candidates", "Candidate selection"},
          {"$.context.allowed_actions", "Permitted actions"}
        ] do
      fragment = LazyHTML.query(document, ~s([data-source="#{path}"]))
      assert Enum.count(fragment) == 1
      assert LazyHTML.attribute(fragment, "data-source-title") == [title]
      assert LazyHTML.attribute(fragment, "aria-describedby") == ["prompt-inspector-tooltip"]
    end

    assert Enum.empty?(LazyHTML.query(document, ~s([data-source="$.context"])))

    assert Enum.empty?(
             LazyHTML.query(document, ~s([data-source="$.context.custom_instructions"]))
           )

    assert Enum.empty?(
             LazyHTML.query(document, ~s([data-source="$.context.conversation_context"]))
           )
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
