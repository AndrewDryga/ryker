defmodule Ryker.ControlPlane.EpisodeDocumentTest do
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Activity, EpisodePage, EpisodeRequest, InspectionRedactor, Projection}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures

  test "opaque routing candidate references never become nonexistent timeline links" do
    # The live follow-up routed correctly but its 'Joins' link opened a 404:
    # candidate references belong to one prompt, not the timeline route namespace.
    ref = "candidate:52af063"

    html =
      render_request(:admission, :result, [
        section("candidate", "Decision", %{
          "action" => "continue_episode",
          "episode_ref" => ref,
          "relation" => "same_work"
        })
      ])

    refute html =~ "/timeline/candidate"
    assert html =~ "data-copy-value=\"#{ref}\""
  end

  test "routing decisions jump to the selected candidate in their own briefing" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)

    candidate = %{
      "episode_ref" => "candidate:52af063",
      "state" => "complete",
      "allowed_relations" => ["same_work"],
      "title" => "Check the response"
    }

    other = %{
      "episode_ref" => "candidate:background",
      "state" => "complete",
      "allowed_relations" => ["history_only"],
      "title" => "Earlier notes"
    }

    request = %{
      id: "routing-link",
      at: snapshot.trace.received_at,
      kind: :request,
      source_kind: :admission,
      phase: :submission,
      band: :ready,
      target: nil,
      title: "Routing",
      status: :settled,
      timing: [],
      coverage: "Retained",
      href: "#routing-link",
      sections: [section("context", "Context", %{"candidates" => [candidate, other]})]
    }

    result = %{
      request
      | id: "routing-link-result",
        phase: :result,
        sections: [
          section("candidate", "Decision", %{
            "action" => "continue_episode",
            "episode_ref" => candidate["episode_ref"]
          })
        ]
    }

    document = render_episode(snapshot, [request, result]) |> LazyHTML.from_fragment()
    link = LazyHTML.query(document, ".request-decision li[data-selected=true] a")
    assert link |> LazyHTML.text() |> String.trim() == "Check the response ↑"
    ["#" <> id] = LazyHTML.attribute(link, "href")
    assert LazyHTML.query(document, ".context-candidate[id='#{id}']") |> Enum.count() == 1

    # The decision card lists every candidate it weighed with its verdict, as
    # the Earlier work fact rather than behind a disclosure; each title links
    # back up to the briefing that offered it, which stays exactly as it was sent.
    outcomes = LazyHTML.query(document, ".request-decision .routing-candidate-outcomes")
    assert Enum.empty?(LazyHTML.query(outcomes, "details"))

    assert outcomes
           |> LazyHTML.query("li")
           |> Enum.map(fn row ->
             {row |> LazyHTML.query(".considered-verdict") |> LazyHTML.text(),
              row |> LazyHTML.query("a") |> LazyHTML.text() |> String.trim()}
           end) == [{"Continued", "Check the response ↑"}, {"Background only", "Earlier notes ↑"}]

    assert outcomes
           |> LazyHTML.query("a")
           |> LazyHTML.attribute("href")
           |> Enum.all?(&String.starts_with?(&1, "#"))
  end

  test "missing full prompts explain availability instead of opening a blank panel" do
    for {artifact, label} <- [
          {InspectionRedactor.artifact(nil), "Not recorded"},
          {InspectionRedactor.artifact(nil, expired: true), "Expired"}
        ] do
      html =
        render_request(:work, :submission, [
          %{id: "request", title: "Submitted request", artifact: artifact}
        ])

      assert html =~ label
      refute html =~ "Highlighted text"
    end
  end

  test "request identity names the destination and keeps its exact reference" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    snapshot = put_in(snapshot.episode.destination, "control_plane:lab:demo")

    identity =
      snapshot
      |> render_episode([])
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".story-identity")
      |> LazyHTML.text()

    assert identity =~ "Direct conversation"
    assert identity =~ "Destination ID"
    assert identity =~ snapshot.episode.destination
  end

  test "a visible input and answer do not acquire duplicate receipt cards" do
    # The replay repeated one delivery as a response, kernel receipt and turn receipt.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    [step | _] = snapshot.trace.steps
    at = snapshot.trace.received_at

    messages = [
      %{id: "input", at: at, actor: "User", text: "Hello", available: true},
      %{
        id: "turn",
        at: at,
        actor: "Ryker",
        text: "Hello back",
        available: true,
        status: "Response sent",
        delivery_ref: "delivery:turn"
      }
    ]

    snapshot =
      snapshot
      |> put_in([:trace, :case_file, :conversation], messages)
      |> put_in([:trace, :steps], [
        %{step | input_id: "input"},
        %{
          step
          | id: "kernel-3",
            title: "Delivery confirmed",
            stage: "Delivery",
            state: "delivery confirmed",
            delivery_ref: "delivery:turn"
        },
        %{
          step
          | id: "turn-turn-delivery",
            title: "Reply delivered",
            stage: "Delivery",
            state: "delivered",
            delivery_ref: "delivery:turn"
        }
      ])

    html = render_episode(snapshot, [])
    refute html =~ "Input admitted"
    refute html =~ "Delivery confirmed"
    refute html =~ "Reply delivered"
    assert html =~ "Response sent"
    assert html =~ "Hello back"
  end

  test "the same accepted result is not repeated as a kernel card and a turn card" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    [base | _] = snapshot.trace.steps

    kernel =
      Map.merge(base, %{
        id: "kernel-2",
        stage: "Result",
        title: "Result accepted",
        state: "result accepted",
        result_ref: "result:one"
      })

    turn =
      Map.merge(base, %{
        id: "turn-one-accepted",
        stage: "Result",
        title: "Response accepted",
        state: "accepted",
        result_ref: "result:one"
      })

    html = snapshot |> put_in([:trace, :steps], [kernel, turn]) |> render_episode([])
    assert html =~ "Response accepted"
    refute html =~ "Result accepted"
  end

  test "a retained delivery receipt appears once even when response text is unavailable" do
    # Pruned response bodies left the same delivery repeated as a kernel receipt
    # and a turn receipt. The receipt must remain visible without repeating it.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    [base | _] = snapshot.trace.steps

    kernel =
      Map.merge(base, %{
        id: "kernel-2",
        stage: "Delivery",
        title: "Delivery confirmed",
        summary: "Delivery was confirmed.",
        state: "delivery confirmed",
        delivery_ref: "delivery:one"
      })

    turn =
      Map.merge(kernel, %{
        id: "turn-one-delivery-confirmed",
        state: "delivered",
        summary: "Slack transport confirmed the delivery."
      })

    snapshot = put_in(snapshot, [:trace, :case_file, :conversation], [])
    html = snapshot |> put_in([:trace, :steps], [kernel, turn]) |> render_episode([])
    assert html =~ "Slack transport confirmed the delivery."
    refute html =~ "Delivery was confirmed."
    assert length(Regex.scan(~r/Delivery confirmed/, html)) == 1

    # A different delivery and a receipt with no exact identity are not copies.
    for reference <- ["delivery:other", nil] do
      html =
        snapshot
        |> put_in([:trace, :steps], [%{kernel | delivery_ref: reference}, turn])
        |> render_episode([])

      assert html =~ "Delivery was confirmed."
      assert html =~ "Slack transport confirmed the delivery."
    end

    html = snapshot |> put_in([:trace, :steps], [kernel]) |> render_episode([])
    assert html =~ "Delivery was confirmed."
  end

  test "briefing groups all inputs and contract with token estimates and immediate source labels" do
    html =
      render_request(:admission, :submission, [
        section("instructions", "Instructions", "Classify the source input"),
        section("context", "Context", %{"input" => %{"text" => "Check the alert"}}),
        section("contract", "Required output contract", %{"type" => "object"}),
        section(
          "request",
          "Submitted prompt",
          Jason.encode!(%{
            "instructions" => "Classify the source input",
            "context" => %{"input" => %{"text" => "Check the alert"}}
          })
        )
      ])

    document = LazyHTML.from_fragment(html)

    # Every routing briefing has the same sections; a part the model was not
    # sent keeps its row and says why instead of taking its section with it.
    # This minimal prompt carries no permitted actions, so it has no scope rows.
    assert LazyHTML.query(document, ".prompt-group > header h4") |> Enum.map(&LazyHTML.text/1) ==
             [
               "Instructions",
               "Custom instructions",
               "Messages",
               "Summaries",
               "Related history",
               "Selected knowledge"
             ]

    assert LazyHTML.query(document, ".final-prompt > .ui-disclosure-source .prompt-source-title")
           |> Enum.map(&LazyHTML.text/1) == ["Prompt text", "Response format"]

    assert LazyHTML.query(document, ".prompt-source[open]") |> Enum.empty?()

    assert LazyHTML.query(document, ".prompt-source[data-source='contract']") |> LazyHTML.text() =~
             "object"

    assert html =~ ~r/≈ [\d,]+ tokens/

    assert LazyHTML.query(document, ".prompt-fragment")
           |> LazyHTML.attribute("data-source-title")
           |> Enum.any?(&(&1 == "Current message"))

    refute html =~ "Open full request record"
  end

  test "work response review shows the message and evidence without duplicating the delivery document" do
    html =
      render_request(:work, :result, [
        section("candidate", "Response to validate", %{
          "delivery" => "reply",
          "message" => "The check is **partial**",
          "outcome" => %{"record_refs" => ["record:evidence:one"]}
        }),
        section("delivery", "Validated response", %{"message" => "The check is **partial**"}),
        section("validation", "Validation history", %{
          "history" => [%{"verdict" => "accept", "candidate_attempt" => 1}]
        })
      ])

    assert html =~ "Model response"
    assert html =~ "<strong>partial</strong>"
    assert html =~ "Supporting records"
    refute html =~ "Validated response"
    refute html =~ "Validation history"
  end

  test "an answer that named its episode shows the name on its card" do
    # The title is set by the answer the host accepted; the card that shows
    # that answer is where a reader learns when the episode got its name.
    html =
      render_request(:work, :result, [
        section("candidate", "Response to validate", %{
          "delivery" => "reply",
          "message" => "Checked.",
          "outcome" => %{"record_refs" => []},
          "title" => "Investigate checkout 502s"
        })
      ])

    title = html |> LazyHTML.from_fragment() |> LazyHTML.query(".response-title")
    assert LazyHTML.text(title) =~ "Episode title"
    assert LazyHTML.text(title) =~ "Investigate checkout 502s"

    untitled =
      render_request(:work, :result, [
        section("candidate", "Response to validate", %{
          "delivery" => "reply",
          "message" => "Checked.",
          "outcome" => %{"record_refs" => []},
          "title" => nil
        })
      ])

    refute untitled =~ "response-title"
  end

  test "sent text stays visible even when it matches the validated response" do
    # The full timeline needs both the checked candidate and the delivery
    # outcome; a link to one must not erase the other.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    at = snapshot.trace.received_at
    text = "The check is **partial**"

    request = %{
      id: "request-turn-result",
      at: at,
      kind: :request,
      source_kind: :work,
      phase: :result,
      band: :answer,
      target: nil,
      title: "Result",
      status: :settled,
      coverage: "Retained",
      href: "#request-turn",
      timing: [],
      sections: [section("candidate", "Response", %{"message" => text})]
    }

    message = %{
      id: "turn",
      at: DateTime.add(at, 1),
      actor: "Ryker",
      text: text,
      available: true,
      status: "Response sent",
      delivered: true,
      delivery_ref: "delivery:turn"
    }

    for transformed <- [false, true] do
      sent = if transformed, do: %{message | text: "A corrected response"}, else: message
      page = put_in(snapshot, [:trace, :case_file, :conversation], [sent])
      document = render_episode(page, [request]) |> LazyHTML.from_fragment()
      previews = LazyHTML.query(document, ".markdown-preview") |> Enum.map(&LazyHTML.text/1)

      assert Enum.count(previews, &String.contains?(&1, "The check is partial")) ==
               if(transformed, do: 1, else: 2)

      assert LazyHTML.query(document, "a.response-reference") |> Enum.count() ==
               if(transformed, do: 0, else: 1)

      if transformed,
        do: assert(Enum.any?(previews, &String.contains?(&1, "A corrected response")))
    end
  end

  test "routing shows its briefing and decision separately at their real times" do
    # A one-word greeting looked like two executions with tiny repeated phases.
    # Routing is one model execution, but its input and result have distinct times.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    at = snapshot.trace.received_at
    [step | _] = snapshot.trace.steps

    start = %{
      id: "routing-1",
      at: at,
      kind: :request,
      source_kind: :admission,
      phase: :submission,
      band: :ready,
      target: "codex:gpt-5.6-luna/low@emisar",
      timing: [],
      coverage: "Retained",
      href: "/timeline/ingress-input%3Aone",
      sections: []
    }

    result = %{
      start
      | id: "routing-1-result",
        phase: :result,
        at: DateTime.add(at, 1),
        sections: [
          section("candidate", "Decision", %{
            "action" => "reply",
            "work_class" => "conversational",
            "reason" => "The user sent a greeting that can be answered directly."
          })
        ]
    }

    snapshot =
      put_in(snapshot, [:trace, :steps], [
        %{step | id: "work", at: DateTime.add(at, 2), band: :work},
        %{step | id: "answer", at: DateTime.add(at, 3), band: :answer}
      ])

    briefing = %{start | id: "work-briefing", source_kind: :work, at: DateTime.add(at, 2)}
    document = render_episode(snapshot, [start, result, briefing]) |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query(".chapter-heading h3") |> Enum.map(&LazyHTML.text/1) ==
             ["Episode setup"]

    assert document
           |> LazyHTML.query(".conversation-phase-heading h4")
           |> Enum.map(&LazyHTML.text/1) == ["Routing", "Work", "Answer"]

    assert document
           |> LazyHTML.query(
             "section.conversation-phase.phase-routing > .phase-entries > article.case-request"
           )
           |> Enum.count() == 2

    assert document |> LazyHTML.query(".phase-routing") |> LazyHTML.text() =~
             "The user sent a greeting that can be answered directly."

    assert document |> LazyHTML.query("#routing-1-result time") |> LazyHTML.text() ==
             Calendar.strftime(result.at, "%H:%M:%S")

    assert document
           |> LazyHTML.query("#routing-1-result time")
           |> LazyHTML.attribute("datetime") == [DateTime.to_iso8601(result.at)]

    assert Enum.empty?(LazyHTML.query(document, ".case-receipt-group, .case-system-event"))
    assert LazyHTML.query(document, "#routing-1-result") |> Enum.count() == 1

    assert LazyHTML.query(document, ".phase-routing .chapter-span") |> LazyHTML.text() ==
             "+0s → +1s from start"

    # Truncated history may retain either side of the pair. Neither disappears.
    assert render_episode(snapshot, [result]) =~ "Conversational reply"
    assert render_episode(snapshot, [start]) =~ "Routing briefing"
  end

  test "a follow-up and earlier work stay in their own causal message groups" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    at = snapshot.trace.received_at
    [step | _] = snapshot.trace.steps

    messages = [
      %{id: "first", at: at, actor: "User", text: "How is health of our infra?", available: true},
      %{
        id: "next",
        at: DateTime.add(at, 2),
        actor: "User",
        text: "And how many customers we have right now?",
        available: true
      }
    ]

    snapshot =
      snapshot
      |> put_in([:trace, :case_file, :conversation], messages)
      |> put_in([:trace, :steps], [%{step | id: "running", band: :work, at: DateTime.add(at, 1)}])

    document = render_episode(snapshot, []) |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, ".case-entry") |> LazyHTML.attribute("id") ==
             ["story-message-first", "event-running", "story-message-next"]

    assert LazyHTML.query(document, ".chapter-heading h3") |> Enum.map(&LazyHTML.text/1) ==
             ["Message 1", "Message 2"]

    assert LazyHTML.query(document, ".conversation-chapter")
           |> LazyHTML.attribute("data-conversation-turn") == ["1", "2"]

    assert LazyHTML.query(document, ".conversation-chapter")
           |> Enum.map(fn chapter ->
             chapter |> LazyHTML.query(".conversation-phase-heading h4") |> LazyHTML.text()
           end) ==
             ["IntakeWork", "Intake"]
  end

  test "timeline jumps visit adjacent messages and existing stages without dead end controls" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    at = snapshot.trace.received_at
    [step | _] = snapshot.trace.steps

    messages =
      for index <- 1..3 do
        %{
          id: "message-#{index}",
          at: DateTime.add(at, index * 2),
          actor: "User",
          text: "Message #{index}",
          available: true
        }
      end

    snapshot =
      snapshot
      |> put_in([:trace, :case_file, :conversation], messages)
      |> put_in([:trace, :steps], [%{step | id: "running", band: :work, at: DateTime.add(at, 3)}])

    document = render_episode(snapshot, []) |> LazyHTML.from_fragment()

    assert document
           |> LazyHTML.query(".timeline-index a")
           |> LazyHTML.attribute("href") == ["#chapter-1", "#chapter-2", "#chapter-3"]

    assert document
           |> LazyHTML.query(".timeline-index a")
           |> Enum.map(&LazyHTML.text/1) == ["Message 1", "Message 2", "Message 3"]

    for {message, targets} <- [{1, [2]}, {2, [1, 3]}, {3, [2]}] do
      links =
        LazyHTML.query(document, "#timeline-message-#{message} .timeline-jumps a")

      assert LazyHTML.attribute(links, "href") == Enum.map(targets, &"#timeline-message-#{&1}")
    end

    assert document
           |> LazyHTML.query("#timeline-message-1-ready .timeline-jumps a")
           |> LazyHTML.attribute("href") == ["#timeline-message-1-work"]

    assert document
           |> LazyHTML.query("#timeline-message-1-work .timeline-jumps a")
           |> LazyHTML.attribute("href") == ["#timeline-message-1-ready"]

    assert document
           |> LazyHTML.query("#timeline-message-1-ready .timeline-jumps a")
           |> LazyHTML.attribute("aria-label") == ["Next stage: Work"]

    assert Enum.empty?(LazyHTML.query(document, "#timeline-message-2-ready .timeline-jumps"))

    for href <- document |> LazyHTML.query(".timeline-jumps a") |> LazyHTML.attribute("href") do
      assert Enum.count(LazyHTML.query(document, href)) == 1
    end

    assert document
           |> LazyHTML.query(".timeline-jumps .ui-icon path")
           |> LazyHTML.attribute("d")
           |> Enum.uniq()
           |> Enum.sort() ==
             ["M12 19V5 M6 11l6-6 6 6", "M12 5v14 M18 13l-6 6-6-6"] |> Enum.sort()
  end

  test "the briefing lists sources directly and nests only message diagnostics" do
    # Instructions and operator context previously took three or four clicks
    # to reach. The source inventory must be visible before opening any part.
    html =
      render_request(:work, :submission, [
        section("instructions", "Instructions", "Retained host policy <not markup>"),
        section("context", "Context", %{
          "inputs" => [%{"text" => "Hi"}],
          "operator_context" => %{
            "guidance" => [%{"subject" => "Review style", "summary" => "Risk first"}]
          },
          "destination" => %{"transport" => "slack"}
        })
      ])

    document = LazyHTML.from_fragment(html)

    summaries =
      document |> LazyHTML.query(".prompt-assembly .prompt-source > summary") |> LazyHTML.text()

    assert summaries =~ "System prompt"
    assert summaries =~ "Guidance"
    assert summaries =~ "Conversation messages"

    assert Enum.count(
             LazyHTML.query(
               document,
               ".context-message-details > .ui-disclosure-body > .context-message-raw"
             )
           ) == 1

    assert Enum.empty?(
             LazyHTML.query(document, ".prompt-assembly details details details details")
           )

    assert Enum.empty?(LazyHTML.query(document, ".request-input-parts > details"))
    refute LazyHTML.text(document) =~ "$.work.operator_context.guidance"
    assert html =~ "data-source=\"guidance\""
    assert html =~ "Retained host policy &lt;not markup&gt;"
  end

  test "a model briefing keeps its purpose with its title instead of below right-side metadata" do
    html =
      render_request(:admission, :submission, [
        section("instructions", "Instructions", "Retained host policy"),
        section("context", "Context", %{"inputs" => [%{"text" => "Hi"}]})
      ])

    document = LazyHTML.from_fragment(html)
    heading = LazyHTML.query(document, ".episode-request > .case-card-heading")

    assert LazyHTML.query(heading, ".case-card-heading-description")
           |> LazyHTML.text()
           |> String.trim() ==
             "Use an AI model to classify this message and choose how to respond."

    assert Enum.empty?(LazyHTML.query(document, ".episode-request > .request-explanation"))
  end

  test "the routing card states the decision it made, not only its reasoning" do
    # The card showed a paragraph of the model's reasoning and two timings while
    # the record behind it held the decision itself, one collapsible away.
    candidate = %{
      "action" => "continue_episode",
      "episode_ref" => "episode:abc123",
      "reason" => "The alert continues the checkout outage already under way.",
      "relation" => "continues",
      "repository_source" => %{"kind" => "branch", "name" => "main"},
      "work_class" => "engineering"
    }

    request = %{
      id: "routing-decision",
      phase: :result,
      source_kind: :admission,
      target: "codex:recorded",
      timing: [],
      coverage: "Retained",
      href: "/",
      sections: [section("candidate", "Candidate", candidate)]
    }

    facts =
      render_component(&EpisodeRequest.render/1, request: request)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".request-decision")
      |> LazyHTML.text()

    assert facts =~ "Continue existing work"
    assert facts =~ "episode:abc123"
    assert facts =~ "engineering"
    assert facts =~ "branch main"
  end

  test "a model call names the confirmed rules and recalled instructions it actually received" do
    # A rule affecting a reply was invisible unless the operator decoded context JSON.
    context = %{
      "operator_context" => %{
        "standing_assignments" => [
          %{
            "assignment_ref" => "rule:recorded",
            "task" => "Review the posted plan <as text>",
            "trigger" => "terraform_plan"
          }
        ],
        "preferences" => %{"response_detail" => %{"value" => "concise", "scope" => "operator"}},
        "guidance" => [%{"subject" => "Review style", "summary" => "Lead with availability risk"}],
        "memory" => [%{"subject" => "Primary repository", "value" => "emisar"}]
      }
    }

    request = %{
      id: "context-test",
      phase: :submission,
      source_kind: :work,
      target: "codex:recorded",
      timing: [],
      coverage: "Retained",
      href: "/",
      sections: [section("context", "Context", context)]
    }

    html = render_component(&EpisodeRequest.render/1, request: request)

    visible =
      html |> LazyHTML.from_fragment() |> LazyHTML.query(".applied-context") |> LazyHTML.text()

    assert visible =~ "Standing rules used"
    assert visible =~ "Review the posted plan <as text>"
    assert visible =~ "Response detail"
    assert visible =~ "Lead with availability risk"
    assert visible =~ "Primary repository"
    refute html =~ "<as text>"

    # Preferences and guidance moved under Instructions on 2026-09-24; their
    # old pages answer 404, so each group links to its own filtered section.
    hrefs =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".applied-context a")
      |> LazyHTML.attribute("href")

    assert "/instructions?show=preferences#saved" in hrefs
    assert "/instructions?show=guidance#saved" in hrefs
    refute Enum.any?(hrefs, &(&1 in ["/preferences", "/guidance"]))

    for artifact <- [
          InspectionRedactor.artifact(nil),
          %{hd(request.sections).artifact | truncated: true}
        ] do
      html =
        render_component(&EpisodeRequest.render/1,
          request: %{request | sections: [%{hd(request.sections) | artifact: artifact}]}
        )

      refute html =~ "applied-context"
    end
  end

  test "the timeline leaves forensic identity to the dedicated request inspector" do
    request = %{
      id: "request-turn-recorded",
      request_id: "turn-recorded",
      phase: :submission,
      source_kind: :work,
      target: "codex:gpt-5.6-sol/medium@default",
      policy: "ryker-chat",
      fingerprint: String.duplicate("a", 64),
      timing: [],
      coverage: "Retained",
      sections: []
    }

    document =
      render_component(&EpisodeRequest.render/1, request: request)
      |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(document, "details.request-technical-details"))
    refute LazyHTML.text(document) =~ "turn-recorded"
    refute LazyHTML.text(document) =~ "ryker-chat"
    refute LazyHTML.text(document) =~ String.duplicate("a", 64)
  end

  test "a briefing says which model ran and why before its instructions" do
    # The model sat in the corner of the header as a label; a reader could not
    # tell whether it was chosen for this call or fixed for the whole install.
    submission = %{
      id: "admission-model-1",
      request_id: "model-1",
      phase: :submission,
      source_kind: :admission,
      target: "codex:gpt-5.6-sol/medium@default",
      policy: "ryker-admission",
      model_choice: %{
        purpose: :admission,
        scope_kind: :installation,
        scope_ref: "",
        settings: true
      },
      timing: [],
      coverage: "Retained",
      sections: [section("instructions", "System prompt", "Classify the message.")]
    }

    html = render_component(&EpisodeRequest.render/1, request: submission)
    document = LazyHTML.from_fragment(html)
    model = LazyHTML.query(document, ".request-model-section")

    assert LazyHTML.text(model) =~ "gpt-5.6-sol"
    assert LazyHTML.text(model) =~ "Medium reasoning"

    # The model is an operator choice in Settings; the card says where to change it
    # instead of naming an environment variable nobody could see or edit.
    assert LazyHTML.query(model, ".request-model-reason") |> LazyHTML.text() |> words() ==
             "Routing uses the model set for it in Settings"

    assert Enum.count(LazyHTML.query(model, ~s(.request-model-reason a[href="/settings/models"]))) ==
             1

    assert Enum.empty?(LazyHTML.query(document, ".case-card-heading-meta .execution-target"))
    refute LazyHTML.text(document) =~ "ryker-admission"

    assert :binary.match(html, "request-model-section") < :binary.match(html, "prompt-assembly")

    # Work names what it was classified as; a result card does not repeat the model.
    work = %{
      submission
      | source_kind: :work,
        model_choice: %{
          submission.model_choice
          | purpose: :deep,
            scope_kind: :repository,
            scope_ref: "emisar"
        }
    }

    assert render_component(&EpisodeRequest.render/1, request: work)
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".request-model-reason")
           |> LazyHTML.text()
           |> words() ==
             "Deep work in emisar uses the model set for it in Settings"

    result = render_component(&EpisodeRequest.render/1, request: %{submission | phase: :result})
    assert Enum.empty?(LazyHTML.query(LazyHTML.from_fragment(result), ".request-model-section"))
    refute result =~ "gpt-5.6-sol"
  end

  test "each stage label says how that stage ended" do
    # Stage labels only named the stage; a reader scanning a long timeline had to
    # open each stage's cards to learn what it produced. The label summarizes
    # the stage from its own recorded entries; no card is rewritten.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    at = snapshot.trace.received_at
    [step | _] = snapshot.trace.steps

    queue = %{
      step
      | id: "queue-summary",
        band: :ready,
        stage: "Queue",
        title: "Queue",
        tone: nil,
        at: at
    }

    queue =
      Map.put(queue, :queue, %{
        kind: :claimed,
        qualifier: nil,
        current: false,
        events: [
          %{kind: :saved, label: "Saved", at: at, reason: "Saved.", href: nil, link_label: nil}
        ],
        started_at: at,
        ended_at: DateTime.add(at, 57, :millisecond),
        duration_ms: 57,
        tone: nil
      })

    reply = %{
      id: "summary-reply",
      at: DateTime.add(at, 2, :second),
      actor: "Ryker",
      text: "Hello back",
      available: true,
      status: "Response sent"
    }

    routing = %{
      id: "admission-summary-1-result",
      at: at,
      kind: :request,
      source_kind: :admission,
      phase: :result,
      band: :ready,
      title: "Admission · result",
      target: "codex:gpt-5.6-sol/medium@default",
      status: :decided,
      coverage: "Retained",
      href: "#admission-summary-1-result",
      timing: [],
      sections: [
        section("candidate", "Committed admission decision", %{
          "action" => "reply",
          "relation" => "unrelated",
          "work_class" => "conversational"
        })
      ]
    }

    summaries =
      snapshot
      |> put_in([:trace, :steps], [queue])
      |> put_in([:trace, :case_file, :conversation], [reply])
      |> render_episode([routing])
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".conversation-phase-heading")
      |> Enum.map(fn heading ->
        {heading |> LazyHTML.query("h4") |> LazyHTML.text(),
         heading |> LazyHTML.query(".phase-summary") |> LazyHTML.text()}
      end)

    # Intake and Routing carry no summary: their own cards already say how long
    # the message waited and what routing decided.
    assert {"Intake", ""} in summaries
    assert {"Routing", ""} in summaries
    assert {"Answer", "Response sent"} in summaries
  end

  test "a greeting explains routing without expanding protocol JSON or duplicating delivery chapters" do
    # The real September 5 "Hi" took 11,151 pixels and 63 disclosures to explain;
    # its accepted reply was separated from delivery by a second answer chapter.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    at = snapshot.trace.received_at

    request = %{
      id: "admission-recorded-1",
      at: at,
      kind: :request,
      source_kind: :admission,
      phase: :result,
      band: :ready,
      title: "Admission · execution 1 · result",
      target: "codex:gpt-5.6-luna/low@emisar",
      status: :decided,
      coverage: "Retained submission only",
      href: "/timeline/ingress-input%3Arecorded",
      timing: [%{label: "Agent execution", value: "37.7 s"}],
      sections: [
        section("routing", "Routing evidence", %{
          "routing_receipt" => %{
            "cutoff_reason" => "shortlist_limit",
            "eligible_conversations" => 3,
            "examined" => 7,
            "lanes" => %{
              "identity" => %{"returned" => 1, "saturated" => false},
              "text" => %{"returned" => 7, "saturated" => true},
              "thread" => %{"returned" => 4, "saturated" => false}
            },
            "offered" => 4,
            "omitted" => 3,
            "scope" => "workspace_public"
          },
          "context_manifest" => %{
            "included" => 11,
            "requested" => 20,
            "source_read" => "retained"
          }
        }),
        section("response", "Observed model response", %{
          "action" => "reply",
          "reason" => "The user sent a greeting that can be answered directly."
        }),
        section("candidate", "Committed admission decision", %{
          "action" => "reply",
          "episode_ref" => nil,
          "reaction" => nil,
          "reason" => "The user sent a greeting that can be answered directly.",
          "relation" => "unrelated",
          "repository_source" => nil,
          "work_class" => "conversational"
        }),
        section("progress", "Observed execution milestones", %{"phase" => "committed"}),
        section("measurements", "Reported usage and timing", %{"usage_provider_ms" => 37_700})
      ]
    }

    [step | _] = snapshot.trace.steps

    steps =
      for {band, i} <- Enum.with_index([:answer, :outcome, :answer, :outcome]),
          do: %{step | band: band, id: "receipt-#{i}", at: at}

    snapshot = put_in(snapshot, [:trace, :steps], steps)
    html = render_episode(snapshot, [request])
    document = LazyHTML.from_fragment(html)

    assert html =~ "Conversational reply"
    assert html =~ "The user sent a greeting that can be answered directly."
    # The model belongs to the briefing's Model section; the result does not repeat it.
    refute html =~ "gpt-5.6-luna"

    assert Enum.count(
             LazyHTML.query(document, ".conversation-phase-heading h4"),
             &(LazyHTML.text(&1) == "Answer")
           ) == 1

    # The result already states the committed decision and timing above. It
    # keeps only the exact response; how the search chose earlier work is told
    # in the briefing beside that work, not in four narrow columns here.
    evidence = LazyHTML.query(document, ".routing-evidence")
    assert Enum.count(LazyHTML.query(evidence, ".ui-disclosure-source")) == 1
    assert Enum.empty?(LazyHTML.query(evidence, "details[open]"))
    assert html =~ "Raw routing response"
    refute html =~ "Selection evidence"
    refute html =~ "Technical record"
    refute html =~ "Committed admission decision"
    refute html =~ "Observed execution milestones"
    refute html =~ "Reported usage and timing"
    refute html =~ "Routing records"
    refute html =~ "Inspect admission"
    refute html =~ "CONVERSATION · PART"
  end

  test "an unreadable committed admission decision keeps its recorded availability visible" do
    for {artifact, expected} <- [
          {InspectionRedactor.artifact(nil, expired: true), "Expired"},
          {InspectionRedactor.artifact(%{"action" => "reply"}, max_bytes: 5), "Partial display"},
          {InspectionRedactor.artifact("malformed retained decision"),
           "malformed retained decision"}
        ] do
      html =
        render_request(:admission, :result, [
          %{
            id: "candidate",
            title: "Committed admission decision",
            source_kind: :admission,
            artifact: artifact
          }
        ])

      document = LazyHTML.from_fragment(html)
      evidence = LazyHTML.query(document, ".routing-evidence .artifact-candidate")
      assert Enum.count(evidence) == 1
      assert LazyHTML.text(evidence) =~ "Committed admission decision"
      assert LazyHTML.text(evidence) =~ expected
    end
  end

  test "model input keeps source-aware instructions and context accessible in the same timeline" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)

    input = %{
      id: "request-input",
      at: snapshot.trace.received_at,
      kind: :request,
      source_kind: :work,
      phase: :submission,
      band: :ready,
      title: "Work request",
      target: "codex:gpt-5.6-terra/medium@emisar",
      status: :settled,
      coverage: "Retained submission only",
      href: "/timeline/example?attempt=retained#request-retained",
      timing: [],
      sections: [
        section("instructions", "Ryker instructions", "Retained instructions <not HTML>"),
        section("context", "Messages and selected context", %{"inputs" => [%{"text" => "Hi"}]}),
        section("request", "Submitted prompt", "retained raw input")
      ]
    }

    html = render_episode(snapshot, [input])
    document = LazyHTML.from_fragment(html)
    heading = LazyHTML.query(document, ".episode-request > .case-card-heading")

    assert LazyHTML.query(heading, ".case-card-heading-main > h3") |> LazyHTML.text() ==
             "Work briefing"

    assert LazyHTML.query(document, ".request-model-section .execution-target-model")
           |> LazyHTML.text() == "gpt-5.6-terra"

    assert Enum.empty?(LazyHTML.query(heading, ".execution-target"))

    assert html =~ "System prompt"
    assert LazyHTML.text(document) =~ "Briefing sources"
    assert html =~ "System prompt"
    refute html =~ "Host-authored instructions"
    assert html =~ "Conversation messages"
    assert html =~ "Retained instructions &lt;not HTML&gt;"
    refute html =~ "<not HTML>"
    visible = LazyHTML.from_fragment(html) |> LazyHTML.text()
    refute visible =~ "$.instructions"
    refute visible =~ "$.work.inputs"
    assert Enum.empty?(LazyHTML.from_fragment(html) |> LazyHTML.query(".prompt-source[open]"))

    assert Enum.count(
             LazyHTML.from_fragment(html)
             |> LazyHTML.query(".prompt-assembly .prompt-source")
           ) == 2

    assert Enum.count(
             LazyHTML.from_fragment(html)
             |> LazyHTML.query(".final-prompt .submitted-prompt")
           ) == 1
  end

  test "expired and truncated decisions do not acquire a reconstructed outcome" do
    for artifact <- [
          InspectionRedactor.artifact(nil, expired: true),
          InspectionRedactor.artifact(String.duplicate("x", 100), max_bytes: 10)
        ] do
      html =
        render_component(&EpisodeRequest.render/1,
          request: %{
            id: "missing",
            source_kind: :admission,
            phase: :result,
            title: "Admission",
            target: "Not recorded",
            timing: [],
            coverage: "Retained only",
            href: "/timeline/ingress-input%3Amissing",
            sections: [
              %{id: "candidate", title: "Decision", source_kind: :admission, artifact: artifact}
            ]
          }
        )

      refute html =~ "Conversational reply"
      assert html =~ "Routing result"
    end
  end

  test "the outcome shortcut lands on the reply and wall time uses minutes and seconds" do
    # Jumping past the answer left the operator at a bookkeeping footer instead.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    at = snapshot.trace.received_at

    reply = %{
      id: "accepted-reply",
      at: DateTime.add(at, 84),
      actor: "Ryker",
      text: "Hi! How can I help?",
      available: true
    }

    snapshot =
      snapshot
      |> put_in([:trace, :case_file, :conversation], [reply])
      |> put_in([:trace, :case_file, :awaiting_reply], false)
      |> put_in([:trace, :response_metrics, :wall], %{
        state: :complete,
        milliseconds: 84_000,
        reason: nil
      })
      |> put_in([:trace, :response_metrics, :response], %{
        minimum_ms: 84_000,
        average_ms: 84_000,
        maximum_ms: 84_000,
        measured: 1,
        expected: 1
      })
      |> put_in([:episode, :updated_at], reply.at)

    html = render_episode(snapshot, [])
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, ".episode-location > a:first-of-type")
           |> LazyHTML.attribute("href") == [
             "#story-message-accepted-reply"
           ]

    metrics = LazyHTML.query(document, ".episode-metrics")
    assert LazyHTML.text(metrics) =~ "1m 24s"

    assert LazyHTML.query(metrics, "dt") |> Enum.map(&LazyHTML.text/1) == [
             "Conversation span",
             "Response time",
             "Received",
             "Sent",
             "Total cost"
           ]

    response = LazyHTML.query(metrics, ".metric-response") |> LazyHTML.text()
    assert compact(response) =~ "Responsetime1m24s"
    refute response =~ "min"
    refute response =~ "avg"
    refute response =~ "max"

    assert LazyHTML.query(document, "#story-message-accepted-reply .ui-message-body")
           |> LazyHTML.text()
           |> String.trim() == "Hi! How can I help?"

    refute html =~ "End of retained execution"
  end

  test "a sent response keeps its text when an exact validated response is linked" do
    # The latest-outcome shortcut landed on an empty message surface: the link
    # to the validated attempt replaced the very reply the operator came to see.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    at = snapshot.trace.received_at

    reply = %{
      id: "linked-reply",
      at: DateTime.add(at, 2),
      actor: "Ryker",
      text: "session reuse validated.",
      available: true,
      status: "Response sent",
      delivery_ref: "delivery:linked"
    }

    request = %{
      id: "request-linked-reply-result",
      at: reply.at,
      kind: :request,
      source_kind: :work,
      phase: :result,
      band: :answer,
      target: nil,
      title: "Model response",
      status: :settled,
      timing: [],
      coverage: "Retained",
      href: "#request-linked-reply-result",
      sections: [section("candidate", "Candidate response", %{"message" => reply.text})]
    }

    document =
      snapshot
      |> put_in([:trace, :case_file, :conversation], [reply])
      |> render_episode([request])
      |> LazyHTML.from_fragment()

    sent = LazyHTML.query(document, "#story-message-linked-reply")
    assert LazyHTML.query(sent, ".ui-message-title") |> LazyHTML.text() == "Sent response"
    assert LazyHTML.query(sent, ".ui-message-body") |> LazyHTML.text() =~ reply.text

    assert LazyHTML.query(sent, "a.response-reference") |> LazyHTML.text() =~
             "View validated response"
  end

  test "the header keeps state, actions and navigation in their operator-facing order" do
    # The completed badge occupied the only useful action position, while the
    # review control sat below the metrics and source navigation replaced the
    # page the operator was reading. This is the exact completed state from the
    # manual review, including both source and Ryker thread links.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, _} = Episodes.apply(EpisodeFixtures.accept_result())
    {:ok, _} = Episodes.apply(EpisodeFixtures.confirm_delivery())
    {:ok, snapshot} = Projection.episode(episode.key)

    snapshot =
      put_in(snapshot, [:trace, :source], %{
        href: "https://slack.com/archives/C456/p1787832000001000",
        label: "Open source message",
        transport: "Slack"
      })

    document = snapshot |> render_episode([]) |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, ".episode-initial-label") |> LazyHTML.text() ==
             "Initial request"

    assert Enum.empty?(LazyHTML.query(document, ".episode-title-row .ui-status"))

    assert LazyHTML.query(document, ".episode-location .ui-status") |> LazyHTML.text() ==
             "Completed"

    assert LazyHTML.query(document, ".episode-title-actions button") |> LazyHTML.text() =~
             "Mark ending reviewed"

    links = LazyHTML.query(document, ".episode-location > a")

    # One request in its conversation: the Activity list would show only this
    # page, so there is no "all activity" link to follow.
    assert Enum.map(links, &LazyHTML.text/1) == [
             "Jump to latest outcome ↓",
             "Open source message →",
             "This Slack thread →"
           ]

    blank_links = LazyHTML.query(document, ".episode-location > a[target='_blank']")

    assert Enum.map(blank_links, &LazyHTML.text/1) == [
             "Open source message →",
             "This Slack thread →"
           ]

    assert LazyHTML.attribute(blank_links, "rel") == [
             "noopener noreferrer",
             "noopener noreferrer"
           ]

    assert Enum.empty?(LazyHTML.query(document, ".case-actions"))
  end

  test "a conversation link leads somewhere the reader has not just been" do
    # Andrew, 2026-09-24: "All activity in this conversation" opened Activity
    # filtered to a conversation whose only item was the page he came from.
    # A chat now opens the chat itself, and a conversation with more than
    # one request lists them all.
    assert Activity.conversation_link("control_plane", "control-plane:lab:abc", :live) ==
             %{href: "/conversations/abc", label: "Open in Chat"}

    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())

    assert Activity.conversation_link(
             episode.destination_transport,
             episode.destination_conversation_ref,
             episode.execution_mode
           ) == nil

    {:ok, _second} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: Ecto.UUID.generate(),
          episode_key: "slack:second-request",
          native_input_id: "slack-message:second-request",
          turn_ref: "turn:second-request"
        })
      )

    assert %{label: "All 2 requests in this conversation", href: "/activity?" <> _query} =
             Activity.conversation_link(
               episode.destination_transport,
               episode.destination_conversation_ref,
               episode.execution_mode
             )
  end

  test "untimed historical events do not inflate the projected wall time" do
    # Unknown timeline timestamps and late episode bookkeeping are not timing boundaries.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    [step | _] = snapshot.trace.steps

    snapshot =
      snapshot
      |> put_in([:trace, :steps], [%{step | at: nil}])
      |> put_in([:trace, :response_metrics, :wall], %{
        state: :complete,
        milliseconds: 84_000,
        reason: nil
      })
      |> put_in([:episode, :updated_at], DateTime.add(snapshot.trace.received_at, 1_200))

    document = render_episode(snapshot, []) |> LazyHTML.from_fragment()
    assert LazyHTML.query(document, ".episode-metrics") |> LazyHTML.text() =~ "1m 24s"
  end

  test "silent outcomes stay visible and never jump to an older answer" do
    # Collapsing bookkeeping must not hide the decision to send no reply.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    at = snapshot.trace.received_at
    [step | _] = snapshot.trace.steps

    silent = %{
      step
      | id: "turn-silent-accepted",
        at: DateTime.add(at, 90),
        band: :answer,
        stage: "Result",
        state: "accepted",
        tone: :good,
        summary: "No reply: The message was deleted.",
        details: [%{label: "Delivery", value: "none"}]
    }

    prior_reply = %{
      id: "prior",
      at: DateTime.add(at, 30),
      actor: "Ryker",
      text: "Hi! How can I help?",
      available: true
    }

    for conversation <- [[], [prior_reply], [%{prior_reply | id: "silent", text: ""}]] do
      page =
        snapshot
        |> put_in([:trace, :steps], [silent])
        |> put_in([:trace, :case_file, :conversation], conversation)
        |> put_in([:trace, :case_file, :awaiting_reply], false)

      document = render_episode(page, []) |> LazyHTML.from_fragment()

      assert LazyHTML.query(document, ".episode-location > a:first-of-type")
             |> LazyHTML.attribute("href") == [
               "#event-turn-silent-accepted"
             ]

      assert LazyHTML.query(document, "#event-turn-silent-accepted h3") |> LazyHTML.text() ==
               "No reply sent"

      assert LazyHTML.query(document, "#event-turn-silent-accepted .case-event-summary")
             |> LazyHTML.text() =~ "The message was deleted."

      assert Enum.empty?(LazyHTML.query(document, ".case-system-event"))
    end
  end

  test "every receipt has its own visible action block without hiding failures or losing order" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    [step | _] = snapshot.trace.steps
    at = snapshot.trace.received_at

    steps =
      for {tone, index} <- Enum.with_index([:good, :good, :bad, :good, :good]) do
        %{
          step
          | id: "receipt-#{index}",
            at: DateTime.add(at, 84),
            band: :answer,
            stage: "Delivery",
            tone: tone
        }
      end

    page = put_in(snapshot, [:trace, :steps], steps)
    document = render_episode(page, []) |> LazyHTML.from_fragment()
    assert Enum.empty?(LazyHTML.query(document, ".case-receipt-group"))
    assert Enum.count(LazyHTML.query(document, ".case-entry h3")) == 5

    assert LazyHTML.query(document, ".case-entry") |> LazyHTML.attribute("id") ==
             Enum.map(steps, &("event-" <> &1.id))

    assert Enum.empty?(LazyHTML.query(document, ".case-receipt-group #event-receipt-2"))
    assert Enum.empty?(LazyHTML.query(document, ".case-checkpoint#event-receipt-2"))
    assert LazyHTML.query(document, ".chapter-span") |> LazyHTML.text() == "+1m 24s from start"
  end

  test "validation summaries cannot mistake missing or malformed evidence for an accepted answer" do
    # Accepted fields from the retained greeting; the other cases deliberately
    # corrupt that host receipt, not generate replacement model responses.
    accepted = %{"candidate_attempt" => 1, "verdict" => %{"verdict" => "accept"}}

    for {value, expected, rejected} <- [
          {accepted, "Answer passed validation", false},
          {put_in(accepted, ["verdict", "verdict"], "reject"), "Answer needs correction", true},
          {%{"verdict" => "accept"}, "Model result", false},
          {"not JSON", "Model result", false},
          {nil, "Model result", false}
        ] do
      html = render_request(:work, :result, [section("validation", "Host validation", value)])
      text = LazyHTML.from_fragment(html) |> LazyHTML.text()
      assert text =~ expected
      if rejected, do: assert(text =~ "was returned for correction")
      refute text =~ "Delivery confirmed"
    end
  end

  test "continuations and unavailable prompt components remain distinguishable" do
    context = section("context", "Context", %{"mode" => "continuation"})

    for {artifact, status} <- [
          {InspectionRedactor.artifact(nil), "Not recorded"},
          {InspectionRedactor.artifact(nil, expired: true), "Expired"},
          {InspectionRedactor.artifact("retained instructions", max_bytes: 5), "Partial display"}
        ] do
      instructions = %{
        id: "instructions",
        title: "Instructions",
        source_kind: :work,
        artifact: artifact
      }

      html = render_request(:work, :submission, [context, instructions])
      assert html =~ "Continue with the new messages"
      assert html =~ status
    end
  end

  test "the episode summary groups timing, conversation and cost with concise response statistics" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)

    metrics = %{
      wall: %{state: :complete, milliseconds: 120_000, reason: nil},
      messages: %{received: 2, sent: 1, total: 3},
      response: %{
        minimum_ms: 60_000,
        average_ms: 90_000,
        maximum_ms: 120_000,
        measured: 2,
        expected: 3
      }
    }

    snapshot =
      snapshot
      |> put_in([:trace, :response_metrics], metrics)
      |> Map.put(:accounting, %{
        cost_usd: Decimal.new("0.125"),
        estimated_cost_usd: Decimal.new("0.025"),
        costed: 1,
        estimated: 1,
        attempts: 3
      })

    document = render_episode(snapshot, []) |> LazyHTML.from_fragment()
    headline = LazyHTML.query(document, ".episode-metrics")
    text = LazyHTML.text(headline)

    assert LazyHTML.query(headline, ".metric-group-label") |> Enum.map(&LazyHTML.text/1) == [
             "Timing",
             "Conversation",
             "Cost"
           ]

    assert LazyHTML.query(headline, "dt") |> Enum.map(&LazyHTML.text/1) == [
             "Conversation span",
             "Average response",
             "Received",
             "Sent",
             "Total cost"
           ]

    assert text =~ "2m"
    assert text =~ "1m 30s"
    assert text =~ "3"
    assert text =~ "≈ $0.15"
    assert text =~ "min 1m, max 2m"
    refute text =~ "includes estimates"
    refute text =~ "Includes time between messages"

    # The cost is one figure; a disclosure larger than its one line is gone.
    assert Enum.empty?(LazyHTML.query(document, ".metric-cost-details"))

    refute text =~ "2 of 3 responses timed"
    refute text =~ "avg"
    refute text =~ "Elapsed"
    refute text =~ "Work turns"
    refute text =~ "Tool calls"
  end

  test "review history shows review state rather than cost coverage" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)

    document = snapshot |> render_episode([]) |> LazyHTML.from_fragment()
    review = LazyHTML.query(document, ".story-review") |> LazyHTML.text()

    assert review =~ "Not reviewed"
    refute review =~ "reported"
    refute review =~ "estimated"
  end

  test "active work calls its pending response waiting without missing-measurement prose" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)

    metrics = %{
      wall: %{state: :active, milliseconds: 48_000, reason: nil},
      messages: %{received: 1, sent: 0, total: 1},
      response: %{
        minimum_ms: nil,
        average_ms: nil,
        maximum_ms: nil,
        measured: 0,
        expected: 1
      }
    }

    summary =
      snapshot
      |> put_in([:trace, :response_metrics], metrics)
      |> render_episode([])
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".episode-metrics")

    response = LazyHTML.query(summary, ".metric-response") |> LazyHTML.text()
    assert compact(response) == "ResponsetimeWaiting"
    refute LazyHTML.text(summary) =~ "No completed responses"
    refute LazyHTML.text(summary) =~ "responses timed"
    refute LazyHTML.text(summary) =~ "first message"
  end

  test "unknown response measurements remain unknown instead of reading as zero" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)

    metrics = %{
      wall: %{
        state: :unknown,
        milliseconds: nil,
        reason: "No accepted or delivered outcome time was recorded."
      },
      messages: %{received: 1, sent: 0, total: 1},
      response: %{
        minimum_ms: nil,
        average_ms: nil,
        maximum_ms: nil,
        measured: 0,
        expected: 1
      }
    }

    document =
      snapshot
      |> put_in([:trace, :response_metrics], metrics)
      |> render_episode([])
      |> LazyHTML.from_fragment()

    headline = LazyHTML.query(document, ".episode-metrics")
    text = LazyHTML.text(headline)
    assert text =~ "Not measured"
    refute text =~ "No completed responses"
    refute text =~ "responses timed"
    refute text =~ "min 0s"
  end

  defp render_request(kind, phase, sections) do
    render_component(&EpisodeRequest.render/1,
      request: %{
        id: "recorded-request",
        source_kind: kind,
        phase: phase,
        target: "codex:gpt-5.6-terra/medium@emisar",
        timing: [],
        coverage: "Retained only",
        href: "/timeline/example#recorded-request",
        sections: sections
      }
    )
  end

  defp section(id, title, value),
    do: %{id: id, title: title, source_kind: :work, artifact: InspectionRedactor.artifact(value)}

  defp compact(value), do: String.replace(value, ~r/\s+/, "")
  defp words(value), do: value |> String.split() |> Enum.join(" ")

  defp render_episode(snapshot, items),
    do:
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: %{items: items, truncated: false},
        requests: nil,
        params: %{}
      )
end
