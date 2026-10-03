defmodule Ryker.ControlPlane.ModelRequestsTest do
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest
  alias Ryker.Admission.Attempt
  alias Ryker.ControlPlane.ConversationLab
  alias Ryker.ControlPlane.{EpisodePage, EpisodeProjection, EpisodeRequest}
  alias Ryker.ControlPlane.ModelRequests
  alias Ryker.CoopFleet.JobTemplates
  alias Ryker.Ingress.{InputCustodyTransition, WorkProfile}
  alias Ryker.InspectionRedactor
  alias Ryker.Settings
  alias Ryker.Work.{Custody, Session, Submission, Turn}

  test "a request reads the frozen submission and distinguishes instructions from provider-owned context" do
    {episode, turn, original} = frozen_turn!()
    request = timeline_request(episode, turn)
    instructions = Enum.find(request.sections, &(&1.id == "instructions"))

    assert instructions.artifact.text ==
             "Host-authored retained instructions for this submission."

    raw = Enum.find(request.sections, &(&1.id == "request"))
    assert raw.artifact.sha256 == :crypto.hash(:sha256, original) |> Base.encode16(case: :lower)

    html = render_component(&EpisodeRequest.render/1, request: request)
    full = html |> LazyHTML.from_fragment() |> LazyHTML.query(".final-prompt")

    assert LazyHTML.text(full) =~
             "Provider-owned instructions and wrappers are not part of this record."

    refute html =~ raw.artifact.sha256
    refute html =~ "xoxb-recorded-credential"
  end

  test "a request that held a credential shows it removed, with no secrets disclaimer anywhere" do
    # Andrew, 2026-09-26: "i also do not want to add disclaimers like 'Secrets
    # redacted' anywhere". The request page carried a standing SECRETS
    # REDACTED label, each redacted body said "Retained · redacted", the
    # Timeline's full request said "Secrets redacted" and its prompt row said
    # "Sensitive values are hidden in this view". The credential is still
    # removed before anything renders; the pages just stop saying so.
    {episode, turn, _original} = frozen_turn!()
    request = timeline_request(episode, turn)
    assert Enum.find(request.sections, &(&1.id == "request")).artifact.redacted

    html = render_component(&EpisodeRequest.render/1, request: request)
    text = html |> LazyHTML.from_document() |> LazyHTML.text()
    refute html =~ "xoxb-recorded-credential"
    assert text =~ "Full submitted request"
    refute text =~ ~r/secrets redacted/i
    refute text =~ ~r/· redacted/i
    refute text =~ ~r/sensitive values are hidden/i
  end

  test "a request cannot be inspected through another episode" do
    {episode, _turn, _prompt} = frozen_turn!()
    {_other, other_turn, _prompt} = frozen_turn!()

    for attempt <- [other_turn.id, Ecto.UUID.generate(), "not-a-uuid"] do
      assert {:ok, timeline} = ModelRequests.timeline(episode.key, %{"attempt" => attempt})
      refute Enum.any?(timeline.items, &String.contains?(&1.id, other_turn.id))
    end
  end

  test "the full submitted request groups exact prompt text and output contract as collapsed components" do
    # The full-request disclosure previously left the contract as an unrelated
    # open block, while the technical inspector showed only the prompt text.
    {episode, turn, _original} = frozen_turn!()

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

    html = render_component(&EpisodeRequest.render/1, request: request)
    document = LazyHTML.from_document(html)
    full = LazyHTML.query(document, ".final-prompt")
    assert Enum.count(full) == 1

    # The full request is a section with a heading. It had been a disclosure
    # held permanently open, whose summary then had to be made unfocusable so
    # it would stop behaving like a control nobody could use — three
    # workarounds for not being the element it already was.
    assert Enum.count(LazyHTML.query(document, "section.final-prompt")) == 1
    assert Enum.empty?(LazyHTML.query(document, "details.final-prompt"))
    assert LazyHTML.query(full, "header h4") |> LazyHTML.text() =~ "Full submitted request"

    # Its components inside it stay collapsed.
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
    refute LazyHTML.text(prompt_component) =~ "Retained submission"
    refute LazyHTML.text(prompt_component) =~ "exact retained prompt text"
    refute LazyHTML.text(full) =~ "alongside"
    assert LazyHTML.text(full) |> String.downcase() =~ "provider"
    ids = LazyHTML.query(document, "[id]") |> LazyHTML.attribute("id")
    assert ids == Enum.uniq(ids)
    refute html =~ "xoxb-recorded-credential"
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
    html = timeline_html(episode)
    document = LazyHTML.from_document(html)
    first = LazyHTML.query(document, "#event-turn-#{turn.id}-validation-1")
    second = LazyHTML.query(document, "#event-turn-#{turn.id}-validation-2")

    assert LazyHTML.text(first) =~ "Sent back to fix"
    assert LazyHTML.text(first) =~ "not ready"
    assert LazyHTML.text(second) =~ "Answer validated"

    for check <- [first, second] do
      assert LazyHTML.text(check) =~ "Response body not retained for this attempt"
      assert Enum.empty?(LazyHTML.query(check, ".candidate-response"))
    end

    refute html =~ rejected["candidate_sha256"]
    refute html =~ "<script>"
    assert Repo.get!(Turn, turn.id).validation_history == [rejected, accepted]
  end

  test "a validation receipt links only the exact retained response attempt" do
    # Reuse the harvested Airflow response. Even identical response text does
    # not prove an older attempt's body remains in the latest-candidate slot.
    candidate =
      "test/ryker/evals/fixtures/airflow_after_observation_window.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("candidate")
      |> Jason.encode!()

    digest = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)
    {episode, turn, _original} = frozen_turn!()

    history =
      for attempt <- [1, 2] do
        %{
          "candidate_attempt" => attempt,
          "candidate_sha256" => digest,
          "verdict" => "accept",
          "violations" => []
        }
      end

    # No per-attempt archive: only the latest answer, still in its slot, can be linked.
    for {latest, linked} <- [{candidate, true}, {candidate <> "\n", false}] do
      turn
      |> Ecto.Changeset.change(
        candidate: latest,
        candidate_attempt: 2,
        candidate_sha256: digest,
        validation_history: history
      )
      |> Repo.update!()

      document = episode |> timeline_html() |> LazyHTML.from_document()
      first = LazyHTML.query(document, "#event-turn-#{turn.id}-validation-1")
      second = LazyHTML.query(document, "#event-turn-#{turn.id}-validation-2")

      assert Enum.empty?(LazyHTML.query(first, ".candidate-evidence a"))
      assert LazyHTML.text(first) =~ "Response body not retained for this attempt"

      # The latest answer is read on its model call's result card.
      expected = if linked, do: ["request-#{turn.id}-result"], else: []

      fragments =
        second
        |> LazyHTML.query(".candidate-evidence a")
        |> LazyHTML.attribute("href")
        |> Enum.map(&URI.parse(&1).fragment)

      assert fragments == expected

      for fragment <- fragments do
        assert document |> LazyHTML.query_by_id(fragment) |> Enum.count() == 1
      end
    end
  end

  test "prompt provenance uses submitted work fields rather than an adjacent context copy" do
    {episode, turn, _original} = frozen_turn!()
    # A source-labelled viewer must not call a neighboring document model input.
    submission = put_in(turn.submission, ["context", "inputs"], [])
    turn |> Ecto.Changeset.change(submission: submission) |> Repo.update!()
    request = timeline_request(episode, turn)
    context = Enum.find(request.sections, &(&1.id == "context"))
    assert context.artifact.text =~ "source message"

    submission = Map.put(submission, "prompt", "unstructured historical prompt")
    turn |> Ecto.Changeset.change(submission: submission) |> Repo.update!()
    request = timeline_request(episode, turn)

    assert Enum.find(request.sections, &(&1.id == "context")).artifact.state == :not_recorded

    assert Enum.find(request.sections, &(&1.id == "request")).artifact.text =~
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

    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

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
    refute visible =~ "$.work.controller_tools"
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

  test "only exact current template identity explains a retained model call" do
    {episode, turn, _prompt} = frozen_turn!()
    {:ok, snapshot} = Settings.initialize("control-plane:local")
    template = Enum.find(JobTemplates.from_settings(snapshot), &(&1.policy_name == "ryker-chat"))

    Repo.get!(Session, turn.session_id)
    |> Ecto.Changeset.change(policy: template.policy_name, policy_digest: template.policy_digest)
    |> Repo.update!()

    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    request = Enum.find(timeline.items, &(&1.id == "request-#{turn.id}"))

    assert request.model_choice == %{
             purpose: :conversational,
             scope_kind: :installation,
             scope_ref: "",
             settings: true
           }

    assert {:ok, _} =
             Settings.save_work(
               %{conversation_models: ["codex:gpt-5.6-terra/high@default"]},
               snapshot.installation.revision,
               "control-plane:local"
             )

    {:ok, changed} = ModelRequests.timeline(episode.key, %{})
    historical = Enum.find(changed.items, &(&1.id == request.id))
    assert historical.policy == request.policy
    assert historical.policy_digest == request.policy_digest
    refute historical.model_choice.settings
    assert historical.model_choice.purpose == nil
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

    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

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

    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

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
      render_component(&EpisodeRequest.render/1,
        request: %{
          id: "request-truncated",
          source_kind: :work,
          phase: :submission,
          target: "codex:gpt-5.6-terra/medium@emisar",
          sections: [
            %{id: "context", title: "Frozen context", source_kind: :work, artifact: artifact}
          ]
        }
      )

    assert html =~ "Partial display"
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
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

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
    assert missing_prompt?(missing_request)

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
               "/timeline/#{episode.id}#admission-#{entry.id}-#{generation}"

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
    refute Enum.any?(bounded.items, &missing_prompt?/1)

    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

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

    request = timeline_request(episode, turn)
    assert Enum.find(request.sections, &(&1.id == "request")).artifact.state == :expired

    html = render_component(&EpisodeRequest.render/1, request: request)
    assert html =~ "Expired."
    refute html =~ "Host-authored retained instructions"
  end

  # A request that says its prompt was never recorded, rather than showing one.
  defp missing_prompt?(request) do
    match?(
      %{artifact: %{state: :not_recorded}},
      Enum.find(request[:sections] || [], &(&1.id == "request"))
    )
  end

  # The work request the timeline shows for `turn`, its prompt body opened.
  defp timeline_request(episode, turn) do
    {:ok, timeline} =
      ModelRequests.timeline(episode.key, %{"disclosed" => ["work-#{turn.id}-request"]})

    Enum.find(timeline.items, &(&1.id == "request-#{turn.id}"))
  end

  defp timeline_html(episode) do
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    {:ok, snapshot} = EpisodeProjection.fetch(episode.key)

    render_component(&EpisodePage.render/1,
      snapshot: snapshot,
      timeline: timeline,
      requests: nil,
      params: %{}
    )
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
      "controller_tools" => ["validate_final"],
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
