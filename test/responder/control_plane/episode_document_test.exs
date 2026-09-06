defmodule Responder.ControlPlane.EpisodeDocumentTest do
  use Responder.DataCase, async: true
  import Phoenix.LiveViewTest

  alias Responder.ControlPlane.{EpisodePage, EpisodeRequest, InspectionRedactor, Projection}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures

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
      href: "/episodes/ingress-input%3Aone",
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
             "+0s → +1s from start"

    # Truncated history may retain either side of the pair. Neither disappears.
    assert render_episode(snapshot, [result]) =~ "Conversational reply"
    assert render_episode(snapshot, [start]) =~ "Routing briefing"
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
      document |> LazyHTML.query(".prompt-assembly > details > summary") |> LazyHTML.text()

    assert summaries =~ "Responder instructions"
    assert summaries =~ "Confirmed guidance"
    assert summaries =~ "Episode input history"
    assert Enum.empty?(LazyHTML.query(document, ".prompt-assembly details details details"))
    assert Enum.empty?(LazyHTML.query(document, ".request-input-parts > details"))
    assert html =~ "$.work.operator_context.guidance"
    assert html =~ "Retained host policy &lt;not markup&gt;"
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
      href: "/episodes/ingress-input%3Arecorded",
      timing: [%{label: "Agent execution", value: "37.7 s"}],
      sections: [
        section("candidate", "Committed admission decision", %{
          "action" => "reply",
          "episode_ref" => nil,
          "reaction" => nil,
          "reason" => "The user sent a greeting that can be answered directly.",
          "relation" => "unrelated",
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

    assert Enum.count(LazyHTML.query(document, ".case-request details.request-evidence")) == 1
    assert Enum.empty?(LazyHTML.query(document, ".request-evidence[open]"))
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
      href: "/episodes/example/requests?attempt=retained",
      timing: [],
      sections: [
        section("instructions", "Responder instructions", "Retained instructions <not HTML>"),
        section("context", "Messages and selected context", %{"inputs" => [%{"text" => "Hi"}]}),
        section("request", "Submitted prompt", "retained raw input")
      ]
    }

    html = render_episode(snapshot, [input])
    assert html =~ "Model briefing"
    assert html =~ "Responder instructions"
    assert LazyHTML.from_fragment(html) |> LazyHTML.text() =~ "Briefing sources"
    assert html =~ "Host-authored instructions"
    assert html =~ "Episode input history"
    assert html =~ "Retained instructions &lt;not HTML&gt;"
    refute html =~ "<not HTML>"
    assert html =~ "$.instructions"
    assert html =~ "$.work.inputs"
    assert Enum.empty?(LazyHTML.from_fragment(html) |> LazyHTML.query(".request-evidence[open]"))

    assert Enum.empty?(LazyHTML.from_fragment(html) |> LazyHTML.query(".prompt-source[open]"))

    assert Enum.count(
             LazyHTML.from_fragment(html)
             |> LazyHTML.query(".prompt-assembly > details")
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
            href: "/episodes/ingress-input%3Amissing",
            sections: [
              %{id: "candidate", title: "Decision", source_kind: :admission, artifact: artifact}
            ]
          }
        )

      refute html =~ "Conversational reply"
      assert html =~ "Routing result"
    end
  end

  test "the outcome shortcut lands on the reply and elapsed time uses minutes and seconds" do
    # Jumping past the answer left the operator at a bookkeeping footer instead.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, snapshot} = Projection.episode(episode.key)
    at = snapshot.trace.received_at

    reply = %{
      id: "accepted-reply",
      at: DateTime.add(at, 84),
      actor: "Responder",
      text: "Hi! How can I help?",
      available: true
    }

    snapshot =
      snapshot
      |> put_in([:trace, :case_file, :conversation], [reply])
      |> put_in([:trace, :case_file, :awaiting_reply], false)
      |> put_in([:episode, :updated_at], reply.at)

    html = render_episode(snapshot, [])
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, ".case-actions > a") |> LazyHTML.attribute("href") == [
             "#story-message-accepted-reply"
           ]

    assert LazyHTML.query(document, ".episode-metrics") |> LazyHTML.text() =~ "1m 24s"

    assert LazyHTML.query(document, "#story-message-accepted-reply .case-message-text")
           |> LazyHTML.text() == "Hi! How can I help?"

    refute html =~ "End of retained execution"
  end

  test "model labels separate the saved profile without guessing a missing target" do
    assert EpisodeRequest.model("codex:gpt-5.6-sol/high@emisar") == %{
             name: "gpt-5.6-sol/high",
             account: "codex · emisar"
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
      actor: "Responder",
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

      assert LazyHTML.query(document, ".case-actions > a") |> LazyHTML.attribute("href") == [
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

  defp render_request(kind, phase, sections) do
    render_component(&EpisodeRequest.render/1,
      request: %{
        id: "recorded-request",
        source_kind: kind,
        phase: phase,
        target: "codex:gpt-5.6-terra/medium@emisar",
        timing: [],
        coverage: "Retained only",
        href: "/episodes/example/requests",
        sections: sections
      }
    )
  end

  defp section(id, title, value),
    do: %{id: id, title: title, source_kind: :work, artifact: InspectionRedactor.artifact(value)}

  defp render_episode(snapshot, items),
    do:
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: %{items: items, truncated: false},
        requests: nil,
        params: %{}
      )
end
