defmodule Ryker.ControlPlane.PromptReadabilityTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.RequestContextHTML
  alias Ryker.InspectionRedactor

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

  test "source help is visible before expansion and readable sources end in highlight, not copy" do
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
           |> LazyHTML.query(".prompt-source-body > button:last-child")
           |> LazyHTML.attribute("data-prompt-highlight") == ["System prompt"]

    assert Enum.empty?(LazyHTML.query(document, "[data-copy-block]"))
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
