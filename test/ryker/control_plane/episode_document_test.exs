defmodule Ryker.ControlPlane.EpisodeDocumentTest do
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Activity, EpisodePage, EpisodeProjection, EpisodeRequest}
  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.InspectionRedactor
  alias Ryker.Operator.EpisodeReviews

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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

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

  # Andrew, 2026-09-27, of the "Request identity" disclosure (Request ID,
  # Conversation, Destination ID, Created): "do we even need this? i think
  # everything in here is duped in message?" The header already says where
  # the request came from and when, and the message's own details carry its
  # IDs.
  test "a request's page ends with its chapters, not an identity box that repeats its header" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

    document = snapshot |> render_episode([]) |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("[id^=request-identity-]") |> Enum.empty?()
    refute LazyHTML.text(document) =~ "Request identity"
    refute LazyHTML.text(document) =~ "Destination ID"
  end

  test "a visible input and answer do not acquire duplicate receipt cards" do
    # The replay repeated one delivery as a response, kernel receipt and turn receipt.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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
    refute html =~ "Message added"
    refute html =~ "Delivery confirmed"
    refute html =~ "Reply delivered"
    assert html =~ "Response sent"
    assert html =~ "Hello back"
  end

  test "the same accepted result is not repeated as a kernel card and a turn card" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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

  # Andrew, 2026-09-27, of a card that read "Request title Hello": "what is
  # this? updating title of episode? maybe say that? ... or do not show it if
  # title stayed the same." Every answer carries a title, so the row showed on
  # every answer, the same one each time.
  test "an answer's card says it renamed the request only when it did" do
    answer = %{
      "delivery" => "reply",
      "message" => "Checked.",
      "outcome" => %{"record_refs" => []},
      "title" => "Investigate checkout 502s"
    }

    renamed =
      render_component(&EpisodeRequest.render/1,
        request:
          request(:work, :result, [section("candidate", "Response to validate", answer)])
          |> Map.put(:title_update, "Investigate checkout 502s")
      )
      |> LazyHTML.from_fragment()

    assert renamed |> LazyHTML.query(".title-update") |> LazyHTML.text() |> words() ==
             "Episode title is updated to: Investigate checkout 502s"

    # Andrew, 2026-10-01: "rename to 'Episode title is updated to: ' and remove pencil icon".
    refute renamed |> LazyHTML.query(".title-update .ui-icon") |> Enum.any?()

    # The same title again, as every later answer of the request sends it.
    # Only the raw response, opened on purpose, still carries it.
    kept =
      render_request(:work, :result, [section("candidate", "Response to validate", answer)])
      |> LazyHTML.from_fragment()

    assert kept |> LazyHTML.query(".title-update") |> Enum.empty?()
    refute kept |> LazyHTML.query(".response-review") |> LazyHTML.text() =~ "502s"
    refute LazyHTML.text(kept) =~ "Request title"
  end

  test "sent text stays visible even when it matches the validated response" do
    # The full timeline needs both the checked candidate and the delivery
    # outcome; a link to one must not erase the other.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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

      # Andrew, 2026-09-27: the links between a reply and its checked
      # answer ("View validated response ↑", "View response with attempt
      # 1's checks ↑") are gone; both cards are on the same page.
      assert LazyHTML.query(document, ".response-reference") |> Enum.empty?()
      refute LazyHTML.text(document) =~ "View validated response"

      # A reply is Ryker's, whether or not it went out as checked. The
      # title came from that link, so a changed reply read "Incoming message".
      assert LazyHTML.query(document, "#story-message-turn .ui-message-title")
             |> LazyHTML.text() == "Sent response"

      if transformed,
        do: assert(Enum.any?(previews, &String.contains?(&1, "A corrected response")))
    end
  end

  test "routing shows its briefing and decision separately at their real times" do
    # A one-word greeting looked like two executions with tiny repeated phases.
    # Routing is one model execution, but its input and result have distinct times.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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
      href: "/timeline/one",
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
             ["Before the first message"]

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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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
               ".context-message-details > .context-message-raw"
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

  # Andrew, 2026-09-29, of PR #2's task briefing (gpt-5.6-sol, no line under
  # it): "missing link to settings". Its job was frozen on 27 Sep, and the
  # Default environment's template changed since, so no current template
  # matched and the card said nothing about where the model came from.
  test "a briefing whose job no longer matches today's settings still says where models are chosen" do
    submission = %{
      id: "work-model-1",
      request_id: "model-1",
      phase: :submission,
      source_kind: :work,
      target: "codex:gpt-5.6-sol/medium@default",
      policy: "ryker-env-default-andrewdryga-test-contributor",
      model_choice: %{purpose: nil, scope_kind: nil, scope_ref: nil, settings: false},
      timing: [],
      sections: [section("instructions", "System prompt", "Make the change.")]
    }

    model =
      render_component(&EpisodeRequest.render/1, request: submission)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".request-model-section")

    assert LazyHTML.query(model, ".request-model-reason") |> LazyHTML.text() |> words() ==
             "Chosen when this work started, from the models set in Settings"

    assert Enum.count(LazyHTML.query(model, ~s(.request-model-reason a[href="/settings/models"]))) ==
             1

    # A call recorded before model choices were kept links there too.
    older =
      render_component(&EpisodeRequest.render/1, request: Map.delete(submission, :model_choice))

    assert older =~ ~s(href="/settings/models")
  end

  test "each stage label says how that stage ended" do
    # Stage labels only named the stage; a reader scanning a long timeline had to
    # open each stage's cards to learn what it produced. The label summarizes
    # the stage from its own recorded entries; no card is rewritten.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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
      href: "/timeline/recorded",
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
          "messages" => nil,
          "reactions" => nil,
          "reason" => "The user sent a greeting that can be answered directly.",
          "relation" => "unrelated",
          "repository" => nil,
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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

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
            href: "/timeline/missing",
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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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

  test "a sent response keeps its text when it matches the checked answer" do
    # The latest-outcome shortcut landed on an empty message surface: the link
    # to the validated attempt replaced the very reply the operator came to see.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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

    # Nothing under the reply leads away from it; the checked answer is on
    # the same page.
    assert LazyHTML.query(sent, ".ui-message-footer") |> Enum.empty?()
    refute LazyHTML.text(sent) =~ "validated response"
  end

  test "the header keeps state, actions and navigation in their operator-facing order" do
    # The completed badge occupied the only useful action position, while the
    # review control sat below the metrics and source navigation replaced the
    # page the operator was reading. This is the exact completed state from the
    # manual review, including both source and Ryker thread links.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, _} = Episodes.apply(EpisodeFixtures.accept_result())
    {:ok, _} = Episodes.apply(EpisodeFixtures.confirm_delivery())
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

    snapshot =
      put_in(snapshot, [:trace, :source], %{
        href: "https://slack.com/archives/C456/p1787832000001000",
        label: "Open in Slack",
        transport: "Slack"
      })

    document = snapshot |> render_episode([]) |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, ".episode-initial-label") |> LazyHTML.text() ==
             "Initial request"

    assert Enum.empty?(LazyHTML.query(document, ".episode-title-row .ui-status"))

    assert LazyHTML.query(document, ".episode-location .ui-status") |> LazyHTML.text() ==
             "Completed"

    # How it went is asked where the timeline ends, not in the header.
    assert LazyHTML.query(document, ".episode-title-actions button") |> Enum.empty?()

    assert LazyHTML.query(document, "#rate-request button") |> Enum.map(&LazyHTML.text/1) ==
             ["Went well", "Needs work"]

    links = LazyHTML.query(document, ".episode-location > a")

    # One request in its conversation: the Activity list would show only this
    # page, so there is no "all activity" link to follow.
    assert Enum.map(links, &LazyHTML.text/1) == [
             "Jump to latest outcome ↓",
             "Open in Slack →",
             "All messages in this thread →"
           ]

    # Only Slack opens in a new tab; the thread's messages are a page of Ryker.
    blank_links = LazyHTML.query(document, ".episode-location > a[target='_blank']")
    assert Enum.map(blank_links, &LazyHTML.text/1) == ["Open in Slack →"]
    assert LazyHTML.attribute(blank_links, "rel") == ["noopener noreferrer"]

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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)
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
      if rejected, do: assert(text =~ "Try 1 was sent back to be fixed.")
      if value == accepted, do: assert(text =~ "Try 1 passed Ryker's checks.")
      refute text =~ "Candidate 1"
      refute text =~ "host's checks"
      refute text =~ "Delivery confirmed"
    end
  end

  test "a routing decision's stored reason reads in plain words on its card" do
    # QA re-test, 2026-09-26: 26 timelines showed "no candidate episode is
    # available" under "Model's reason". The stored decision keeps its words.
    reason =
      "The user explicitly requests investigation of whether yesterday's checkout readiness probe alert is related to the 08:00 deployment. This requires operational evidence and correlation; no candidate episode is available."

    html =
      render_request(:admission, :result, [
        section("candidate", "Committed admission decision", %{
          "action" => "start_episode",
          "reason" => reason
        })
      ])

    rationale =
      html |> LazyHTML.from_fragment() |> LazyHTML.query(".request-rationale") |> LazyHTML.text()

    assert rationale =~ "This requires operational evidence and correlation."
    refute rationale =~ "candidate"
    refute rationale =~ "episode"
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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

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

  # Andrew, 2026-09-28, of "Mark how this request ended as reviewed?": "WHAT
  # IS THE POINT OF THIS? i just mark it so what next? this is half baked!"
  # Marking it recorded that someone looked and nothing followed.
  test "a finished request asks how it went, and a rating is feedback that can start self-analysis" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())

    {:ok, _cancelled} =
      Episodes.apply(%Command.CancelEpisode{
        cancel_ref: "work:stalled:#{Ecto.UUID.generate()}",
        episode_key: episode.key,
        expected_owner: %{kind: :turn, ref: episode.owner_ref},
        occurred_at: DateTime.utc_now(),
        reason: "Stopped."
      })

    {:ok, ended} = EpisodeProjection.fetch(episode.key)
    document = ended |> render_episode([]) |> LazyHTML.from_fragment()
    rate = LazyHTML.query(document, "#rate-request")

    assert rate |> LazyHTML.query("h2") |> LazyHTML.text() == "How did this go?"
    assert LazyHTML.text(rate) =~ "Needs work sends it to Self-improvement"

    assert rate |> LazyHTML.query("form") |> LazyHTML.attribute("action") == [
             "/actions/episode/#{episode.id}/rate-good",
             "/actions/episode/#{episode.id}/rate-needs-work"
           ]

    {:ok, _rated} =
      EpisodeReviews.review(
        episode.key,
        "control-plane:local",
        :needs_work,
        "It stopped for good; the deploy needed a retry."
      )

    # Rated: nothing asks again, the rating is in the Feedback chapter with
    # its note, and the request waits for Ryker's own analysis.
    {:ok, rated} = EpisodeProjection.fetch(episode.key)
    document = rated |> render_episode([]) |> LazyHTML.from_fragment()
    assert document |> LazyHTML.query("#rate-request") |> Enum.empty?()

    card = LazyHTML.query(document, "#feedback .feedback-card")

    assert card |> LazyHTML.query("h3") |> LazyHTML.text() == "Rated: needs work"
    assert card |> LazyHTML.query(".state-word") |> LazyHTML.text() == "Needs work"

    assert card |> LazyHTML.query(".case-event-summary") |> LazyHTML.text() |> String.trim() ==
             "“It stopped for good; the deploy needed a retry.”"

    assert %{reasons: ["rated"]} =
             Repo.get_by(Ryker.Improvement.Candidate, episode_id: episode.id)

    # A request that went on after the rating and ended again asks again.
    document =
      rated
      |> update_in([:trace, :rating], &%{&1 | awaiting: true})
      |> render_episode([])
      |> LazyHTML.from_fragment()

    refute document |> LazyHTML.query("#rate-request") |> Enum.empty?()
  end

  test "a request still working asks nothing about how it went" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

    document = snapshot |> render_episode([]) |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("#rate-request") |> Enum.empty?()
    refute LazyHTML.text(document) =~ "How did this go?"
  end

  # The same question, on the card of the model call: "Passed first time"
  # read fine, but a call that needed corrections said "Passed after 1
  # correction" and gave no way to the answer that was sent back.
  test "a model call's checks line says on which attempt it passed and leads to what was sent back" do
    run = fn checks, corrections ->
      %{
        target: "codex:gpt-5.6-sol/high@work",
        tokens: nil,
        cost: nil,
        checks: checks,
        corrections: corrections,
        segments: [],
        total_ms: 1_200
      }
    end

    first =
      render_component(&EpisodeRequest.render/1,
        request: Map.put(request(:work, :result, []), :run, run.("Passed first time", []))
      )
      |> LazyHTML.from_fragment()

    assert checks(first) == "Passed first time"
    assert first |> LazyHTML.query(".call-run a") |> Enum.empty?()

    corrected =
      render_component(&EpisodeRequest.render/1,
        request:
          Map.put(
            request(:work, :result, []),
            :run,
            run.("Passed on attempt 2 · 1 correction", [
              %{attempt: 1, href: "#event-turn-recorded-validation-1"}
            ])
          )
      )
      |> LazyHTML.from_fragment()

    assert checks(corrected) ==
             "Passed on attempt 2 · 1 correction Attempt 1 was sent back to be fixed ↑"

    assert corrected |> LazyHTML.query(".call-run a") |> LazyHTML.attribute("href") == [
             "#event-turn-recorded-validation-1"
           ]
  end

  test "active work calls its pending response waiting without missing-measurement prose" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

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

  defp render_request(kind, phase, sections),
    do: render_component(&EpisodeRequest.render/1, request: request(kind, phase, sections))

  defp request(kind, phase, sections) do
    %{
      id: "recorded-request",
      source_kind: kind,
      phase: phase,
      target: "codex:gpt-5.6-terra/medium@emisar",
      timing: [],
      href: "/timeline/example#recorded-request",
      sections: sections
    }
  end

  defp checks(document) do
    document
    |> LazyHTML.query(".call-run > div")
    |> Enum.find(&(&1 |> LazyHTML.query("dt") |> LazyHTML.text() == "Checks"))
    |> LazyHTML.query("dd")
    |> LazyHTML.text()
    |> words()
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
