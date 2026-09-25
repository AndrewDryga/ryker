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
      |> PromptDocument.render("prompt")
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

    assert formatted_json(document) == Jason.decode!(prompt)
  end

  test "dotted JSON keys cannot impersonate a nested briefing source" do
    prompt = ~s({"work":{"operator_context.guidance":"ordinary field"}})

    html =
      prompt
      |> InspectionRedactor.artifact(preserve_format: true)
      |> PromptDocument.render("prompt")
      |> IO.iodata_to_binary()

    refute html =~ "Guidance"

    assert html |> LazyHTML.from_fragment() |> formatted_json() == Jason.decode!(prompt)
  end

  test "the annotated prompt keeps every submitted value and names each source" do
    # The old inspector prettified the request and never connected final text to its sources.
    prompt =
      ~s({"instructions":"Read only.\\nReport findings.", "work":{"operator_context":{"continuity":{"current":{"state":{"goal":"Check infrastructure health"}}}},"inputs":[{"text":"Check health"}]}})

    artifact = InspectionRedactor.artifact(prompt, preserve_format: true)
    assert artifact.text == prompt

    document =
      artifact |> PromptDocument.render() |> IO.iodata_to_binary() |> LazyHTML.from_fragment()

    assert formatted_json(document) == Jason.decode!(prompt)
    assert LazyHTML.query(document, ~s([data-source="$.instructions"])) |> Enum.count() == 1

    assert LazyHTML.query(document, ~s([data-source="$.work.operator_context.continuity"]))
           |> Enum.count() == 1

    assert LazyHTML.query(document, ~s([data-source="$.work.inputs"])) |> Enum.count() == 1
  end

  test "the formatted prompt is the whole prompt, one row per line" do
    # A one-line retained request made individual context components difficult to
    # scan. The formatted view is the only one, so it carries every value; a raw
    # copy beside it differed only in spacing.
    prompt =
      ~s({"instructions":"Route carefully.","context":{"input":{"content":{"text":"Hello"}}}})

    document =
      prompt
      |> InspectionRedactor.artifact(preserve_format: true)
      |> PromptDocument.render("prompt")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    # One row per formatted line, so each part can carry its own colour line.
    rows =
      document
      |> LazyHTML.query(".submitted-prompt-formatted .prompt-row")
      |> Enum.map(&LazyHTML.text/1)

    # In the order the model read it: routing sends its instructions first.
    assert Enum.join(rows, "\n") ==
             prompt |> Jason.decode!(objects: :ordered_objects) |> Jason.encode!(pretty: true)

    assert Enum.at(rows, 1) =~ ~s("instructions")
    assert length(rows) > 1
    refute LazyHTML.text(document) =~ "Raw text"
    assert Enum.count(LazyHTML.query(document, ~s([data-source="$.context.input"]))) == 1
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
      |> PromptDocument.render("prompt")
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
          {"$.context.conversation_observations", "Conversation notes"},
          {"$.context.conversation_knowledge", "Learned topics"},
          {"$.context.slack_addressing", "Who this Slack message addresses"},
          {"$.context.repository_source_kinds", "Permitted actions"},
          {"$.context.candidates[0]", "Background matches"},
          {"$.context.allowed_actions", "Permitted actions"}
        ] do
      fragment = LazyHTML.query(document, ~s([data-source="#{path}"]))
      assert Enum.count(fragment) == 1
      assert LazyHTML.attribute(fragment, "data-source-title") == [title]
      assert LazyHTML.attribute(fragment, "aria-describedby") == ["ryker-tooltip"]
    end

    assert Enum.empty?(LazyHTML.query(document, ~s([data-source="$.context"])))

    assert Enum.empty?(
             LazyHTML.query(document, ~s([data-source="$.context.custom_instructions"]))
           )

    assert Enum.empty?(
             LazyHTML.query(document, ~s([data-source="$.context.conversation_context"]))
           )
  end

  # Real prompts left the conversation manifest, the current-message copy, Work
  # continuity, reaction feedback and alert signals unhighlighted, and the
  # briefing showed them only inside one mixed Raw context blob. A reader could
  # not tell which section had put a large chunk of text in front of the model.
  test "every submitted value belongs to exactly one named prompt part" do
    for name <- ~w(routing routing-lean work-full work-continuation learning) do
      prompt = File.read!("testdata/control_plane/submitted-prompts/#{name}.json")
      document = prompt_document(prompt)
      fragments = LazyHTML.query(document, ".prompt-fragment")
      paths = LazyHTML.attribute(fragments, "data-source")

      assert Enum.empty?(LazyHTML.query(document, ".prompt-fragment .prompt-fragment")), name
      refute "Other fields" in LazyHTML.attribute(fragments, "data-part"), name

      for leaf <- leaf_paths(Jason.decode!(prompt), "$") do
        owners =
          Enum.filter(paths, &(leaf == &1 or String.starts_with?(leaf, [&1 <> ".", &1 <> "["])))

        assert length(owners) == 1, "#{name}: #{leaf} belongs to #{inspect(owners)}"
      end
    end
  end

  test "each prompt part is named after the briefing row that shows it" do
    # The legend and the briefing name the same thing; a chip nobody can find
    # in the briefing sends the reader looking for a section that does not exist.
    for {name, key, root} <- [
          {"routing", "context", "$.context"},
          {"routing-lean", "context", "$.context"},
          {"work-full", "work", "$.work"},
          {"work-continuation", "work", "$.work"}
        ] do
      prompt = File.read!("testdata/control_plane/submitted-prompts/#{name}.json")

      briefing =
        prompt
        |> Jason.decode!()
        |> Map.fetch!(key)
        |> InspectionRedactor.artifact()
        |> RequestContextHTML.assembly(root, "briefing")
        |> IO.iodata_to_binary()
        |> LazyHTML.from_fragment()

      named =
        Enum.map(LazyHTML.query(briefing, ".prompt-source-title"), &LazyHTML.text/1) ++
          LazyHTML.attribute(LazyHTML.query(briefing, "[data-part]"), "data-part")

      refute "Raw context" in named, name

      chips =
        prompt |> prompt_document() |> LazyHTML.query(".prompt-part") |> Enum.to_list()

      assert chips != []

      for chip <- chips,
          [title] = LazyHTML.attribute(chip, "data-prompt-part"),
          title != "System prompt" do
        assert title in named, "#{name}: #{title} is not a briefing row"
      end
    end
  end

  test "a part sent empty keeps its place in the legend and says it was empty" do
    # Empty parts were gathered into a trailing "Sent empty" row, apart from the
    # section they belong to.
    document =
      "testdata/control_plane/submitted-prompts/routing-lean.json"
      |> File.read!()
      |> prompt_document()

    refute LazyHTML.text(document) =~ "Sent empty"

    [history] =
      document
      |> LazyHTML.query(".prompt-parts > div")
      |> Enum.filter(&(LazyHTML.text(LazyHTML.query(&1, "dt")) == "Related history"))

    chip = LazyHTML.query(history, ~s(.prompt-part[data-prompt-part="Candidates"]))
    assert LazyHTML.attribute(chip, "data-empty") == [""]
    assert chip |> LazyHTML.query(".prompt-part-share") |> LazyHTML.text() == "empty"
  end

  test "the prompt starts plain and offers every part as its own highlight" do
    prompt = File.read!("testdata/control_plane/submitted-prompts/routing.json")
    document = prompt_document(prompt)

    chips = LazyHTML.query(document, ".prompt-part")
    titles = LazyHTML.attribute(chips, "data-prompt-part")
    assert titles == Enum.uniq(titles)
    assert Enum.all?(LazyHTML.attribute(chips, "aria-pressed"), &(&1 == "false"))
    assert Enum.empty?(LazyHTML.query(document, ".is-highlighted"))

    for title <- ["System prompt", "Current message", "Earlier messages", "Conversation notes"] do
      assert title in titles
    end

    fragment_parts =
      document |> LazyHTML.query(".prompt-fragment") |> LazyHTML.attribute("data-part")

    assert Enum.sort(Enum.uniq(fragment_parts)) == Enum.sort(titles)

    [container] = document |> LazyHTML.query(".prompt-document") |> Enum.to_list()
    assert LazyHTML.attribute(container, "phx-update") == ["ignore"]
    assert LazyHTML.attribute(container, "id") == ["prompt"]
  end

  test "each prompt block has a copy button in its corner" do
    # Large prompts were copied by selecting thousands of lines by hand.
    prompt = File.read!("testdata/control_plane/submitted-prompts/routing.json")
    document = prompt_document(prompt)

    assert Enum.count(LazyHTML.query(document, ".copy-block")) == 1

    assert Enum.count(LazyHTML.query(document, ".copy-block > pre.submitted-prompt-formatted")) ==
             1

    assert document
           |> LazyHTML.query(".copy-block > button[data-copy-block]")
           |> LazyHTML.attribute("aria-label") == ["Copy formatted prompt"]
  end

  defp formatted_json(document) do
    document
    |> LazyHTML.query(".submitted-prompt-formatted .prompt-row")
    |> Enum.map_join("\n", &LazyHTML.text/1)
    |> Jason.decode!()
  end

  defp prompt_document(prompt) do
    prompt
    |> InspectionRedactor.artifact(preserve_format: true)
    |> PromptDocument.render("prompt")
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
  end

  defp leaf_paths(value, path) when is_map(value) and map_size(value) > 0,
    do: Enum.flat_map(value, fn {key, nested} -> leaf_paths(nested, segment(path, key)) end)

  defp leaf_paths(value, path) when is_list(value) and value != [],
    do:
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {nested, index} -> leaf_paths(nested, "#{path}[#{index}]") end)

  defp leaf_paths(_value, path), do: [path]

  defp segment(path, key) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z_0-9]*$/, key),
      do: path <> "." <> key,
      else: path <> "[" <> Jason.encode!(key) <> "]"
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
