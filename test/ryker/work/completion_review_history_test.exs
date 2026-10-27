defmodule Ryker.Work.CompletionReviewHistoryTest do
  use Ryker.DataCase, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias Ryker.ControlPlane.{CompletionReviews, EpisodeRequest}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Work.CompletionReview.{Result, Run}
  alias Ryker.Work.{Custody, Session}

  test "retired reviewer history stays readable and its stopped session remains reclaimable" do
    # Removing execution must not erase the exact old prompt, judgment, attempt
    # reason or cleanup ownership, nor rebuild them from today's work state.
    id = Ecto.UUID.generate()

    {:ok, _} =
      Episodes.apply(EpisodeFixtures.admit_input(%{episode_id: id, episode_key: "history:#{id}"}))

    {:ok, _} = WorkSessions.pin_episode(id, "work-read-only", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("history:#{id}", 60, :work)
    result = File.read!("testdata/work/completion-review-last-correction.json")
    assert {:ok, judgment} = Result.parse(result)
    assert judgment["decision"] == "continue"

    prompt =
      Jason.encode!(%{
        "instructions" => "Historical review instructions.",
        "snapshot" => %{
          "candidate" => %{"message" => "The backup is still running."},
          "work" => %{"inputs" => %{"items" => []}},
          "previous_inputs" => [],
          "records" => [],
          "tool_observations" => %{"items" => []},
          "previous_reviews" => [],
          "request_input_available" => true,
          "dismissible_wait_refs" => [],
          "ledger_sha256" => "ledger",
          "progress_sha256" => "progress"
        }
      })

    digest = String.duplicate("a", 64)
    now = Repo.now!()

    run =
      Repo.insert!(%Run{
        turn_id: claim.turn.id,
        generation: 1,
        status: :applied,
        candidate_sha256: digest,
        ledger_sha256: digest,
        progress_sha256: digest,
        policy: claim.session.policy,
        policy_digest: digest,
        prompt: prompt,
        prompt_sha256: Ryker.Crypto.sha256_hex(prompt),
        output_schema: %{},
        result: result,
        result_sha256: Ryker.Crypto.sha256_hex(result),
        started_at: now,
        remote_stopped_at: now,
        stop_receipt: %{},
        validation_receipt: %{}
      })

    session =
      Repo.insert!(%Session{
        execution_kind: :completion_review,
        completion_review_id: run.id,
        policy: run.policy,
        policy_digest: run.policy_digest,
        external_ref: "history:#{run.id}"
      })

    [briefing, response] = CompletionReviews.entries([claim.turn], [])
    assert briefing.owner == {:turn, claim.turn.id}
    assert response.owner == {:turn, claim.turn.id}
    assert hd(response.sections).artifact.text =~ judgment["reason"]
    html = render_component(&EpisodeRequest.render/1, request: briefing)
    assert html =~ "Historical review instructions."
    assert html =~ "Proposed answer"
    refute html =~ "Other fields"

    for kind <- [:admission, :learning, :completion_review] do
      initial = %{briefing | source_kind: kind, generations: 1}

      assert render_component(&EpisodeRequest.render/1, request: initial) ==
               render_component(&EpisodeRequest.render/1, request: %{initial | generations: 3})
    end

    assert {:ok, %{session: %{id: cleanup_id}}} =
             Ryker.Retention.Custody.claim_next("history-cleanup", 60)

    assert cleanup_id == session.id
    assert Repo.get!(Run, run.id).result == result

    # Old failures must still explain why their next attempt existed; they
    # must not be reinterpreted as a model's rejection after retirement.
    failed =
      run
      |> Ecto.Changeset.change(
        status: :rejected,
        result: nil,
        error_code: "completion_review_provider_failed",
        stop_receipt: %{"error_code" => "acp_protocol_error"}
      )
      |> Repo.update!()

    Repo.insert!(%{run | id: Ecto.UUID.generate(), generation: 2})
    history = CompletionReviews.entries([claim.turn], [])
    failure = Enum.find(history, &(&1.generation == 1 and &1.phase == :result))
    retry = Enum.find(history, &(&1.generation == 2 and &1.phase == :submission))
    assert failure.background.model_reason? == false
    assert failure.background.reason =~ "protocol error"
    assert retry.retried_after.href == "#completion-review-#{failed.id}-result"
    assert retry.retried_after.transition == "failed"
    assert retry.retried_after.summary == failure.background.reason
  end

  test "malformed retained judgments are not presented as valid decisions" do
    captured =
      File.read!("testdata/work/completion-review-last-correction.json") |> Jason.decode!()

    invalid = captured |> Map.put("decision", "complete") |> Jason.encode!()
    assert Result.parse(invalid) == {:error, :invalid_completion_review}
    assert Result.parse("Finished.") == {:error, :invalid_completion_review}
  end
end
