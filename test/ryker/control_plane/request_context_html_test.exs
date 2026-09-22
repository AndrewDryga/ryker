defmodule Ryker.ControlPlane.RequestContextHTMLTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.{InspectionRedactor, RequestContextHTML}

  test "custom instruction provenance shows only the submitted revisions through redaction and expiry" do
    snapshot = %{
      "global" => %{"scope" => "global", "revision" => 7, "text" => "Saved global PRIVATE_TOKEN"},
      "channel" => %{
        "scope" => "slack:T1:C1",
        "revision" => 3,
        "text" => "Saved channel <script>text</script>"
      }
    }

    artifact =
      InspectionRedactor.artifact(%{"custom_instructions" => snapshot},
        secrets: ["PRIVATE_TOKEN"]
      )

    html =
      artifact |> RequestContextHTML.assembly("$.work", "instructions") |> IO.iodata_to_binary()

    # Each scope is its own collapsible, so a reader sees whether the channel
    # said anything without opening the workspace text.
    assert html =~ "Global instructions"
    assert html =~ "Channel instructions"
    assert html =~ "Configured in Settings for this request"
    assert html =~ "Configured for this Slack channel at request time"
    refute html =~ "Saved with this request"
    assert html =~ "Saved global"
    assert html =~ "Revision 7 at request time"
    refute html =~ "Scope global"
    refute html =~ "Scope slack:T1:C1"
    refute html =~ "PRIVATE_TOKEN"
    refute html =~ "<script>text</script>"

    document = LazyHTML.from_fragment(html)

    assert document
           |> LazyHTML.query(".prompt-group[data-group=policy] .prompt-source-title")
           |> Enum.map(&LazyHTML.text/1) == ["Global instructions", "Channel instructions"]

    refute LazyHTML.text(document) =~ "Retained input"
    expired = InspectionRedactor.artifact(nil, expired: true)
    assert RequestContextHTML.assembly(expired, "$.work", "instructions") == []
  end

  test "instruction estimates count text only and empty scopes have no estimate or visible path" do
    artifact =
      InspectionRedactor.artifact(%{
        "custom_instructions" => %{
          "global" => %{
            "scope" => String.duplicate("workspace-metadata-", 20),
            "revision" => 77,
            "text" => "abcd"
          },
          "channel" => %{"scope" => "slack:T1:C1", "revision" => 3, "text" => ""}
        }
      })

    document =
      artifact
      |> RequestContextHTML.assembly("$.work", "instructions")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    global = LazyHTML.query(document, ".prompt-source[data-source=global]")
    channel = LazyHTML.query(document, ".prompt-source[data-source=channel]")

    assert LazyHTML.text(global) =~ "≈ 1 estimated tokens"
    refute LazyHTML.text(global) =~ "≈ 100"
    refute LazyHTML.text(channel) =~ "estimated tokens"
    assert LazyHTML.text(channel) =~ "Not configured"
    assert LazyHTML.text(channel) =~ "No channel instructions were configured at request time"
    refute LazyHTML.text(channel) =~ "Retained input"
    refute LazyHTML.text(document) =~ "$.work.custom_instructions"
    assert Enum.empty?(LazyHTML.query(document, ".prompt-source-path"))
  end

  test "non-Slack requests show why channel instructions did not apply" do
    artifact =
      InspectionRedactor.artifact(%{
        "custom_instructions" => %{
          "global" => %{"scope" => "global", "revision" => 0, "text" => ""},
          "channel" => nil
        }
      })

    document =
      artifact
      |> RequestContextHTML.assembly("$.work", "instructions")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    global = LazyHTML.query(document, ".prompt-source[data-source=global]")
    channel = LazyHTML.query(document, ".prompt-source[data-source=channel]")

    assert LazyHTML.text(global) =~ "Not configured"
    assert LazyHTML.text(global) =~ "No global instructions were configured for this request"
    assert LazyHTML.text(channel) =~ "Not applicable"
    assert LazyHTML.text(channel) =~ "did not have a Slack channel scope"
    refute LazyHTML.text(document) =~ "Retained input"
  end

  test "Slack addressing is a collapsed message component with its exact retained source" do
    artifact =
      InspectionRedactor.artifact(%{
        "input" => %{"text" => "<@UOTHER> can you check this?"},
        "slack_addressing" => %{"audience" => "ambient", "ryker_user_ref" => "UBOT"}
      })

    html =
      artifact |> RequestContextHTML.assembly("$.context", "routing-1") |> IO.iodata_to_binary()

    document = LazyHTML.from_fragment(html)
    messages = LazyHTML.query(document, ".prompt-group") |> Enum.at(0)
    assert LazyHTML.text(messages) =~ "Messages"
    assert LazyHTML.text(messages) =~ "Who this Slack message addresses"
    component = LazyHTML.query(messages, "[data-source=slack_addressing]")
    refute LazyHTML.text(component) =~ "$.context.slack_addressing"
    assert LazyHTML.text(component) =~ "ambient"
    assert LazyHTML.text(component) =~ "UBOT"
    assert LazyHTML.text(component) =~ "first receipt"
    assert LazyHTML.text(component) =~ "host-configured"
    assert LazyHTML.text(component) =~ "does not grant authority"
    assert Enum.empty?(LazyHTML.query(component, "[open]"))
    assert html =~ "data-source=\"slack_addressing\""
  end

  # A directory enhancement must not erase a name already retained with the
  # message: operators otherwise lose the author while inspecting a request.
  test "retained display names are not interpreted as Slack directory IDs" do
    artifact =
      InspectionRedactor.artifact(%{
        "input" => %{
          "source" => %{"kind" => "slack", "ref" => "T123"},
          "actor" => %{"ref" => "U123", "display_name" => "Andrew <admin>"},
          "text" => "Hello"
        }
      })

    html = artifact |> RequestContextHTML.render() |> IO.iodata_to_binary()
    assert html =~ "<strong>Andrew &lt;admin&gt;</strong>"
    refute html =~ "<strong>Slack reference</strong>"
  end

  # Andrew's screenshot of this block, 2026-09-13: thirteen alphabetised labels
  # — Companions, Freshness, Owner, Repositories, Fetched at, Name, Remote
  # identity, Requested revision, Resolved revision, Stale base revision, Stale
  # base status, Version, Workspace base revision — before the reader learned
  # which repository the model could see. The shape below is the real one from
  # a production submission; `source` is a sibling of `primary`, not its child.
  test "the workspace block names the repository, access and checkout, not every field" do
    artifact =
      InspectionRedactor.artifact(%{
        "workspace" => %{
          "companions" => [],
          "freshness" => %{
            "owner" => "coop",
            "repositories" => [
              %{
                "fetched_at" => "2026-09-13T09:48:09.420651Z",
                "name" => "primary",
                "remote_identity" => "origin",
                "requested_revision" => "refs/heads/main",
                "resolved_revision" => "92c952f7d4f04fd058c4bb3ae7746d9118129ba1",
                "stale_base_revision" => "92c952f7d4f04fd058c4bb3ae7746d9118129ba1",
                "stale_base_status" => "current",
                "version" => 2
              }
            ]
          },
          "primary" => %{
            "base_commit" => "92c952f7d4f04fd058c4bb3ae7746d9118129ba1",
            "name" => "emisar",
            "path" => ".",
            "read_only" => true
          },
          "source" => %{
            "admitted_tree" => "0143954589d4aa290fbb4c6e7cf9ae385ca0c8e0",
            "base_commit" => "92c952f7d4f04fd058c4bb3ae7746d9118129ba1",
            "default_commit" => "92c952f7d4f04fd058c4bb3ae7746d9118129ba1",
            "default_ref" => "refs/heads/main",
            "kind" => "default",
            "remote_identity" => "origin",
            "requested" => %{"kind" => "default"},
            "resolved_at" => "2026-09-13T09:48:09.420710Z",
            "selected_commit" => "92c952f7d4f04fd058c4bb3ae7746d9118129ba1",
            "selected_ref" => "refs/heads/main",
            "version" => 1
          }
        }
      })

    html = artifact |> RequestContextHTML.render("$.work", "work") |> IO.iodata_to_binary()

    for row <- [
          "<dt>Repository</dt><dd>emisar</dd>",
          "<dt>Access</dt><dd>read-only</dd>",
          "<dt>Checked out</dt><dd>refs/heads/main · 92c952f7</dd>",
          "<dt>Freshness</dt><dd>current · fetched 2026-09-13 09:48 UTC</dd>",
          "<dt>Companions</dt><dd>none</dd>"
        ] do
      assert html =~ row
    end

    # None of the dumped labels survive as headings.
    for gone <- ["Stale base revision", "Workspace base revision", "Remote identity", "Version"] do
      refute html =~ "<h4>#{gone}</h4>"
    end
  end

  test "message roles and context omissions are readable without making source HTML executable" do
    artifact =
      InspectionRedactor.artifact(%{
        "inputs" => %{
          "items" => [
            %{
              "actor_ref" => "slack:user:U123",
              "current" => true,
              "content" => %{"content" => %{"text" => "Inspect <script>alert('x')</script>"}}
            }
          ],
          "omitted_count" => 3
        }
      })

    html = artifact |> RequestContextHTML.render() |> IO.iodata_to_binary()
    assert html =~ "context-message-body"
    assert html =~ "slack:user:U123"
    assert html =~ "3 earlier inputs were omitted"
    assert html =~ "Inspect &lt;script&gt;"
    refute html =~ "<script>"
  end

  test "an incomplete sanitized artifact is not presented as complete readable context" do
    artifact =
      InspectionRedactor.artifact(%{"input" => %{"text" => String.duplicate("x", 100)}},
        max_bytes: 30
      )

    assert RequestContextHTML.render(artifact) == []
    assert RequestContextHTML.render(InspectionRedactor.artifact(nil, expired: true)) == []

    assert RequestContextHTML.instructions(InspectionRedactor.artifact(nil, expired: true), :work) ==
             []
  end

  test "all retained fields including empty and unfamiliar layers remain source-labelled and escaped" do
    # New context fields previously disappeared from the readable projection.
    artifact =
      InspectionRedactor.artifact(%{
        "records" => [],
        "future.layer" => "<script>opaque</script>",
        "operator_context" => %{"memory" => [], "continuity" => %{}}
      })

    html = artifact |> RequestContextHTML.render("$.work") |> IO.iodata_to_binary()
    assert html =~ "data-source=\"future.layer\""
    assert html =~ "Additional retained field"
    assert html =~ "Empty in request"
    refute html =~ "$.work.operator_context.memory"
    assert html =~ "data-source=\"memory\""
    assert html =~ "Conversation memory"
    assert html =~ "&lt;script&gt;opaque&lt;/script&gt;"
    refute html =~ "<script>"
  end

  test "unexpected retained context shapes remain inspectable instead of crashing the page" do
    for context <- [
          %{"inputs" => %{"items" => nil}},
          %{"candidates" => [nil, "legacy value", %{"state" => %{}, "allowed_relations" => 1}]},
          %{"input" => %{"actor" => %{"kind" => %{}}, "occurred_at" => %{}, "text" => "Hello"}}
        ] do
      artifact = InspectionRedactor.artifact(context)
      assert artifact |> RequestContextHTML.render() |> IO.iodata_to_binary() |> is_binary()
    end
  end

  test "the flat briefing retains empty runtime fields and escapes unfamiliar paths" do
    # Flattening the prompt inventory must not erase less common retained fields.
    artifact =
      InspectionRedactor.artifact(%{
        "operator_context" => %{"guidance" => [], "memory" => []},
        "future.<script>" => "<script>opaque</script>",
        "offer_confirmation_supported" => false
      })

    html = artifact |> RequestContextHTML.assembly("$.work", "request-1") |> IO.iodata_to_binary()
    # The request settings read as named blocks now; no field is erased by that,
    # because Raw context carries the exact submitted bytes.
    assert html =~ "What it was allowed to do"
    assert html =~ "Raw context"
    refute html =~ "$.work.operator_context.guidance"
    refute html =~ "$.work.operator_context.memory"
    refute html =~ "$.work.offer_confirmation_supported"
    assert html =~ "&quot;guidance&quot;: []"
    assert html =~ "&quot;memory&quot;: []"
    assert html =~ "&quot;offer_confirmation_supported&quot;: false"
    assert html =~ "false"
    assert html =~ "&lt;script&gt;opaque&lt;/script&gt;"
    refute html =~ "<script>"
    assert RequestContextHTML.assembly(%{artifact | truncated: true}, "$.work", "request-1") == []

    empty_context = InspectionRedactor.artifact(%{"operator_context" => %{}})

    empty_html =
      empty_context
      |> RequestContextHTML.assembly("$.work", "request-1")
      |> IO.iodata_to_binary()

    refute empty_html =~ "$.work.operator_context"
    assert empty_html =~ "&quot;operator_context&quot;: {}"

    assert RequestContextHTML.assembly(
             InspectionRedactor.artifact(nil, expired: true),
             "$.work",
             "request-1"
           ) == []
  end

  test "an incomplete instruction is labelled before its source disclosure opens" do
    # A shortened policy otherwise looked complete in the visible source list.
    artifact = InspectionRedactor.artifact("Host-authored retained instructions", max_bytes: 10)

    document =
      artifact
      |> RequestContextHTML.assembly_instructions("partial")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query(".prompt-source > summary") |> LazyHTML.text() =~
             "Partial display"

    assert Enum.empty?(LazyHTML.query(document, ".prompt-source[open]"))
  end

  test "each collapsed partial exposes every retained value without a second hidden cutoff" do
    # The old readable view silently stopped at 40 items even when the full
    # retained component was available, making the prompt impossible to audit.
    artifact =
      InspectionRedactor.artifact(%{
        "records" => Enum.to_list(1..51),
        "unknown" => %{"empty" => []}
      })

    html = artifact |> RequestContextHTML.assembly("$.work", "all") |> IO.iodata_to_binary()
    assert html =~ "<p>51</p>"
    # A field with no named home is still retained in full, in Raw context.
    assert html =~ "Raw context"
    assert html =~ "unknown"
    refute html =~ "Additional entries remain"
    assert Enum.empty?(html |> LazyHTML.from_fragment() |> LazyHTML.query("details[open]"))
  end

  test "conversation recall keeps source metadata and unfamiliar state fields inspectable" do
    # The readable summary previously dropped purpose, evidence and new fields.
    context = %{
      "operator_context" => %{
        "continuity" => %{
          "current" => %{
            "source_ref" => "continuity:source",
            "state" => %{
              "situation" => "Allocation recovered",
              "purpose" => "Track recovery",
              "future" => "<extra>"
            }
          }
        }
      }
    }

    html =
      context
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.work", "recall")
      |> IO.iodata_to_binary()

    assert html =~ "Track recovery"
    assert html =~ "&lt;extra&gt;"
    assert html =~ "Exact component"
  end

  test "retained source notes are readable even when no conversation summary was selected" do
    # Harvested unchanged from the September 6 Livebook request's retained
    # briefing. All three browser widths exposed only an Exact component JSON
    # disclosure: the readable view silently ignored the only recalled memory.
    memory =
      "testdata/learning/retained-livebook-briefing-memory.json"
      |> File.read!()
      |> Jason.decode!()

    document = recall_document(memory)
    note = LazyHTML.query(document, ".conversation-recall[data-memory-kind=observation]")
    assert LazyHTML.text(note) =~ hd(memory["observations"])["summary"]
    assert LazyHTML.text(note) =~ "Source note"
    assert LazyHTML.text(note) =~ "intended infrastructure configuration"
    assert Enum.empty?(LazyHTML.query(note, "details, pre"))
    assert LazyHTML.text(document) =~ "Conversation memory"
    assert LazyHTML.text(document) =~ "Exact component"
    assert Enum.empty?(LazyHTML.query(document, "details[open]"))
  end

  test "malformed retained memory remains inspectable without crashing readable recall" do
    for memory <- [
          %{"current" => %{"state" => "malformed"}},
          %{"observations" => [nil, "malformed", %{"summary" => "<script>note</script>"}]},
          %{"knowledge" => [nil, %{"title" => "<topic>", "summary" => "<script>fact</script>"}]}
        ] do
      document = recall_document(memory)
      assert LazyHTML.text(document) =~ "Exact component"
      assert Enum.empty?(LazyHTML.query(document, "script"))
    end
  end

  test "maintained topics expose their retained title and summary without opening raw JSON" do
    # Exact topic state harvested from the private replay, September 7. Topic
    # knowledge shared the source-note omission in the compact briefing view.
    topic =
      "testdata/learning/retained-blitz-release-knowledge.json"
      |> File.read!()
      |> Jason.decode!()

    document = recall_document(%{"knowledge" => [topic]})
    knowledge = LazyHTML.query(document, ".conversation-recall[data-memory-kind=knowledge]")
    assert LazyHTML.text(knowledge) =~ topic["title"]
    assert LazyHTML.text(knowledge) =~ topic["summary"]
    assert LazyHTML.text(knowledge) =~ "Maintained topic"
    assert Enum.empty?(LazyHTML.query(knowledge, "details, pre"))
  end

  defp recall_document(memory) do
    %{"operator_context" => %{"continuity" => memory}}
    |> InspectionRedactor.artifact()
    |> RequestContextHTML.assembly("$.work", "recall")
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
  end

  test "attachment-only messages are readable in the briefing as well as the timeline" do
    # Slack alert bodies can live entirely in attachments while text is empty.
    context = %{
      "input" => %{
        "content" => %{
          "text" => "",
          "attachments" => [
            %{"title" => "Host OOM kills", "text" => "RESOLVED - 1 alert"}
          ]
        }
      }
    }

    html =
      context
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "source")
      |> IO.iodata_to_binary()

    body =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".context-message-body")
      |> LazyHTML.text()

    assert body =~ "Host OOM kills"
    assert body =~ "RESOLVED - 1 alert"
  end

  test "admission candidates lead with a readable objective, evidence and rationale" do
    preview = fn text, at, truncated ->
      %{
        "content_preview" =>
          Jason.encode!(%{
            "actor" => %{"ref" => "slack:user:U1"},
            "content" => %{"text" => text},
            "event_kind" => "message"
          }),
        "occurred_at" => at,
        "truncated" => truncated
      }
    end

    candidate = %{
      "episode_ref" => "candidate:opaque-reference",
      "state" => "complete",
      "allowed_relations" => ["history_only"],
      "digest" => %{
        "objective" => "Restore the production deployment",
        "input_count" => 4,
        "conversations" => 2,
        "covered_through" => "2026-09-18T18:10:00Z",
        "freshness" => "current",
        "latest_development" => "The replacement allocation became healthy."
      },
      "first_input" => preview.("Deployment is failing", "2026-09-18T17:00:00Z", false),
      "latest_input" => preview.("Replacement is healthy", "2026-09-18T18:10:00Z", true),
      "match" => %{
        "same_thread" => true,
        "topic_fit" => 0.91,
        "direct_references" => 1
      }
    }

    document =
      %{"candidates" => [candidate]}
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "admission")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    option = LazyHTML.query(document, ".context-candidate")
    text = LazyHTML.text(option)
    assert text =~ "Completed - background only"
    assert text =~ "Restore the production deployment"
    assert text =~ "4 messages"
    assert text =~ "2 conversations"
    assert text =~ "Current"
    assert text =~ "The replacement allocation became healthy."
    assert text =~ "First message"
    assert text =~ "Deployment is failing"
    assert text =~ "Latest message"
    assert text =~ "Replacement is healthy"
    assert text =~ "truncated"
    assert text =~ "Why offered"
    assert text =~ "same thread"
    assert text =~ "direct reference"
    refute text =~ "Technical details"
    assert Enum.empty?(LazyHTML.query(option, ".context-candidate-technical"))
    refute LazyHTML.text(option) =~ "Allowed relations"
    assert Enum.empty?(LazyHTML.query(option, ".context-field"))
  end

  test "candidate previews omit duplicates and sparse or malformed history stays bounded" do
    preview = %{
      "content_preview" => Jason.encode!(%{"content" => %{"text" => "Same message"}}),
      "occurred_at" => "2026-09-18T17:00:00Z",
      "truncated" => false
    }

    candidates = [
      %{
        "episode_ref" => "candidate:sparse",
        "state" => "active",
        "allowed_relations" => ["same_work", "history_only"],
        "digest" => %{"objective" => "Continue the incident"},
        "first_input" => preview,
        "latest_input" => preview
      },
      %{
        "episode_ref" => "candidate:truncated",
        "state" => "cancelled",
        "allowed_relations" => ["history_only"],
        "digest" => %{"objective" => "Retained partial history"},
        "first_input" => %{
          "content_preview" => ~s({"content":{"text":"Readable prefix from a partial preview"),
          "occurred_at" => "2026-09-17T17:00:00Z",
          "truncated" => true
        }
      },
      %{"state" => %{}, "allowed_relations" => 1},
      String.duplicate("legacy-value-", 100)
    ]

    document =
      %{"candidates" => candidates}
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "admission")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    options = LazyHTML.query(document, ".context-candidate")
    assert Enum.count(options) == 4

    sparse = Enum.at(options, 0)
    assert LazyHTML.text(sparse) =~ "Active - may continue or provide background"
    assert Enum.count(LazyHTML.query(sparse, ".candidate-preview")) == 1

    truncated = Enum.at(options, 1) |> LazyHTML.text()
    assert truncated =~ "Readable prefix from a partial preview"
    assert truncated =~ "truncated"

    malformed = options |> Enum.drop(2) |> Enum.map_join(&LazyHTML.text/1)
    assert malformed =~ "Historical candidate - retained shape unavailable"
    assert malformed =~ "Retained raw candidate"
    assert String.length(malformed) < 1_000
  end
end
