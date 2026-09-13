defmodule Ryker.Publication.FollowupsTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Episodes
  alias Ryker.Episodes.{Event, EventChangeset}
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Publication.{Custody, Followup, Followups, LifecycleEvent, Publication}

  alias Ryker.State.{
    Continuity,
    ConversationObservation,
    KnowledgeSnapshot,
    LearningSources,
    Observations
  }

  alias Ryker.Work.Custody, as: WorkCustody
  alias Ryker.Work.DeliveryReceipt
  alias Ryker.Work.SubmissionBuilder

  @now ~U[2026-08-28 12:10:00.000000Z]

  test "published work survives checks, merge, exact deployment correlation, and verification wakeup" do
    %{episode: episode, publication: publication} = PublicationFixture.published!("followup")

    followup = Repo.get_by!(Followup, publication_id: publication.id)
    assert followup.pr_state == "open"
    assert followup.checks_state == "unknown"

    assert {:ok, check_claim} = Followups.claim_poll("publication-followup:checks", 60)
    assert check_claim.publication.id == publication.id

    passing = lifecycle_status(publication, "passing", false)

    assert {:ok, passed} =
             Followups.store_poll(publication.ref, check_claim.lease_ref, passing, 120)

    assert passed.checks_state == "passing"
    assert passed.checks_passed == 2
    assert passed.lease_ref == nil

    assert %LifecycleEvent{kind: "checks", state: "succeeded"} =
             Repo.get_by!(LifecycleEvent, publication_id: publication.id, kind: "checks")

    deliver_pending!()

    Repo.update_all(
      from(saved in Followup, where: saved.id == ^followup.id),
      set: [next_poll_at: @now]
    )

    assert {:ok, merge_claim} = Followups.claim_poll("publication-followup:merge", 60)
    merge_sha = String.duplicate("b", 40)
    merged = lifecycle_status(publication, "passing", true, merge_sha)

    assert {:ok, merged_followup} =
             Followups.store_poll(publication.ref, merge_claim.lease_ref, merged, 120)

    assert merged_followup.pr_state == "merged"
    assert merged_followup.merge_sha == merge_sha

    unrelated = typed_lifecycle_input(["unrelated"], "deployment", "succeeded")
    assert Followups.observe_input(unrelated) == {:ok, 0}

    correlated =
      typed_lifecycle_input(
        [publication.branch_ref, publication.commit_sha],
        "deployment",
        "succeeded"
      )

    assert Followups.observe_input(correlated) == {:ok, 1}
    assert Followups.observe_input(correlated) == {:ok, 0}

    deployment =
      Repo.get_by!(LifecycleEvent,
        publication_id: publication.id,
        kind: "deployment",
        state: "succeeded"
      )

    assert deployment.wakeup_state == :pending
    deliver_pending!()

    assert {:ok, resumed} = Episodes.fetch_by_key(episode.key)
    assert resumed.state == :working
    assert resumed.owner_ref == "turn:publication-verification:#{deployment.id}"

    stored_followup = Repo.get!(Followup, followup.id)
    assert stored_followup.verification_event_ref == deployment.ref
    assert stored_followup.verification_turn_ref == resumed.owner_ref
    assert stored_followup.verification_sequence > 0
  end

  # A draft PR whose checks fail is work the agent can still finish: the change
  # is its own, the scope is the task's, and a Slack line saying "checks are
  # failing, open the PR for the exact failures" teaches an operator nothing they
  # can act on faster than the agent can. Before this the failure was a
  # history-only fact and the episode stayed settled, so every red run waited for
  # a person to notice and retype the task.
  test "failing checks on the exact reviewed head return the task to in-scope correction" do
    %{episode: episode, publication: publication} = PublicationFixture.published!("ci-correction")

    assert {:ok, claim} = Followups.claim_poll("publication-followup:ci", 60)

    failing =
      publication
      |> lifecycle_status("failing", false)
      |> Map.merge(%{"checks_failed" => 2, "checks_passed" => 5, "checks_total" => 7})

    assert {:ok, _followup} = Followups.store_poll(publication.ref, claim.lease_ref, failing, 120)

    assert %LifecycleEvent{state: "failed", wakeup_state: :pending} =
             event = Repo.get_by!(LifecycleEvent, publication_id: publication.id, kind: "checks")

    # The same red run observed again is the same fact, not a second correction.
    Repo.update_all(
      from(saved in Followup, where: saved.publication_id == ^publication.id),
      set: [next_poll_at: @now]
    )

    assert {:ok, repeat} = Followups.claim_poll("publication-followup:ci-repeat", 60)
    assert {:ok, _same} = Followups.store_poll(publication.ref, repeat.lease_ref, failing, 120)

    assert [only] =
             Repo.all(
               from(saved in LifecycleEvent,
                 where: saved.publication_id == ^publication.id and saved.kind == "checks"
               )
             )

    assert only.id == event.id

    deliver_pending!()

    assert {:ok, resumed} = Episodes.fetch_by_key(episode.key)
    assert resumed.state == :working
    assert resumed.owner_ref == "turn:publication-verification:#{event.id}"

    assert [wake] =
             Repo.all(
               from(saved in Event,
                 where:
                   saved.episode_id == ^episode.id and saved.kind == :input_admitted and
                     fragment(
                       "?::jsonb -> 'payload' -> 'content' ->> 'kind' = ?",
                       saved.payload,
                       "publication_lifecycle"
                     )
               )
             )

    content = wake.payload["payload"]["content"]

    # The agent is asked to fix its own change inside the scope the task already
    # granted, not to verify a deployment and not to widen the work.
    assert content["correction_request"] =~ "existing scope"
    refute content["verification_request"]
    assert content["lifecycle"]["state"] == "failed"
    assert content["publication"]["head_sha"] == publication.commit_sha
  end

  test "only the exact verification turn can satisfy a queued deployment wakeup" do
    %{episode: episode, publication: publication} =
      PublicationFixture.published!("exact-verification-turn")

    followup = Repo.get_by!(Followup, publication_id: publication.id)
    verification_sequence = 100
    verification_turn_ref = "turn:publication-verification:exact"

    Repo.update_all(
      from(saved in Followup, where: saved.id == ^followup.id),
      set: [
        next_poll_at: @now,
        verification_event_ref: "lifecycle:deployment:exact",
        verification_sequence: verification_sequence,
        verification_turn_ref: verification_turn_ref
      ]
    )

    insert_result_event!(episode.id, verification_sequence + 1, "turn:older-work")

    assert {:ok, claim} = Followups.claim_poll("publication-followup:wrong-verification", 60)

    assert {:ok, not_verified} =
             Followups.reconcile_verification(publication.ref, claim.lease_ref, 60)

    assert not_verified.verified_at == nil

    Repo.update_all(
      from(saved in Followup, where: saved.id == ^followup.id),
      set: [next_poll_at: @now]
    )

    insert_result_event!(episode.id, verification_sequence + 2, verification_turn_ref)

    assert {:ok, exact_claim} =
             Followups.claim_poll("publication-followup:exact-verification", 60)

    assert {:ok, verified} =
             Followups.reconcile_verification(publication.ref, exact_claim.lease_ref, 60)

    assert %DateTime{} = verified.verified_at
  end

  test "GitHub webhook nudges only the exact recorded pull request and head" do
    %{publication: publication} = PublicationFixture.published!("nudge", pull_request_number: 92)
    head_sha = publication.commit_sha

    Repo.update_all(
      from(followup in Followup, where: followup.publication_id == ^publication.id),
      set: [next_poll_at: DateTime.add(@now, 1, :day)]
    )

    payload = %{
      "pull_request" => %{"head" => %{"sha" => head_sha}, "number" => 92}
    }

    assert Followups.nudge_github_event("acme/ryker", "pull_request", "delivery:1", payload) ==
             {:ok, :nudged}

    assert {:ok, claim} = Followups.claim_poll("publication-followup:webhook", 60)
    assert claim.publication.id == publication.id

    crossed = put_in(payload, ["pull_request", "head", "sha"], String.duplicate("c", 40))

    assert Followups.nudge_github_event(
             "acme/ryker",
             "pull_request",
             "delivery:2",
             crossed
           ) == {:ok, :ignored}
  end

  test "review feedback fails closed when two publications claim one pull request" do
    PublicationFixture.published!("ambiguous-review-one",
      github_repository: "octo/ambiguous",
      pull_request_number: 73
    )

    PublicationFixture.published!("ambiguous-review-two",
      github_repository: "octo/ambiguous",
      pull_request_number: 73
    )

    base = lifecycle_input_with(:user, %{}, "ambiguous-review")

    input = %{
      base
      | content: %{
          "event_name" => "issue_comment",
          "payload" => %{
            "issue" => %{"number" => 73, "pull_request" => %{}},
            "repository" => %{"full_name" => "octo/ambiguous"}
          }
        },
        source: %{kind: "github", ref: "ryker-app"}
    }

    assert Followups.observe_github_feedback(input) ==
             {:error, :publication_review_feedback_ambiguous}

    assert Repo.aggregate(LifecycleEvent, :count) == 0
  end

  test "authorized GitHub bot edits retain their actor and edit semantics on continuation" do
    %{episode: episode} =
      PublicationFixture.published!("bot-review-edit",
        github_repository: "octo/bot-review",
        pull_request_number: 74
      )

    base = lifecycle_input_with(:bot, %{}, "bot-review-edit")

    input = %{
      base
      | content: %{
          "event_name" => "issue_comment",
          "payload" => %{
            "issue" => %{"number" => 74, "pull_request" => %{}},
            "repository" => %{"full_name" => "octo/bot-review"}
          }
        },
        event_kind: :edit,
        source: %{kind: "github", ref: "ryker-app"},
        source_item_ref: "github:issue_comment:740"
    }

    assert {:ok, %{event: event, status: :recorded}} =
             Followups.observe_github_feedback(input)

    assert {:ok, claim} = Followups.claim_delivery("publication-followup:bot-edit", 60)
    assert claim.event.id == event.id
    assert {:ok, %{wakeup_state: :admitted}} = Followups.admit_wakeup(event.ref, claim.lease_ref)

    admitted =
      Repo.one!(
        from(saved in Event,
          where: saved.episode_id == ^episode.id and saved.kind == :input_admitted,
          order_by: [desc: saved.sequence],
          limit: 1
        )
      )

    assert get_in(admitted.payload, ["payload", "actor", "kind"]) == "bot"
    assert get_in(admitted.payload, ["payload", "event_kind"]) == "edit"
  end

  for changed_field <- [
        :actor,
        :source,
        :destination,
        :event_kind,
        :revision,
        :native_input_id,
        :source_item_ref,
        :source_capabilities,
        :occurred_at,
        :occurred_at_source,
        :content
      ] do
    test "GitHub feedback changing #{changed_field} is not an equivalent receipt" do
      # Coalescing transport retries must not hide a changed actor, scope, source
      # revision or document; integer and float JSON values also remain distinct.
      suffix = "feedback-distinct-#{unquote(changed_field)}"

      PublicationFixture.published!(suffix,
        github_repository: "octo/feedback-equivalence",
        pull_request_number: 74
      )

      input = feedback_input(suffix)
      assert {:ok, %{event: first, status: :recorded}} = Followups.observe_github_feedback(input)

      alternatives = %{
        actor: %{kind: :bot, ref: "another-actor"},
        source: %{kind: "github", ref: "another-app"},
        destination: %{input.destination | thread_ref: "another-thread"},
        event_kind: :edit,
        revision: input.revision + 1,
        native_input_id: input.native_input_id <> ":another",
        source_item_ref: "github:issue_comment:another",
        source_capabilities: %{"react" => %{"emoji_names" => ["eyes"]}},
        occurred_at: DateTime.add(input.occurred_at, 1, :second),
        occurred_at_source: :ingress,
        content: Map.put(input.content, "numeric_value", 1.0)
      }

      changed =
        input
        |> Map.put(:event_ref, input.event_ref <> ":changed")
        |> Map.put(unquote(changed_field), Map.fetch!(alternatives, unquote(changed_field)))

      assert {:ok, %{event: second, status: :recorded}} =
               Followups.observe_github_feedback(changed)

      assert second.id != first.id
      assert Repo.get!(LifecycleEvent, first.id) == first

      if unquote(changed_field) == :content do
        assert first.observation["content"]["numeric_value"] === 1
        assert second.observation["content"]["numeric_value"] === 1.0
      end
    end
  end

  for malformed <- [:not_a_map, :missing_content, :bad_content, :missing_identity, :bad_identity] do
    test "a #{malformed} historical feedback document cannot become duplicate authority" do
      # A malformed retained observation must neither crash a valid retry nor
      # silently inherit its authority by deleting the malformed fields.
      suffix = "feedback-malformed-#{unquote(malformed)}"

      PublicationFixture.published!(suffix,
        github_repository: "octo/feedback-equivalence",
        pull_request_number: 74
      )

      input = feedback_input(suffix)
      assert {:ok, %{event: first}} = Followups.observe_github_feedback(input)

      malformed =
        case unquote(malformed) do
          :not_a_map -> []
          :missing_content -> Map.delete(first.observation, "content")
          :bad_content -> Map.put(first.observation, "content", nil)
          :missing_identity -> Map.delete(first.observation, "event_ref")
          :bad_identity -> Map.put(first.observation, "event_ref", "")
        end

      Repo.update_all(from(event in LifecycleEvent, where: event.id == ^first.id),
        set: [observation: malformed]
      )

      retry = %{input | event_ref: input.event_ref <> ":retry"}
      assert {:ok, %{event: fresh, status: :recorded}} = Followups.observe_github_feedback(retry)
      assert fresh.id != first.id
      assert Repo.get!(LifecycleEvent, first.id).observation == malformed
    end
  end

  for event_kind <- [:edit, :delete],
      route <- [:matched, :closed, :tied, :reopened],
      event_kind == :edit or route != :tied do
    test "matched GitHub feedback stays private and a later #{route} #{event_kind} invalidates its warm session" do
      # Signed review feedback bypasses Admission. Without independent source
      # custody it either blocks useful Work or leaves its copied facts irrevocable.
      %{episode: episode, publication: publication} =
        PublicationFixture.published!("review-lineage-#{unquote(event_kind)}",
          conversation_ref: "slack:TREVIEW:C456",
          github_repository: "octo/private-review",
          pull_request_number: 74
        )

      for channel <- ["C456", "COTHER"] do
        Repo.insert!(%Ryker.Slack.ChannelMembership{
          id: Ecto.UUID.generate(),
          generation: 1,
          workspace_ref: "TREVIEW",
          channel_ref: channel,
          status: :joined,
          private: false,
          external_shared: false,
          joined_at: @now
        })
      end

      base = lifecycle_input_with(:user, %{}, "review-lineage")

      input = %{
        base
        | source: %{kind: "github", ref: "ryker-app"},
          destination: %{
            transport: "github",
            conversation_ref: "github:ryker-app:octo/private-review:pull:74",
            thread_ref: nil
          },
          event_kind: if(unquote(route) == :tied, do: unquote(event_kind), else: :message),
          content: %{
            "event_name" => "issue_comment",
            "payload" => %{
              "issue" => %{"number" => 74, "pull_request" => %{}},
              "repository" => %{"full_name" => "octo/private-review"}
            }
          }
      }

      {input, previous_source} =
        if unquote(route) == :reopened do
          Repo.update_all(from(f in Followup, where: f.publication_id == ^publication.id),
            set: [pr_state: "closed"]
          )

          assert {:ok, :unmatched} = Followups.observe_github_feedback(input)

          assert {:ok, inbox} =
                   Inbox.record(input, revision_ties: :receipt_order)

          assert [receipt] = LearningSources.for_entry(inbox.entry)
          assert {:ok, scope} = Continuity.destination_context(inbox.entry, nil)

          Repo.update_all(from(f in Followup, where: f.publication_id == ^publication.id),
            set: [pr_state: "open"]
          )

          {%{input | revision: input.revision + 1, event_ref: input.event_ref <> ":reopened"},
           {receipt, scope}}
        else
          {input, nil}
        end

      assert {:ok, %{event: event}} = Followups.observe_github_feedback(input)
      source = Repo.get_by(ConversationObservation, source_input_id: event.id)
      assert source != nil
      assert source.visibility == :private
      assert source.source_result_ref == "publication-feedback:#{event.id}"
      assert source.conversation_ref == episode.destination_conversation_ref

      if previous_source do
        {previous, previous_scope} = previous_source

        assert {:ok, false} =
                 Repo.transaction(fn -> LearningSources.valid?([previous], previous_scope) end)

        assert Repo.aggregate(Entry, :count) == 1
      else
        assert Repo.aggregate(Entry, :count) == 0
      end

      assert {:ok, %{event: duplicate, status: :duplicate}} =
               Followups.observe_github_feedback(input)

      assert duplicate.id == event.id
      assert Repo.get!(ConversationObservation, source.id) == source

      assert {:ok, {:error, :publication_feedback_source_invalid}} =
               Repo.transaction(fn ->
                 Observations.record_publication_feedback_in_transaction(
                   event,
                   %{publication | episode_id: Ecto.UUID.generate()}
                 )
               end)

      assert {:ok, delivery} = Followups.claim_delivery("review-lineage", 60)
      assert {:ok, _} = Followups.admit_wakeup(event.ref, delivery.lease_ref)
      assert {:ok, claim} = WorkCustody.claim_next("review-lineage", 60, :work)
      assert {:ok, submission} = SubmissionBuilder.build(claim)
      claim = %{claim | turn: %{claim.turn | submission: submission}}
      assert :ok = KnowledgeSnapshot.expose_submission(claim)
      assert [receipt] = KnowledgeSnapshot.session_sources(claim.session.id)
      assert receipt["source_input_id"] == event.id

      assert {:ok, scope} = Continuity.destination_context(episode, publication.repository)
      assert scope.visibility == :public
      assert {:ok, true} = Repo.transaction(fn -> LearningSources.valid?([receipt], scope) end)
      other_scope = %{scope | conversation_ref: "slack:TREVIEW:COTHER"}

      assert {:ok, false} =
               Repo.transaction(fn -> LearningSources.valid?([receipt], other_scope) end)

      changed = %{
        input
        | event_ref: input.event_ref <> ":changed",
          revision: if(unquote(route) == :tied, do: input.revision, else: input.revision + 1),
          event_kind: unquote(event_kind),
          content: Map.put(input.content, "revision_marker", "changed")
      }

      if unquote(route) != :closed do
        assert {:ok, %{event: replacement}} = Followups.observe_github_feedback(changed)
        assert replacement.id != event.id
      else
        Repo.update_all(from(f in Followup, where: f.publication_id == ^publication.id),
          set: [pr_state: "closed"]
        )

        assert {:ok, :unmatched} = Followups.observe_github_feedback(changed)

        assert {:ok, inbox} =
                 Inbox.record(changed, revision_ties: :receipt_order)

        assert [current] = LearningSources.for_entry(inbox.entry)
        assert {:ok, canonical_scope} = Continuity.destination_context(inbox.entry, nil)

        assert {:ok, true} =
                 Repo.transaction(fn -> LearningSources.valid?([current], canonical_scope) end)
      end

      assert {:error, :work_knowledge_context_stale} =
               KnowledgeSnapshot.authorize_session(episode, claim.session)

      assert LearningSources.for_work_input(Input.document(input)) == nil

      if unquote(route) == :tied do
        quarantined = Repo.get!(ConversationObservation, source.id)
        assert quarantined.updated_at == source.updated_at
        assert String.starts_with?(quarantined.source_result_ref, "source-conflict:")
        assert LearningSources.for_work_input(Input.document(changed)) == nil
        assert {:ok, %{status: :duplicate}} = Followups.observe_github_feedback(input)
        assert Repo.get!(ConversationObservation, source.id) == quarantined

        newer = %{
          changed
          | revision: changed.revision + 1,
            event_ref: changed.event_ref <> ":newer"
        }

        assert {:ok, %{event: recovered}} = Followups.observe_github_feedback(newer)
        assert [current] = LearningSources.for_work_input(Input.document(newer))
        assert current["source_input_id"] == recovered.id
      else
        current = Repo.get!(ConversationObservation, source.id)

        assert {:ok, :ok} =
                 Repo.transaction(fn ->
                   Observations.record_publication_feedback_in_transaction(
                     event,
                     publication
                   )
                 end)

        assert Repo.get!(ConversationObservation, source.id) == current
      end
    end
  end

  test "every supported GitHub lifecycle envelope nudges only its exact pull request" do
    %{publication: publication} =
      PublicationFixture.published!("nudge-envelopes", pull_request_number: 93)

    sha = publication.commit_sha

    events = [
      {"check_run",
       %{
         "check_run" => %{
           "head_sha" => sha,
           "pull_requests" => [%{"number" => 93}]
         }
       }},
      {"check_suite",
       %{
         "check_suite" => %{
           "head_sha" => sha,
           "pull_requests" => [%{"number" => 93}]
         }
       }},
      {"workflow_run",
       %{
         "workflow_run" => %{
           "head_commit" => %{"id" => sha},
           "pull_requests" => [%{"number" => 93}]
         }
       }}
    ]

    Enum.with_index(events, 1)
    |> Enum.each(fn {{event, payload}, index} ->
      assert Followups.nudge_github_event(
               "acme/ryker",
               event,
               "delivery:envelope:#{index}",
               payload
             ) == {:ok, :nudged}
    end)

    assert Followups.nudge_github_event(
             "acme/ryker",
             "status",
             "delivery:status",
             %{"sha" => sha}
           ) == {:ok, :ignored}

    assert Followups.nudge_github_event(
             "acme/ryker",
             "check_run",
             "delivery:malformed",
             %{"check_run" => %{"pull_requests" => []}}
           ) == {:ok, :ignored}

    assert Followups.nudge_github_event(
             "other/repository",
             "check_run",
             "delivery:other",
             elem(hd(events), 1)
           ) == {:ok, :ignored}
  end

  test "only exact typed deployment signals can correlate publications" do
    %{publication: publication} = PublicationFixture.published!("nested-signals")
    merge_sha = String.duplicate("d", 40)

    Repo.update_all(
      from(followup in Followup, where: followup.publication_id == ^publication.id),
      set: [merge_sha: merge_sha, pr_state: "merged"]
    )

    assert Followups.observe_input(
             lifecycle_input_with(
               :user,
               %{
                 "deployment" => publication.pull_request_url,
                 "status" => "succeeded"
               },
               "human"
             )
           ) == {:ok, 0}

    terraform =
      typed_lifecycle_content([publication.pull_request_url], "terraform", "succeeded")

    assert Followups.observe_input(lifecycle_input_with(:app, terraform, "terraform")) ==
             {:ok, 0}

    assert Followups.observe_input(authorized_lifecycle_input(terraform, "terraform")) ==
             {:ok, 1}

    deployment_failure =
      typed_lifecycle_content([publication.branch_ref], "deployment", "failed")

    assert Followups.observe_input(
             lifecycle_input_with(:bot, deployment_failure, "deployment-failed")
           ) == {:ok, 0}

    assert Followups.observe_input(
             authorized_lifecycle_input(deployment_failure, "deployment-failed")
           ) == {:ok, 1}

    deployment_pending =
      typed_lifecycle_content([publication.commit_sha], "deployment", "pending")

    assert Followups.observe_input(
             lifecycle_input_with(:system, deployment_pending, "deployment-pending")
           ) == {:ok, 0}

    assert Followups.observe_input(
             authorized_lifecycle_input(deployment_pending, "deployment-pending")
           ) == {:ok, 1}

    unknown =
      typed_lifecycle_content([publication.commit_sha], "deployment", "unexpected")

    assert Followups.observe_input(authorized_lifecycle_input(unknown, "unknown")) == {:ok, 0}

    heuristic = %{
      "events" => [
        %{"deployment" => publication.branch_ref},
        %{"conclusion" => "succeeded"}
      ]
    }

    assert Followups.observe_input(authorized_lifecycle_input(heuristic, "heuristic")) ==
             {:ok, 0}

    events =
      Repo.all(
        from(event in LifecycleEvent,
          where: event.publication_id == ^publication.id,
          order_by: [asc: event.kind, asc: event.state]
        )
      )

    assert Enum.map(events, &{&1.kind, &1.state}) == [
             {"deployment", "failed"},
             {"deployment", "pending"},
             {"terraform", "succeeded"}
           ]

    assert Enum.find(events, &(&1.kind == "terraform")).summary =~ "Terraform succeeded"
    assert Enum.find(events, &(&1.state == "failed")).wakeup_state == :pending
    assert Enum.find(events, &(&1.state == "pending")).wakeup_state == :none
  end

  test "lifecycle source scope and repository identity prevent cross-repository branch matches" do
    %{publication: ryker} = PublicationFixture.published!("scoped-ryker")

    %{publication: other} =
      PublicationFixture.published!("scoped-other",
        repository: "other",
        github_repository: "acme/other",
        pull_request_number: 92
      )

    branch_ref = "refs/heads/release/shared"
    merge_sha = String.duplicate("f", 40)
    ids = [ryker.id, other.id]

    Repo.update_all(
      from(publication in Publication, where: publication.id in ^ids),
      set: [branch_ref: branch_ref]
    )

    Repo.update_all(
      from(followup in Followup, where: followup.publication_id in ^ids),
      set: [merge_sha: merge_sha, pr_state: "merged"]
    )

    signal = typed_lifecycle_input(["release/shared"], "deployment", "succeeded")
    assert Followups.observe_input(signal) == {:ok, 1}

    assert Repo.get_by(LifecycleEvent,
             publication_id: ryker.id,
             kind: "deployment",
             state: "succeeded"
           )

    refute Repo.get_by(LifecycleEvent, publication_id: other.id, kind: "deployment")

    unauthorized =
      put_in(
        signal.source_capabilities,
        ["publication_lifecycle", "repositories"],
        ["other"]
      )
      |> then(&%{signal | source_capabilities: &1})

    assert Followups.observe_input(unauthorized) == {:ok, 0}
  end

  test "typed lifecycle correlation is not capped at one hundred active publications" do
    publications =
      for index <- 1..101 do
        PublicationFixture.published!("lifecycle-cap-#{index}",
          pull_request_number: 1_000 + index
        ).publication
      end

    ids = Enum.map(publications, & &1.id)
    branch_ref = "refs/heads/release/all-active"

    Repo.update_all(
      from(publication in Publication, where: publication.id in ^ids),
      set: [branch_ref: branch_ref]
    )

    Repo.update_all(
      from(followup in Followup, where: followup.publication_id in ^ids),
      set: [merge_sha: String.duplicate("a", 40), pr_state: "merged"]
    )

    assert Followups.observe_input(
             typed_lifecycle_input(["release/all-active"], "deployment", "pending")
           ) == {:ok, 101}

    assert Repo.aggregate(
             from(event in LifecycleEvent,
               where: event.publication_id in ^ids and event.kind == "deployment"
             ),
             :count
           ) == 101
  end

  test "manual status checks and lifecycle delivery retain exact lease and receipt custody" do
    %{publication: publication} = PublicationFixture.published!("manual-check")

    assert {:ok, %{status: :requested}} =
             Followups.request_check(publication.ref, "manual-check:1")

    assert {:ok, %{status: :duplicate}} =
             Followups.request_check(publication.ref, "manual-check:1")

    assert {:ok, claim} = Followups.claim_poll("publication-followup:manual", 60)
    assert {:ok, renewed} = Followups.renew_poll(publication.ref, claim.lease_ref, 120)
    assert renewed.lease_ref == claim.lease_ref

    pending = lifecycle_status(publication, "pending", false)
    assert {:ok, stored} = Followups.store_poll(publication.ref, claim.lease_ref, pending, 120)
    assert stored.manual_check_ref == nil

    event = Repo.get_by!(LifecycleEvent, publication_id: publication.id, kind: "status")
    assert event.state == "pending"

    assert {:ok, delivery_claim} =
             Followups.claim_delivery("publication-followup:manual-delivery", 60)

    assert delivery_claim.event.id == event.id

    assert {:ok, renewed_event} =
             Followups.renew_delivery(event.ref, delivery_claim.lease_ref, 120)

    assert renewed_event.lease_ref == delivery_claim.lease_ref
    assert {:ok, request} = Followups.delivery_request(renewed_event)
    assert request.document["message"] =~ "GitHub checks are pending"

    assert {:ok, deferred} =
             Followups.defer_delivery(event.ref, delivery_claim.lease_ref, 1, :slack_unavailable)

    assert deferred.last_error =~ "slack_unavailable"
    assert deferred.lease_ref == nil

    Repo.update_all(
      from(saved in LifecycleEvent, where: saved.id == ^event.id),
      set: [next_attempt_at: @now]
    )

    assert {:ok, retry_claim} =
             Followups.claim_delivery("publication-followup:manual-delivery-retry", 60)

    assert {:ok, admitted} = Followups.admit_wakeup(event.ref, retry_claim.lease_ref)
    assert admitted.wakeup_state == :none

    {:ok, receipt} =
      DeliveryReceipt.new(
        request.ref,
        request.transport,
        request.conversation_ref,
        request.thread_ref,
        "message:manual-check"
      )

    assert {:ok, delivered} =
             Followups.confirm_delivery(event.ref, retry_claim.lease_ref, receipt)

    assert delivered.delivery_state == :delivered
    assert {:ok, duplicate} = Followups.confirm_delivery(event.ref, "expired-lease", receipt)
    assert duplicate.id == delivered.id

    {:ok, crossed_receipt} =
      DeliveryReceipt.new(
        request.ref,
        request.transport,
        request.conversation_ref,
        request.thread_ref,
        "message:other"
      )

    assert Followups.confirm_delivery(event.ref, "expired-lease", crossed_receipt) ==
             {:error, :publication_lifecycle_delivery_conflict}

    assert Followups.delivery_request(delivered) ==
             {:error, :publication_lifecycle_delivery_not_pending}
  end

  test "failed, closed, stale, and deadline-expired pull requests become durable lifecycle facts" do
    %{publication: failed_publication} = PublicationFixture.published!("checks-failed")
    assert {:ok, failed_claim} = Followups.claim_poll("publication-followup:failed", 60)

    failing =
      failed_publication
      |> lifecycle_status("failing", false)
      |> Map.merge(%{"checks_failed" => 2, "checks_passed" => 0})

    assert {:ok, failed} =
             Followups.store_poll(failed_publication.ref, failed_claim.lease_ref, failing, 60)

    assert failed.checks_state == "failing"

    assert %LifecycleEvent{state: "failed"} =
             Repo.get_by!(LifecycleEvent,
               publication_id: failed_publication.id,
               kind: "checks"
             )

    Repo.update_all(
      from(saved in Followup, where: saved.publication_id == ^failed_publication.id),
      set: [next_poll_at: @now]
    )

    assert {:ok, close_claim} = Followups.claim_poll("publication-followup:closed", 60)
    closed = %{failing | "state" => "closed", "draft" => false}

    assert {:ok, closed_followup} =
             Followups.store_poll(failed_publication.ref, close_claim.lease_ref, closed, 60)

    assert closed_followup.pr_state == "closed"

    assert %LifecycleEvent{state: "stopped"} =
             Repo.get_by!(LifecycleEvent,
               publication_id: failed_publication.id,
               kind: "closed"
             )

    %{publication: stale_publication} = PublicationFixture.published!("stale-head")
    assert {:ok, stale_claim} = Followups.claim_poll("publication-followup:stale", 60)

    stale_status =
      stale_publication
      |> lifecycle_status("pending", false)
      |> Map.put("head_sha", String.duplicate("d", 40))

    assert {:ok, stale_followup} =
             Followups.store_poll(stale_publication.ref, stale_claim.lease_ref, stale_status, 60)

    assert stale_followup.pr_state == "stale"

    assert Repo.get!(Publication, stale_publication.id).expected_remote_head_sha ==
             stale_status["head_sha"]

    %{publication: expired_publication} = PublicationFixture.published!("deadline")

    Repo.update_all(
      from(saved in Followup, where: saved.publication_id == ^expired_publication.id),
      set: [
        deadline_at: @now,
        inserted_at: DateTime.add(@now, -1, :second),
        next_poll_at: @now
      ]
    )

    assert {:ok, deadline_claim} = Followups.claim_poll("publication-followup:deadline", 60)

    assert {:ok, expired_followup} =
             Followups.store_poll(
               expired_publication.ref,
               deadline_claim.lease_ref,
               lifecycle_status(expired_publication, "pending", false),
               60
             )

    assert expired_followup.pr_state == "expired"
  end

  # The agent corrected the failure and the host republished, so the pull request
  # tracks a newer head. A poll that was already in flight carries the older
  # head's result; letting it through would report checks green for an attempt
  # that observation predates. Two independent fences refuse it, and the test
  # names both because either one alone is a single point of failure.
  test "a late poll for an older head cannot green a newer attempt" do
    %{publication: publication} = PublicationFixture.published!("late-callback")
    older_head = publication.commit_sha

    assert {:ok, in_flight} = Followups.claim_poll("publication-followup:late", 60)
    assert in_flight.publication.id == publication.id

    # This poller's GitHub call outlived its lease, and meanwhile the corrected
    # candidate reached the same pull request, so the publication now records a
    # newer head.
    Repo.update_all(
      from(saved in Followup, where: saved.publication_id == ^publication.id),
      set: [lease_expires_at: @now]
    )

    newer_head = String.duplicate("f", 40)
    republish!(publication, newer_head)

    late =
      publication
      |> lifecycle_status("passing", false)
      |> Map.put("head_sha", older_head)

    # The recovery reset this follow-up, so the in-flight lease is no longer the
    # one that owns the poll.
    assert Followups.store_poll(publication.ref, in_flight.lease_ref, late, 120) ==
             {:error, :publication_followup_lease_lost}

    assert Repo.get_by!(Followup, publication_id: publication.id).checks_state == "unknown"

    # Even from a live lease, a result describing a head this publication is no
    # longer at cannot record a passing check.
    assert {:ok, fresh} = Followups.claim_poll("publication-followup:late-fresh", 60)

    assert {:ok, fenced} = Followups.store_poll(publication.ref, fresh.lease_ref, late, 120)
    assert fenced.pr_state == "stale"
    assert fenced.checks_state == "unknown"

    refute Repo.get_by(LifecycleEvent,
             publication_id: publication.id,
             kind: "checks",
             state: "succeeded"
           )
  end

  test "a stale published draft can be review-refreshed by exact generation" do
    %{publication: update_publication} = PublicationFixture.published!("stale-update")
    observed_update_head = String.duplicate("d", 40)
    mark_stale!(update_publication, observed_update_head)

    assert {:ok, %{publication: refreshed}} =
             Custody.recover(update_publication.ref, :update, 1)

    assert refreshed.status == :review_pending
    assert refreshed.recovery_generation == 2
    assert refreshed.review_generation == update_publication.review_generation + 1
    assert refreshed.expected_remote_head_sha == observed_update_head
    assert refreshed.branch_ref == update_publication.branch_ref
    assert refreshed.pull_request_number == update_publication.pull_request_number
    assert refreshed.publication_receipt == nil
    assert refreshed.published_delivery_receipt == nil
    assert refreshed.approval_ref == nil
    assert Repo.get_by!(Followup, publication_id: refreshed.id).pr_state == "open"

    Repo.update_all(
      from(followup in Followup, where: followup.publication_id == ^refreshed.id),
      set: [next_poll_at: @now]
    )

    assert {:ok, nil} = Followups.claim_poll("publication-followup:re-review", 60)

    Repo.update_all(
      from(followup in Followup, where: followup.publication_id == ^refreshed.id),
      set: [pr_state: "open"]
    )

    Repo.update_all(
      from(publication in Publication, where: publication.id == ^refreshed.id),
      set: [
        approval_ref: "interaction:republish",
        approved_at: @now,
        approved_by_actor_ref: "slack:user:U-operator",
        last_error_code: "publication_branch_changed",
        last_error_detail: "The draft head changed again before the leased push.",
        review_delivery_receipt: update_publication.review_delivery_receipt,
        review_delivery_receipt_fingerprint:
          update_publication.review_delivery_receipt_fingerprint,
        review_document: update_publication.review_document,
        review_fingerprint: update_publication.review_fingerprint,
        review_patch: update_publication.review_patch,
        reviewed_at: update_publication.reviewed_at,
        status: :publish_pending
      ]
    )

    assert {:ok, %{publication: conflict_refreshed}} =
             Custody.recover(update_publication.ref, :update, 2)

    assert conflict_refreshed.status == :review_pending
    assert conflict_refreshed.recovery_generation == 3
    assert conflict_refreshed.approval_ref == nil
  end

  test "a stale published draft can be discarded by exact generation" do
    %{publication: discard_publication} = PublicationFixture.published!("stale-discard")
    observed_discard_head = String.duplicate("e", 40)
    mark_stale!(discard_publication, observed_discard_head)

    assert {:ok, %{publication: discarded}} =
             Custody.recover(discard_publication.ref, :discard, 1)

    assert discarded.status == :discarded
    assert discarded.recovery_generation == 2
    assert discarded.expected_remote_head_sha == observed_discard_head
    assert discarded.publication_receipt == discard_publication.publication_receipt

    assert discarded.published_delivery_receipt ==
             discard_publication.published_delivery_receipt
  end

  test "follow-up public boundaries fail closed without queue mutation" do
    assert {:error, _reason} = Followups.claim_poll("", 0)
    assert {:error, _reason} = Followups.claim_delivery("", 0)
    assert {:error, _reason} = Followups.request_check("", "")
    assert Followups.nudge_github_event(nil, nil, nil, nil) == {:ok, :ignored}

    assert Followups.nudge_github_event("acme/ryker", "unknown", "delivery", %{}) ==
             {:ok, :ignored}

    assert Followups.observe_input(%{}) ==
             {:error, {:invalid_publication_lifecycle_input, :input}}

    assert Followups.observe_github_feedback(%{}) ==
             {:error, {:invalid_publication_review_feedback, :input}}

    slack_input = lifecycle_input("ordinary Slack input", "message", "created")

    assert Followups.observe_github_feedback(slack_input) ==
             {:error, {:invalid_publication_review_feedback, :source}}

    github_input = %{
      slack_input
      | content: %{"event_name" => "push", "payload" => %{}},
        source: %{kind: "github", ref: "ryker-app"}
    }

    assert Followups.observe_github_feedback(github_input) == {:ok, :unmatched}

    unmatched_review = %{
      github_input
      | content: %{
          "event_name" => "issue_comment",
          "payload" => %{
            "issue" => %{"number" => 404, "pull_request" => %{}},
            "repository" => %{"full_name" => "octo/missing"}
          }
        }
    }

    assert Followups.observe_github_feedback(unmatched_review) == {:ok, :unmatched}

    assert {:error, _reason} = Followups.store_poll("publication", "lease", %{}, 0)
    assert {:error, _reason} = Followups.defer_poll("publication", "lease", 0, :failed)
    assert {:error, _reason} = Followups.reconcile_verification("publication", "lease", 0)
    assert {:error, _reason} = Followups.renew_poll("publication", "lease", 0)
    assert {:error, _reason} = Followups.renew_delivery("event", "lease", 0)
    assert {:error, _reason} = Followups.defer_delivery("event", "lease", 0, :failed)

    assert Followups.delivery_request(%{}) ==
             {:error, :publication_lifecycle_delivery_not_pending}

    assert Followups.request_check("publication:missing", "request:1") ==
             {:error, :publication_followup_not_found}

    assert Followups.renew_delivery("event:missing", "lease:1", 60) ==
             {:error, :publication_lifecycle_event_not_found}

    assert Followups.defer_delivery("event:missing", "lease:1", 60, :failed) ==
             {:error, :publication_lifecycle_event_not_found}

    assert Followups.admit_wakeup("event:missing", "lease:1") ==
             {:error, :publication_lifecycle_event_not_found}

    assert Followups.delivery_request(%LifecycleEvent{
             delivery_state: :pending,
             publication_id: Ecto.UUID.generate()
           }) == {:error, :publication_not_found}
  end

  defp deliver_pending! do
    case Followups.claim_delivery("publication-followup:delivery", 60) do
      {:ok, nil} ->
        :ok

      {:ok, claim} ->
        assert {:ok, _event} = Followups.admit_wakeup(claim.event.ref, claim.lease_ref)
        assert {:ok, request} = Followups.delivery_request(claim.event)

        {:ok, receipt} =
          DeliveryReceipt.new(
            request.ref,
            request.transport,
            request.conversation_ref,
            request.thread_ref,
            "message:#{claim.event.id}"
          )

        assert {:ok, _event} =
                 Followups.confirm_delivery(claim.event.ref, claim.lease_ref, receipt)

        deliver_pending!()
    end
  end

  defp lifecycle_status(publication, checks_state, merged, merge_sha \\ nil) do
    %{
      "base_ref" => "main",
      "checks_failed" => 0,
      "checks_passed" => 2,
      "checks_state" => checks_state,
      "checks_total" => 2,
      "checks_url" => "#{publication.pull_request_url}/checks",
      "draft" => not merged,
      "head_ref" => String.replace_prefix(publication.branch_ref, "refs/heads/", ""),
      "head_sha" => publication.commit_sha,
      "merge_sha" => merge_sha,
      "merged" => merged,
      "merged_at" => if(merged, do: "2026-08-28T12:05:00Z", else: nil),
      "number" => publication.pull_request_number,
      "state" => if(merged, do: "closed", else: "open"),
      "url" => publication.pull_request_url
    }
  end

  # Exactly the row state `persist_publication/3` leaves once the corrected
  # candidate reaches the same pull request: a newer head, nothing outstanding.
  defp republish!(publication, head_sha) do
    {1, _rows} =
      Repo.update_all(
        from(row in Publication, where: row.id == ^publication.id),
        set: [commit_sha: head_sha, expected_remote_head_sha: nil]
      )

    :ok
  end

  defp mark_stale!(publication, head_sha) do
    Repo.update_all(
      from(saved in Followup, where: saved.publication_id == ^publication.id),
      set: [next_poll_at: @now]
    )

    assert {:ok, claim} = Followups.claim_poll("publication-followup:#{publication.id}", 60)

    status =
      publication
      |> lifecycle_status("pending", false)
      |> Map.put("head_sha", head_sha)

    assert {:ok, %Followup{pr_state: "stale"}} =
             Followups.store_poll(publication.ref, claim.lease_ref, status, 60)
  end

  defp lifecycle_input(text, event_type, status) do
    lifecycle_input_with(
      :app,
      %{
        "event_type" => event_type,
        "payload" => %{"message" => text, "status" => status}
      },
      "#{event_type}:#{status}:#{:erlang.phash2(text)}"
    )
  end

  defp typed_lifecycle_input(references, kind, state) do
    authorized_lifecycle_input(
      typed_lifecycle_content(references, kind, state),
      "#{kind}:#{state}:#{:erlang.phash2(references)}"
    )
  end

  defp typed_lifecycle_content(references, kind, state) do
    %{
      "event_type" => "responder.publication_lifecycle.v1",
      "payload" => %{
        "environment" => "production",
        "kind" => kind,
        "references" => references,
        "repository" => "ryker",
        "run_ref" => "deployment-run:#{Ecto.UUID.generate()}",
        "state" => state,
        "target" => "ryker"
      }
    }
  end

  defp authorized_lifecycle_input(content, suffix) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :system, ref: "webhook-route:deployments"},
        content: content,
        destination: %{
          conversation_ref: "slack:T123:C-deployments",
          thread_ref: "deployment-thread",
          transport: "slack"
        },
        event_kind: :event,
        event_ref: "lifecycle:#{suffix}:#{Ecto.UUID.generate()}",
        native_input_id: "lifecycle-item:#{suffix}:#{Ecto.UUID.generate()}",
        occurred_at: @now,
        occurred_at_source: :source,
        revision: 1,
        source: %{kind: "webhook", ref: "deployments"},
        source_capabilities: %{
          "publication_lifecycle" => %{
            "environments" => ["production"],
            "kinds" => ["deployment", "terraform"],
            "repositories" => ["ryker"],
            "targets" => ["ryker"]
          }
        },
        source_item_ref: nil
      })

    input
  end

  defp feedback_input(suffix) do
    base = lifecycle_input_with(:user, %{}, suffix)

    %{
      base
      | source: %{kind: "github", ref: "ryker-app"},
        content: %{
          "event_name" => "issue_comment",
          "numeric_value" => 1,
          "payload" => %{
            "issue" => %{"number" => 74, "pull_request" => %{}},
            "repository" => %{"full_name" => "octo/feedback-equivalence"}
          }
        }
    }
  end

  defp lifecycle_input_with(actor_kind, content, suffix) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: actor_kind, ref: "lifecycle-actor"},
        content: content,
        destination: %{
          conversation_ref: "slack:T123:C-deployments",
          thread_ref: "deployment-thread",
          transport: "slack"
        },
        event_kind: :event,
        event_ref: "lifecycle:#{suffix}:#{Ecto.UUID.generate()}",
        native_input_id: "lifecycle-item:#{suffix}:#{Ecto.UUID.generate()}",
        occurred_at: @now,
        occurred_at_source: :source,
        revision: 1,
        source: %{kind: "slack", ref: "T123"},
        source_capabilities: %{},
        source_item_ref: nil
      })

    input
  end

  defp insert_result_event!(episode_id, sequence, turn_ref) do
    payload = %{
      "decision_reason" => "Verified exact deployment state.",
      "delivery" => "none",
      "delivery_ref" => nil,
      "episode_key" => "publication-verification-test",
      "expected_turn_ref" => turn_ref,
      "kind" => "accept_result",
      "next_turn_ref" => nil,
      "occurred_at" => DateTime.to_iso8601(@now),
      "result_ref" => "result:#{sequence}"
    }

    %Event{
      dedupe_key: "result:verification:#{sequence}",
      fingerprint: Ryker.CanonicalJSON.digest(payload),
      kind: :result_accepted,
      occurred_at: @now,
      payload: payload,
      sequence: sequence
    }
    |> EventChangeset.insert(episode_id)
    |> Repo.insert!()
  end
end
