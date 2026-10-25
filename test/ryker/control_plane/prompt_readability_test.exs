defmodule Ryker.ControlPlane.PromptReadabilityTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.{PageRead, RepositoryNames, RequestContextHTML}
  alias Ryker.InspectionRedactor

  test "continuity separates the opening source, previous reply and actual resume cause" do
    # Shape harvested from a resumed production request. A bounded opening
    # snapshot was rendered as pages of JSON, digests and source dependencies.
    continuity = %{
      "first_input" => %{
        "actor_ref" => "local-operator",
        "occurred_at" => "2026-10-20T22:35:21Z",
        "source_ref" => "slack-source:v1:T123:C456:message:1792535721.651629",
        "content" => %{
          "json_preview" => ~s({"content":{"text":"unfinished...),
          "original_bytes" => 1388,
          "sha256" => String.duplicate("a", 64),
          "truncated" => true
        }
      },
      "previous_delivery" => %{
        "delivery" => "reply",
        "message" => "The saved plan awaits **confirmation**.",
        "outcome" => %{"state" => "waiting_for_event", "record_refs" => ["record:evidence:one"]}
      },
      "host_continuation" => %{
        "requested" => %{"kind" => "wait", "wait_kind" => "event", "deadline_at" => nil},
        "resume_cause" => "new_input"
      },
      "prior_input_count" => 2
    }

    document = readable(%{"continuity" => continuity})

    assert LazyHTML.query(document, ".continuity-resume") |> LazyHTML.text() =~
             "New message received"

    assert LazyHTML.query(document, ".continuity-opening") |> LazyHTML.text() =~ "Opening message"

    assert LazyHTML.query(document, ".continuity-opening a") |> LazyHTML.attribute("href") ==
             ["https://slack.com/archives/C456/p1792535721651629"]

    assert LazyHTML.query(document, ".continuity-reply .ui-message strong") |> LazyHTML.text() =~
             "Ryker"

    assert LazyHTML.query(document, ".continuity-reply .markdown-preview strong")
           |> LazyHTML.text() == "confirmation"

    assert LazyHTML.query(document, ".continuity-opening") |> LazyHTML.text() =~ "truncated"
    assert Enum.empty?(LazyHTML.query(document, ".continuity-opening .context-fields"))

    assert Enum.count(LazyHTML.query(document, ".conversation-continuity .knowledge-provenance")) ==
             1

    refute LazyHTML.text(document) =~ "unfinished"
  end

  test "selected knowledge leads with useful text and keeps provenance secondary" do
    # Same retained shapes as the production briefing, without tenant identity.
    document =
      readable(%{
        "operator_context" => %{
          "memory" => [
            %{
              "subject" => "Service owner",
              "value" => "The owner is Dana.",
              "scope" => "conversation",
              "memory_ref" => "memory:one"
            }
          ],
          "guidance" => [%{"subject" => "Review style", "summary" => "Lead with risks."}],
          "preferences" => %{"response_detail" => %{"value" => "concise", "scope" => "operator"}},
          "standing_assignments" => [
            %{
              "task" => "Review the saved plan.",
              "authority_ceiling" => "read_only",
              "assignment_ref" => "rule:one"
            }
          ]
        },
        "repository_knowledge" => %{
          "content" => "# Deployment\n\nCheck readiness before rollout.",
          "sha256" => String.duplicate("b", 64),
          "source_commit" => "abc123"
        },
        "records" => [
          %{
            "kind" => "finding",
            "ref" => "record:finding:one",
            "status" => "open",
            "payload" => %{
              "what" => "Readiness passed.",
              "reason" => "Both probes returned 200."
            }
          }
        ]
      })

    assert LazyHTML.query(document, ".knowledge-entry-title") |> LazyHTML.text() =~
             "Service owner"

    assert LazyHTML.query(document, ".knowledge-entry-body") |> LazyHTML.text() =~
             "The owner is Dana."

    assert LazyHTML.query(document, ".repository-understanding .knowledge-document-title")
           |> LazyHTML.text() == "Deployment"

    assert LazyHTML.query(document, ".knowledge-entry-body") |> LazyHTML.text() =~
             "Readiness passed."

    assert LazyHTML.query(document, ".knowledge-actions a")
           |> LazyHTML.attribute("href")
           |> Enum.sort() ==
             Enum.sort([
               "/memory",
               "/instructions?show=guidance#saved",
               "/instructions?show=preferences#saved",
               "/rules"
             ])

    assert Enum.empty?(LazyHTML.query(document, ".knowledge-entry > .context-fields"))
    assert LazyHTML.query(document, ".knowledge-provenance") |> LazyHTML.text() =~ "memory:one"
  end

  test "a previous accepted outcome reads the delivery inside its retained envelope" do
    # A restarted session wraps its prior delivery with provenance, unlike a
    # continued session's direct previous_delivery. Neither may lose the reply.
    document =
      readable(%{
        "prior_outcome" => %{
          "source_turn_ref" => "turn:prior",
          "delivery" => %{
            "delivery" => "reply",
            "message" => "Both instances pass readiness.",
            "outcome" => %{"state" => "waiting_for_event"}
          }
        }
      })

    assert LazyHTML.query(document, ".continuity-reply .ui-message") |> LazyHTML.text() =~
             "Both instances pass readiness."
  end

  test "historical repository paths never use a mutable current repository identity" do
    # The retained knowledge carries a commit, not its GitHub owner/repository.
    # A settings rename/repoint must not fabricate a historical source URL.
    document =
      PageRead.run(fn ->
        PageRead.memo({RepositoryNames, :all}, fn -> %{"repo-ref" => "acme/repointed"} end)

        readable(%{
          "repository_ref" => "repo-ref",
          "repository_knowledge" => %{
            "content" => "# RYKER.md\n\n## Components\n\nRead [README.md](README.md).",
            "source_commit" => String.duplicate("a", 40)
          }
        })
      end)

    assert LazyHTML.query(document, ".repository-understanding a") |> Enum.empty?()
    assert LazyHTML.query(document, ".repository-understanding") |> LazyHTML.text() =~ "README.md"
  end

  defp readable(context) do
    context
    |> InspectionRedactor.artifact()
    |> RequestContextHTML.assembly("$.work", "knowledge")
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
  end

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
