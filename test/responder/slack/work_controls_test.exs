defmodule Responder.Slack.WorkControlsTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Fixtures.Publication, as: PublicationFixture
  alias Responder.Publication.{Followup, Publication}
  alias Responder.Repo

  alias Responder.Slack.{TaskCardChangeset, WorkControls, WorkRecord, WorkTarget}
  alias Responder.State.Records
  alias Responder.TestSupport.FakeWorkCoopAPI
  alias Responder.Work.Custody

  @now ~U[2026-08-28 12:00:00.000000Z]

  defmodule SlackAPI do
    def find_message(agent, channel_ref, thread_ref, delivery_ref) do
      Agent.get(agent, fn state ->
        Map.get(state.messages, {channel_ref, thread_ref, delivery_ref}, :not_found)
      end)
    end

    def post_message(agent, channel_ref, thread_ref, document, delivery_ref) do
      Agent.get_and_update(agent, fn state ->
        message_ref = "1787832999.000100"

        next =
          state
          |> put_in(
            [:messages, {channel_ref, thread_ref, delivery_ref}],
            {:ok, message_ref}
          )
          |> update_in([:posts], &[{channel_ref, thread_ref, document, delivery_ref} | &1])

        {{:ok, message_ref}, next}
      end)
    end

    def update_message(agent, channel_ref, message_ref, document, delivery_ref) do
      Agent.update(agent, fn state ->
        update_in(state, [:updates], &[{channel_ref, message_ref, document, delivery_ref} | &1])
      end)

      :ok
    end
  end

  test "a copied control cannot stop work and the exact operator control keeps the task resumable" do
    fixture = task_fixture!("stop")
    attributes = attributes(fixture.card.ref)

    copied = put_in(attributes, [:target, :message_ref], "1787832009.000900")
    assert WorkControls.stop(copied) == {:error, :work_control_target_mismatch}
    assert Repo.get!(Responder.Work.Turn, fixture.claim.turn.id).status == :pending

    assert {:ok, result} = WorkControls.stop(attributes)
    assert result.outcome == :stopping
    assert result.work_ref == fixture.card.ref
    assert result.turn.status == :cancel_pending
    assert result.turn.cancellation_intent["action"] == "block"

    episode = Repo.get!(Responder.Episodes.Episode, fixture.episode.id)
    assert episode.state == :working
    assert episode.owner_ref == fixture.claim.turn.turn_ref
  end

  test "a full member can inspect one exact bounded Coop diff in the task thread" do
    fixture = task_fixture!("diff", bind_session: true)
    patch = "diff --git a/lib/responder.ex b/lib/responder.ex\n+safe change\n"
    patch_digest = :crypto.hash(:sha256, patch) |> Base.encode16(case: :lower)

    changes = %{
      "base_commit" => String.duplicate("a", 40),
      "committed" => [%{"path" => "lib/responder.ex", "status" => "modified"}],
      "conflicts" => [],
      "fork_head" => String.duplicate("b", 40),
      "fork_tree" => String.duplicate("c", 40),
      "parent_head" => String.duplicate("d", 40),
      "parent_divergence" => %{
        "ahead" => 1,
        "base_to_fork" => 1,
        "base_to_parent" => 0,
        "behind" => 0,
        "diverged" => false
      },
      "patch" => Base.encode64(patch),
      "patch_bytes" => byte_size(patch),
      "patch_digest" => patch_digest,
      "patch_has_more" => false,
      "patch_next_offset" => byte_size(patch),
      "patch_offset" => 0,
      "staged" => [],
      "truncated" => false,
      "unstaged" => [],
      "untracked" => []
    }

    coop =
      start_supervised!(%{
        id: {:work_diff_coop, Ecto.UUID.generate()},
        start: {FakeWorkCoopAPI, :start_link, [[], [changes: [changes]]]}
      })

    slack = start_supervised!({Agent, fn -> %{messages: %{}, posts: [], updates: []} end})

    assert {:ok, result} =
             WorkControls.show_diff(attributes(fixture.card.ref), %{
               coop_api: FakeWorkCoopAPI,
               coop_client: coop,
               slack_api: SlackAPI,
               slack_client: slack
             })

    assert result.outcome == :shown
    assert result.message_ref == "1787832999.000100"

    assert [
             {"C456", "1787832000.000100", %{"work_diff" => diff}, delivery_ref}
           ] =
             Agent.get(slack, & &1.posts)

    assert delivery_ref == "work-diff:#{fixture.card.ref}"
    message = diff["message"]
    assert message =~ "lib/responder.ex"
    assert message =~ patch_digest
    assert message =~ "+safe change"

    assert FakeWorkCoopAPI.state(coop).changes_page_requests == [
             {"remote-work-controls-diff", 0, 2_400}
           ]
  end

  test "diff navigation updates only its exact message and restarts at page zero after a snapshot change" do
    fixture = task_fixture!("diff-page", bind_session: true)
    old_patch = String.duplicate("a", 2_400) <> String.duplicate("b", 600)
    old_digest = digest(old_patch)
    new_patch = "new snapshot\n"
    new_digest = digest(new_patch)

    old_first = changes_page(old_patch, old_digest, 0, 2_400)
    new_first = changes_page(new_patch, new_digest, 0, 2_400)

    coop =
      start_supervised!(%{
        id: {:work_diff_page_coop, Ecto.UUID.generate()},
        start: {FakeWorkCoopAPI, :start_link, [[], [changes: [old_first, new_first]]]}
      })

    slack = start_supervised!({Agent, fn -> %{messages: %{}, posts: [], updates: []} end})
    options = presentation_options(coop, slack)

    assert {:ok, %{message_ref: message_ref}} =
             WorkControls.show_diff(attributes(fixture.card.ref), options)

    page_attributes =
      fixture.card.ref
      |> attributes()
      |> put_in([:target, :message_ref], message_ref)
      |> Map.merge(%{patch_offset: 2_400, snapshot_digest: old_digest})

    assert {:ok, %{outcome: :shown}} = WorkControls.show_diff_page(page_attributes, options)

    assert [{"C456", ^message_ref, %{"work_diff" => page}, _delivery_ref}] =
             Agent.get(slack, & &1.updates)

    assert page["patch_digest"] == new_digest
    assert page["patch_offset"] == 0
    assert page["message"] =~ "new snapshot"

    assert FakeWorkCoopAPI.state(coop).changes_page_requests == [
             {"remote-work-controls-diff-page", 0, 2_400},
             {"remote-work-controls-diff-page", 0, 2_400}
           ]

    copied = put_in(page_attributes, [:target, :message_ref], "1787832999.999999")
    assert WorkControls.show_diff_page(copied, options) == {:error, :work_diff_message_mismatch}
  end

  test "diff navigation fetches the requested page only for the exact current snapshot" do
    fixture = task_fixture!("diff-stable-page", bind_session: true)
    patch = String.duplicate("a", 2_400) <> String.duplicate("b", 600)
    patch_digest = digest(patch)
    first = changes_page(patch, patch_digest, 0, 2_400)
    second = changes_page(patch, patch_digest, 2_400, 2_400)

    coop =
      start_supervised!(%{
        id: {:work_diff_stable_page_coop, Ecto.UUID.generate()},
        start: {FakeWorkCoopAPI, :start_link, [[], [changes: [first, first, second]]]}
      })

    slack = start_supervised!({Agent, fn -> %{messages: %{}, posts: [], updates: []} end})
    options = presentation_options(coop, slack)

    assert {:ok, %{message_ref: message_ref}} =
             WorkControls.show_diff(attributes(fixture.card.ref), options)

    page_attributes =
      fixture.card.ref
      |> attributes()
      |> put_in([:target, :message_ref], message_ref)
      |> Map.merge(%{patch_offset: 2_400, snapshot_digest: patch_digest})

    assert {:ok, %{outcome: :shown}} = WorkControls.show_diff_page(page_attributes, options)

    assert [{"C456", ^message_ref, %{"work_diff" => page}, _delivery_ref}] =
             Agent.get(slack, & &1.updates)

    assert page["patch_digest"] == patch_digest
    assert page["patch_offset"] == 2_400
    assert page["message"] =~ String.duplicate("b", 20)

    assert FakeWorkCoopAPI.state(coop).changes_page_requests == [
             {"remote-work-controls-diff-stable-page", 0, 2_400},
             {"remote-work-controls-diff-stable-page", 0, 2_400},
             {"remote-work-controls-diff-stable-page", 2_400, 2_400}
           ]
  end

  test "work records are evidence-backed and say when material conclusions are unknown" do
    fixture = task_fixture!("record", rich_records: true)

    assert {:ok, timeline} =
             WorkRecord.build(fixture.card.ref, attributes(fixture.card.ref).target, :timeline)

    assert timeline["message"] =~ "Input admitted"
    assert timeline["message"] =~ "Evidence recorded"
    assert timeline["message"] =~ "Goal state recorded"
    assert timeline["message"] =~ "Input request recorded"

    assert {:ok, evidence} =
             WorkRecord.build(fixture.card.ref, attributes(fixture.card.ref).target, :evidence)

    assert evidence["message"] =~ "Repository test output"
    assert evidence["message"] =~ "Focused tests passed"
    assert evidence["message"] =~ "application: unknown"
    assert evidence["message"] =~ "remain unexplained"
    refute evidence["message"] =~ "root cause confirmed"

    assert {:ok, handoff} =
             WorkRecord.build(fixture.card.ref, attributes(fixture.card.ref).target, :handoff)

    assert handoff["message"] =~ "Latest progress: verifying"
    assert handoff["message"] =~ "Which deployment should I inspect?"
    assert handoff["message"] =~ "verify-workers · blocked"
    assert handoff["message"] =~ "Publication: none recorded"

    assert WorkRecord.build(
             fixture.card.ref,
             attributes(fixture.card.ref).target,
             :postmortem
           ) == {:error, :work_record_not_available}

    assert WorkRecord.build("unknown", %{}, :timeline) ==
             {:error, :work_control_not_found}

    assert WorkRecord.build(fixture.card.ref, attributes(fixture.card.ref).target, :unknown) ==
             {:error, :work_record_not_available}
  end

  test "the exact task card starts its delivered readiness review" do
    fixture = PublicationFixture.published!("task-card-readiness")
    card = publication_task_card!(fixture.publication, "readiness")

    Repo.delete_all(
      from(followup in Followup, where: followup.publication_id == ^fixture.publication.id)
    )

    Repo.delete!(fixture.publication)

    attributes =
      card
      |> publication_attributes()
      |> Map.put(:record_ref, "record:publication_offer:#{fixture.publication.record_id}")

    record = Repo.get!(Responder.State.Record, fixture.publication.record_id)
    attributes = %{attributes | record_ref: record.ref}

    assert {:ok, result} = WorkControls.request_readiness(attributes)
    assert result.outcome == :requested
    assert result.work_ref == card.ref
    assert Repo.get_by!(Publication, ref: result.publication_ref).episode_id == card.episode_id

    crossed = put_in(attributes, [:target, :message_ref], "message:someone-else")
    assert WorkControls.request_readiness(crossed) == {:error, :work_control_target_mismatch}
  end

  test "the exact task card approves only its reviewed publication" do
    fixture = PublicationFixture.published!("task-card-publish")
    card = publication_task_card!(fixture.publication, "publish")

    Repo.delete_all(
      from(followup in Followup, where: followup.publication_id == ^fixture.publication.id)
    )

    {1, _rows} =
      Repo.update_all(
        from(publication in Publication, where: publication.id == ^fixture.publication.id),
        set: [
          approval_ref: nil,
          approved_at: nil,
          approved_by_actor_ref: nil,
          branch_ref: nil,
          commit_sha: nil,
          github_repository: nil,
          publication_receipt: nil,
          publication_receipt_fingerprint: nil,
          published_at: nil,
          published_delivery_receipt: nil,
          published_delivery_receipt_fingerprint: nil,
          pull_request_number: nil,
          pull_request_url: nil,
          status: :reviewed
        ]
      )

    attributes =
      card
      |> publication_attributes()
      |> Map.put(:publication_ref, fixture.publication.ref)

    assert {:ok, result} = WorkControls.approve_publication(attributes)
    assert result.outcome == :approved
    assert Repo.get!(Publication, fixture.publication.id).status == :publish_pending
  end

  test "a task card refreshes only its own published GitHub lifecycle" do
    fixture = PublicationFixture.published!("task-card-check")
    card = publication_task_card!(fixture.publication, "check")

    attributes =
      card
      |> publication_attributes()
      |> Map.put(:publication_ref, fixture.publication.ref)

    assert {:ok, result} = WorkControls.check_publication(attributes)
    assert result.outcome == :requested
    assert result.publication_ref == fixture.publication.ref

    other = PublicationFixture.published!("task-card-other")
    crossed = %{attributes | publication_ref: other.publication.ref}
    assert WorkControls.check_publication(crossed) == {:error, :task_publication_mismatch}
  end

  test "a task card recovers only its exact publication generation" do
    fixture = PublicationFixture.published!("task-card-recovery")
    card = publication_task_card!(fixture.publication, "recovery")
    observed_head = String.duplicate("d", 40)

    Repo.update_all(
      from(followup in Followup, where: followup.publication_id == ^fixture.publication.id),
      set: [pr_state: "stale"]
    )

    {1, _rows} =
      Repo.update_all(
        from(publication in Publication, where: publication.id == ^fixture.publication.id),
        set: [expected_remote_head_sha: observed_head]
      )

    attributes =
      card
      |> publication_attributes()
      |> Map.merge(%{
        expected_generation: 1,
        publication_ref: fixture.publication.ref
      })

    assert {:ok, result} = WorkControls.recover_publication(attributes, :update)
    assert result.outcome == :review_pending
    assert result.work_ref == card.ref

    recovered = Repo.get!(Publication, fixture.publication.id)
    assert recovered.status == :review_pending
    assert recovered.recovery_generation == 2
    assert recovered.expected_remote_head_sha == observed_head
    assert recovered.branch_ref == fixture.publication.branch_ref
    assert Repo.get_by!(Followup, publication_id: recovered.id).pr_state == "open"

    stale = %{attributes | request_ref: "interaction:stale-publication-recovery"}

    assert WorkControls.recover_publication(stale, :update) ==
             {:error, :publication_recovery_generation_stale}
  end

  test "timeline and evidence controls publish one recoverable thread message" do
    fixture = task_fixture!("record-control", rich_records: true)
    slack = start_supervised!({Agent, fn -> %{messages: %{}, posts: [], updates: []} end})
    options = %{slack_api: SlackAPI, slack_client: slack}

    timeline =
      fixture.card.ref
      |> attributes()
      |> Map.put(:record_kind, :timeline)

    assert {:ok, first} = WorkControls.show_record(timeline, options)
    assert first.outcome == :shown
    assert first.record_kind == :timeline
    assert first.work_ref == fixture.card.ref

    assert [{"C456", "1787832000.000100", %{"message" => message}, delivery_ref}] =
             Agent.get(slack, & &1.posts)

    assert message =~ "Input admitted"
    assert delivery_ref == "work-record:#{fixture.card.ref}:timeline"

    assert {:ok, second} = WorkControls.show_record(timeline, options)
    assert second.message_ref == first.message_ref

    assert [{"C456", message_ref, %{"message" => updated}, ^delivery_ref}] =
             Agent.get(slack, & &1.updates)

    assert message_ref == first.message_ref
    assert updated =~ "Evidence recorded"
  end

  test "close requests stop only the exact active turn and stale controls fail closed" do
    fixture = task_fixture!("close")
    exact = attributes(fixture.card.ref)

    assert {:ok, result} = WorkControls.close(exact)
    assert result.outcome == :closing
    assert result.work_ref == fixture.card.ref

    turn = Repo.get!(Responder.Work.Turn, fixture.claim.turn.id)
    assert turn.status == :cancel_pending
    assert turn.cancellation_intent["action"] == "cancel"

    assert WorkControls.stop(exact) == {:error, :work_control_stale}

    assert WorkControls.close(put_in(exact, [:target, :thread_ref], "copied-thread")) ==
             {:error, :work_control_target_mismatch}
  end

  test "closing a durable wait is immediate and exact retries stay closed" do
    fixture = task_fixture!("close-wait")

    assert {:ok, question} =
             Records.create(Records.token(fixture.claim.turn), "close-wait", "input_request", %{
               "choices" => [],
               "question" => "Should this work remain open?"
             })

    assert {:ok, _waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 episode_key: fixture.episode.key,
                 expected_turn_ref: fixture.episode.owner_ref,
                 wait_ref: question.ref
               })
             )

    exact = attributes(fixture.card.ref)
    assert {:ok, %{outcome: :closed}} = WorkControls.close(exact)
    assert Repo.get!(Responder.Episodes.Episode, fixture.episode.id).state == :cancelled
    assert {:ok, %{outcome: :closed}} = WorkControls.close(exact)
    assert WorkControls.stop(exact) == {:error, :work_control_stale}
  end

  test "work presentation controls require exact typed attributes and configured adapters" do
    fixture = task_fixture!("invalid-presentation")
    exact = attributes(fixture.card.ref)

    assert WorkControls.show_diff(exact, %{}) == {:error, :invalid_work_control_options}
    assert WorkControls.show_diff(exact, :options) == {:error, :invalid_work_control}

    assert WorkControls.show_diff(exact, %{
             coop_api: FakeWorkCoopAPI,
             coop_client: self(),
             slack_api: SlackAPI,
             slack_client: self()
           }) == {:error, :work_changes_not_available}

    assert WorkControls.show_diff_page(exact, %{}) == {:error, :invalid_work_control}
    assert WorkControls.show_diff_page(exact, :options) == {:error, :invalid_work_control}
    assert WorkControls.show_record(exact, %{}) == {:error, :invalid_work_control}
    assert WorkControls.show_record(exact, :options) == {:error, :invalid_work_control}
    assert WorkControls.stop(%{}) == {:error, :invalid_work_control}
    assert WorkControls.close(:invalid) == {:error, :invalid_work_control}
    assert WorkControls.request_readiness(%{}) == {:error, :invalid_work_control}
    assert WorkControls.approve_publication(%{}) == {:error, :invalid_work_control}
    assert WorkControls.check_publication(%{}) == {:error, :invalid_work_control}
    assert WorkControls.recover_publication(%{}, :retry) == {:error, :invalid_work_control}
  end

  test "work target resolution fences card and thread controls independently" do
    fixture = task_fixture!("target-resolution")
    exact = attributes(fixture.card.ref).target

    assert {:ok, resolved} = WorkTarget.resolve_thread(fixture.card.ref, exact)
    assert resolved.work_ref == fixture.card.ref
    assert resolved.kind == :task

    root_target = %{exact | message_ref: fixture.card.thread_ref, thread_ref: nil}
    assert {:ok, root} = WorkTarget.resolve_thread(fixture.card.ref, root_target)
    assert root.output_thread_ref == fixture.card.thread_ref

    assert WorkTarget.resolve(fixture.card.ref, :invalid) ==
             {:error, :work_control_target_mismatch}

    assert WorkTarget.resolve_thread(fixture.card.ref, :invalid) ==
             {:error, :work_control_target_mismatch}

    assert WorkTarget.resolve("task-card:missing", exact) ==
             {:error, :work_control_not_found}

    assert WorkTarget.resolve("incident-room:missing", exact) ==
             {:error, :work_control_not_found}

    assert WorkTarget.resolve_thread("incident-room:missing", exact) ==
             {:error, :work_control_not_found}

    assert WorkTarget.resolve_thread("unknown", exact) == {:error, :work_control_not_found}
  end

  defp task_fixture!(suffix, options \\ []) do
    episode_id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: "slack:T123:C456",
          thread_ref: "1787832000.000100",
          transport: "slack"
        },
        episode_id: episode_id,
        episode_key: "work-controls:#{suffix}:#{episode_id}",
        native_input_id: "slack-message:work-controls:#{suffix}:#{episode_id}",
        occurred_at: @now,
        payload: %{"text" => "Investigate the parser failure."},
        turn_ref: "turn:work-controls:#{suffix}:#{episode_id}"
      })

    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "responder-contributor", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("work-controls:#{suffix}", 60, :work)

    assert {:ok, evidence} =
             Records.create(Records.token(claim.turn), "record-evidence", "evidence", %{
               "claim_id" => "focused-tests",
               "confidence" => "high",
               "observation" => "Focused tests passed.",
               "observed_at" => DateTime.to_iso8601(@now),
               "source_name" => "Repository test output",
               "source_type" => "repository",
               "target" => "api.production"
             })

    if Keyword.get(options, :rich_records, false) do
      rich_records!(Records.token(claim.turn), evidence.ref)
    end

    card =
      %{
        attempt_count: 0,
        channel_ref: "C456",
        episode_id: transition.episode.id,
        id: Ecto.UUID.generate(),
        message_ref: "1787832001.000200",
        record_id: evidence.id,
        ref: "task-card:#{evidence.id}",
        thread_ref: "1787832000.000100",
        workspace_ref: "T123"
      }
      |> TaskCardChangeset.insert()
      |> Repo.insert!()

    claim =
      if Keyword.get(options, :bind_session, false) do
        assert {:ok, _session} =
                 Custody.bind_session(
                   episode_id,
                   claim.turn.turn_ref,
                   claim.lease_ref,
                   claim.session.generation,
                   claim.session.create_generation,
                   "remote-work-controls-#{suffix}"
                 )

        %{claim | session: Repo.get!(Responder.Work.Session, claim.session.id)}
      else
        claim
      end

    %{card: card, claim: claim, episode: transition.episode}
  end

  defp rich_records!(token, evidence_ref) do
    assert {:ok, _coverage} =
             Records.create(token, "record-coverage", "coverage", %{
               "claim_ids" => ["focused-tests"],
               "detail" => "Background workers were not sampled.",
               "layer" => "application",
               "observed_at" => DateTime.to_iso8601(@now),
               "source" => "Repository test output",
               "status" => "unknown"
             })

    assert {:ok, _finding} =
             Records.create(token, "record-finding", "finding", %{
               "alternatives" => [],
               "cause_evidence" => [],
               "reason" => nil,
               "scope" => "Background workers",
               "status" => "unexplained",
               "what" => "Background-worker health was not verified."
             })

    assert {:ok, _progress} =
             Records.create(token, "record-progress", "progress", %{
               "next_due_at" => nil,
               "phase" => "verifying",
               "summary" => String.duplicate("Worker verification remains. ", 45)
             })

    assert {:ok, _goal} =
             Records.create(token, "record-goal", "goal", %{
               "authority" => "read_only",
               "completion_contract" => "A current worker observation is recorded.",
               "id" => "verify-workers",
               "kind" => "check",
               "prerequisite_goal_ids" => [],
               "read_only_repositories" => [],
               "requested_outcome" => "Verify background-worker health",
               "required" => true,
               "writable_repository" => nil
             })

    assert {:ok, _goal_state} =
             Records.create(token, "record-goal-state", "goal_state", %{
               "detail" => "No worker metric was available.",
               "goal_id" => "verify-workers",
               "state" => "blocked"
             })

    assert {:ok, _question} =
             Records.create(token, "record-question", "input_request", %{
               "choices" => ["Production", "Staging"],
               "question" => "Which deployment should I inspect?"
             })

    assert {:ok, _wait} =
             Records.create(token, "record-wait", "event_wait", %{
               "deadline_at" => "2099-08-28T13:00:00.000000Z",
               "event_matcher" => %{"deployment_id" => "deploy-1"},
               "kind" => "deployment",
               "verification" => "All allocations are healthy."
             })

    assert {:ok, _assessment} =
             Records.create(token, "record-assessment", "alert_assessment", %{
               "cause" => nil,
               "cause_claim_ids" => [],
               "cause_status" => nil,
               "evidence_refs" => [],
               "immediate_action" => "Inspect a current worker-health signal.",
               "immediate_action_kind" => "investigation",
               "impact" => "The API is healthy, but worker health is not verified.",
               "long_term_solution" => nil,
               "scope" => %{
                 "checked_targets" => ["api.production"],
                 "evidence_refs" => [evidence_ref],
                 "status" => "bounded",
                 "unverified_targets" => ["workers.production"],
                 "universe_evidence_ref" => nil
               },
               "verification" => nil,
               "verdict" => "unverified"
             })
  end

  defp publication_task_card!(publication, suffix) do
    %{
      attempt_count: 0,
      channel_ref: "C456",
      episode_id: publication.episode_id,
      id: Ecto.UUID.generate(),
      message_ref: "message:task-card:#{suffix}",
      record_id: publication.record_id,
      ref: "task-card:#{publication.record_id}",
      thread_ref: "thread:task-card-#{suffix}",
      workspace_ref: "T123"
    }
    |> TaskCardChangeset.insert()
    |> Repo.insert!()
  end

  defp publication_attributes(card) do
    %{
      actor_ref: "slack:user:U123",
      occurred_at: DateTime.add(@now, 10, :second),
      request_ref: "interaction:#{card.ref}",
      target: %{
        conversation_ref: "slack:T123:C456",
        message_ref: card.message_ref,
        thread_ref: card.thread_ref,
        transport: "slack"
      },
      work_ref: card.ref
    }
  end

  defp attributes(work_ref) do
    %{
      actor_ref: "slack:user:U123",
      occurred_at: DateTime.add(@now, 1, :second),
      request_ref: "interaction:#{work_ref}",
      target: %{
        conversation_ref: "slack:T123:C456",
        message_ref: "1787832001.000200",
        thread_ref: "1787832000.000100",
        transport: "slack"
      },
      work_ref: work_ref
    }
  end

  defp presentation_options(coop, slack) do
    %{
      coop_api: FakeWorkCoopAPI,
      coop_client: coop,
      slack_api: SlackAPI,
      slack_client: slack
    }
  end

  defp changes_page(full_patch, patch_digest, offset, limit) do
    size = byte_size(full_patch)
    page = binary_part(full_patch, offset, min(limit, size - offset))
    next_offset = offset + byte_size(page)

    %{
      "base_commit" => String.duplicate("a", 40),
      "committed" => [%{"path" => "lib/responder.ex", "status" => "modified"}],
      "conflicts" => [],
      "fork_head" => String.duplicate("b", 40),
      "fork_tree" => String.duplicate("c", 40),
      "parent_head" => String.duplicate("d", 40),
      "parent_divergence" => %{
        "ahead" => 1,
        "base_to_fork" => 1,
        "base_to_parent" => 0,
        "behind" => 0,
        "diverged" => false
      },
      "patch" => Base.encode64(page),
      "patch_bytes" => size,
      "patch_digest" => patch_digest,
      "patch_has_more" => next_offset < size,
      "patch_next_offset" => next_offset,
      "patch_offset" => offset,
      "staged" => [],
      "truncated" => false,
      "unstaged" => [],
      "untracked" => []
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
