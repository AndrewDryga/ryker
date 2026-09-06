defmodule Responder.ControlPlane.ToolCardTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Responder.ControlPlane.{InspectionRedactor, ToolCard}

  test "recorded evidence and conversation tools explain the change without a metadata table" do
    # The OOM replay showed an MCP JSON blob, then an unexplained 'Evidence: Open'.
    events =
      File.stream!("testdata/control-plane/oom-activity.jsonl") |> Enum.map(&Jason.decode!/1)

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

  test "a started tool does not present proposed observations as recorded work" do
    event =
      File.stream!("testdata/control-plane/oom-activity.jsonl")
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(get_in(&1, ["payload", "input", "tool"]) == "cite_source"))

    html =
      render_component(&ToolCard.render/1, step: %{step(event["payload"]) | state: "started"})

    assert html =~ "Started: Record evidence"
    assert Enum.empty?(html |> LazyHTML.from_fragment() |> LazyHTML.query(".action-observation"))
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

  test "project paths use a recorded root and cannot hide traversal outside it" do
    assert ToolCard.path("/repo/terraform/main.tf", "/repo") == {"terraform/main.tf", nil}

    assert ToolCard.path("/repository/main.tf", "/repo") ==
             {"/repository/main.tf", "Outside project"}

    assert ToolCard.path("/repo/../secrets.txt", "/repo") == {"/secrets.txt", "Outside project"}
    assert ToolCard.path("../../secrets.txt", "/repo") == {"../../secrets.txt", "Outside project"}

    assert ToolCard.path("/unverified/main.tf", nil) ==
             {"/unverified/main.tf", "Project boundary not recorded"}
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
