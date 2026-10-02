defmodule Ryker.ControlPlane.RequestContextHTMLTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.{CallRun, CapabilityTools, RequestContextHTML}
  alias Ryker.InspectionRedactor
  alias Ryker.StateTools.FixedTools

  # Andrew, 2026-09-28, of a Work briefing's Related outcomes: it dumped every
  # stored field, "Not supplied", refs, Slack's block JSON and ISO times, six
  # outcomes some 19,000 pixels tall. Each outcome now reads as what was
  # asked, by whom and when, what Ryker answered, and how it ended.
  test "a related outcome reads as what was asked and what Ryker answered, not its stored fields" do
    outcome = %{
      "blocker" => nil,
      "episode_ref" => "1c2f27cb-67dd-47cd-bd82-02ef378fc3d4",
      "finished_at" => "2026-09-28T04:32:29.752010Z",
      "records" => [],
      "result" => %{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "Yes, Emisar access is available now: *two* runners.",
        "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
      },
      "source_event_ref" => "a0ca5e83-237c-4fec-bd23-bdede7fa1a9e",
      "source_turn_ref" => "66b851e0-8516-4ccf-9079-f885c13f3a47",
      "state" => "complete",
      "trigger" => %{
        "actor" => %{"kind" => "user", "ref" => "U0BHTNFCW6S"},
        "content" => %{
          "blocks" => [%{"block_id" => "w0344", "type" => "rich_text"}],
          "subtype" => nil,
          "text" => "And now?"
        },
        "occurred_at" => "2026-09-28T04:29:46.896249Z",
        "source" => %{"kind" => "slack", "ref" => "T0BHXKZJVDX"}
      },
      "verified" => false
    }

    document =
      %{
        "related_outcomes" => [
          outcome,
          %{outcome | "state" => "blocked", "blocker" => "The worker stopped."}
        ]
      }
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.work", "outcomes")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    [finished, stopped] = document |> LazyHTML.query(".context-outcome") |> Enum.to_list()

    assert LazyHTML.query(finished, "h4") |> LazyHTML.text() == "And now?"
    assert LazyHTML.query(finished, "time") |> LazyHTML.text() == "finished 28 Sep, 04:32:29 UTC"
    assert LazyHTML.query(finished, ".candidate-outcome") |> LazyHTML.text() == "Finished"

    assert finished |> LazyHTML.query("dt") |> Enum.map(&LazyHTML.text/1) == [
             "Asked",
             "Ryker answered"
           ]

    assert LazyHTML.query(finished, ".candidate-message-meta") |> LazyHTML.text() =~
             "28 Sep, 04:29:46 UTC"

    assert LazyHTML.query(finished, ".markdown-preview strong") |> LazyHTML.text() == "two"
    assert LazyHTML.text(stopped) =~ "Stopped: The worker stopped."

    all = LazyHTML.text(document)

    for plumbing <- [
          "Not supplied",
          "1c2f27cb",
          "a0ca5e83",
          "rich_text",
          "w0344",
          "2026-09-28T04"
        ],
        do: refute(all =~ plumbing, plumbing)
  end

  # "Other fields · $.work.connected" showed what the Work was told is
  # connected as raw JSON, and routing's repository choices the same way.
  test "connected services and repository choices have rows of their own, in words" do
    work =
      %{
        "connected" => %{
          "emisar" => true,
          "github" => true,
          "repositories" => ["andrewdryga-emisar"],
          "slack" => true
        }
      }
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.work", "connected")
      |> IO.iodata_to_binary()
      |> html_text()

    refute work =~ "Other fields"
    assert work =~ "Connected services"
    assert work =~ "Slack, GitHub and Emisar were connected."
    # Without the database the repository keeps its ref.
    assert work =~ "Repositories it can reach: andrewdryga-emisar"

    routing =
      %{
        "repository_choices" => [
          %{"description" => "AndrewDryga/emisar", "ref" => "andrewdryga-emisar"},
          %{"description" => "AndrewDryga/test", "ref" => "andrewdryga-test"}
        ]
      }
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "choices")
      |> IO.iodata_to_binary()
      |> html_text()

    refute routing =~ "Other fields"
    assert routing =~ "Repositories to choose from"
    assert routing =~ "AndrewDryga/emisar"
    refute routing =~ "andrewdryga-test"
  end

  # Andrew, 2026-09-30, of the four names under "Repositories to choose from": "this could show
  # which read/write modes available for each". Routing may only choose a repository work can
  # change, and the one it chooses is the working copy while the rest are mounted read only.
  test "each repository routing could choose says whether work may change it" do
    routing =
      %{
        "repository_choices" => [
          %{"description" => "AndrewDryga/emisar", "ref" => "andrewdryga-emisar"},
          %{"ref" => "andrewdryga-test"}
        ]
      }
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "choices")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    rows =
      routing
      |> LazyHTML.query(".context-rows > div")
      |> Enum.map(fn row ->
        {row |> LazyHTML.query("dt") |> LazyHTML.text(),
         row |> LazyHTML.query("dd") |> LazyHTML.text()}
      end)

    assert rows == [
             {"AndrewDryga/emisar", "Read and write"},
             {"andrewdryga-test", "Read and write"}
           ]

    assert LazyHTML.text(routing) =~
             "The one routing chooses can be changed; the others are mounted read only beside it."
  end

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

  # The briefing named retained fields by capitalizing their keys, so a
  # reader saw "Sha256", "Json preview" and "Source url" (QA, 2026-09-26).
  test "retained field names spell their abbreviations the way people write them" do
    document =
      %{
        "prior_outcome" => %{
          "json_preview" => "{}",
          "message_id" => "m1",
          "sha256" => String.duplicate("a", 64),
          "source_url" => "https://example.invalid/alert"
        }
      }
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.work", "field-names")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    labels = document |> LazyHTML.query(".context-field > h4") |> Enum.map(&LazyHTML.text/1)

    assert "SHA-256" in labels
    assert "JSON preview" in labels
    assert "Message ID" in labels
    assert "Source URL" in labels
    refute Enum.any?(labels, &(&1 in ["Sha256", "Json preview", "Message id", "Source url"]))
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

  # On 2026-09-27 this card read "Audience: ambient" and "Ryker user ref:
  # U0C1LCVNF52" under "The audience and host-configured Ryker user reference
  # saved on the first receipt. This context does not grant authority." Andrew
  # asked what it meant and why a person is shown it: the ID is Ryker's own, the
  # same on every message, and the last sentence is a note for the model. The
  # card says in words how the message reached Ryker; the exact JSON the model
  # got stays in the prompt view.
  test "a Slack message says in words how it reached Ryker, without Ryker's own ID or notes for the model" do
    for {audience, words} <- [
          {"direct", "A direct message to Ryker."},
          {"mention", "The message mentions @Ryker."},
          {"ambient",
           "Ryker read it in the channel. It was not a direct message or an @Ryker mention."}
        ] do
      messages =
        %{
          "input" => %{"text" => "<@UOTHER> can you check this?"},
          "slack_addressing" => %{"audience" => audience, "ryker_user_ref" => "UBOT"}
        }
        |> InspectionRedactor.artifact()
        |> RequestContextHTML.assembly("$.context", "routing-1")
        |> IO.iodata_to_binary()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".prompt-group[data-group=conversation]")

      component = LazyHTML.query(messages, "[data-source=slack_addressing]")
      assert Enum.count(component) == 1
      text = LazyHTML.text(component)

      assert text =~ "How the message reached Ryker"
      assert text =~ words
      refute text =~ "UBOT"
      refute text =~ "Audience"
      refute text =~ "ambient"
      refute text =~ "authority"
      refute text =~ "$.context.slack_addressing"
      assert Enum.empty?(LazyHTML.query(component, "[open]"))
    end
  end

  # "Who can manage Ryker" read "Slack user U0BHTNFCW6S" on 2026-09-26, and so
  # did every sender, note and routing candidate kept with a Slack ID in a
  # request's context. A Slack person reads as their name linked to their
  # Slack profile; the raw ID stays only in the raw event, for support.
  test "a Slack person in a request's context reads as a linked name, never a raw ID" do
    message =
      %{
        "input" => %{
          "source" => %{"kind" => "slack", "ref" => "T123"},
          "actor" => %{"kind" => "user", "ref" => "U0BHTNFCW6S"},
          "text" => "Is the deploy healthy?"
        }
      }
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "context")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    sender = LazyHTML.query(message, ".ui-message-header strong a")
    assert LazyHTML.text(sender) == "Slack user"

    assert LazyHTML.attribute(sender, "href") == [
             "https://slack.com/app_redirect?team=T123&channel=U0BHTNFCW6S"
           ]

    refute message |> LazyHTML.query(".ui-message-header") |> LazyHTML.text() =~ "U0BHTNFCW6S"

    assert message |> LazyHTML.query(".context-message-details") |> LazyHTML.text() =~
             "U0BHTNFCW6S"

    # A note and a message a router weighed, each kept with a bare Slack ID.
    notes =
      recall_document(%{
        "observations" => [
          %{
            "summary" => "Deploy rolled back.",
            "actor_ref" => "U0BHTNFCW6S",
            "occurred_at" => "2026-09-18T17:00:00Z"
          }
        ]
      })

    # The exact component beneath keeps the retained JSON for support.
    note = LazyHTML.query(notes, ".context-note")
    assert note |> LazyHTML.query(".context-note-meta") |> LazyHTML.text() =~ "Slack user · "
    refute LazyHTML.text(note) =~ "U0BHTNFCW6S"

    candidate = %{
      "state" => "complete",
      "episode_ref" => "candidate:named",
      "title" => "Deploy",
      "message_count" => 1,
      "first_message" => %{
        "actor" => "U0BHTNFCW6S",
        "at" => "2026-09-18T17:00:00Z",
        "text" => "Deploy failing"
      }
    }

    candidates =
      %{"candidates" => [candidate]}
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "admission")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert candidates |> LazyHTML.query(".candidate-message-meta") |> LazyHTML.text() =~
             "Slack user · "

    refute LazyHTML.text(candidates) =~ "U0BHTNFCW6S"

    # The people a conversation involved, as the model wrote them down.
    people =
      recall_document(%{
        "current" => [%{"state" => %{"participants" => ["<@U0BHTNFCW6S> (on call)"]}}]
      })

    participants = LazyHTML.query(people, ".conversation-recall")
    assert LazyHTML.text(participants) =~ "Slack user (on call)"
    refute LazyHTML.text(participants) =~ "U0BHTNFCW6S"
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

    document =
      artifact |> RequestContextHTML.assembly("$.context", "context") |> IO.iodata_to_binary()

    sender = document |> LazyHTML.from_fragment() |> LazyHTML.query(".ui-message-header strong")
    assert LazyHTML.text(sender) == "Andrew <admin>"

    # Still the person: the retained name links to their Slack profile.
    assert sender |> LazyHTML.query("a") |> LazyHTML.attribute("href") == [
             "https://slack.com/app_redirect?team=T123&channel=U123"
           ]

    refute document =~ "Slack reference"
  end

  # Andrew's screenshot of this block, 2026-09-13: thirteen alphabetised labels
  # — Companions, Freshness, Owner, Repositories, Fetched at, Name, Remote
  # identity, Requested revision, Resolved revision, Stale base revision, Stale
  # base status, Version, Workspace base revision — before the reader learned
  # which repository the model could see. The shape below is the real one from
  # a production submission; `source` is a sibling of `primary`, not its child.
  test "each tool the request could use says in a line what it is for" do
    # Andrew, 2026-09-26: the list headed "State operations advertised to this
    # request. Availability is not a receipt that a tool ran." showed eighteen
    # bare names. Each keeps its name, which the timeline's tool steps show,
    # and says what it is for. The tool lists are the harvested Work prompt's.
    %{"work" => work} =
      "testdata/control_plane/submitted-prompts/work-full.json"
      |> File.read!()
      |> Jason.decode!()

    for key <- ["controller_tools", "responder_state_tools"] do
      document =
        Map.take(work, ["source_and_action_tools"])
        |> Map.put(key, work["responder_state_tools"] ++ ["record_emisar_approval"])
        |> InspectionRedactor.artifact()
        |> RequestContextHTML.assembly("$.work", "tools")
        |> IO.iodata_to_binary()
        |> LazyHTML.from_fragment()

      state = LazyHTML.query(document, "[data-source=#{key}]")

      assert LazyHTML.text(state) =~
               "Tools Ryker could use for this request. Listed here does not mean it used them."

      refute LazyHTML.text(state) =~ "State operations advertised"
      refute LazyHTML.text(state) =~ "receipt"

      for {source, names} <- [
            {key, work["responder_state_tools"] ++ ["record_emisar_approval"]},
            {"source_and_action_tools", work["source_and_action_tools"]}
          ] do
        rows =
          document
          |> LazyHTML.query("[data-source=#{source}] .context-rows > div")
          |> Enum.map(fn row ->
            {row |> LazyHTML.query("dt") |> LazyHTML.text(),
             row |> LazyHTML.query("dd") |> LazyHTML.text()}
          end)

        assert Enum.map(rows, &elem(&1, 0)) == names

        for {name, description} <- rows do
          assert description =~ ~r/^[A-Z][^_]+\.$/, "#{name} has no plain description"
        end
      end

      rows = LazyHTML.query(document, "[data-source=#{key}] .context-rows > div")

      assert Enum.find_value(rows, fn row ->
               if LazyHTML.text(LazyHTML.query(row, "dt")) == "request_input",
                 do: LazyHTML.text(LazyHTML.query(row, "dd"))
             end) == "Asks a person a question and waits for the answer."
    end
  end

  test "every tool Ryker can offer a request has words for what it is for" do
    # A tool added to the catalog without a line here would show as a bare
    # name again.
    names =
      FixedTools.names() ++
        ["record_emisar_approval"] ++ Enum.map(CapabilityTools.list(), & &1["name"])

    described =
      %{"controller_tools" => names}
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.work", "catalog")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-source=controller_tools] .context-rows > div")
      |> Enum.map(fn row ->
        {row |> LazyHTML.query("dt") |> LazyHTML.text(),
         row |> LazyHTML.query("dd") |> LazyHTML.text() |> String.trim()}
      end)

    assert Enum.map(described, &elem(&1, 0)) == names
    assert for({name, ""} <- described, do: name) == []
  end

  test "a tool this view has no words for keeps its name and gains no invented description" do
    document =
      %{"controller_tools" => ["validate_final", "retired_tool"]}
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.work", "tools")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    rows =
      document
      |> LazyHTML.query("[data-source=controller_tools] .context-rows > div")
      |> Enum.map(fn row ->
        {row |> LazyHTML.query("dt") |> LazyHTML.text(),
         row |> LazyHTML.query("dd") |> LazyHTML.text() |> String.trim()}
      end)

    assert [{"validate_final", checks}, {"retired_tool", ""}] = rows
    assert checks != ""
  end

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

    html = artifact |> RequestContextHTML.assembly("$.work", "work") |> IO.iodata_to_binary()

    assert workspace_rows(html) == [
             {"emisar", "Read only · main at 92c952f7 · up to date as of 13 Sep, 09:48:09 UTC"}
           ]

    # None of the dumped labels survive as headings.
    for gone <- ["Stale base revision", "Workspace base revision", "Remote identity", "Version"] do
      refute html =~ "<h4>#{gone}</h4>"
    end
  end

  test "workspace access lists every repository by name, with its access and freshness in words" do
    # Andrew, 2026-09-26: the card showed "Repository: primary", "Access:
    # read-only", "Freshness: not_applicable · fetched …" and "Companions:
    # none". An environment can hold several repositories; each is its own
    # row, named, with whether the run could change it and how fresh it was.
    artifact =
      InspectionRedactor.artifact(%{
        "repository_ref" => "payments",
        "workspace" => %{
          "companions" => [
            %{
              "base_commit" => String.duplicate("5e0a7f2", 6) |> binary_part(0, 40),
              "name" => "infra",
              "path" => "/coop/repositories/infra",
              "read_only" => true
            }
          ],
          "context_ref" => "payments",
          "freshness" => %{
            "owner" => "coop",
            "repositories" => [
              receipt("primary", "current", "2026-09-26T09:14:05.118223Z"),
              receipt("infra", "stale", "2026-09-26T09:14:06.402113Z")
            ],
            "status" => "recorded"
          },
          "parallel_goal_limit" => 1,
          "primary" => %{
            "base_commit" => String.duplicate("c1b143d", 6) |> binary_part(0, 40),
            "name" => "payments",
            "path" => ".",
            "read_only" => false
          }
        }
      })

    html = artifact |> RequestContextHTML.assembly("$.work", "work") |> IO.iodata_to_binary()

    assert workspace_rows(html) == [
             {"payments", "Can change · up to date as of 26 Sep, 09:14:05 UTC"},
             {"infra", "Read only · behind its remote as of 26 Sep, 09:14:06 UTC"}
           ]

    for gone <- ["primary", "Companions", "Access", "Freshness", "stale", "current"] do
      refute workspace_text(html) =~ gone
    end
  end

  test "a workspace without a repository says so instead of naming the scratch folder" do
    # The harvested Work prompt ran with no repository: Coop's empty scratch
    # folder, which it names "primary", read-only, with a not_applicable
    # freshness receipt. None of those words mean anything to a reader.
    %{"work" => work} =
      "testdata/control_plane/submitted-prompts/work-full.json"
      |> File.read!()
      |> Jason.decode!()

    html =
      work
      |> Map.take(["repository_ref", "workspace"])
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.work", "work")
      |> IO.iodata_to_binary()

    assert workspace_rows(html) == [{"No repository", "An empty working folder · read only"}]

    for gone <- ["primary", "Companions", "not_applicable", "fetched"] do
      refute workspace_text(html) =~ gone
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

    html =
      artifact |> RequestContextHTML.assembly("$.context", "context") |> IO.iodata_to_binary()

    assert html =~ "ui-message-body"
    assert html =~ "slack:user:U123"
    assert html =~ "3 earlier inputs were omitted"
    assert html =~ "Inspect &lt;script&gt;"
    refute html =~ "<script>"
  end

  test "a Chat sender is named, not shown as its routing reference" do
    # The Work briefing named the person at the keyboard
    # "control_plane:user:local-operator" while the timeline and the routing
    # briefing said "Local operator"; all three now say "You", as Chat does.
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
      |> RequestContextHTML.assembly("$.context", "context")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".ui-message")

    assert LazyHTML.query(message, ".ui-message-header strong") |> LazyHTML.text() == "You"
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
             ["You", "Ryker"]

    assert LazyHTML.attribute(messages, "data-author") == ["person", "ryker"]
  end

  test "an incomplete sanitized artifact is not presented as complete readable context" do
    artifact =
      InspectionRedactor.artifact(%{"input" => %{"text" => String.duplicate("x", 100)}},
        max_bytes: 30
      )

    assert RequestContextHTML.assembly(artifact, "$.context", "context") == []
    expired = InspectionRedactor.artifact(nil, expired: true)
    assert RequestContextHTML.assembly(expired, "$.context", "context") == []
    assert RequestContextHTML.assembly_instructions(expired, "instructions") == []
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

    # Every routing card also said "Channel summary: None saved", a row that
    # could never fill because nothing saves a summary of a whole channel; it
    # was gone from routing on 2026-09-28.
    assert absent == [
             {"Global instructions", "Not configured"},
             {"Channel instructions", "Not applicable"},
             {"Thread summary", "Not applicable"},
             {"Continuation candidates", "None"},
             {"Background matches", "None"},
             {"Conversation notes", "None"},
             {"Learned topics", "None matched"}
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

      assert artifact
             |> RequestContextHTML.assembly("$.context", "context")
             |> IO.iodata_to_binary()
             |> is_binary()
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
    assert LazyHTML.text(run) =~ "Request title"
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

    # A summary is a saved document about the conversation, not its messages.
    assert document
           |> LazyHTML.query(".prompt-group[data-group=summaries] > .prompt-source")
           |> LazyHTML.attribute("data-source") == ~w(thread_summary)

    assert LazyHTML.text(document) =~ "1 message"
    assert LazyHTML.text(document) =~ "Earlier question"
    assert LazyHTML.text(document) =~ "Up to 20 earlier messages"
    assert LazyHTML.text(document) =~ "Thread summary"

    # The recorded reason picks the same words routing uses when it leaves a
    # summary out: not applicable outside a thread.
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
             {"Quick reply (not permitted)", ["false"]},
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
    assert LazyHTML.text(note) =~ "You ·"
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
      "testdata/learning/retained-tenant-release-knowledge.json"
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
    assert text =~ "You"
    assert text =~ "21 Sep, 05:48:52 UTC"

    # Andrew, 2026-09-30, of a "Details" fold that held only "Raw event (JSON)": "can there be
    # any details other than JSON? If not then why have one collapsible item within other one?"
    # The raw event is each message's one fold.
    footers = LazyHTML.query(document, ".ui-message-footer")

    assert footers
           |> LazyHTML.query("details > summary")
           |> Enum.map(&String.trim(LazyHTML.text(&1))) == [
             "Raw event (JSON)",
             "Raw event (JSON)"
           ]

    refute text =~ "Copy raw event"
    refute text =~ "Sender ID"

    assert Enum.empty?(
             LazyHTML.query(document, ".context-message-details dt")
             |> Enum.filter(&(LazyHTML.text(&1) == "Received"))
           )

    assert Enum.empty?(LazyHTML.query(document, "[data-copy-status][aria-live=polite]"))
    refute text =~ "The message that started this routing call"
    refute text =~ ~r/local operator/i
    refute text =~ "Source fields and attachment metadata"
  end

  # Manual testing, 2026-09-26: a message carrying a log read "Attachments:
  # 1 attachment" on its card, so nobody could tell which file it was, or
  # that a second one had been refused.
  test "a message's card names the files it carried and the one Ryker could not read" do
    context = %{
      "inputs" => %{
        "items" => [
          %{
            "current" => true,
            "source" => %{"kind" => "control_plane", "ref" => "local"},
            "actor" => %{"kind" => "user", "ref" => "local-operator"},
            "content" => %{
              "text" => "Summarize the attached log.",
              "files" => [
                %{"status" => "available", "name" => "probe.log", "bytes" => 35},
                %{"status" => "unavailable", "reason" => "unsupported_media_type"}
              ]
            },
            "occurred_at" => "2026-09-26T14:47:51Z"
          }
        ]
      }
    }

    document =
      context
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.work", "messages", %{
        "inputs" => %{label: "1 message", known?: true}
      })
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    [attachments] =
      document
      |> LazyHTML.query(".context-message-details dl.context-rows > div")
      |> Enum.filter(&(LazyHTML.text(LazyHTML.query(&1, "dt")) == "Attachments"))

    assert LazyHTML.text(LazyHTML.query(attachments, "dd")) ==
             "probe.log, a file Ryker could not read"
  end

  # Andrew, 2026-09-27: a voice message reached Ryker as "an unavailable file
  # with no text", and its card said "This source event has no text body."
  # The card reads as what the message said, labelled as a transcript, and a
  # voice message Ryker could not transcribe says so in words.
  test "a voice message's card shows what it said, labelled as a transcript" do
    context = %{
      "inputs" => %{
        "items" => [
          %{
            "current" => true,
            "source" => %{"kind" => "control_plane", "ref" => "local"},
            "actor" => %{"kind" => "user", "ref" => "local-operator"},
            "content" => %{
              "text" => "",
              "files" => [
                %{
                  "status" => "available",
                  "name" => "audio_message.m4a",
                  "media_type" => "audio/mp4",
                  "bytes" => 109_145,
                  "transcript" => "Please audit the checkout service"
                },
                %{
                  "status" => "unavailable",
                  "reason" => "recording_too_long",
                  "transcript_unavailable" =>
                    "a voice message longer than 5 minutes, the most Ryker transcribes"
                }
              ]
            },
            "occurred_at" => "2026-09-27T09:00:00Z"
          }
        ]
      }
    }

    document =
      context
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.work", "messages", %{
        "inputs" => %{label: "1 message", known?: true}
      })
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    body = document |> LazyHTML.query(".ui-message-body") |> LazyHTML.text()
    assert body =~ "Voice message transcript: Please audit the checkout service"
    assert body =~ "A voice message longer than 5 minutes, the most Ryker transcribes."
    refute LazyHTML.text(document) =~ "no text body"

    [attachments] =
      document
      |> LazyHTML.query(".context-message-details dl.context-rows > div")
      |> Enum.filter(&(LazyHTML.text(LazyHTML.query(&1, "dt")) == "Attachments"))

    assert LazyHTML.text(LazyHTML.query(attachments, "dd")) ==
             "audio_message.m4a, transcribed, a voice message longer than 5 minutes, the most Ryker transcribes"
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

    assert LazyHTML.text(document) =~
             "Earlier work this message may belong to, found by Search for related history."

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
        "candidate_episodes" => %{
          "candidate:history" => "/timeline/0193a5d2-7c1e-7b8a-9f00-000000000001"
        }
      })
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert document
           |> LazyHTML.query(".context-candidate a.candidate-episode-link")
           |> LazyHTML.attribute("href") == ["/timeline/0193a5d2-7c1e-7b8a-9f00-000000000001"]

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

  defp workspace_rows(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-source=workspace] .context-rows > div")
    |> Enum.map(fn row ->
      {row |> LazyHTML.query("dt") |> LazyHTML.text(),
       row |> LazyHTML.query("dd") |> LazyHTML.text()}
    end)
  end

  defp workspace_text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-source=workspace] .context-rows")
    |> LazyHTML.text()
  end

  defp receipt(name, status, fetched_at) do
    resolved = String.duplicate(if(name == "primary", do: "c1b143d", else: "5e0a7f2"), 6)

    %{
      "fetched_at" => fetched_at,
      "name" => name,
      "remote_identity" => "origin",
      "requested_revision" => "refs/heads/main",
      "resolved_revision" => binary_part(resolved, 0, 40),
      "stale_base_revision" =>
        if(status == "stale", do: String.duplicate("9", 40), else: binary_part(resolved, 0, 40)),
      "stale_base_status" => status,
      "version" => 2
    }
  end

  defp html_text(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.split() |> Enum.join(" ")
end
