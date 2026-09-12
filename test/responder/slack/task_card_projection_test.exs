defmodule Responder.Slack.TaskCardProjectionTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Fixtures.Publication, as: PublicationFixture
  alias Responder.Publication.{FollowupChangeset, Followups}
  alias Responder.Slack.{Renderer, TaskCardProjection}
  alias Responder.State.{Record, Records}
  alias Responder.Work.{Custody, Turn}

  @records Jason.decode!(File.read!("priv/card_lab/legacy_task_records.json"))

  test "a waiting task links the question when the host knows its workspace" do
    # The 2026-09-12 coverage measurement: a card that says an operator response
    # is required could not point at the question, because a Slack message link
    # needs the workspace origin and the host stored every part of it but that.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, _} = Custody.pin_episode(episode.id, "read-only", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("question-link", 60, :work)

    {:ok, _record} =
      Records.create(Records.token(claim.turn), "question-link", "input_request", %{
        "choices" => [],
        "question" => "Which project hosts this deployment?",
        "remember" => nil
      })

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:question-link",
      payload: %{
        "title" => "Link the question",
        "repository" => "responder",
        "prompt" => "Ask something answerable."
      }
    }

    assert {:ok, without} = TaskCardProjection.build(source)
    assert without.document["task_card"]["question_url"] == nil
  end

  test "a confirmed task with no turn yet reads as queued, not working" do
    # The 2026-09-12 coverage measurement: between confirming a task and a
    # worker being asked for anything, the card said "Working". Nothing was.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:queued",
      payload: %{
        "title" => "Wait for a worker",
        "repository" => "responder",
        "prompt" => "Do the thing once a worker is free."
      }
    }

    assert {:ok, projection} = TaskCardProjection.build(source)
    assert projection.document["task_card"]["status"] == "queued"
  end

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

  test "a blocked publication names the branch it is blocked on" do
    # The 2026-09-12 coverage measurement: the blocked card carries the material
    # cause but not the branch, so an operator reading "PR creation is blocked"
    # cannot tell which of the task's branches is stuck without opening the web
    # console, which this installation does not publish a URL for.
    %{publication: publication, episode: episode} = PublicationFixture.published!("branch-fact")

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:branch-fact",
      payload: %{
        "title" => "Name the blocked branch",
        "repository" => "responder",
        "prompt" => "Name the blocked branch on the card."
      }
    }

    assert {:ok, projection} = TaskCardProjection.build(source)
    assert projection.document["task_card"]["publication"]["branch"] == publication.branch_ref
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

  # A gate that could not start is never publishable, but its snapshot is exact,
  # so an operator may open it as an explicitly unverified draft. The moment that
  # draft existed the card forgot why: "✓ Self-review and checks", "Draft PR
  # created. Open it to review the changes.", and — once CI settled — "Review and
  # merge ← 🙋 your turn" on a change no required check had ever run against.
  test "a draft opened on an unrun gate never reads as a checked change" do
    %{episode: episode, publication: publication} =
      PublicationFixture.published!("unrun-gate",
        gate: "startup_error",
        gate_error: "docker: command not found"
      )

    assert publication.status == :published
    assert publication.review_document["gate"] == "startup_error"

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:unrun-gate",
      payload: %{
        "title" => "Bump the hosted runner",
        "repository" => "responder",
        "prompt" => "Bump the internal hosted runner from 0.23.1 to 0.27.0."
      }
    }

    assert {:ok, opened} = TaskCardProjection.build(source)
    task = opened.document["task_card"]

    assert stage(opened, "self_review")["state"] == "failed"
    assert stage(opened, "self_review")["detail"] == "docker: command not found"

    # The pull request exists and stays reachable; only the check is missing.
    assert stage(opened, "draft_pr")["state"] == "completed"
    assert stage(opened, "draft_pr")["url"] == "https://github.com/acme/responder/pull/91"
    assert task["publication"]["controls"] == ["open", "check"]
    assert task["publication"]["unverified"] == "docker: command not found"
    refute "publish" in task["publication"]["controls"]

    assert {:ok, rendered} = Renderer.render(opened.document)
    json = Jason.encode!(rendered)
    assert json =~ "! Self-review and checks · docker: command not found"
    assert json =~ "the checks still haven't finished (docker: command not found)"
    assert json =~ "Open PR"
    refute json =~ "Create draft PR"

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

    # CI on the exact published head is its own stage and may well be green. It
    # is not the trusted gate, so it cannot hand the task to a reviewer.
    assert stage(checked, "ci")["state"] == "completed"
    assert stage(checked, "ci")["detail"] == "8/8"
    assert stage(checked, "self_review")["state"] == "failed"
    assert stage(checked, "review_and_merge")["state"] == "pending"
    refute stage(checked, "review_and_merge")["your_turn"]
    refute Jason.encode!(elem(Renderer.render(checked.document), 1)) =~ "your turn"

    # The retained snapshot keeps its own changes page, so local work that is not
    # in the pull request stays readable.
    assert "view_diff" in task["controls"]
  end

  # "Keep any existing PR link, clearly identifying its older snapshot." A card
  # that says only "Draft PR created. Open it to review the changes." above a
  # working copy the host could not keep offers an older snapshot as the current
  # state of the change.
  test "a held workspace keeps an earlier draft's link and says which snapshot it is" do
    %{episode: episode, publication: publication} = PublicationFixture.published!("held-draft")

    # Force this episode's own turn into the harvested hosted-runner shape: a
    # completed worker whose working copy the host could not snapshot. The
    # projection still reads it from the database, and the closed-session variant
    # is covered end to end in Responder.State.TaskOffersTest.
    {1, _rows} =
      Repo.update_all(
        from(turn in Turn, where: turn.episode_id == ^episode.id),
        set: [
          last_error_code: "work_execution_blocked",
          last_error_detail:
            "invalid_work_executor: {:invalid_work_executor, :workspace_checkpoint_api}",
          status: :blocked
        ]
      )

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:held-draft",
      payload: %{
        "title" => "Bump the hosted runner",
        "repository" => "responder",
        "prompt" => "Bump the internal hosted runner from 0.23.1 to 0.27.0."
      }
    }

    assert {:ok, projection} = TaskCardProjection.build(source)
    task = projection.document["task_card"]

    assert task["action_needed"] =~
             "Draft PR ##{publication.pull_request_number} stays open, but it is an earlier snapshot without this work."

    refute task["action_needed"] =~ "Nothing was published"

    assert stage(projection, "draft_pr")["state"] == "stale"
    assert stage(projection, "draft_pr")["url"] == publication.pull_request_url

    assert stage(projection, "draft_pr")["detail"] ==
             "##{publication.pull_request_number} · earlier snapshot, newer work not saved"

    # The link survives; the controls that would act on a snapshot nobody has do not.
    assert "open" in task["publication"]["controls"]
    refute "publish" in task["publication"]["controls"]
    refute "view_diff" in task["controls"]
    assert "recovery" in task["controls"]
  end

  defp stage(projection, stage) do
    Enum.find(projection.document["task_card"]["stages"], &(&1["stage"] == stage))
  end
end
