defmodule Responder.Publication.FollowupsTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Episodes.{Event, EventChangeset}
  alias Responder.Fixtures.Publication, as: PublicationFixture
  alias Responder.Ingress.Input
  alias Responder.Publication.{Followup, Followups, LifecycleEvent}
  alias Responder.Work.DeliveryReceipt

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

    unrelated = lifecycle_input("unrelated", "deployment", "succeeded")
    assert Followups.observe_input(unrelated) == {:ok, 0}

    correlated =
      lifecycle_input(
        "Deploying #{publication.branch_ref} from #{publication.commit_sha}",
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

    assert Followups.nudge_github_event("acme/responder", "pull_request", "delivery:1", payload) ==
             {:ok, :nudged}

    assert {:ok, claim} = Followups.claim_poll("publication-followup:webhook", 60)
    assert claim.publication.id == publication.id

    crossed = put_in(payload, ["pull_request", "head", "sha"], String.duplicate("c", 40))

    assert Followups.nudge_github_event(
             "acme/responder",
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
        source: %{kind: "github", ref: "responder-app"}
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
        source: %{kind: "github", ref: "responder-app"},
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
               "acme/responder",
               event,
               "delivery:envelope:#{index}",
               payload
             ) == {:ok, :nudged}
    end)

    assert Followups.nudge_github_event(
             "acme/responder",
             "status",
             "delivery:status",
             %{"sha" => sha}
           ) == {:ok, :ignored}

    assert Followups.nudge_github_event(
             "acme/responder",
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

  test "nested deployment and Terraform signals correlate exact publications without trusting prose" do
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

    terraform = %{
      "payload" => %{
        "attempt" => 1,
        "references" => [publication.pull_request_url],
        "terraform" => %{"status" => "applied"}
      }
    }

    assert Followups.observe_input(lifecycle_input_with(:app, terraform, "terraform")) ==
             {:ok, 1}

    deployment_failure = %{
      "events" => [
        %{"deployment" => publication.branch_ref},
        %{"conclusion" => "timed_out"}
      ]
    }

    assert Followups.observe_input(
             lifecycle_input_with(:bot, deployment_failure, "deployment-failed")
           ) == {:ok, 1}

    deployment_pending = %{
      "deployment" => %{
        "head" => publication.commit_sha,
        "status" => "running"
      }
    }

    assert Followups.observe_input(
             lifecycle_input_with(:system, deployment_pending, "deployment-pending")
           ) == {:ok, 1}

    unknown = %{
      "deployment" => publication.commit_sha,
      "status" => %{"unexpected" => true}
    }

    assert Followups.observe_input(lifecycle_input_with(:app, unknown, "unknown")) == {:ok, 0}

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

  test "follow-up public boundaries fail closed without queue mutation" do
    assert {:error, _reason} = Followups.claim_poll("", 0)
    assert {:error, _reason} = Followups.claim_delivery("", 0)
    assert {:error, _reason} = Followups.request_check("", "")
    assert Followups.nudge_github_event(nil, nil, nil, nil) == {:ok, :ignored}

    assert Followups.nudge_github_event("acme/responder", "unknown", "delivery", %{}) ==
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
        source: %{kind: "github", ref: "responder-app"}
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
      fingerprint: Responder.CanonicalJSON.digest(payload),
      kind: :result_accepted,
      occurred_at: @now,
      payload: payload,
      sequence: sequence
    }
    |> EventChangeset.insert(episode_id)
    |> Repo.insert!()
  end
end
