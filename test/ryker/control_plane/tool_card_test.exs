defmodule Ryker.ControlPlane.ToolCardTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.ToolCard
  alias Ryker.InspectionRedactor

  test "known platform calls use human action names without erasing their native tool identity" do
    recorded =
      step(%{
        "title" => "mcp.controller-tools.read_slack_source",
        "input" => %{
          "server" => "controller-tools",
          "tool" => "read_slack_source",
          "arguments" => %{}
        }
      })

    assert ToolCard.project(recorded).title == "Slack messages read"
    assert ToolCard.project(recorded).tool == "read_slack_source"
    assert ToolCard.line(recorded).service == :slack
  end

  test "a failed working-status update has one error rather than duplicate detail and error text" do
    line = ToolCard.line(%{stage: "Status", state: "failed", summary: "Slack did not respond."})
    assert line.error == "Slack did not respond."
    assert line.detail == nil
    assert line.service == :slack
  end

  test "file rows keep the full filename and disclose when one call reported additional files" do
    # Stress the retained read-file argument shape: a generic 160-character
    # preview must not remove the basename, the part a person needs to identify.
    path = String.duplicate("nested/", 30) <> "deployment.md"
    recorded = step(%{"kind" => "read", "title" => "Read file", "input" => %{"path" => path}})
    assert ToolCard.line(recorded).detail == path

    # The closed row already identifies this single file. Opening it should
    # expose evidence, not repeat the same filename above the Files fold.
    grouped = render_component(&ToolCard.render/1, step: recorded, grouped: true)
    assert Enum.empty?(grouped |> LazyHTML.from_fragment() |> LazyHTML.query(".action-path"))
    standalone = render_component(&ToolCard.render/1, step: recorded)

    assert standalone
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".action-path")
           |> LazyHTML.text() ==
             path

    recorded = Map.put(recorded, :reported_paths, %{"/locations/0/path" => "README.md"})
    assert ToolCard.line(recorded).detail == path <> " · 1 more file"
  end

  test "cancellation without a reason does not repeat its state as an error" do
    recorded = %{step(%{}) | state: "cancelled", summary: "The tool call was cancelled."}
    assert ToolCard.line(recorded).failed
    assert ToolCard.line(recorded).error == nil
  end

  test "a successful check search does not claim it found checks" do
    recorded =
      step(%{
        "input" => %{
          "server" => "controller-tools",
          "tool" => "find_github_ci",
          "arguments" => %{}
        },
        "output" => %{"checks" => []}
      })

    assert ToolCard.project(recorded).title == "GitHub checks searched"
  end

  test "a single tool shares aggregate branding and keeps raw evidence in peer disclosures" do
    # Tool redesign must not turn native grouped calls into one invented call,
    # nor make every reader scan the raw tool envelopes.
    fixture = File.read!("testdata/control_plane/oom-evidence-link.json") |> Jason.decode!()

    document =
      render_component(&ToolCard.render/1, step: step(hd(fixture["activities"])["payload"]))
      |> LazyHTML.from_fragment()

    assert Enum.count(LazyHTML.query(document, ".action-card > header .tool-run-badge")) == 1
    assert Enum.empty?(LazyHTML.query(document, ".action-technical"))
    refute Enum.empty?(LazyHTML.query(document, ".action-card > .action-raw"))
    assert Enum.count(LazyHTML.query(document, ".action-observation")) == 1
  end

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

  test "expanded tools do not repeat a query already visible or offer copy for a plain error" do
    # The failure card repeated Search beneath the same query and gave plain
    # error prose a JSON-style copy button at the bottom of another fold.
    recorded =
      step(%{
        "input" => %{
          "server" => "controller-tools",
          "tool" => "search_memory",
          "arguments" => %{"query" => "project region infrastructure"}
        }
      })

    recorded = %{
      recorded
      | artifacts:
          recorded.artifacts ++
            [
              %{
                label: "Error",
                artifact:
                  InspectionRedactor.artifact("invalid_arguments: missing required fields")
              }
            ]
    }

    document =
      render_component(&ToolCard.render/1, step: recorded, grouped: true)
      |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(document, ".action-facts"))
    error = LazyHTML.query(document, ".action-raw:last-child")
    assert LazyHTML.query(error, "pre") |> LazyHTML.text() =~ "invalid_arguments"
    assert Enum.empty?(LazyHTML.query(error, "button"))

    assert Enum.count(LazyHTML.query(document, ".action-raw:first-child button[data-copy-block]")) ==
             1
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
        "server" => "controller-tools",
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

  # Since 2026-09-27 Emisar's tools reach Work through Ryker's own server, so
  # a call to one is narrated under that server's name.
  test "an Emisar tool reached through Ryker's server is named as Emisar work" do
    payload = %{
      "input" => %{
        "server" => "controller-tools",
        "tool" => "run_action",
        "arguments" => %{"action_id" => "linux.disk_usage", "reason" => "Is /srv full?"}
      }
    }

    assert render_component(&ToolCard.render/1, step: %{step(payload) | state: "started"}) =~
             "Ask Emisar to run an action"

    assert render_component(&ToolCard.render/1, step: step(payload)) =~ "Emisar run requested"
  end

  test "a finding tool shows the conclusion and reason with a meaningful action name" do
    payload = %{
      "input" => %{
        "server" => "controller-tools",
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
        "server" => "controller-tools",
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

    line = step |> Map.put(:withheld, %{"output" => "too large"}) |> ToolCard.line()
    assert line.warning =~ "Outside project"
    assert line.warning =~ "withheld"
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

  test "opening a search preserves the full query when only its worker title was retained" do
    # The card polish removed the old description along with its extra fold,
    # losing anything beyond the closed row's 160-character search preview.
    # Stress the harvested worker-title shape without inventing tool arguments.
    title = "Search for '" <> String.duplicate("credits ", 24) <> "' in config"
    recorded = step(%{"kind" => "search", "title" => title})
    assert String.length(ToolCard.line(recorded).detail) == 160

    document =
      render_component(&ToolCard.render/1, step: recorded, grouped: true)
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, ".action-description") |> LazyHTML.text() |> String.trim() ==
             title

    assert Enum.empty?(LazyHTML.query(document, ".action-technical"))
  end

  test "goal cards expose the requested outcome and completion condition without opening JSON" do
    # Host tool-schema boundary: these are the canonical goal fields, not a model fixture.
    args = %{
      "requested_outcome" => "Check current allocation health",
      "completion_contract" => "Source evidence confirms health",
      "authority" => "read_only"
    }

    payload = %{
      "input" => %{"server" => "controller-tools", "tool" => "plan_goal", "arguments" => args}
    }

    html = render_component(&ToolCard.render/1, step: step(payload))

    visible =
      html |> LazyHTML.from_fragment() |> LazyHTML.query(".action-facts") |> LazyHTML.text()

    assert visible =~ args["requested_outcome"]
    assert visible =~ args["completion_contract"]
  end

  # The emisar task's timeline, 2026-09-28: the worker reports a code step's
  # kind without its command or file, and 55 of its lines read only "Tool
  # call", so nobody could tell a command from a thought.
  test "a code step the worker reported only by its kind is named by that kind" do
    for {kind, title} <- [
          {"execute", "Run command"},
          {"think", "Think it through"},
          {"fetch", "Fetch a web page"},
          {"other", "Tool call"}
        ] do
      assert ToolCard.line(step(%{"kind" => kind})).title == title
    end

    card =
      render_component(&ToolCard.render/1, step: step(%{"kind" => "execute"}))
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()

    assert card =~ "The worker reported that a command ran, not which one."

    # A named tool keeps its own name, whatever its kind.
    tool = %{"kind" => "execute", "input" => %{"server" => "emisar", "tool" => "recent_runs"}}
    assert ToolCard.line(step(tool)).title == "Recent runs"
  end

  # Andrew, 2026-09-28: "workers must report commands, thinking and
  # everything else". A command reads as the command, a failed one says its
  # exit code, and a command the worker withheld says why instead of saying
  # nothing was reported.
  test "a narrated command shows what it ran and how it exited, and a withheld one says why" do
    ran = %{
      "kind" => "execute",
      "title" => "Run make check",
      "input" => %{"command" => "make check", "cwd" => "/workspace"}
    }

    assert ToolCard.line(Map.put(step(ran), :exit_code, 2)) |> Map.take([:title, :detail]) ==
             %{title: "Run command", detail: "make check"}

    card = render_component(&ToolCard.render/1, step: Map.put(step(ran), :exit_code, 2))
    document = LazyHTML.from_fragment(card)
    assert LazyHTML.query(document, "pre.action-command-line") |> LazyHTML.text() == "make check"
    assert LazyHTML.query(document, ".action-facts") |> LazyHTML.text() =~ "Exit code2"

    succeeded = render_component(&ToolCard.render/1, step: Map.put(step(ran), :exit_code, 0))
    refute succeeded =~ "Exit code"

    withheld =
      %{"kind" => "execute", "title" => "Run curl"}
      |> step()
      |> Map.put(:withheld, %{"input" => "likely GitHub token", "output" => "too large"})

    text =
      render_component(&ToolCard.render/1, step: withheld)
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()

    assert text =~ "The command was withheld: it looked like it held a GitHub token."
    assert text =~ "What it printed was withheld: it was too large to send."
    refute text =~ "The worker reported that a command ran, not which one."
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
