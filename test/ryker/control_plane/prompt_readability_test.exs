defmodule Ryker.ControlPlane.PromptReadabilityTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.RequestContextHTML
  alias Ryker.InspectionRedactor

  test "source glyphs align with their first line and remaining copy controls finish at the right" do
    css = File.read!("priv/static/workspace.css")
    assert css =~ ".prompt-source > summary { align-items:flex-start; }"
    assert css =~ ".ryker-app .copy-block-button { align-self:flex-end;"
    refute css =~ ".ryker-app .prompt-highlight {"
    assert css =~ ".prompt-part-share { flex:none; white-space:nowrap;"
    assert css =~ "min-height:44px; padding:8px; text-align:left;"

    assert css =~
             ".search-method-static .prompt-source-row { display:flex; flex-wrap:wrap; align-items:center; min-height:44px;"
  end

  test "candidate outcomes render retained link formatting safely instead of exposing Markdown syntax" do
    # Dense real histories showed literal [title](URL) in every outcome, even
    # though the adjacent message used the safe Markdown renderer.
    candidate = %{
      "state" => "complete",
      "title" => "Earlier deployment",
      "outcome" =>
        "Replied: [Run details](https://example.com/run/123) — **discarded**. <script>bad()</script>"
    }

    document =
      %{"candidates" => [candidate]}
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "outcome-formatting")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    outcome = LazyHTML.query(document, ".candidate-outcome")

    assert outcome |> LazyHTML.query("a") |> LazyHTML.attribute("href") == [
             "https://example.com/run/123"
           ]

    assert outcome |> LazyHTML.query("strong") |> LazyHTML.text() == "discarded"
    assert Enum.empty?(LazyHTML.query(outcome, "script"))
    assert LazyHTML.text(outcome) =~ "<script>bad()</script>"
  end

  test "source token links reveal the original JSON without extra buttons in the readable body" do
    # The design lost the explanation in the fold and offered an ambiguous copy
    # of the readable view, rather than the actual submitted JSON.
    document =
      "Fixed system instructions"
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly_instructions("briefing")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("summary .prompt-source-help") |> LazyHTML.text() =~
             "fixed instructions"

    assert document
           |> LazyHTML.query("summary a.prompt-source-estimate")
           |> LazyHTML.attribute("data-prompt-highlight") == ["System prompt"]

    assert Enum.empty?(LazyHTML.query(document, "[data-copy-block]"))
    assert Enum.empty?(LazyHTML.query(document, ".prompt-source-body button"))
  end

  test "retained button answers read as messages rather than serialized events" do
    # The reported conversation notes rendered the exact retained button JSON
    # as prose. Keep the answer, not the storage envelope, on the readable face.
    answer =
      Jason.encode!(%{
        "interaction_kind" => "button",
        "choice" => "Accessible text-only",
        "choice_index" => 6,
        "input_request_ref" => "record:input_request:example"
      })

    document =
      %{
        "conversation_observations" => [
          %{"summary" => answer, "actor" => "local-operator", "at" => "2026-10-11T11:53:42Z"}
        ]
      }
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "notes")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, ".context-note .ui-message") |> Enum.count() == 1
    assert LazyHTML.text(document) =~ ~s(Answered "Accessible text-only")
    refute LazyHTML.text(document) =~ "choice_index"
    refute LazyHTML.text(document) =~ "input_request_ref"
  end

  test "learned topics lead with the retained understanding and keep metadata secondary" do
    # Retained shape from the reported topic, with tenant identity removed.
    topic = %{
      "title" => "Recurrent job alert closed",
      "summary" => "The metric returned to zero. Application recovery remains unverified.",
      "conversation_ref" => "control-plane:lab:example",
      "source_count" => 2,
      "source_reads" => [
        %{
          "tool" => "read_slack_source",
          "arguments" => %{"source_ref" => "slack-source:v1:T123:C456:message:1791403283.668939"}
        },
        %{
          "tool" => "read_slack_source",
          "arguments" => %{"source_ref" => "slack-source:v1:T123:C456:message:1791402591.068909"}
        }
      ],
      "latest_source_at" => "2026-10-07T20:01:23Z",
      "version" => 2,
      "can_update" => false,
      "environment_known" => true,
      "kind" => "conversation_knowledge",
      "topic_key" => "recurrent-alert",
      "source_ref" => "knowledge:018f0000-0000-7000-8000-000000000003"
    }

    document =
      %{"conversation_knowledge" => [topic]}
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "topics")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, ".learned-topic h4") |> LazyHTML.text() ==
             "Recurrent job alert closed"

    assert LazyHTML.query(document, ".learned-topic-summary") |> LazyHTML.text() =~
             "Application recovery remains unverified."

    assert LazyHTML.text(document) =~ "2 source messages"
    links = document |> LazyHTML.query(".learned-topic-sources a") |> Enum.map(&LazyHTML.text/1)
    assert length(Enum.uniq(links)) == 2
    assert Enum.at(links, 0) =~ "20:01:23 UTC"
    assert Enum.at(links, 1) =~ "19:49:51 UTC"
    assert Enum.empty?(LazyHTML.query(document, ".learned-topic > .context-fields"))
    refute LazyHTML.text(document) =~ "Maintained topic"
  end

  test "structured sources use compact labelled facts instead of nested section headings" do
    context =
      "testdata/control_plane/retained-work-conversation-context.json"
      |> File.read!()
      |> Jason.decode!()

    document =
      %{"conversation_context" => context}
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.work", "retained")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    # Every actual message remains a message, and the original submitted input
    # remains available separately; no generic JSON dump replaces source prose.
    assert Enum.count(LazyHTML.query(document, ".ui-message")) == 11
    assert Enum.empty?(LazyHTML.query(document, ".context-field h4"))
    assert LazyHTML.text(document) =~ "progress validation complete"
  end
end
