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

  alias Ryker.ControlPlane.{EpisodePage, EpisodeProjection, ImprovementRequests, ModelRequests}
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Improvement
  alias Ryker.Improvement.{AnalysisRun, Prompt}

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

    assert result.background.headline == "Prompt bug"
    assert result.background.reason == "Routing read the staging question as production."

    assert Enum.map(result.background.facts, &{&1.label, &1.value}) == [
             {"Finding", "Prompt bug"},
             {"Went wrong at", "Routing"},
             {"Should have", "Checks the staging database and says which checks it ran."},
             {"Confidence", "High"},
             {"What to fix", "Open the finding"}
           ]

    {:ok, snapshot} = EpisodeProjection.fetch(reply.episode.key)
    {:ok, timeline} = ModelRequests.timeline(reply.episode.key, %{})

    chapter =
      render_component(&EpisodePage.render/1, snapshot: snapshot, timeline: timeline, params: %{})
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#feedback")

    text = chapter |> LazyHTML.text() |> String.replace(~r/\s+/, " ")
    assert text =~ "Self-analysis briefing"
    assert text =~ "Prompt bug"
    assert text =~ "Routing read the staging question as production."
    assert text =~ "Full submitted request"

    # The evidence reads as what happened, never as unlabelled fields, and
    # none of routing's rows for parts a self-analysis is never sent.
    assert text =~ "The evidence"
    assert text =~ "What was said"
    assert text =~ "Is the staging database healthy?"
    refute text =~ "Other fields"
    refute text =~ "$.context"
    assert text =~ "Changed by the person; the words it had first are not kept."
    assert text =~ "Not sent: it quoted words that were later changed, deleted or forgotten"
    refute text =~ "Prompt forgotten"
    refute text =~ "Custom instructions"
    refute text =~ "Continuation candidates"
    refute text =~ "Thread summary"
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
    assert result.background.headline == "No usable answer"

    assert result.background.facts == [
             %{
               label: "Outcome",
               value: "Not used",
               note: "the answer did not match the format asked for"
             }
           ]
  end

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

    candidate = Improvement.for_request({:episode, reply.episode.id})

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
        work: [],
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
