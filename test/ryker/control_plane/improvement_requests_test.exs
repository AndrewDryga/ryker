defmodule Ryker.ControlPlane.ImprovementRequestsTest do
  @moduledoc """
  Andrew, 2026-09-28, of the prompts behind every kind of work: "make sure we
  don't render one but send other one". Routing, Work and learning show the
  exact prompt they were sent on the Timeline; the self-analysis of a request
  a person was unhappy with had no card anywhere, so what it was told and what
  it answered could only be read from the database.
  """
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest
  alias Ryker.Accounting.Execution
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{EpisodePage, EpisodeProjection, ImprovementRequests, ModelRequests}
  alias Ryker.ControlPlane.Units
  alias Ryker.Crypto
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Improvement
  alias Ryker.Improvement.{AnalysisRun, Prompt}
  alias Ryker.Inspectors
  alias Ryker.Work.Activity

  @workspace "TSELFANALYSIS"

  test "a request's self-analysis shows the exact prompt it was sent and what it found" do
    %{reply: reply, prompt: prompt} = analyzed_request!()

    assert [briefing, result] = ImprovementRequests.entries(episode_id: reply.episode.id)

    submitted = Enum.find(briefing.sections, &(&1.id == "request"))
    assert submitted.artifact.state == :retained
    assert submitted.artifact.text == prompt

    assert Enum.map(briefing.sections, & &1.title) == [
             "Self-analysis instructions",
             "The evidence it was given",
             "Required output contract",
             "Submitted prompt"
           ]

    # The review leads with what went wrong; the category is a suspected
    # cause with its confidence, never the headline (approved 2026-10-15).
    assert %{
             title: "Review",
             meta: "Suspected cause: Ryker's instructions (high confidence)",
             what_went_wrong: "Routing read the staging question as production.",
             expected: "Checks the staging database and says which checks it ran.",
             attempts: %{count: 1, href: "#self-analysis-" <> _first}
           } = result.review

    refute Map.has_key?(result, :identity)

    {:ok, snapshot} = EpisodeProjection.fetch(reply.episode.key)
    {:ok, timeline} = ModelRequests.timeline(reply.episode.key, %{})

    chapter =
      render_component(&EpisodePage.render/1, snapshot: snapshot, timeline: timeline, params: %{})
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#feedback")

    text = chapter |> LazyHTML.text() |> String.replace(~r/\s+/, " ")
    assert text =~ "Self-analysis briefing"
    assert text =~ "Suspected cause: Ryker's instructions (high confidence)"
    refute text =~ "Prompt bug"
    assert text =~ "Routing read the staging question as production."
    assert text =~ "What Ryker should have done"
    assert text =~ "Full submitted request"

    # Attempt and worker IDs, fingerprints and receipts stay in the records.
    for internal <- ["Worker session", "Prompt fingerprint", "Validation and stop receipts"] do
      refute text =~ internal
    end

    assert chapter
           |> LazyHTML.query(".finding-review .finding-footer a")
           |> LazyHTML.attribute("href") ==
             [
               "/feedback/fix?candidate=#{run_candidate(reply)}#improvement-#{run_candidate(reply)}"
             ]

    # The evidence reads as what happened, never as unlabelled fields, and
    # none of routing's rows for parts a self-analysis is never sent.
    assert text =~ "The evidence"
    assert text =~ "What was said"
    assert text =~ "Is the staging database healthy?"
    refute text =~ "Other fields"
    refute text =~ "$.context"
    assert text =~ "Changed by the person; the words it had first are not kept."
    assert text =~ "Not sent: it quoted words that were later changed, deleted or forgotten"

    # Each Work turn's calls, with the error a refused one got, its
    # corrections, and the exact instructions it ran with.
    assert text =~ "controller-tools.get_work_state"
    assert text =~ "/limit (required): is required."
    assert text =~ "1 answer sent back"
    assert text =~ "Work instructions"
    assert text =~ "Finish the exact request."
    refute text =~ "Prompt forgotten"
    refute text =~ "Custom instructions"
    refute text =~ "Continuation candidates"
    refute text =~ "Thread summary"
  end

  # A self-analysis showed its saved prompt as the prompt its model was given;
  # its worker sent the output contract after it too. The session keeps the
  # worker's record of each send, as it has no other activity owner.
  test "a self-analysis shows each prompt its worker sent, checked against the prompt it saved" do
    %{reply: reply, prompt: prompt, run: run} = analyzed_request!()
    run = run |> Ecto.Changeset.change(coop_turn_id: "coop-turn-analysis") |> Repo.update!()
    assert {:ok, _session} = Improvement.FleetSession.ensure(run)
    assert {:ok, session} = Improvement.FleetSession.bind(run, "coop-analysis-sent")

    schema = CanonicalJSON.worker_encode!(run.output_schema)
    opening = "\n\n<coop-output-contract>\n<json-schema>"
    closing = "</json-schema>\n</coop-output-contract>"
    text = prompt <> opening <> schema <> closing

    record = %{
      "version" => 1,
      "state" => "sent",
      "text_sha256" => Crypto.sha256_hex(text),
      "text_bytes" => byte_size(text),
      "parts" => [
        digest_part("caller_prompt", prompt),
        text_part(opening),
        digest_part("output_schema", schema),
        text_part(closing)
      ],
      "blocks" => []
    }

    event = %{
      "id" => "event-analysis-1",
      "session_id" => "coop-analysis-sent",
      "sequence" => 1,
      "turn_id" => "coop-turn-analysis",
      "type" => "prompt.sent",
      "version" => 1,
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "payload" => record
    }

    assert {:ok, %{inserted: 1}} =
             Activity.ingest_fleet(session.id, "coop-analysis-sent", 0, [event])

    assert [briefing, _result] = ImprovementRequests.entries(episode_id: reply.episode.id)
    assert [%{title: "First message", matches?: true}] = briefing.sent
  end

  test "an attempt Ryker could not use says so in words, never as a code" do
    %{reply: reply, run: run} = analyzed_request!()

    run
    |> Ecto.Changeset.change(
      status: :rejected,
      result: ~s({"category":"sure"}),
      result_sha256: String.duplicate("c", 64),
      error_code: "invalid_improvement_result"
    )
    |> Repo.update!()

    assert [_briefing, result] = ImprovementRequests.entries(episode_id: reply.episode.id)

    assert %{
             title: "No usable answer",
             meta: nil,
             what_went_wrong: nil,
             note: "Ryker did not use this answer: it did not match the format asked for.",
             finding_href: nil
           } = result.review
  end

  # The review's Model run is three groups (approved 2026-10-15): the model
  # and every attempt, where the time went, and the tokens and cost, then the
  # model's raw response with its format and size.
  test "a review's Model run reads its model, attempts, time, tokens and raw response" do
    %{reply: reply, run: run} = analyzed_request!()
    second = retried!(run)

    Repo.insert!(%Execution{
      kind: "improvement",
      source_id: second.id,
      generation: "2",
      transport: "slack",
      conversation_ref: "T1:C1",
      status: "succeeded",
      execution_mode: "live",
      recorded_at: DateTime.utc_now(),
      execution_target: "codex:gpt-5.6-sol/medium@emisar",
      usage_recorded: true,
      usage_input_tokens: 7_073,
      usage_cached_input_tokens: 20_000,
      usage_output_tokens: 261,
      usage_reasoning_tokens: 65,
      usage_cost_recorded: true,
      usage_cost_usd: Decimal.new("0.11"),
      timing_recorded: true,
      usage_queued_ms: 6,
      usage_provider_ms: 18_900
    })

    {:ok, snapshot} = EpisodeProjection.fetch(reply.episode.key)
    {:ok, timeline} = ModelRequests.timeline(reply.episode.key, %{})

    card =
      render_component(&EpisodePage.render/1, snapshot: snapshot, timeline: timeline, params: %{})
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[id='self-analysis-#{second.id}-result']")

    assert words(card, ".case-card-heading") =~ "Attempt 2"
    assert words(card, ".finding-run > summary") == "Model run 30 s · $0.11"

    assert group(card, "Model and attempts") ==
             "Model & attempts gpt-5.6-sol Medium reasoning 2 attempts View all attempts →"

    assert card |> LazyHTML.query(".run-attempts a") |> LazyHTML.attribute("href") ==
             ["#self-analysis-#{run.id}"]

    assert group(card, "Timing") ==
             "Timing Total 30 s Model 18.9 s Prepare, check, save 11.1 s Worker queue 6 ms"

    assert group(card, "Tokens and cost") ==
             "Tokens & cost Input tokens 27,073 Output tokens 261 Reasoning tokens 65 Cost $0.11"

    response = LazyHTML.query(card, ".finding-run details.json-disclosure")
    assert words(response, ".ui-disclosure-label") == "Raw model response"
    text = response |> LazyHTML.query("pre") |> LazyHTML.text()
    assert words(response, ".ui-disclosure-meta") == "JSON · #{Units.bytes(byte_size(text))}"
  end

  defp retried!(%AnalysisRun{} = run) do
    Repo.insert!(%{
      run
      | id: Ecto.UUID.generate(),
        generation: 2,
        inserted_at: DateTime.add(run.inserted_at, 60, :second),
        started_at: DateTime.add(run.started_at, 60, :second),
        remote_stopped_at: DateTime.add(run.started_at, 90, :second),
        updated_at: DateTime.add(run.started_at, 90, :second)
    })
  end

  defp group(card, label),
    do: words(card, ".run-group[aria-label='#{label}']")

  defp digest_part(kind, text),
    do: %{"kind" => kind, "sha256" => Crypto.sha256_hex(text), "bytes" => byte_size(text)}

  defp text_part(text),
    do: %{
      "kind" => "text",
      "text" => text,
      "sha256" => Crypto.sha256_hex(text),
      "bytes" => byte_size(text)
    }

  defp words(node, selector),
    do: node |> LazyHTML.query(selector) |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp run_candidate(reply),
    do: Inspectors.improvement_candidate({:episode, reply.episode.id}).id

  defp analyzed_request! do
    base = DateTime.to_unix(DateTime.utc_now()) - 600
    channel = "CSELF#{System.unique_integer([:positive])}"

    question =
      Answers.slack_message!(
        workspace: @workspace,
        channel: channel,
        text: "Is the staging database healthy?",
        ts: "#{base}.000100"
      )

    reply =
      Answers.work_reply!(
        question,
        "The production database is healthy.",
        "#{base + 60}.000100",
        DateTime.from_unix!((base + 60) * 1_000_000, :microsecond)
      )

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :reaction_added,
               value: "-1",
               actor_ref: "UALICE",
               source: "slack",
               source_ref: "slack-event:self-analysis-#{base}",
               occurred_at: DateTime.from_unix!((base + 120) * 1_000_000, :microsecond),
               request: {:episode, reply.episode.id}
             })

    candidate = Inspectors.improvement_candidate({:episode, reply.episode.id})

    prompt =
      %{
        request: %{"kind" => "work", "ended" => "answered"},
        conversation: [
          %{"from" => "person", "text" => nil, "note" => "edited by the person"},
          %{"from" => "person", "text" => "Is the staging database healthy?"}
        ],
        routing: [
          %{
            "decision" => "start_episode",
            "prompt" => nil,
            "answer" => nil,
            "model" => nil,
            "kept" => "forgotten"
          }
        ],
        work: [
          %{
            "started_at" => "2026-09-27T12:00:00Z",
            "status" => "settled",
            "error" => nil,
            "model" => "codex:gpt-5.6-sol/medium@personal",
            "instructions" => "instructions-1",
            "calls" => [
              %{
                "tool" => "controller-tools.get_work_state",
                "status" => "completed",
                "arguments" => "{}",
                "result" => nil,
                "error" => "invalid_arguments: 1 issue. /limit (required): is required."
              }
            ],
            "corrections" => [%{"attempt" => 1, "violations" => "[]"}],
            "outcome" => "complete",
            "answer" => "The production database is healthy."
          }
        ],
        instructions: [%{"id" => "instructions-1", "text" => "Finish the exact request."}],
        feedback: [%{"kind" => "reaction_added", "value" => "-1"}],
        omitted: []
      }
      |> Prompt.build()
      |> Prompt.render()

    at = DateTime.from_unix!((base + 400) * 1_000_000, :microsecond)

    run =
      Repo.insert!(%AnalysisRun{
        id: Ecto.UUID.generate(),
        candidate_id: candidate.id,
        generation: 1,
        status: :applied,
        policy: "ryker-learning",
        policy_digest: String.duplicate("a", 64),
        prompt: prompt,
        prompt_sha256: String.duplicate("b", 64),
        output_schema: Prompt.output_schema(),
        manifest: %{},
        started_at: at,
        result:
          Jason.encode!(%{
            "category" => "prompt_bug",
            "step" => "routing",
            "what_went_wrong" => "Routing read the staging question as production.",
            "expected" => "Checks the staging database and says which checks it ran.",
            "confidence" => "high"
          }),
        stop_receipt: %{"kind" => "terminal_turn"},
        remote_stopped_at: DateTime.add(at, 30, :second),
        inserted_at: at,
        updated_at: DateTime.add(at, 30, :second)
      })

    %{reply: reply, prompt: prompt, run: run}
  end
end
