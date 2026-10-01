defmodule Ryker.Slack.TaskCardProjectionTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Delivery.ChatCard
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Publication.Custody, as: PublicationCustody
  alias Ryker.Publication.{FollowupChangeset, Followups}
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.Slack.{Renderer, TaskCardProjection}
  alias Ryker.Work.{Custody, Turn}

  @records Jason.decode!(File.read!("testdata/slack/legacy_task_records.json"))

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
        "repository" => "ryker",
        "prompt" => "Ask something answerable."
      }
    }

    assert {:ok, without} = TaskCardProjection.build(source)
    assert without.document["task_card"]["question_url"] == nil
  end

  # Andrew, 2026-09-28: "why repo name is andrewdryga-emisar while it's
  # andrewdryga/emisar?" The card named the repository by the ref the task
  # offer recorded, not as it was added from GitHub.
  test "a task card names its repository as owner/repo, as it was added from GitHub" do
    now = DateTime.utc_now()

    Repo.insert_all(Ryker.Settings.Repository, [
      %{
        ref: "andrewdryga-emisar",
        github_repository: "AndrewDryga/emisar",
        inserted_at: now,
        updated_at: now
      }
    ])

    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: episode.id,
      confirmed_at: now,
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:named-repository",
      payload: %{
        "title" => "Fix the diagnostic log access",
        "repository" => "andrewdryga-emisar",
        "prompt" => "Fix it."
      }
    }

    assert {:ok, projection} = TaskCardProjection.build(source)
    assert projection.document["task_card"]["repository"] == "AndrewDryga/emisar"

    # One no longer added keeps the name the task recorded.
    gone = put_in(source.payload["repository"], "since-removed")
    assert {:ok, projection} = TaskCardProjection.build(gone)
    assert projection.document["task_card"]["repository"] == "since-removed"
  end

  # The request travels whole since 2026-09-28, and with it came what the host
  # appends for the Work: success checks, authority limits, and the Slack
  # references the task came from, which read on #test as
  # "Sources: slack-source:v1:T0BHXKZJVDX:C0BLU1GACKC:message:…". The card
  # shows what the person asked for, and the Work still gets all of it.
  test "a task card's request is what the person asked for, without the host's appended parts" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())

    asked =
      "Restore the diagnostic log reads that were denied.\n\nTrace the log action's requested view first."

    prompt =
      Enum.join(
        [
          asked,
          "Success checks: Log targeting and read grants align.; A focused commit is prepared.",
          "Authority limits: Edit only acme-api.; Do not deploy.",
          "Instruction: slack-source:v1:T123:C456:message:1790573171.598909",
          "Sources: slack-source:v1:T123:C456:message:1790573171.598909"
        ],
        "\n\n"
      )

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:request-only",
      payload: %{"title" => "Fix log access", "repository" => "acme-api", "prompt" => prompt}
    }

    assert {:ok, projection} = TaskCardProjection.build(source)
    assert projection.document["task_card"]["request"] == asked
    refute Jason.encode!(projection.document) =~ "slack-source"
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
        "repository" => "ryker",
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

    # Andrew, 2026-09-28: "why you trimmed text that is behind show more/less
    # anyways?" The request travels whole, up to what a task offer can hold;
    # Slack folds a long one and opening it shows all of it.
    long_request =
      put_in(source.payload["prompt"], String.duplicate(source.payload["prompt"], 25))

    assert {:ok, request_card} = TaskCardProjection.build(long_request)
    assert request_card.document["task_card"]["request"] == long_request.payload["prompt"]

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
    assert json =~ "*▸ Implementation* · 8/9 subtasks"
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
        "repository" => "ryker",
        "prompt" => "Name the blocked branch on the card."
      }
    }

    assert {:ok, projection} = TaskCardProjection.build(source)
    assert projection.document["task_card"]["publication"]["branch"] == publication.branch_ref
  end

  # Ryker ends a publication whose worker session closed, because that review
  # can never run, and records why (2026-09-25). The Slack card read "PR
  # preparation stopped" for it, the same words as a person's discard.
  test "a publication Ryker ended for a closed session says so on the task card" do
    %{episode: episode, publication: publication} =
      PublicationFixture.review_requested!("closed-session-card")

    assert {:ok, review} = PublicationCustody.claim_next("publication:closed-session-card", 60)
    assert review.publication.id == publication.id

    assert {:ok, %{status: :discarded}} =
             PublicationCustody.discard_unreviewable(
               publication.ref,
               review.lease_ref,
               :review_session_closed
             )

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:closed-session-card",
      payload: %{
        "title" => "Implement closed-session-card",
        "repository" => "ryker",
        "prompt" => "Implement the change."
      }
    }

    assert {:ok, projection} = TaskCardProjection.build(source)

    assert projection.document["task_card"]["publication"]["discarded_reason"] ==
             "review_session_closed"

    assert {:ok, rendered} = Renderer.render(projection.document)

    assert Jason.encode!(rendered) =~
             "the worker session holding these changes closed before they could be checked"
  end

  # 2026-09-30: after a refused publication grant the card offered "Retry publication", which
  # custody refuses for that code because the worker finished the publish as refused. The card
  # offers the recovery that works, and says the draft was not made.
  test "a refused publication grant offers a fresh review, never a retry that cannot work" do
    %{claim: work, publication: approved} = PublicationFixture.approved!("refused-grant-card")
    assert {:ok, claim} = PublicationCustody.claim_next("publication:refused-grant-card", 60)
    assert claim.publication.id == approved.id

    assert {:ok, _refused} =
             PublicationCustody.defer(
               approved.ref,
               claim.lease_ref,
               60,
               "publication_authorization_revoked",
               "The worker refused publication."
             )

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: work.episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:refused-grant-card",
      payload: %{
        "title" => "Implement refused-grant-card",
        "repository" => "ryker",
        "prompt" => "Implement the change."
      }
    }

    assert {:ok, projection} = TaskCardProjection.build(source)
    card = projection.document["task_card"]["publication"]
    assert card["controls"] == ["update", "discard"]

    assert {:ok, rendered} = Renderer.render(projection.document)
    json = Jason.encode!(rendered)
    assert json =~ "The draft PR wasn't created."
    refute json =~ "Retry"
    refute json =~ "Waiting for GitHub"

    # The live card said "needs operator attention: `publication_authorization_revoked`".
    assert projection.document["task_card"]["action_needed"] ==
             "Ryker couldn't get permission to publish this reviewed change."

    refute json =~ "publication_authorization_revoked"

    # Andrew, 2026-09-30, of "Discard candidate" with the "…" menu on its own row below it:
    # "can ... button be in the same row?"
    assert [row] = Enum.filter(rendered["blocks"], &(&1["type"] == "actions"))

    assert Enum.map(row["elements"], & &1["action_id"]) == [
             "ryker_task_update_publication",
             "ryker_task_discard_publication",
             "ryker_work_record"
           ]
  end

  # Manual test, 2026-10-01: once a draft pull request was closed on GitHub while Ryker updated
  # it, the task's Chat card read "Action needed :publication_existing_pull_request_changed",
  # beside "Work settled" and "Session 1", and its Slack card named the same code. Both say what
  # happened in words, and neither prints Ryker's own states.
  test "a draft changed on GitHub is said in words on the task card, without codes" do
    %{claim: work, publication: approved} = PublicationFixture.approved!("changed-on-github")
    assert {:ok, claim} = PublicationCustody.claim_next("publication:changed-on-github", 60)

    assert {:ok, _refused} =
             PublicationCustody.defer(
               approved.ref,
               claim.lease_ref,
               60,
               "publication_existing_pull_request_changed",
               ":publication_existing_pull_request_changed"
             )

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: work.episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:changed-on-github",
      payload: %{
        "kind" => "engineering",
        "title" => "Implement changed-on-github",
        "repository" => "ryker",
        "prompt" => "Implement the change."
      }
    }

    assert {:ok, projection} = TaskCardProjection.build(source)

    assert projection.document["task_card"]["action_needed"] =~
             "changed this draft's branch or pull request on GitHub"

    assert {:ok, rendered} = Renderer.render(projection.document)
    json = Jason.encode!(rendered)
    refute json =~ "publication_existing_pull_request_changed"

    # Discard is all the card offers here, and it said "Waiting for GitHub to confirm" under
    # "▸ Draft PR · creating the draft".
    assert projection.document["task_card"]["publication"]["controls"] == ["discard"]
    assert json =~ "The draft PR wasn't created."
    assert json =~ "■ Draft PR · changed on GitHub"
    refute json =~ "Waiting for GitHub"
    refute json =~ "creating the draft"

    assert {:ok, card} = ChatCard.project(source)
    assert Enum.map(card.details, &elem(&1, 0)) == ["Repository", "Action needed"]
    refute inspect(card.details) =~ "publication_existing_pull_request_changed"
  end

  # Andrew, 2026-09-30, of PR #2's card in AndrewDryga/test: "why do I even need to click to
  # review latest state?" A repository with no checks gives the same answer to every review, and
  # a newer finished run is reviewed without a click, so the button could only repeat the check.
  test "a change with no checks to run is offered as a draft without a re-check" do
    %{claim: work, publication: blocked} =
      PublicationFixture.reviewed!("no-checks-card", gate: "none")

    assert blocked.status == :blocked

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: work.episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:no-checks-card",
      payload: %{
        "title" => "Implement no-checks-card",
        "repository" => "ryker",
        "prompt" => "Implement the change."
      }
    }

    assert {:ok, projection} = TaskCardProjection.build(source)
    assert projection.document["task_card"]["publication"]["controls"] == ["publish", "discard"]

    assert {:ok, rendered} = Renderer.render(projection.document)
    json = Jason.encode!(rendered)

    assert json =~
             "I saved the change exactly as it is. I can open it as a draft PR marked unverified."

    refute json =~ "Review latest state"
    refute json =~ "review the latest state"
  end

  # A check that could not start may start next time, so that one keeps its re-check.
  test "a change whose checks could not start can still be checked again" do
    %{claim: work} =
      PublicationFixture.reviewed!("unstarted-checks-card",
        gate: "startup_error",
        gate_error: "docker: command not found"
      )

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: work.episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:unstarted-checks-card",
      payload: %{
        "title" => "Implement unstarted-checks-card",
        "repository" => "ryker",
        "prompt" => "Implement the change."
      }
    }

    assert {:ok, projection} = TaskCardProjection.build(source)

    assert projection.document["task_card"]["publication"]["controls"] ==
             ["publish", "update", "discard"]
  end

  # Andrew, 2026-09-30, after Review latest state: "Action needed: Draft pull-request work needs
  # operator attention: coop_worker_command_timeout. again!!" The review was running; Ryker's own
  # wait for it had ended, as it does for any review longer than the wait. Nothing needed a person.
  for code <- ~w(coop_worker_command_timeout coop_unavailable publication_review_generation_spent) do
    @in_flight_code code
    test "a review still running says it is checking, not that it needs attention (#{code})" do
      suffix = "in-flight-#{:erlang.phash2(@in_flight_code)}"
      %{episode: episode} = PublicationFixture.review_requested!(suffix)
      assert {:ok, claim} = PublicationCustody.claim_next("publication:#{suffix}", 60)

      assert {:ok, _deferred} =
               PublicationCustody.defer(
                 claim.publication.ref,
                 claim.lease_ref,
                 60,
                 @in_flight_code,
                 "{:#{@in_flight_code}, \"25d038fb\"}"
               )

      source = %Record{
        kind: "task_offer",
        status: :confirmed,
        confirmed_episode_id: episode.id,
        confirmed_at: DateTime.utc_now(),
        confirmed_by_actor_ref: "slack:user:U1",
        ref: "task-card:#{suffix}",
        payload: %{
          "title" => "Implement in-flight",
          "repository" => "ryker",
          "prompt" => "Implement the change."
        }
      }

      assert {:ok, projection} = TaskCardProjection.build(source)
      card = projection.document["task_card"]
      assert card["publication"]["controls"] == ["discard"]
      assert card["action_needed"] == nil

      assert {:ok, rendered} = Renderer.render(projection.document)
      json = Jason.encode!(rendered)
      assert json =~ "Checking the changes before creating a PR."
      refute json =~ @in_flight_code
      refute json =~ "Action needed"
      refute json =~ "Action required"
    end
  end

  # Andrew, 2026-09-28: "I clicked review latest state and now all actions are
  # gone and I can't do anything with the task?" For the minutes Coop checked
  # the change, the card offered no publication control at all.
  test "a change being checked can still be discarded from its task card" do
    %{episode: episode, publication: publication} =
      PublicationFixture.review_requested!("discard-while-checking")

    assert {:ok, _running} = PublicationCustody.claim_next("publication:discard-checking", 60)

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:discard-while-checking",
      payload: %{
        "title" => "Implement discard-while-checking",
        "repository" => "ryker",
        "prompt" => "Implement the change."
      }
    }

    assert {:ok, projection} = TaskCardProjection.build(source)
    card = projection.document["task_card"]["publication"]
    assert card["status"] == "review_pending"
    assert card["controls"] == ["discard"]
    assert card["recovery_generation"] == publication.recovery_generation

    assert {:ok, rendered} = Renderer.render(projection.document)
    json = Jason.encode!(rendered)
    assert json =~ "Checking the changes before creating a PR."
    assert json =~ "ryker_task_discard_publication"
  end

  test "a stopped task offers a resume bound to the turn it was rendered against" do
    # The card that offers Stop has to offer the way back, or stopping from
    # Slack means finishing from the control plane.
    %{episode: episode} = PublicationFixture.review_requested!("stopped-task")

    card_record = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:stopped-task",
      payload: %{
        "title" => "Fix parser retries",
        "repository" => "ryker",
        "prompt" => "Make the parser retry safely."
      }
    }

    {1, _rows} =
      Repo.update_all(
        from(turn in Turn, where: turn.episode_id == ^episode.id),
        set: [
          cancellation_intent: %{"action" => "block", "reason" => "operator stopped the run"},
          status: :blocked
        ]
      )

    assert {:ok, %{document: %{"task_card" => card}}} = TaskCardProjection.build(card_record)
    assert "resume" in card["controls"]

    turn = Repo.one!(from(turn in Turn, where: turn.episode_id == ^episode.id))

    assert card["resume_ref"] ==
             "#{card_record.ref}|#{Custody.recovery_fingerprint(turn)}"

    assert {:ok, rendered} = Renderer.render(%{"task_card" => card})

    assert Enum.any?(
             Enum.flat_map(rendered["blocks"], &Map.get(&1, "elements", [])),
             &(&1["action_id"] == "ryker_resume_work" and &1["value"] == card["resume_ref"])
           )
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
        "repository" => "ryker",
        "prompt" => "Make imports restart-safe."
      }
    }

    assert {:ok, published} = TaskCardProjection.build(source)
    task = published.document["task_card"]
    assert task["repository_url"] == "https://github.com/acme/ryker"
    assert stage(published, "draft_pr")["state"] == "completed"
    assert stage(published, "draft_pr")["detail"] == "#91"
    assert stage(published, "draft_pr")["url"] == "https://github.com/acme/ryker/pull/91"
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
    # The row links to the pull request it merged.
    assert json =~ "✓ <https://github.com/acme/ryker/pull/91|Review and merge> · merged"
    assert json =~ "<https://github.com/acme/ryker|ryker>"
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
        "repository" => "ryker",
        "prompt" => "Bump the internal hosted runner from 0.23.1 to 0.27.0."
      }
    }

    assert {:ok, opened} = TaskCardProjection.build(source)
    task = opened.document["task_card"]

    assert stage(opened, "self_review")["state"] == "failed"

    assert stage(opened, "self_review")["reason"] ==
             "The repository's checks couldn't start: docker: command not found."

    # The pull request exists and stays reachable; only the check is missing.
    assert stage(opened, "draft_pr")["state"] == "completed"
    assert stage(opened, "draft_pr")["url"] == "https://github.com/acme/ryker/pull/91"
    assert task["publication"]["controls"] == ["open"]

    assert task["publication"]["unverified"] ==
             "The repository's checks couldn't start: docker: command not found."

    refute "publish" in task["publication"]["controls"]

    assert {:ok, rendered} = Renderer.render(opened.document)
    json = Jason.encode!(rendered)

    assert json =~
             "*! Self-review and checks*\\n    The repository's checks couldn't start: docker: command not found."

    assert json =~ "Draft PR created from the saved change. It isn't verified"
    assert length(String.split(json, "command not found")) == 2

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
    # is covered end to end in Ryker.Records.TaskOffersTest.
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
        "repository" => "ryker",
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
