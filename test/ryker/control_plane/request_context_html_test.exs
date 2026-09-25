defmodule Ryker.ControlPlane.RequestContextHTMLTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.{CallRun, InspectionRedactor, RequestContextHTML}

  test "retained Work history exposes its messages, limits and summary availability" do
    # The live Work card hid all eleven retained messages and both summaries
    # because their bundle/manifest envelope differs from routing's flat shape.
    context =
      "testdata/control_plane/retained-work-conversation-context.json"
      |> File.read!()
      |> Jason.decode!()

    document =
      %{"conversation_context" => context}
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.work", "nested-history")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    earlier = LazyHTML.query(document, "[data-source=earlier_messages]")
    assert LazyHTML.text(earlier) =~ "11 messages"
    assert Enum.count(LazyHTML.query(earlier, ".context-message")) == 11
    assert Enum.count(LazyHTML.query(earlier, ".context-messages-history")) == 1
    assert Enum.count(LazyHTML.query(earlier, ".ui-message > .ui-message-body")) == 11

    assert Enum.count(LazyHTML.query(earlier, ".ui-message-footer > .context-message-details")) ==
             11

    refute LazyHTML.text(earlier) =~ "Current message"

    assert LazyHTML.attribute(LazyHTML.query(earlier, ".context-message"), "data-message-context") ==
             List.duplicate("Earlier context", 11)

    assert LazyHTML.text(earlier) =~ "Reply with exactly: progress validation complete."
    assert LazyHTML.text(earlier) =~ "Up to 20 earlier messages"
    refute LazyHTML.text(earlier) =~ "Bodies not retained"

    for kind <- ["channel", "thread"] do
      summary = LazyHTML.query(document, "[data-source=#{kind}_summary]")
      assert LazyHTML.text(summary) =~ "None saved"

      assert summary |> LazyHTML.query(".prompt-source-row") |> LazyHTML.attribute("title") ==
               ["No summary had been saved for this conversation."]
    end
  end

  test "continuation context never borrows the conversation memory source-note count" do
    # The live second-turn briefing labelled both different continuity sources
    # 'Source notes 13', though only operator_context contained those notes.
    artifact =
      InspectionRedactor.artifact(%{
        "continuity" => %{
          "first_input" => %{
            "content" => %{"text" => "Reply with exactly: session reuse validated."}
          }
        },
        "operator_context" => %{
          "continuity" => %{"observations" => [%{"summary" => "session reuse validated."}]}
        }
      })

    document =
      artifact
      |> RequestContextHTML.assembly("$.work", "scoped-counts", %{
        "continuity" => %{label: "1 source note", known?: true}
      })
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    sources = LazyHTML.query(document, "[data-source=continuity]") |> Enum.to_list()
    assert length(sources) == 2
    [continuation, memory] = sources
    assert LazyHTML.query(continuation, "summary") |> LazyHTML.text() =~ "Conversation continuity"
    refute LazyHTML.query(continuation, "summary") |> LazyHTML.text() =~ "source note"
    assert LazyHTML.query(memory, "summary") |> LazyHTML.text() =~ "1 source note"
  end

  test "a context manifest without message bodies cannot claim no messages were supplied" do
    # Work briefings retain the count separately from the message bundle. The
    # timeline labelled the missing bundle '0 messages', contradicting the count.
    artifact =
      InspectionRedactor.artifact(%{"context_manifest" => %{"included" => 11, "requested" => 20}})

    document =
      artifact
      |> RequestContextHTML.assembly("$.work", "missing-bodies")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    earlier = LazyHTML.query(document, "[data-source=earlier_messages]")
    assert LazyHTML.text(earlier) =~ "11 reported"
    assert LazyHTML.text(earlier) =~ "Message bodies were not retained in this context."
    refute LazyHTML.text(earlier) =~ "0 messages"
    refute LazyHTML.text(earlier) =~ "No earlier messages were supplied"
    assert Enum.empty?(LazyHTML.query(earlier, ".prompt-source-estimate"))
  end

  test "a work context manifest is not mistaken for an earlier-message bundle" do
    artifact =
      InspectionRedactor.artifact(%{"context_manifest" => %{"inputs" => %{"eligible" => 1}}})

    document =
      artifact
      |> RequestContextHTML.assembly("$.work", "work-manifest")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(document, "[data-source=earlier_messages]"))
    other = LazyHTML.query(document, "[data-source=other_fields]")
    assert LazyHTML.text(other) =~ "$.work.context_manifest.inputs"
  end

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
    assert html =~ "Global instructions"
    assert html =~ "Channel instructions"
    assert html =~ "Applied"
    refute html =~ "Saved with this request"
    assert html =~ "Saved global"
    assert html =~ "From Settings"
    assert html =~ "Revision 7"
    refute html =~ "Captured when request arrived"
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

    assert LazyHTML.text(global) =~ "≈ 1 token"
    refute LazyHTML.text(global) =~ "≈ 100"
    refute LazyHTML.text(channel) =~ ~r/≈ [\d,]+ tokens/
    assert LazyHTML.text(channel) =~ "Not configured"

    assert channel |> LazyHTML.query(".prompt-source-row") |> LazyHTML.attribute("title") ==
             ["No channel instructions were saved for this Slack channel when this request ran."]

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

    assert global
           |> LazyHTML.query(".prompt-source-row > .ui-disclosure-meta > .prompt-source-status")
           |> LazyHTML.text() == "Not configured"

    assert channel
           |> LazyHTML.query(".prompt-source-row > .ui-disclosure-meta > .prompt-source-status")
           |> LazyHTML.text() == "Not applicable"

    assert Enum.empty?(LazyHTML.query(document, ".prompt-source-main .prompt-source-status"))

    # A scope with nothing in it is a flat row, not a disclosure opening onto one sentence.
    assert Enum.empty?(LazyHTML.query(document, "details.prompt-source"))

    assert global |> LazyHTML.query(".prompt-source-row") |> LazyHTML.attribute("title") ==
             ["No global instructions were saved in Settings when this request ran."]

    assert channel |> LazyHTML.query(".prompt-source-row") |> LazyHTML.attribute("title") ==
             ["This request did not come through Slack, so channel instructions did not apply."]

    refute LazyHTML.text(channel) =~ "came through Chat"

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
    messages = LazyHTML.query(document, ".prompt-group[data-group=conversation]")
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
    assert html =~ "ui-message-body"
    assert html =~ "slack:user:U123"
    assert html =~ "3 earlier inputs were omitted"
    assert html =~ "Inspect &lt;script&gt;"
    refute html =~ "<script>"
  end

  test "a Chat sender is named, not shown as its routing reference" do
    # The Work briefing named the Local operator "control_plane:user:local-operator"
    # while the timeline and the routing briefing said "Local operator".
    artifact =
      InspectionRedactor.artifact(%{
        "inputs" => %{
          "items" => [
            %{
              "actor_ref" => "control_plane:user:local-operator",
              "current" => true,
              "content" => %{"content" => %{"text" => "Reply with exactly: done."}}
            }
          ]
        }
      })

    message =
      artifact
      |> RequestContextHTML.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".ui-message")

    assert LazyHTML.query(message, ".ui-message-header strong") |> LazyHTML.text() ==
             "Local operator"
  end

  test "Ryker's own earlier replies read as Ryker's messages in the briefing" do
    # Earlier messages now carry Ryker's delivered replies; they are Ryker
    # speaking, drawn in Ryker's bubble, not an unknown sender named "ryker".
    artifact =
      InspectionRedactor.artifact(%{
        "conversation_context" => %{
          "messages" => [
            %{"actor_ref" => "local-operator", "content" => %{"text" => "Status?"}},
            %{"actor_ref" => "ryker", "content" => %{"text" => "All healthy."}}
          ]
        }
      })

    messages =
      artifact
      |> RequestContextHTML.assembly("$.context", "ryker-replies")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-source=earlier_messages] .ui-message")

    assert Enum.map(
             messages,
             &(LazyHTML.query(&1, ".ui-message-header strong") |> LazyHTML.text())
           ) ==
             ["Local operator", "Ryker"]

    assert LazyHTML.attribute(messages, "data-author") == ["person", "ryker"]
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
    assert html =~ "More specific provenance was not recorded by this viewer."
    assert html =~ "Empty in request"
    refute html =~ "$.work.operator_context.memory"
    assert html =~ "data-source=\"memory\""
    assert html =~ "Conversation notes"
    assert html =~ "&lt;script&gt;opaque&lt;/script&gt;"
    refute html =~ "<script>"
  end

  test "a routing briefing keeps every row and says why a part was not sent" do
    # Routing sends a part only when it has something in it. The briefing hid
    # every missing part, so a first message in a new chat read as a broken
    # card beside a busy one, and the only trace of the empty candidate list
    # was a loose "Sent empty: Candidates" line.
    context =
      "testdata/control_plane/submitted-prompts/routing-lean.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("context")

    document =
      context
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "request-1")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    absent =
      document
      |> LazyHTML.query(".prompt-source-absent")
      |> Enum.map(fn row ->
        {row |> LazyHTML.query(".prompt-source-title") |> LazyHTML.text(),
         row |> LazyHTML.query(".prompt-source-status") |> LazyHTML.text()}
      end)

    assert absent == [
             {"Global instructions", "Not configured"},
             {"Channel instructions", "Not applicable"},
             {"Channel summary", "None saved"},
             {"Thread summary", "Not applicable"},
             {"Continuation candidates", "None"},
             {"Background matches", "None"},
             {"Conversation notes", "None"},
             {"Learned topics", "None"}
           ]

    # Each says why on hover, and none is a disclosure that opens onto nothing.
    for row <- LazyHTML.query(document, ".prompt-source-absent .prompt-source-row") do
      assert [hint] = LazyHTML.attribute(row, "title")
      assert hint != ""
    end

    assert Enum.empty?(LazyHTML.query(document, "details.prompt-source-absent"))
    refute LazyHTML.text(document) =~ "Sent empty"

    # What was sent still opens as before.
    assert document
           |> LazyHTML.query("details.prompt-source[data-source=earlier_messages]")
           |> Enum.count() == 1
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

  test "every retained field has a named home instead of a mixed raw blob" do
    # Raw context dumped the manifest, run settings, empty memory and unknown
    # fields into one JSON block; a reader could not tell what any of it was for.
    artifact =
      InspectionRedactor.artifact(%{
        "operator_context" => %{"guidance" => [], "memory" => []},
        "future.<script>" => "<script>opaque</script>",
        "offer_confirmation_supported" => false,
        "episode_title" => "Investigate checkout 502s"
      })

    html = artifact |> RequestContextHTML.assembly("$.work", "request-1") |> IO.iodata_to_binary()
    document = LazyHTML.from_fragment(html)
    refute html =~ "Raw context"
    refute html =~ "Request scope"

    assert document
           |> LazyHTML.query(".prompt-source-absent .prompt-source-title")
           |> Enum.map(&LazyHTML.text/1) == ["Guidance", "Facts"]

    run = LazyHTML.query(document, "[data-source=run_details]")
    assert LazyHTML.text(run) =~ "Offer confirmation"
    assert LazyHTML.text(run) =~ "Not supported"
    assert LazyHTML.text(run) =~ "Episode title"
    assert LazyHTML.text(run) =~ "Investigate checkout 502s"

    other = LazyHTML.query(document, "[data-source=other_fields]")
    assert LazyHTML.text(other) =~ ~s($.work["future.<script>"])
    assert html =~ "&lt;script&gt;opaque&lt;/script&gt;"
    refute html =~ "<script>"
    assert RequestContextHTML.assembly(%{artifact | truncated: true}, "$.work", "request-1") == []

    empty_context = InspectionRedactor.artifact(%{"operator_context" => %{}})

    empty_html =
      empty_context
      |> RequestContextHTML.assembly("$.work", "request-1")
      |> IO.iodata_to_binary()

    refute empty_html =~ "$.work.operator_context"
    refute empty_html =~ "Sent empty"

    assert empty_html
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".prompt-source-absent")
           |> LazyHTML.text() =~ "None"

    assert RequestContextHTML.assembly(
             InspectionRedactor.artifact(nil, expired: true),
             "$.work",
             "request-1"
           ) == []
  end

  test "a prompt that loads on open shows its size before it is opened" do
    # The collapsed Prompt text row showed no size until it was opened, while
    # every other row of the card did. Its size is known without its text.
    prompt =
      Jason.encode!(%{"instructions" => String.duplicate("Route. ", 60), "context" => %{}})

    tokens = "≈ #{CallRun.delimit(ceil(byte_size(prompt) / 4))} tokens"

    for artifact <- [
          InspectionRedactor.artifact(prompt, disclosed: false),
          InspectionRedactor.artifact(prompt, preserve_format: true)
        ] do
      summary =
        [%{id: "request", artifact: artifact}]
        |> RequestContextHTML.submitted("request-1", "request-1-artifact")
        |> IO.iodata_to_binary()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".prompt-source[data-source=request] > summary")
        |> LazyHTML.text()

      assert summary =~ tokens, "#{artifact.state}: #{summary}"
      refute summary =~ "Empty in request"
    end
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

  test "conversation context is split into useful top-level disclosures" do
    artifact =
      InspectionRedactor.artifact(%{
        "input" => %{
          "source" => %{"kind" => "control_plane", "ref" => "local"},
          "actor" => %{"ref" => "local-operator"}
        },
        "context_manifest" => %{
          "included" => 5,
          "requested" => 20,
          "source_read" => "retained_only",
          "cutoff" => "2026-09-21T05:48:52.427135Z",
          "channel_summary" => %{"status" => "unavailable", "reason" => "absent"},
          "thread_summary" => %{"status" => "unavailable", "reason" => "not_applicable"}
        },
        "conversation_context" => %{
          "messages" => [
            %{
              "actor_ref" => "local-operator",
              "content" => %{"text" => "Earlier question"},
              "occurred_at" => "2026-09-21T05:47:00Z"
            }
          ],
          "channel_summary" => nil,
          "thread_summary" => nil
        },
        "allowed_actions" => ["start_episode", "reply"]
      })

    document =
      artifact
      |> RequestContextHTML.assembly("$.work", "request-1")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    messages = ".prompt-group[data-group=conversation]"

    # Counts sit on the rows they count; the section heading does not total them.
    refute LazyHTML.text(LazyHTML.query(document, messages <> " > header")) =~ "message"

    assert document
           |> LazyHTML.query(messages <> " > .prompt-source")
           |> LazyHTML.attribute("data-source") == ~w(input earlier_messages)

    # Summaries are saved documents about the conversation, not its messages.
    assert document
           |> LazyHTML.query(".prompt-group[data-group=summaries] > .prompt-source")
           |> LazyHTML.attribute("data-source") == ~w(channel_summary thread_summary)

    assert LazyHTML.text(document) =~ "1 message"
    assert LazyHTML.text(document) =~ "Earlier question"
    assert LazyHTML.text(document) =~ "Up to 20 earlier messages"
    assert LazyHTML.text(document) =~ "Channel summary"
    assert LazyHTML.text(document) =~ "Thread summary"

    # The recorded reason picks the same words routing uses when it leaves a
    # summary out: none saved for the conversation, not applicable outside a thread.
    assert document
           |> LazyHTML.query("[data-source=channel_summary] .prompt-source-status")
           |> LazyHTML.text() == "None saved"

    assert document
           |> LazyHTML.query("[data-source=thread_summary] .prompt-source-status")
           |> LazyHTML.text() == "Not applicable"

    # Every routing choice is on the row without opening it, and the ones this
    # input did not allow are marked: a restriction explains a decision the
    # model could not make. With nothing else to show, the row does not expand.
    permitted = LazyHTML.query(document, "[data-source=permitted_actions]")
    assert Enum.empty?(LazyHTML.query(permitted, "details, summary"))

    chips =
      permitted
      |> LazyHTML.query(".permitted-action")
      |> Enum.map(fn chip ->
        {chip |> LazyHTML.text() |> String.trim(), LazyHTML.attribute(chip, "data-permitted")}
      end)

    assert chips == [
             {"Start work", ["true"]},
             {"Continue work (not permitted)", ["false"]},
             {"Reply", ["true"]},
             {"React (not permitted)", ["false"]},
             {"Ignore (not permitted)", ["false"]}
           ]

    sources = LazyHTML.query(document, ".prompt-group[data-group=runtime] > .prompt-source")
    assert LazyHTML.attribute(sources, "data-source") == ["permitted_actions"]

    # Permitted actions has nothing to open, so it has no chevron.
    assert Enum.empty?(LazyHTML.query(document, ".prompt-group[data-group=runtime] .ui-icon"))
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
    # A field with no named home is still retained in full, in Other fields.
    assert html =~ "Other fields"
    assert html =~ "$.work.unknown"
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
    note = LazyHTML.query(document, ".context-note[data-memory-kind=observation]")
    assert LazyHTML.text(note) =~ hd(memory["observations"])["summary"]
    assert LazyHTML.text(note) =~ "Local operator"
    assert LazyHTML.text(note) =~ "intended infrastructure configuration"
    assert Enum.empty?(LazyHTML.query(note, "details, pre"))
    assert LazyHTML.text(document) =~ "Conversation notes"
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
      |> LazyHTML.query(".ui-message-body")
      |> LazyHTML.text()

    assert body =~ "Host OOM kills"
    assert body =~ "RESOLVED - 1 alert"
  end

  test "supplied messages read as a transcript and keep the raw event subordinate" do
    context = %{
      "inputs" => %{
        "items" => [
          %{
            "current" => false,
            "source" => %{"kind" => "control_plane", "ref" => "local"},
            "actor" => %{"kind" => "user", "ref" => "local-operator"},
            "content" => %{"text" => "Earlier question"},
            "occurred_at" => "2026-09-21T05:44:38.329569Z"
          },
          %{
            "current" => true,
            "source" => %{"kind" => "control_plane", "ref" => "local"},
            "actor" => %{"kind" => "user", "ref" => "local-operator"},
            "content" => %{"text" => "Current question"},
            "occurred_at" => "2026-09-21T05:48:52.427135Z"
          }
        ]
      }
    }

    document =
      context
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.work", "messages", %{
        "inputs" => %{label: "2 current and earlier messages", known?: true}
      })
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    text = LazyHTML.text(document)
    assert text =~ "Messages"

    # The count is on the row it counts, not totalled again in the heading.
    assert document
           |> LazyHTML.query("[data-source=inputs] .prompt-source-count")
           |> LazyHTML.text() == "2 messages"

    assert text =~ "Earlier context"
    assert text =~ "Current message"
    assert text =~ "Local operator"
    assert text =~ "21 Sep, 05:48:52 UTC"
    assert text =~ "Details"
    assert text =~ "Chat"
    assert text =~ "Raw event (JSON)"
    refute text =~ "Copy raw event"
    assert text =~ "Sender ID"

    assert Enum.empty?(
             LazyHTML.query(document, ".context-message-details dt")
             |> Enum.filter(&(LazyHTML.text(&1) == "Received"))
           )

    assert Enum.empty?(LazyHTML.query(document, "[data-copy-status][aria-live=polite]"))
    refute text =~ "The message that started this routing call"
    refute text =~ "You"
    refute text =~ "Source fields and attachment metadata"
  end

  test "related history separates continuation and context matches with compact counts" do
    candidate = %{
      "episode_ref" => "candidate:opaque",
      "state" => "complete",
      "allowed_relations" => ["history_only"],
      "title" => "Restore the production deployment",
      "message_count" => 4,
      "conversations" => 2,
      "first_message" => %{
        "actor" => "U1",
        "at" => "2026-09-18T17:00:00Z",
        "text" => "Deployment is failing"
      },
      "latest_message" => %{
        "actor" => "U1",
        "at" => "2026-09-18T18:10:00Z",
        "text" => "Replacement is healthy",
        "truncated" => true
      },
      "outcome" => "Replied: The replacement allocation is healthy.",
      "idle_minutes" => 90,
      "evidence" => ["shares 1 identifier", "same thread", "similar wording"]
    }

    document =
      %{"candidates" => [candidate]}
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "admission", %{
        "candidates" => %{excluded: 3, reason: "Shortlist limit reached"}
      })
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert LazyHTML.text(document) =~ "Related history"
    assert LazyHTML.text(document) =~ "Earlier work this message may belong to."
    assert LazyHTML.text(document) =~ "Background matches"

    # Work the search found but did not offer was never sent: it belongs to the
    # search card before the briefing, not to the briefing.
    refute LazyHTML.text(document) =~ "Not supplied"

    option = LazyHTML.query(document, ".context-candidate")
    text = LazyHTML.text(option)

    assert LazyHTML.query(option, ".candidate-heading h4") |> LazyHTML.text() =~
             "Restore the production deployment"

    assert text =~ "idle 1 h"
    assert text =~ "Replied: The replacement allocation is healthy."
    assert text =~ "Matched on"
    assert text =~ "shares 1 identifier · same thread · similar wording"
    assert text =~ "Latest of 4 messages"
    assert text =~ "Opening message"
    assert text =~ "Deployment is failing"
    assert text =~ "Replacement is healthy"
    assert text =~ "truncated"
    refute text =~ "Allowed relations"
    assert Enum.empty?(LazyHTML.query(option, ".context-field"))
  end

  test "a candidate is headed by the name the router saw, with its first message beneath" do
    # Candidates were headed by their first message. When the router read the
    # episode's own name, that name heads the card.
    candidate = %{
      "state" => "complete",
      "episode_ref" => "candidate:named",
      "title" => "Investigate checkout 502s",
      "message_count" => 1,
      "first_message" => %{
        "actor" => "U1",
        "at" => "2026-09-18T17:00:00Z",
        "text" => "Something is off with checkout"
      },
      "evidence" => ["same thread"]
    }

    document =
      %{"candidates" => [candidate]}
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "admission")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query(".candidate-heading h4") |> LazyHTML.text() ==
             "Investigate checkout 502s"

    messages = document |> LazyHTML.query(".candidate-messages") |> LazyHTML.text()
    assert messages =~ "Opening message"
    assert messages =~ "Something is off with checkout"

    context = %{
      id: "context",
      artifact: InspectionRedactor.artifact(%{"candidates" => [candidate]})
    }

    assert %{"candidate:named" => %{value: "Investigate checkout 502s"}} =
             RequestContextHTML.candidate_links([context], "admission")
  end

  test "a candidate links to its episode instead of reproducing history the router never read" do
    # The card loaded up to twenty messages of the earlier episode under "not
    # sent to the model". A briefing shows what the router read; the rest of
    # that episode is its own timeline, one link away.
    candidate = %{
      "state" => "complete",
      "episode_ref" => "candidate:history",
      "title" => "Investigate the incident",
      "message_count" => 3,
      "first_message" => %{
        "actor" => "U1",
        "at" => "2026-09-18T17:00:00Z",
        "text" => "First supplied preview"
      },
      "latest_message" => %{
        "actor" => "U1",
        "at" => "2026-09-18T18:00:00Z",
        "text" => "Latest supplied preview"
      },
      "evidence" => ["same thread"]
    }

    document =
      %{"candidates" => [candidate]}
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "admission", %{
        "candidate_episodes" => %{"candidate:history" => "/timeline/episode%3A1"}
      })
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert document
           |> LazyHTML.query(".context-candidate a.candidate-episode-link")
           |> LazyHTML.attribute("href") == ["/timeline/episode%3A1"]

    refute LazyHTML.text(document) =~ "not sent to the model"
    assert Enum.empty?(LazyHTML.query(document, "[data-artifact]"))

    # The messages the router did read stay on the card, under labels that say
    # how much of the episode they are.
    messages = LazyHTML.query(document, ".candidate-messages") |> LazyHTML.text()
    assert messages =~ "Latest of 3 messages"
    assert messages =~ "Latest supplied preview"
    assert messages =~ "Opening message"
    assert messages =~ "First supplied preview"
  end

  test "a sparse candidate reads once, and partial or malformed ones stay bounded" do
    candidates = [
      %{
        "episode_ref" => "candidate:sparse",
        "state" => "active",
        "allowed_relations" => ["same_work", "history_only"],
        "first_message" => %{
          "actor" => "U1",
          "at" => "2026-09-18T17:00:00Z",
          "text" => "Same message"
        }
      },
      %{
        "episode_ref" => "candidate:truncated",
        "state" => "cancelled",
        "allowed_relations" => ["history_only"],
        "title" => "Retained partial history",
        "first_message" => %{
          "actor" => "U1",
          "at" => "2026-09-17T17:00:00Z",
          "text" => "Readable prefix from a partial preview",
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

    # Without a name the opening message is the heading, and is not repeated.
    sparse = Enum.at(options, 0)
    assert Enum.count(Regex.scan(~r/Same message/, LazyHTML.text(sparse))) == 1
    assert Enum.empty?(LazyHTML.query(sparse, ".candidate-history"))

    truncated = Enum.at(options, 1) |> LazyHTML.text()
    assert truncated =~ "This work was cancelled."
    assert truncated =~ "Readable prefix from a partial preview"
    assert truncated =~ "truncated"

    malformed = options |> Enum.drop(2) |> Enum.map_join(&LazyHTML.text/1)
    assert malformed =~ "Historical candidate · retained shape unavailable"
    assert malformed =~ "Retained raw candidate"
    assert String.length(malformed) < 1_000
  end
end
