defmodule Responder.Slack.TaskCardProjectionTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Fixtures.Publication, as: PublicationFixture
  alias Responder.Publication.{FollowupChangeset, Followups}
  alias Responder.Slack.{Renderer, TaskCardProjection}
  alias Responder.State.{Record, Records}
  alias Responder.Work.Custody

  @records Jason.decode!(File.read!("priv/card_lab/legacy_task_records.json"))

  test "subtask transitions refresh the stage rows and the durable card fingerprint" do
    # The old projection retained only the last progress summary plus a flat
    # goal list, so a subtask moving under its stage never refreshed the pinned
    # Slack card and a plan of nine read as one anonymous "N of M completed".
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, _} = Custody.pin_episode(episode.id, "read-only", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("card-details", 60, :work)

    {:ok, _session} =
      Custody.bind_session(
        episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        claim.session.generation,
        claim.session.create_generation,
        "coop-session-card-details"
      )

    token = Records.token(claim.turn)

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:details",
      payload: %{
        "title" => "Retained portal investigation",
        "repository" => "emisar",
        "prompt" => @records["portal_goals"]["goals"] |> hd() |> Map.fetch!("requested_outcome")
      }
    }

    {:ok, before} = TaskCardProjection.build(source)
    stages = before.document["task_card"]["stages"]

    assert Enum.map(stages, & &1["stage"]) ==
             ~w(workspace_setup planning implementation self_review draft_pr ci review_and_merge)

    refute Enum.any?(stages, &(&1["detail"] == "0/0 subtasks"))
    refute Map.has_key?(before.document["task_card"], "goals")
    refute Map.has_key?(before.document["task_card"], "progress")

    for {progress, index} <- Enum.with_index(Enum.take(@records["runner_task"]["progress"], 5)) do
      assert {:ok, _} =
               Records.create(
                 token,
                 "progress-#{index}",
                 "progress",
                 Map.take(progress, ~w(phase summary))
               )
    end

    [retained | _] = @records["portal_goals"]["goals"]

    goal =
      retained
      |> Map.take(~w(id requested_outcome completion_contract))
      |> Map.merge(%{
        "kind" => "check",
        "authority" => "read_only",
        "required" => false,
        "stage" => "implementation"
      })

    assert {:ok, _} = Records.create(token, "goal", "goal", goal)

    assert {:ok, _} =
             Records.create(token, "goal-working", "goal_state", %{
               "goal_id" => goal["id"],
               "state" => "working"
             })

    assert {:ok, active} = TaskCardProjection.build(source)
    implementation = stage(active, "implementation")
    assert implementation["state"] == "running"
    assert implementation["detail"] == "0/1 subtasks"
    assert [%{"state" => "working", "outcome" => outcome}] = implementation["subtasks"]
    assert outcome == goal["requested_outcome"]
    assert active.fingerprint != before.fingerprint
    assert {:ok, ^active} = TaskCardProjection.build(source)

    assert {:ok, _} =
             Records.create(token, "goal-complete", "goal_state", %{
               "goal_id" => goal["id"],
               "state" => "completed"
             })

    assert {:ok, complete} = TaskCardProjection.build(source)
    # A completed stage keeps its name and count; the items it finished stay in
    # the episode's full history instead of padding the card.
    assert stage(complete, "implementation")["detail"] == "1/1 subtasks"
    assert stage(complete, "implementation")["subtasks"] == []
    assert complete.fingerprint != active.fingerprint

    # Feedback shares the progress record kind but is not a public work update.
    # Publishing it here would replace the live card with internal product notes.
    assert {:ok, _} =
             Records.create(token, "feedback", "progress", %{
               "phase" => "feedback:ux:suggestion",
               "summary" => "Internal feedback must not replace task progress"
             })

    assert {:ok, after_feedback} = TaskCardProjection.build(source)
    refute Jason.encode!(after_feedback.document) =~ "Internal feedback"
    assert after_feedback.fingerprint == complete.fingerprint

    long_request =
      put_in(source.payload["prompt"], String.duplicate(source.payload["prompt"], 25))

    assert {:ok, request_card} = TaskCardProjection.build(long_request)
    assert String.length(request_card.document["task_card"]["request"]) == 600
    assert String.ends_with?(request_card.document["task_card"]["request"], "…")

    # Completed history must not conceal the next active subtask on long plans.
    for index <- 2..9 do
      next_goal = Map.put(goal, "id", "goal-#{index}")

      next_goal =
        if index == 9,
          do: Map.update!(next_goal, "requested_outcome", &String.duplicate(&1, 6)),
          else: next_goal

      assert {:ok, _} = Records.create(token, "goal-#{index}", "goal", next_goal)

      assert {:ok, _} =
               Records.create(token, "goal-state-#{index}", "goal_state", %{
                 "goal_id" => next_goal["id"],
                 "state" => if(index == 9, do: "working", else: "completed")
               })
    end

    assert {:ok, many_goals} = TaskCardProjection.build(source)
    implementation = stage(many_goals, "implementation")
    assert implementation["detail"] == "8/9 subtasks"
    assert implementation["subtasks_total"] == 9

    assert [%{"id" => "goal-9", "state" => "working", "current" => true} | _] =
             implementation["subtasks"]

    assert implementation["subtasks"] |> hd() |> Map.fetch!("outcome") |> String.ends_with?("…")

    assert {:ok, rendered} = Renderer.render(many_goals.document)
    json = Jason.encode!(rendered)
    assert json =~ "Implementation · 8/9 subtasks"
    assert json =~ "Showing 6 of 9 subtasks"
  end

  test "draft, CI and merge facts come from publication custody and its follow-up" do
    # The follow-up row already retained checks and merge receipts, but the
    # Slack card never read it: a merged task still said "Draft pull request
    # published" with no CI row at all.
    %{episode: episode, publication: publication} = PublicationFixture.published!("stage-facts")

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:stage-facts",
      payload: %{
        "title" => "Implement stage facts",
        "repository" => "responder",
        "prompt" => "Make imports restart-safe."
      }
    }

    assert {:ok, published} = TaskCardProjection.build(source)
    task = published.document["task_card"]
    assert task["repository_url"] == "https://github.com/acme/responder"
    assert stage(published, "draft_pr")["state"] == "completed"
    assert stage(published, "draft_pr")["detail"] == "#91"
    assert stage(published, "draft_pr")["url"] == "https://github.com/acme/responder/pull/91"
    # No check has been observed yet, so the draft is not a human handoff.
    assert stage(published, "ci")["state"] == "waiting"
    assert stage(published, "review_and_merge")["state"] == "pending"
    refute stage(published, "review_and_merge")["your_turn"]

    {:ok, followup} =
      Repo.transaction(fn ->
        Followups.ensure_published_in_transaction(publication, DateTime.utc_now())
      end)

    followup
    |> FollowupChangeset.update(%{
      checks_failed: 0,
      checks_passed: 8,
      checks_state: "passing",
      checks_total: 8
    })
    |> Repo.update!()

    assert {:ok, checked} = TaskCardProjection.build(source)
    assert stage(checked, "ci")["state"] == "completed"
    assert stage(checked, "ci")["detail"] == "8/8"
    assert stage(checked, "review_and_merge")["state"] == "waiting"
    assert stage(checked, "review_and_merge")["your_turn"]
    assert checked.fingerprint != published.fingerprint

    followup
    |> FollowupChangeset.update(%{
      checks_passed: 8,
      checks_state: "passing",
      checks_total: 8,
      merge_sha: String.duplicate("c", 40),
      merged_at: DateTime.utc_now(),
      pr_state: "merged"
    })
    |> Repo.update!()

    assert {:ok, merged} = TaskCardProjection.build(source)
    assert stage(merged, "review_and_merge")["state"] == "completed"
    assert stage(merged, "review_and_merge")["detail"] == "merged"
    refute stage(merged, "review_and_merge")["your_turn"]

    assert {:ok, rendered} = Renderer.render(merged.document)
    json = Jason.encode!(rendered)
    assert json =~ "✓ CI · 8/8"
    assert json =~ "✓ Review and merge · merged"
    assert json =~ "<https://github.com/acme/responder|responder>"
  end

  defp stage(projection, stage) do
    Enum.find(projection.document["task_card"]["stages"], &(&1["stage"] == stage))
  end
end
