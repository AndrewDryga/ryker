defmodule Responder.ControlPlane.ModelRequestsTest do
  use Responder.DataCase, async: true
  import Phoenix.LiveViewTest
  alias Responder.Admission.Attempt
  alias Responder.ControlPlane.ConversationLab
  alias Responder.ControlPlane.{EpisodePage, InspectionRedactor, Projection}
  alias Responder.ControlPlane.{ModelRequests, RequestPage}
  alias Responder.Ingress.WorkProfile
  alias Responder.Work.{Custody, Submission, Turn}

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
        path: "/episodes/#{URI.encode_www_form(episode.key)}/requests"
      )

    assert html =~ "$.work.inputs"
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
    refute html =~ "xoxb-recorded-credential"
    assert html =~ "source message"
    assert html =~ "Not recorded"

    for section <- view.selected.sections do
      native =
        render_component(&RequestPage.render/1,
          view: view,
          params: %{"section" => section.id},
          path: "/episodes/#{URI.encode_www_form(episode.key)}/requests"
        )

      assert native =~ section.title
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
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
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
    assert html =~ "Messages supplied to this request"
    # The old flat prompt hid which host/context source shaped the answer.
    assert html =~ "data-source=\"instructions\""
    assert html =~ "Responder instructions"
    assert html =~ "$.instructions"
    assert html =~ "$.work.inputs"
    assert html =~ "$.work.responder_state_tools"
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

  test "timeline timing separates remote queue from execution before host acceptance exists" do
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

    assert result.timing == [
             %{label: "Coop queue", value: "2 ms"},
             %{label: "Agent execution", value: "60.0 s"},
             %{label: "Host processing", value: "1.0 s"}
           ]

    {:ok, snapshot} = Projection.episode(episode.key)

    html =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: timeline,
        requests: nil,
        params: %{}
      )

    assert html =~ "2 ms"
    assert html =~ "60.0 s"
    assert html =~ "Model execution"
    assert html =~ "Processing"
    assert html =~ "1.0 s"
    refute html =~ "Host validation and repair history"
    assert html =~ "Response to validate"
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
        decision_document: %{"action" => "reply", "work_class" => "conversational"}
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

      assert request.href =~ "generation=#{generation}"

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
      decision_document: %{"action" => "reply", "work_class" => "conversational"}
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
    refute Enum.any?(bounded.items, &(&1.coverage =~ "no retained submitted prompt"))
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
        path: "/episodes/retained/requests"
      )

    assert native =~ "This artifact has expired"
    refute native =~ "Host-authored retained instructions"
  end

  defp frozen_turn! do
    id = Ecto.UUID.generate()

    {:ok, %{episode: episode}} =
      Responder.Episodes.apply(
        Responder.Fixtures.Episodes.admit_input(%{
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
