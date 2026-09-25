defmodule Ryker.ControlPlane.ModelRequestsTest do
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest
  alias Ryker.Admission.Attempt
  alias Ryker.ControlPlane.ConversationLab
  alias Ryker.ControlPlane.{EpisodePage, EpisodeRequest, InspectionRedactor, Projection}
  alias Ryker.ControlPlane.{ModelRequests, RequestPage}
  alias Ryker.Ingress.{InputCustodyTransition, WorkProfile}
  alias Ryker.Work.{Custody, Submission, Turn}

  test "inspection reads the frozen request and distinguishes instructions from provider-owned context" do
    {episode, turn, original} = frozen_turn!()
    assert {:ok, view} = ModelRequests.project(episode.key, %{})
    assert view.selected.id == turn.id
    instructions = Enum.find(view.selected.sections, &(&1.id == "instructions"))

    assert instructions.artifact.text ==
             "Host-authored retained instructions for this submission."

    raw = Enum.find(view.selected.sections, &(&1.id == "request"))
    assert raw.artifact.sha256 == :crypto.hash(:sha256, original) |> Base.encode16(case: :lower)
    assert view.selected.coverage =~ "Coop wrapper"

    html =
      render_component(&RequestPage.render/1,
        view: view,
        params: %{},
        path: "/timeline/#{URI.encode_www_form(episode.key)}"
      )

    refute LazyHTML.from_fragment(html) |> LazyHTML.text() =~ "$.work.inputs"
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
    refute html =~ "xoxb-recorded-credential"
    assert html =~ "source message"
    assert html =~ "Not recorded"
    refute html =~ "Artifact identity"
    refute html =~ "Original retained bytes"
    refute html =~ raw.artifact.sha256

    identity =
      LazyHTML.from_fragment(html)
      |> LazyHTML.query("details.document-provenance[id^=request-identity-]")

    assert identity |> LazyHTML.query("summary") |> LazyHTML.text() |> String.trim() ==
             "Request identity"

    assert LazyHTML.text(identity) =~ "Execution policy"
    assert LazyHTML.text(identity) =~ view.selected.policy

    assert identity
           |> LazyHTML.query("button[data-copy-value]")
           |> LazyHTML.attribute("data-copy-value") == [view.selected.id]

    refute LazyHTML.text(identity) =~ "Request fingerprint"
    refute LazyHTML.text(identity) =~ view.selected.fingerprint

    refute LazyHTML.text(identity) =~ "Model call identity and policy"

    for section <- view.selected.sections do
      native =
        render_component(&RequestPage.render/1,
          view: view,
          params: %{"section" => section.id},
          path: "/timeline/#{URI.encode_www_form(episode.key)}"
        )

      expected_title =
        case section.id do
          "request" -> "Full submitted request"
          "validation" -> "Response checks"
          _ -> section.title
        end

      assert native =~ expected_title
      # Existing "Inspect accepted answer" links must open the requested artifact,
      # not bury it below instructions and raw submissions after removing the tabs.
      assert native
             |> LazyHTML.from_document()
             |> LazyHTML.query(".inspector-document")
             |> LazyHTML.attribute("id")
             |> hd() == "selected-#{turn.id}-#{section.id}"

      assert native =~ "attempt=#{turn.id}"
      refute native =~ "<script>"
      refute native =~ "xoxb-recorded-credential"
    end
  end

  test "a request cannot be inspected through another episode" do
    {episode, _turn, _prompt} = frozen_turn!()
    assert :not_found == ModelRequests.project(episode.key, %{"attempt" => Ecto.UUID.generate()})
    assert :not_found == ModelRequests.project(episode.key, %{"attempt" => "not-a-uuid"})
  end

  test "the full submitted request groups exact prompt text and output contract as collapsed components" do
    # The full-request disclosure previously left the contract as an unrelated
    # open block, while the technical inspector showed only the prompt text.
    {episode, turn, _original} = frozen_turn!()
    {:ok, view} = ModelRequests.project(episode.key, %{})

    # On the Timeline the prompt body loads when its disclosure is opened, so
    # this asks for the opened view of the same artifact the reader would get.
    {:ok, collapsed} = ModelRequests.timeline(episode.key, %{})
    prompt_id = "work-#{turn.id}-request"

    assert Enum.find(
             Enum.flat_map(collapsed.items, & &1.sections),
             &(&1.id == "request")
           ).artifact.state == :collapsed

    {:ok, timeline} = ModelRequests.timeline(episode.key, %{"disclosed" => [prompt_id]})
    request = Enum.find(timeline.items, &(&1.id == "request-#{turn.id}"))
    prompt = Enum.find(request.sections, &(&1.id == "request")).artifact.text
    contract = Enum.find(request.sections, &(&1.id == "contract")).artifact.text

    for html <- [
          render_component(&EpisodeRequest.render/1, request: request),
          render_component(&RequestPage.render/1,
            view: view,
            params: %{},
            path: "/timeline/#{URI.encode_www_form(episode.key)}"
          )
        ] do
      document = LazyHTML.from_document(html)
      full = LazyHTML.query(document, ".final-prompt")
      assert Enum.count(full) == 1

      assert LazyHTML.text(full) =~ "Full submitted request"

      # The retained submission is the page's subject and reads as a plain
      # section; its components inside it stay collapsed.
      assert Enum.empty?(LazyHTML.query(full, ".prompt-source[open]"))

      for {id, title, text} <- [
            {"request", "Prompt text", prompt},
            {"contract", "Response format", contract}
          ] do
        component = LazyHTML.query(full, ".prompt-source[data-source='#{id}']")
        assert Enum.count(component) == 1
        assert LazyHTML.query(component, "summary") |> LazyHTML.text() =~ title
        assert LazyHTML.query(component, "summary") |> LazyHTML.text() =~ ~r/≈ [\d,]+ tokens/
        refute LazyHTML.text(component) =~ "Raw text"

        assert LazyHTML.query(component, ".submitted-prompt-formatted code")
               |> LazyHTML.text()
               |> Jason.decode!() == Jason.decode!(text)
      end

      prompt_component = LazyHTML.query(full, ".prompt-source[data-source=request]")
      refute LazyHTML.text(prompt_component) =~ "Recorded when the request was sent"
      refute LazyHTML.text(full) =~ "Recorded with this request"
      assert LazyHTML.text(prompt_component) =~ "Sensitive values are hidden in this view"
      refute LazyHTML.text(prompt_component) =~ "Retained submission"
      refute LazyHTML.text(prompt_component) =~ "exact retained prompt text"
      refute LazyHTML.text(full) =~ "alongside"
      assert LazyHTML.text(full) |> String.downcase() =~ "provider"
      ids = LazyHTML.query(document, "[id]") |> LazyHTML.attribute("id")
      assert ids == Enum.uniq(ids)
      refute html =~ "xoxb-recorded-credential"
    end

    # On the page whose subject is this request, it is a section with a heading.
    # It had been a disclosure held permanently open, whose summary then had to
    # be made unfocusable so it would stop behaving like a control nobody could
    # use — three workarounds for not being the element it already was.
    page =
      LazyHTML.from_document(
        render_component(&RequestPage.render/1,
          view: view,
          params: %{},
          path: "/timeline/#{URI.encode_www_form(episode.key)}"
        )
      )

    assert Enum.count(LazyHTML.query(page, "section.final-prompt")) == 1
    assert Enum.empty?(LazyHTML.query(page, "details.final-prompt"))

    assert page
           |> LazyHTML.query(".final-prompt > .document-heading h4")
           |> LazyHTML.text() =~ "Full submitted request"
  end

  test "validation history shows each recorded check and its violations without inventing response bodies" do
    # Same host-history fields recorded by Custody.prepare_validation. The
    # response bodies are deliberately absent; a history receipt is not a body.
    {episode, turn, _original} = frozen_turn!()

    rejected = %{
      "candidate_attempt" => 1,
      "candidate_sha256" => String.duplicate("a", 64),
      "intent_fingerprint" => String.duplicate("b", 64),
      "parse" => "JSON object",
      "response_bytes" => 100,
      "verdict" => "reject",
      "violations" => ["not ready", "<script>unsafe violation text</script>"],
      "recorded_at" => DateTime.to_iso8601(turn.inserted_at)
    }

    accepted = %{
      rejected
      | "candidate_attempt" => 2,
        "candidate_sha256" => String.duplicate("c", 64),
        "verdict" => "accept",
        "violations" => []
    }

    turn |> Ecto.Changeset.change(validation_history: [rejected, accepted]) |> Repo.update!()
    {:ok, view} = ModelRequests.project(episode.key, %{})

    html =
      render_component(&RequestPage.render/1,
        view: view,
        params: %{},
        path: "/timeline/#{URI.encode_www_form(episode.key)}"
      )

    document = LazyHTML.from_document(html)
    attempts = LazyHTML.query(document, ".validation-attempt")
    assert LazyHTML.attribute(attempts, "data-candidate-attempt") == ["1", "2"]
    assert LazyHTML.text(Enum.at(attempts, 0)) =~ "Attempt 1 rejected"
    assert LazyHTML.text(Enum.at(attempts, 0)) =~ "not ready"
    assert LazyHTML.text(Enum.at(attempts, 1)) =~ "Attempt 2 accepted"
    assert LazyHTML.text(Enum.at(attempts, 1)) =~ "JSON object"
    assert LazyHTML.text(Enum.at(attempts, 1)) =~ "100 bytes"
    assert LazyHTML.text(attempts) =~ "Response body not retained for this attempt"
    refute LazyHTML.text(attempts) =~ rejected["candidate_sha256"]
    refute html =~ "<script>"
    refute LazyHTML.text(attempts) =~ "Response sent"
    assert Enum.count(LazyHTML.query(document, ".artifact-validation[open]")) == 1
    assert Enum.empty?(LazyHTML.query(document, ".validation-raw[open]"))
    raw = Enum.find(view.selected.sections, &(&1.id == "validation")).artifact.text
    assert LazyHTML.query(document, ".validation-raw pre") |> LazyHTML.text() == raw
    assert Repo.get!(Turn, turn.id).validation_history == [rejected, accepted]
  end

  test "partial or malformed validation records do not become confident verdicts" do
    for artifact <- [
          InspectionRedactor.artifact(nil, expired: true),
          InspectionRedactor.artifact(%{"history" => "unavailable"}),
          InspectionRedactor.artifact(%{"history" => [nil]}),
          InspectionRedactor.artifact(%{
            "history" => [
              %{"candidate_attempt" => 1, "verdict" => "accept", "violations" => ["not ready"]}
            ]
          }),
          InspectionRedactor.artifact(%{
            "history" => [
              %{"candidate_attempt" => 1, "verdict" => "reject", "violations" => "not a list"}
            ]
          }),
          InspectionRedactor.artifact(
            %{"history" => [%{"candidate_attempt" => 1, "verdict" => "accept"}]},
            max_bytes: 30
          )
        ] do
      html =
        render_component(&RequestPage.artifact/1,
          section: %{
            id: "validation",
            title: "Host validation and repair history",
            artifact: artifact
          },
          prefix: "unavailable"
        )

      refute html =~ "passed checks"
      refute html =~ "Response sent"
      assert html =~ "Validation details" or html =~ "This artifact has expired"
    end
  end

  test "a validation receipt links only the exact retained response attempt" do
    # Reuse the harvested Airflow response. Even identical response text does
    # not prove an older attempt's body remains in the latest-candidate slot.
    candidate =
      "test/ryker/evals/fixtures/airflow_after_observation_window.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("candidate")
      |> InspectionRedactor.artifact()

    history =
      for attempt <- [1, 2] do
        %{
          "candidate_attempt" => attempt,
          "candidate_sha256" => candidate.sha256,
          "verdict" => "accept",
          "violations" => []
        }
      end

    for retained <- [
          candidate,
          %{candidate | truncated: true},
          %{candidate | sha256: String.duplicate("d", 64)}
        ] do
      validation = %{
        id: "validation",
        title: "Host validation and repair history",
        artifact: InspectionRedactor.artifact(%{"history" => history, "candidate_attempt" => 2})
      }

      document =
        render_component(&RequestPage.artifact/1,
          section: validation,
          sections: [validation, %{id: "candidate", artifact: retained}],
          prefix: "checks"
        )
        |> LazyHTML.from_document()

      attempts = LazyHTML.query(document, ".validation-attempt")
      assert Enum.count(attempts) == 2
      assert Enum.empty?(LazyHTML.query(Enum.at(attempts, 0), "a"))

      expected = if retained.sha256 == candidate.sha256, do: ["#checks-candidate-body"], else: []

      assert Enum.at(attempts, 1) |> LazyHTML.query("a") |> LazyHTML.attribute("href") == expected

      # Chromium scrolls to a closed details element without opening it. The
      # link must target its retained body so native fragment navigation reveals it.
      rendered_candidate =
        render_component(&RequestPage.artifact/1,
          section: %{id: "candidate", title: "Response to validate", artifact: retained},
          prefix: "checks"
        )
        |> LazyHTML.from_document()

      assert Enum.empty?(LazyHTML.query(rendered_candidate, "#checks-candidate[open]"))

      assert Enum.count(
               LazyHTML.query(rendered_candidate, "#checks-candidate #checks-candidate-body")
             ) == 1
    end
  end

  test "prompt provenance uses submitted work fields rather than an adjacent context copy" do
    {episode, turn, _original} = frozen_turn!()
    # A source-labelled viewer must not call a neighboring document model input.
    submission = put_in(turn.submission, ["context", "inputs"], [])
    turn |> Ecto.Changeset.change(submission: submission) |> Repo.update!()
    {:ok, view} = ModelRequests.project(episode.key, %{})
    context = Enum.find(view.selected.sections, &(&1.id == "context"))
    assert context.artifact.text =~ "source message"

    submission = Map.put(submission, "prompt", "unstructured historical prompt")
    turn |> Ecto.Changeset.change(submission: submission) |> Repo.update!()
    {:ok, view} = ModelRequests.project(episode.key, %{})

    assert Enum.find(view.selected.sections, &(&1.id == "context")).artifact.state ==
             :not_recorded

    assert Enum.find(view.selected.sections, &(&1.id == "request")).artifact.text =~
             "historical prompt"
  end

  test "inline briefing retains the entire submitted context past sixteen kilobytes" do
    # The replay hid most of the frozen admission context behind 'Partial display'.
    {episode, turn, original} = frozen_turn!()
    prompt = Jason.decode!(original)

    context =
      Map.put(prompt["work"], "large_context", String.duplicate("retained context ", 12_000))

    submission =
      Map.put(turn.submission, "prompt", Jason.encode!(Map.put(prompt, "work", context)))

    turn |> Ecto.Changeset.change(submission: submission) |> Repo.update!()

    # The prompt body is lazy on the Timeline; open it, because the point of
    # this test is that opening it gives the whole retained context back.
    {:ok, timeline} =
      ModelRequests.timeline(episode.key, %{"disclosed" => ["work-#{turn.id}-request"]})

    request = Enum.find(timeline.items, &(&1.id == "request-#{turn.id}"))

    for id <- ["context", "request"] do
      artifact = Enum.find(request.sections, &(&1.id == id)).artifact
      refute artifact.truncated
      assert {:ok, _} = Jason.decode(artifact.text)
    end
  end

  test "the continuous timeline includes frozen instructions and context together with bounded redaction" do
    {episode, turn, _prompt} = frozen_turn!()
    assert {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    assert request = Enum.find(timeline.items, &(&1.id == "request-#{turn.id}"))
    assert request.execution_mode == :live
    assert Enum.any?(request.sections, &(&1.id == "instructions"))
    assert Enum.any?(request.sections, &(&1.id == "context"))
    text = Enum.map_join(request.sections, " ", &(&1.artifact.text || ""))
    assert text =~ "Host-authored retained instructions"
    assert text =~ "source message"
    refute text =~ "xoxb-recorded-credential"
    assert timeline.truncated == false
    assert :not_found == ModelRequests.timeline("absent", %{})

    {:ok, snapshot} = Projection.episode(episode.key)

    html =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: timeline,
        requests: nil,
        params: %{}
      )

    assert html =~ "Host-authored retained instructions"
    assert html =~ "Messages"
    refute html =~ "Messages supplied to this request"
    # The old flat prompt hid which host/context source shaped the answer.
    assert html =~ "data-source=\"instructions\""
    assert html =~ "System prompt"
    # A live run is the normal case; only an evaluation run is called out.
    refute html =~ "Run mode"
    refute html =~ "never delivered"
    visible = LazyHTML.from_document(html) |> LazyHTML.text()
    refute visible =~ "$.instructions"
    refute visible =~ "$.work.inputs"
    refute visible =~ "$.work.responder_state_tools"
    assert html =~ "data-source=\"inputs\""
    assert html =~ "source message &lt;script&gt;"
    refute html =~ "aria-label=\"Request contents\""
    refute html =~ "xoxb-recorded-credential"
    ids = html |> LazyHTML.from_document() |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")
    assert ids == Enum.uniq(ids)

    # Millisecond timestamps can tie; kernel sequence 10 must not precede 9.
    [step | _] = snapshot.trace.steps
    steps = for sequence <- [9, 10], do: %{step | id: "kernel-#{sequence}"}
    snapshot = put_in(snapshot, [:trace, :steps], steps)

    tied =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: timeline,
        requests: nil,
        params: %{}
      )

    assert tied
           |> LazyHTML.from_document()
           |> LazyHTML.query(".case-event")
           |> LazyHTML.attribute("id") == ["event-kernel-9", "event-kernel-10"]
  end

  test "a model call carries the purpose its policy is bound to" do
    # A briefing explains its model by what the call was for. The purpose is
    # the settings binding that selected the Coop policy; the policy's own name
    # stays in the request inspector.
    {episode, turn, _prompt} = frozen_turn!()

    Repo.insert!(%Ryker.Settings.PolicyBinding{
      id: Ecto.UUID.generate(),
      purpose: :conversational,
      scope_kind: :installation,
      scope_ref: "",
      policy_name: "policy:inspection",
      policy_digest: String.duplicate("a", 64),
      verified_by: :import
    })

    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    request = Enum.find(timeline.items, &(&1.id == "request-#{turn.id}"))

    assert request.model_choice == %{
             purpose: :conversational,
             scope_kind: :installation,
             scope_ref: "",
             settings: false
           }
  end

  test "a work result says where its time went before Ryker accepted it" do
    # The card listed "Coop queue", "Agent execution" and "Host processing"
    # beside each other; the time before the model ran, often the longest
    # part, was not on it at all.
    {episode, turn, _prompt} = frozen_turn!()
    started = DateTime.add(turn.inserted_at, 2)
    finished = DateTime.add(started, 60)

    turn
    |> Ecto.Changeset.change(
      timing_recorded: true,
      remote_queued_at: DateTime.add(started, -2, :millisecond),
      remote_started_at: started,
      remote_finished_at: finished,
      usage_queued_ms: 2,
      usage_provider_ms: 60_000,
      usage_host_ms: 1_000
    )
    |> Repo.update!()

    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    result = Enum.find(timeline.items, &(&1.id == "request-#{turn.id}-result"))
    assert result.at == finished

    # Not accepted yet: the time so far, and no total that pretends it ended.
    assert Enum.map(result.run.segments, &{&1.kind, &1.ms}) == [prepare: 2_000, model: 60_000]
    assert result.run.total_ms == nil

    {:ok, snapshot} = Projection.episode(episode.key)

    html =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: timeline,
        requests: nil,
        params: %{}
      )

    # One short two-column table, read top to bottom.
    rows =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#request-#{turn.id}-result dl.call-run > div")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))

    assert "Preparing and waiting for the worker 2.0 s" in rows
    assert "Model 1 min" in rows
    refute html =~ "Agent execution"
    refute html =~ "Host validation and repair history"
    assert html =~ "Raw model response"
  end

  test "a retried routing call names the failure that ended the attempt before it" do
    # Andrew, 2026-09-24: "Conversational reply · Attempt 2" gave no hint why
    # there was a second attempt. The first had failed a whole card earlier.
    {episode, _turn, original} = frozen_turn!()

    {:ok, profile} =
      WorkProfile.new(%{
        policy: "inspection-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    {:ok, %{entry: entry}} = ConversationLab.send_message(Ecto.UUID.generate(), "Hi", profile)

    entry =
      entry
      |> Ecto.Changeset.change(
        episode_id: episode.id,
        status: :decided,
        decision_action: :reply,
        decision_ref: "decision:#{entry.id}",
        decision_fingerprint: String.duplicate("a", 64),
        execution_generation: 2,
        decision_document: %{
          "action" => "reply",
          "repository_source" => nil,
          "work_class" => "conversational"
        }
      )
      |> Repo.update!()

    failed_at = entry.inserted_at

    Repo.insert!(%Attempt{
      input_id: entry.id,
      generation: 1,
      policy: "inspection-test",
      policy_digest: String.duplicate("a", 64),
      phase: "response_received",
      milestones: %{"response_received" => DateTime.to_iso8601(failed_at)},
      submission: %{"prompt" => original},
      response: %{"error_code" => "acp_protocol_error", "state" => "failed"}
    })

    Repo.insert!(%InputCustodyTransition{
      input_id: entry.id,
      sequence: 90,
      kind: :retry_scheduled,
      occurred_at: DateTime.add(failed_at, 1),
      generation: 1,
      attempt: 1,
      error_code: "acp_protocol_error"
    })

    Repo.insert!(%Attempt{
      input_id: entry.id,
      generation: 2,
      policy: "inspection-test",
      policy_digest: String.duplicate("a", 64),
      phase: "committed",
      milestones: %{"response_received" => DateTime.to_iso8601(DateTime.add(failed_at, 30))},
      submission: %{"prompt" => original}
    })

    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    second = Enum.find(timeline.items, &(&1.id == "admission-#{entry.id}-2-result"))

    assert %{generation: 1, href: href, summary: "acp protocol error"} = second.retried_after
    assert href == "#admission-#{entry.id}-1-result"

    first = Enum.find(timeline.items, &(&1.id == "admission-#{entry.id}-1-result"))
    assert first.retried_after == nil

    {:ok, snapshot} = Projection.episode(episode.key)

    html =
      render_component(&EpisodePage.render/1, snapshot: snapshot, timeline: timeline, params: %{})

    retry =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#admission-#{entry.id}-2-result .request-retry")

    assert LazyHTML.text(retry) =~ "Retried after attempt 1 failed: acp protocol error."
    assert LazyHTML.query(retry, "a") |> LazyHTML.attribute("href") == [href]
  end

  test "a truncated context remains readable inline instead of becoming an empty document" do
    artifact =
      InspectionRedactor.artifact(
        %{"inputs" => [String.duplicate("retained context ", 50)]},
        max_bytes: 100
      )

    html =
      render_component(&RequestPage.artifact/1,
        section: %{id: "context", title: "Frozen context", artifact: artifact},
        prefix: "truncated"
      )

    assert html =~ "truncated display"
    assert html =~ "[display truncated]"
    assert html =~ "retained context"
  end

  test "retained model output remains inspectable when remote timing is absent" do
    {episode, turn, _prompt} = frozen_turn!()
    # Telemetry omission must not hide a rejected or still-pending model result.
    turn
    |> Ecto.Changeset.change(validation_history: [%{"verdict" => "rejected"}])
    |> Repo.update!()

    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    assert result = Enum.find(timeline.items, &(&1.id == "request-#{turn.id}-result"))
    assert result.at == nil
    assert Enum.any?(result.sections, &(&1.artifact.text && &1.artifact.text =~ "rejected"))
    {:ok, snapshot} = Projection.episode(episode.key)

    html =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: timeline,
        requests: nil,
        params: %{},
        csrf_token: "test"
      )

    {briefing, _} = :binary.match(html, "id=\"request-#{turn.id}\"")
    {response, _} = :binary.match(html, "id=\"request-#{turn.id}-result\"")
    assert response > briefing
  end

  test "timeline retains each admission generation and marks missing older requests honestly" do
    {episode, _turn, original} = frozen_turn!()

    {:ok, profile} =
      WorkProfile.new(%{
        policy: "inspection-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    {:ok, %{entry: entry}} = ConversationLab.send_message(Ecto.UUID.generate(), "Hi", profile)

    entry =
      entry
      |> Ecto.Changeset.change(
        episode_id: episode.id,
        status: :decided,
        decision_action: :reply,
        decision_ref: "decision:#{entry.id}",
        decision_fingerprint: String.duplicate("a", 64),
        execution_generation: 2,
        decision_document: %{
          "action" => "reply",
          "repository_source" => nil,
          "work_class" => "conversational"
        }
      )
      |> Repo.update!()

    {:ok, missing} = ModelRequests.timeline(episode.key, %{})
    assert missing_request = Enum.find(missing.items, &(&1.id == "admission-#{entry.id}-2"))
    assert missing_request.coverage =~ "no retained submitted prompt"

    for generation <- 1..2 do
      Repo.insert!(%Attempt{
        input_id: entry.id,
        generation: generation,
        policy: "inspection-test",
        policy_digest: String.duplicate("a", 64),
        phase: "committed",
        milestones: %{"response_received" => DateTime.to_iso8601(entry.inserted_at)},
        submission: %{"prompt" => original},
        measurements: %{"usage_queued_ms" => 2}
      })
    end

    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})

    for generation <- 1..2 do
      assert request =
               Enum.find(timeline.items, &(&1.id == "admission-#{entry.id}-#{generation}"))

      assert request.href ==
               "/timeline/#{URI.encode_www_form(episode.key)}#admission-#{entry.id}-#{generation}"

      assert result =
               Enum.find(timeline.items, &(&1.id == "admission-#{entry.id}-#{generation}-result"))

      decision = Enum.find(result.sections, &(&1.id == "candidate"))
      assert decision.artifact.state == if(generation == 2, do: :retained, else: :not_recorded)
      assert result.at == entry.inserted_at
    end

    # A frequently retried input can consume the whole window. Older retained
    # prompts must be omitted with the bounded-history notice, never called missing.
    {:ok, %{entry: newer}} = ConversationLab.send_message(Ecto.UUID.generate(), "Hi", profile)

    newer
    |> Ecto.Changeset.change(
      episode_id: episode.id,
      execution_generation: 21,
      status: :decided,
      decision_action: :reply,
      decision_ref: "decision:#{newer.id}",
      decision_fingerprint: String.duplicate("a", 64),
      decision_document: %{
        "action" => "reply",
        "repository_source" => nil,
        "work_class" => "conversational"
      }
    )
    |> Repo.update!()

    for generation <- 1..21 do
      Repo.insert!(%Attempt{
        input_id: newer.id,
        generation: generation,
        policy: "inspection-test",
        policy_digest: String.duplicate("a", 64),
        submission: %{"prompt" => original}
      })
    end

    {:ok, bounded} = ModelRequests.timeline(episode.key, %{})
    assert bounded.truncated
    assert bounded.call_history.more == 2
    refute Enum.any?(bounded.items, &(&1.coverage =~ "no retained submitted prompt"))

    {:ok, snapshot} = Projection.episode(episode.key)

    html =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: bounded,
        params: %{}
      )

    assert html =~ "Show earlier requests"
    assert html =~ "?calls=2"

    {:ok, expanded} = ModelRequests.timeline(episode.key, %{"calls" => "2"})
    refute expanded.truncated
    assert expanded.call_history.more == nil
    assert expanded.call_history.shown > bounded.call_history.shown
  end

  test "a blocked input shows the attempt that ran, not one that has not started" do
    # A provider failure moves the input to its next attempt and clears the
    # frozen context. The page drew that attempt anyway: a second "Routing
    # briefing" with every section "Not recorded", for a call that never ran.
    {_episode, _turn, original} = frozen_turn!()

    {:ok, profile} =
      WorkProfile.new(%{
        policy: "inspection-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    {:ok, %{entry: entry}} = ConversationLab.send_message(Ecto.UUID.generate(), "Howdy", profile)

    Repo.insert!(%Attempt{
      input_id: entry.id,
      generation: 1,
      policy: "inspection-test",
      policy_digest: String.duplicate("a", 64),
      phase: "response_received",
      submission: %{"prompt" => original},
      response: %{"error_code" => "acp_protocol_error", "state" => "failed"}
    })

    entry
    |> Ecto.Changeset.change(status: :blocked, execution_generation: 2, admission_context: nil)
    |> Repo.update!()

    {:ok, view} = ModelRequests.project_input(entry.id, %{})

    requests =
      view.timeline |> Enum.map(& &1.id) |> Enum.filter(&String.starts_with?(&1, "admission-"))

    assert "admission-#{entry.id}-1" in requests
    refute Enum.any?(requests, &String.starts_with?(&1, "admission-#{entry.id}-2"))
  end

  test "pruned request content is expired rather than silently reconstructed" do
    {episode, turn, _prompt} = frozen_turn!()
    import Ecto.Query

    Repo.update_all(from(t in Turn, where: t.id == ^turn.id),
      set: [submission: %{"retention" => "pruned"}, operational_pruned_at: DateTime.utc_now()]
    )

    assert {:ok, view} = ModelRequests.project(episode.key, %{})
    assert Enum.find(view.selected.sections, &(&1.id == "request")).artifact.state == :expired

    native =
      render_component(&RequestPage.render/1,
        view: view,
        params: %{"section" => "request"},
        path: "/timeline/retained"
      )

    assert native =~ "This artifact has expired"
    refute native =~ "Host-authored retained instructions"
  end

  # Every other directory clamps a page past the end to the last page. This one
  # read the offset straight from the query string, so a stale bookmark or a
  # hand-edited `?page=` answered with an empty request list and no selected
  # request, beside a pager that said "page 99 of 1".
  test "a request page past the end is the last page, never an empty one" do
    {episode, turn, _prompt} = frozen_turn!()

    assert {:ok, view} = ModelRequests.project(episode.key, %{"page" => "99"})
    assert view.page == view.pages
    assert Enum.map(view.items, & &1.id) == [turn.id]
    assert view.selected.id == turn.id

    assert {:ok, first} = ModelRequests.project(episode.key, %{"page" => "0"})
    assert first.page == 1
    assert first.selected.id == turn.id

    assert {:ok, tools} =
             ModelRequests.project(episode.key, %{"attempt" => turn.id, "tools_page" => "40"})

    assert tools.selected.tools.page == tools.selected.tools.pages
  end

  defp frozen_turn! do
    id = Ecto.UUID.generate()

    {:ok, %{episode: episode}} =
      Ryker.Episodes.apply(
        Ryker.Fixtures.Episodes.admit_input(%{
          episode_id: id,
          episode_key: "inspection:#{id}",
          native_input_id: "input:#{id}",
          turn_ref: "turn:#{id}"
        })
      )

    {:ok, _session} =
      Custody.pin_episode(episode.id, "policy:inspection", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("inspection:test", 60, :work)

    context = %{
      "inputs" => [%{"text" => "source message <script>alert('x')</script>"}],
      "responder_state_tools" => ["validate_final"],
      "api_token" => "xoxb-recorded-credential"
    }

    original =
      Jason.encode!(%{
        "instructions" => "Host-authored retained instructions for this submission.",
        "work" => context
      })

    {:ok, submission} =
      Submission.new(context, original, %{"type" => "object"}, "inspection-test")

    {:ok, turn} =
      Custody.freeze_submission(episode.id, claim.turn.turn_ref, claim.lease_ref, submission)

    {episode, turn, original}
  end
end
