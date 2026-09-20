defmodule Ryker.ControlPlane.EpisodeDocumentTest do
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{EpisodePage, EpisodeRequest, InspectionRedactor, Projection}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures

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
    assert LazyHTML.query(document, ".prompt-group") |> Enum.count() >= 3
    assert LazyHTML.query(document, ".prompt-source[open]") |> Enum.empty?()

    assert LazyHTML.query(document, ".prompt-source[data-source='contract']") |> LazyHTML.text() =~
             "object"

    assert html =~ "estimated tokens"

    assert LazyHTML.query(document, ".prompt-fragment")
           |> LazyHTML.attribute("data-source-label")
           |> Enum.any?(&String.contains?(&1, "Messages"))

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

    assert html =~ "Response to validate"
    assert html =~ "<strong>partial</strong>"
    assert html =~ "Supporting records"
    refute html =~ "Validated response"
    refute html =~ "Validation history"
  end

  test "unchanged delivery links to the response while real transformations keep both versions" do
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
      href: "model-calls",
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
      assert Enum.count(previews, &String.contains?(&1, "The check is partial")) == 1

      assert LazyHTML.query(document, ".response-reference a") |> Enum.count() ==
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
             ["Routing", "The work", "The answer"]

    assert document |> LazyHTML.query(".phase-routing .case-request") |> Enum.count() == 2

    assert document |> LazyHTML.query(".phase-routing") |> LazyHTML.text() =~
             "The user sent a greeting that can be answered directly."

    assert document |> LazyHTML.query("#routing-1-result time") |> LazyHTML.text() ==
             Calendar.strftime(result.at, "%H:%M:%S")

    assert Enum.empty?(LazyHTML.query(document, ".case-receipt-group, .case-system-event"))
    assert LazyHTML.query(document, "#routing-1-result") |> Enum.count() == 1

    assert LazyHTML.query(document, ".phase-routing .chapter-span") |> LazyHTML.text() ==
             "+0s to +1s from start"

    # Truncated history may retain either side of the pair. Neither disappears.
    assert render_episode(snapshot, [result]) =~ "Conversational reply"
    assert render_episode(snapshot, [start]) =~ "Routing briefing"
  end

  test "recovered routing remains one forward-moving phase and reuses an identical briefing" do
    # A retained production history repeatedly returned to Getting ready after
    # routing transport failures. The page then read 01, 02, 01, 02 even though
    # every later row happened later in time. Keep one chronological phase and
    # do not print the same several-thousand-token briefing on every recovery.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    at = snapshot.trace.received_at
    [step | _] = snapshot.trace.steps

    briefing = %{
      id: "routing-1",
      at: at,
      kind: :request,
      source_kind: :admission,
      phase: :submission,
      band: :ready,
      fingerprint: "same-retained-briefing",
      target: "codex:gpt-5.6-luna/low@emisar",
      timing: [],
      coverage: "Retained",
      href: "/timeline/ingress-input%3Aone",
      sections: [section("request", "Prompt", "large retained routing briefing")]
    }

    first_result = %{
      briefing
      | id: "routing-1-result",
        at: DateTime.add(at, 1),
        phase: :result,
        sections: []
    }

    recovery_queue = %{
      step
      | id: "recovery-queue",
        at: DateTime.add(at, 60),
        band: :ready,
        stage: "Recovery"
    }

    repeated = %{briefing | id: "routing-2", at: DateTime.add(at, 61)}
    second_result = %{first_result | id: "routing-2-result", at: DateTime.add(at, 62)}

    snapshot = put_in(snapshot, [:trace, :steps], [recovery_queue])

    document =
      render_episode(snapshot, [briefing, first_result, repeated, second_result])
      |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query(".chapter-heading h3") |> Enum.map(&LazyHTML.text/1) ==
             ["Routing"]

    assert document |> LazyHTML.query(".phase-routing .phase-number") |> LazyHTML.text() == "01"
    assert document |> LazyHTML.query(".phase-routing .episode-request") |> Enum.count() == 4

    assert document |> LazyHTML.query(".phase-routing") |> LazyHTML.text() =~
             "Routing briefing reused"

    assert document
           |> LazyHTML.query(".phase-routing .final-prompt")
           |> Enum.count() == 1
  end

  test "follow-up setup stays after earlier model activity in its own message group" do
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
             ["Getting ready", "The work", "New input received"]

    assert LazyHTML.query(document, ".conversation-boundary .turn-divider-label")
           |> LazyHTML.text() =~ "Message 2"
  end

  test "the briefing lists prompt sources without outer or recursively nested disclosures" do
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

    assert summaries =~ "Ryker instructions"
    assert summaries =~ "Confirmed guidance"
    assert summaries =~ "Episode input history"
    assert Enum.empty?(LazyHTML.query(document, ".prompt-assembly details details details"))
    assert Enum.empty?(LazyHTML.query(document, ".request-input-parts > details"))
    refute LazyHTML.text(document) =~ "$.work.operator_context.guidance"
    assert html =~ "data-source=\"guidance\""
    assert html =~ "Retained host policy &lt;not markup&gt;"
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
        section("candidate", "Committed admission decision", %{
          "action" => "reply",
          "episode_ref" => nil,
          "reaction" => nil,
          "reason" => "The user sent a greeting that can be answered directly.",
          "relation" => "unrelated",
          "repository_source" => nil,
          "work_class" => "conversational"
        })
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
    assert html =~ "gpt-5.6-luna/low"
    refute html =~ ">codex:gpt-5.6-luna/low@emisar<"

    assert Enum.count(
             LazyHTML.query(document, ".chapter-heading h3"),
             &(LazyHTML.text(&1) == "The answer")
           ) == 1

    # Each record is its own disclosure under one heading, and none of them is
    # expanded: the point is that the protocol JSON stays out of the page until
    # a reader asks for the specific record they want.
    assert Enum.count(LazyHTML.query(document, ".case-request section.request-evidence")) == 1
    assert Enum.empty?(LazyHTML.query(document, ".request-evidence details[open]"))
    assert Enum.count(LazyHTML.query(document, ".request-evidence details")) == 1
    assert html =~ "Committed admission decision"
    refute html =~ "Inspect admission"
    refute html =~ "CONVERSATION · PART"
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
      href: "/timeline/example/model-calls?attempt=retained",
      timing: [],
      sections: [
        section("instructions", "Ryker instructions", "Retained instructions <not HTML>"),
        section("context", "Messages and selected context", %{"inputs" => [%{"text" => "Hi"}]}),
        section("request", "Submitted prompt", "retained raw input")
      ]
    }

    html = render_episode(snapshot, [input])
    assert html =~ "Model briefing"
    assert html =~ "Ryker instructions"
    assert LazyHTML.from_fragment(html) |> LazyHTML.text() =~ "Briefing sources"
    assert html =~ "Host-authored instructions"
    assert html =~ "Episode input history"
    assert html =~ "Retained instructions &lt;not HTML&gt;"
    refute html =~ "<not HTML>"
    visible = LazyHTML.from_fragment(html) |> LazyHTML.text()
    refute visible =~ "$.instructions"
    refute visible =~ "$.work.inputs"
    assert Enum.empty?(LazyHTML.from_fragment(html) |> LazyHTML.query(".request-evidence[open]"))

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
             "Total wall time",
             "Response time",
             "Messages",
             "Total cost"
           ]

    response = LazyHTML.query(metrics, ".metric-response") |> LazyHTML.text()
    assert compact(response) =~ "Responsetime1m24s"
    refute response =~ "min"
    refute response =~ "avg"
    refute response =~ "max"

    assert LazyHTML.query(document, "#story-message-accepted-reply .case-message-text")
           |> LazyHTML.text()
           |> String.trim() == "Hi! How can I help?"

    refute html =~ "End of retained execution"
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

    assert Enum.empty?(LazyHTML.query(document, ".episode-title-row .ui-status"))

    assert LazyHTML.query(document, ".episode-location .ui-status") |> LazyHTML.text() ==
             "Completed"

    assert LazyHTML.query(document, ".episode-title-actions button") |> LazyHTML.text() =~
             "Mark ending reviewed"

    links = LazyHTML.query(document, ".episode-location > a")

    assert Enum.map(links, &LazyHTML.text/1) == [
             "Jump to latest outcome",
             "Open source message",
             "All activity in this conversation",
             "This Slack thread"
           ]

    blank_links = LazyHTML.query(document, ".episode-location > a[target='_blank']")

    assert Enum.map(blank_links, &LazyHTML.text/1) == [
             "Open source message",
             "This Slack thread"
           ]

    assert LazyHTML.attribute(blank_links, "rel") == [
             "noopener noreferrer",
             "noopener noreferrer"
           ]

    assert LazyHTML.query(
             document,
             ".episode-location > a:not([target]):nth-of-type(3)"
           )
           |> LazyHTML.text() == "All activity in this conversation"

    assert Enum.empty?(LazyHTML.query(document, ".case-actions"))
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

  test "model labels separate the saved profile without guessing a missing target" do
    assert EpisodeRequest.model("codex:gpt-5.6-sol/high@emisar") == %{
             name: "gpt-5.6-sol/high",
             account: "codex"
           }

    assert EpisodeRequest.model("codex:gpt-5.6-sol/high") == %{
             name: "gpt-5.6-sol/high",
             account: "codex"
           }

    assert EpisodeRequest.model("Execution target not recorded") == %{
             name: "Execution target not recorded",
             account: nil
           }

    assert EpisodeRequest.model(nil) == %{name: "Model not recorded", account: nil}
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

      assert Enum.empty?(
               LazyHTML.from_fragment(html)
               |> LazyHTML.query(".request-result-evidence[open]")
             )
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
             "Total wall time",
             "Average response",
             "Messages",
             "Total cost"
           ]

    assert text =~ "2m"
    assert text =~ "1m 30s"
    assert text =~ "3"
    assert text =~ "≈ $0.15"
    assert text =~ "min 1m, max 2m"
    assert text =~ "2 received, 1 sent"
    refute text =~ "1 reported"
    refute text =~ "2 of 3 responses timed"
    refute text =~ "avg"
    refute text =~ "·"
    refute text =~ "Elapsed"
    refute text =~ "Work turns"
    refute text =~ "Tool calls"
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
        href: "/timeline/example/model-calls",
        sections: sections
      }
    )
  end

  defp section(id, title, value),
    do: %{id: id, title: title, source_kind: :work, artifact: InspectionRedactor.artifact(value)}

  defp compact(value), do: String.replace(value, ~r/\s+/, "")

  defp render_episode(snapshot, items),
    do:
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: %{items: items, truncated: false},
        requests: nil,
        params: %{}
      )
end
