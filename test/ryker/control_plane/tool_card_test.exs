defmodule Ryker.ControlPlane.ToolCardTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{InspectionRedactor, ToolCard}

  test "raw tool evidence uses the same disclosure and preserves lazy loading and expiry" do
    # Native raw-tool summaries drifted from every other timeline disclosure;
    # migrating their shell must not eagerly fetch or resurrect expired bodies.
    fixture = File.read!("testdata/control_plane/oom-evidence-link.json") |> Jason.decode!()
    recorded = step(hd(fixture["activities"])["payload"])

    for {state, expected} <- [{:collapsed, "data-artifact"}, {:expired, "data-revoked"}] do
      artifacts =
        Enum.map(
          recorded.artifacts,
          &Map.merge(&1, %{
            artifact_id: "raw-tool",
            artifact: %{&1.artifact | state: state, text: nil}
          })
        )

      document =
        render_component(&ToolCard.render/1, step: %{recorded | artifacts: artifacts})
        |> LazyHTML.from_fragment()

      disclosures = LazyHTML.query(document, ".action-raw.ui-disclosure")
      assert Enum.count(disclosures) == length(artifacts)

      assert LazyHTML.query(disclosures, "summary > .ui-icon") |> Enum.count() ==
               length(artifacts)

      assert LazyHTML.attribute(disclosures, expected) != []
      assert Enum.empty?(LazyHTML.query(disclosures, "pre"))
    end
  end

  test "a completed citation points to the saved observation instead of repeating it" do
    # The real HAProxy episode repeated a full paragraph in adjacent record and
    # tool cards, making one saved observation look like two separate findings.
    fixture = File.read!("testdata/control_plane/oom-evidence-link.json") |> Jason.decode!()
    payload = hd(fixture["activities"])["payload"]
    anchor = "#event-record-" <> fixture["record"]["id"]
    completed = Map.put(step(payload), :saved_evidence, anchor)
    html = render_component(&ToolCard.render/1, step: completed)
    doc = LazyHTML.from_fragment(html)

    assert LazyHTML.query(doc, ".action-card > .case-card-heading") |> Enum.count() == 1

    assert LazyHTML.query(doc, ".case-card-heading-main > h3") |> LazyHTML.text() ==
             "Citation saved"

    assert Enum.empty?(LazyHTML.query(doc, ".action-observation"))
    assert Enum.empty?(LazyHTML.query(doc, ".action-facts"))

    assert LazyHTML.query(doc, ".action-evidence-link a") |> LazyHTML.attribute("href") == [
             anchor
           ]

    assert html =~ "Citation saved"
    assert html =~ "View recorded evidence"

    assert LazyHTML.query(doc, ".action-raw") |> LazyHTML.text() =~
             payload["input"]["arguments"]["observation"]

    for state <- ["started", "failed", "cancelled"] do
      other = render_component(&ToolCard.render/1, step: %{completed | state: state})
      refute other =~ "View recorded evidence"
      refute other =~ "Citation saved"
    end
  end

  test "recorded evidence and conversation tools explain the change without a metadata table" do
    # The OOM replay showed an MCP JSON blob, then an unexplained 'Evidence: Open'.
    events =
      File.stream!("testdata/control_plane/oom-activity.jsonl") |> Enum.map(&Jason.decode!/1)

    for {tool, title, body} <- [
          {"cite_source", "Evidence recorded",
           "does not by itself establish host RAM exhaustion"},
          {"update_conversation_summary", "Conversation summary drafted",
           "Resolution alone does not verify task recovery"}
        ] do
      event = Enum.find(events, &(get_in(&1, ["payload", "input", "tool"]) == tool))
      html = render_component(&ToolCard.render/1, step: step(event["payload"]))
      assert html =~ title
      assert html =~ body
      refute html =~ "Call metadata"
      refute html =~ "<dt>Tool call</dt>"
      assert html =~ "Raw arguments"
    end
  end

  test "a preference proposal is named as inert confirmation work" do
    payload = %{
      "input" => %{
        "server" => "responder-state",
        "tool" => "propose_preference",
        "arguments" => %{
          "explicit_request" => true,
          "expires_at" => nil,
          "key" => "response_detail",
          "scope" => "mine",
          "source_refs" => ["input:preference"],
          "value" => "concise"
        }
      }
    }

    html = render_component(&ToolCard.render/1, step: step(payload))
    assert html =~ "Preference proposed"
    assert html =~ "for confirmation"
  end

  test "a started tool does not present proposed observations as recorded work" do
    event =
      File.stream!("testdata/control_plane/oom-activity.jsonl")
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(get_in(&1, ["payload", "input", "tool"]) == "cite_source"))

    html =
      render_component(&ToolCard.render/1, step: %{step(event["payload"]) | state: "started"})

    assert html =~ "Started: Record evidence"
    assert Enum.empty?(html |> LazyHTML.from_fragment() |> LazyHTML.query(".action-observation"))
  end

  test "a finding tool shows the conclusion and reason with a meaningful action name" do
    payload = %{
      "input" => %{
        "server" => "responder-state",
        "tool" => "record_finding",
        "arguments" => %{
          "what" => "Zero instances are intentional",
          "status" => "expected",
          "reason" => "The checked-out configuration disables the service.",
          "scope" => "Repository intent"
        }
      }
    }

    html = render_component(&ToolCard.render/1, step: step(payload))
    assert html =~ "Finding recorded"
    assert html =~ "Zero instances are intentional"
    assert html =~ "checked-out configuration disables"
    refute html =~ "Call metadata"

    failed =
      render_component(&ToolCard.render/1,
        step: %{step(payload) | state: "failed", summary: "invalid_arguments"}
      )

    assert failed =~ "Record a finding"
    refute failed =~ "Finding recorded"
  end

  test "failed state tool does not claim evidence was recorded" do
    payload = %{
      "input" => %{
        "server" => "responder-state",
        "tool" => "cite_source",
        "arguments" => %{"subject" => "<script>"}
      }
    }

    html =
      render_component(&ToolCard.render/1,
        step: %{step(payload) | state: "failed", summary: "unauthorized"}
      )

    assert html =~ "Record evidence"
    assert html =~ "unauthorized"
    refute html =~ "Evidence recorded"
    refute html =~ "<script>"
  end

  test "edits are not mislabeled as reads just because they have a path argument" do
    payload = %{
      "title" => "Edit file",
      "input" => %{"path" => "lib/config.ex", "diff" => "+ enabled: true"}
    }

    html = render_component(&ToolCard.render/1, step: step(payload))
    assert html =~ "Edit files"
    refute html =~ "Read file"
  end

  test "worker path facts show relative files and warn about every outside path" do
    step =
      step(%{"title" => "Read file '/private/checkout/lib/config.ex'"})
      |> Map.put(:path_context, %{
        "basis" => "lexical",
        "paths" => [
          %{"source" => "/locations/0/path", "scope" => "project", "path" => "lib/config.ex"},
          %{"source" => "/locations/1/path", "scope" => "outside"}
        ]
      })

    html = render_component(&ToolCard.render/1, step: step)
    assert html =~ "lib/config.ex"
    assert html =~ "Outside project"
    refute html =~ "/private/checkout"
  end

  test "file names and search terms cannot change the type of activity" do
    # 'edit' inside .editorconfig and credits used to turn reads into writes.
    for {title, expected} <- [
          {"Read file '.editorconfig'", "Read file"},
          {"Search for 'credits' in lib", "Search project"}
        ] do
      assert ToolCard.project(step(%{"title" => title})).title == expected
    end
  end

  test "goal cards expose the requested outcome and completion condition without opening JSON" do
    # Host tool-schema boundary: these are the canonical goal fields, not a model fixture.
    args = %{
      "requested_outcome" => "Check current allocation health",
      "completion_contract" => "Source evidence confirms health",
      "authority" => "read_only"
    }

    payload = %{
      "input" => %{"server" => "responder-state", "tool" => "plan_goal", "arguments" => args}
    }

    html = render_component(&ToolCard.render/1, step: step(payload))

    visible =
      html |> LazyHTML.from_fragment() |> LazyHTML.query(".action-facts") |> LazyHTML.text()

    assert visible =~ args["requested_outcome"]
    assert visible =~ args["completion_contract"]
  end

  defp step(payload) do
    %{
      id: "recorded",
      title: payload["title"] || "Tool call",
      state: "completed",
      summary: nil,
      duration_ms: 12,
      tool_kind: payload["kind"],
      details: [],
      artifacts:
        for(
          {key, label} <- [{"input", "Arguments"}, {"output", "Response"}],
          payload[key],
          do: %{label: label, artifact: InspectionRedactor.artifact(payload[key])}
        )
    }
  end
end
