defmodule Responder.GitHub.ConfirmationsTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.GitHub.{Binding, Confirmations, Input}
  alias Responder.Repo
  alias Responder.State.{Behavior, MemoryEntry, Record, Records, Schedule}
  alias Responder.Work.{Custody, DeliveryReceipt, Result, Session, Submission}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @digest String.duplicate("b", 64)

  test "an authenticated exact-thread command confirms each offer at most once" do
    fixture = delivered_offers!()
    task_input = input!("/responder confirm #{fixture.task.ref}", 9_101, 42)

    assert {:ok,
            %{
              "kind" => "task_offer",
              "record_ref" => task_ref,
              "resource_ref" => task_episode_ref,
              "status" => "confirmed"
            }} = Confirmations.apply(task_input, options())

    assert task_ref == fixture.task.ref
    assert is_binary(task_episode_ref)

    assert %Session{policy: "responder-contributor", repository_ref: "responder"} =
             Repo.get_by!(Session, policy: "responder-contributor")

    assert {:ok, %{"resource_ref" => ^task_episode_ref, "status" => "duplicate"}} =
             Confirmations.apply(
               input!("/responder confirm #{fixture.task.ref}", 9_102, 42),
               options()
             )

    assert Repo.aggregate(Session, :count, :id) == 2

    assert {:ok,
            %{
              "kind" => "memory_offer",
              "record_ref" => memory_ref,
              "resource_ref" => "memory:" <> _,
              "status" => "confirmed"
            }} =
             Confirmations.apply(
               input!("/responder confirm #{fixture.memory.ref}", 9_103, 42),
               options()
             )

    assert memory_ref == fixture.memory.ref
    assert Repo.aggregate(MemoryEntry, :count, :id) == 1

    for {record, resource_prefix} <- [
          {fixture.preference, "behavior:"},
          {fixture.guidance, "behavior:"},
          {fixture.assignment, "behavior:"},
          {fixture.schedule, "schedule:"}
        ] do
      assert {:ok,
              %{
                "record_ref" => record_ref,
                "resource_ref" => resource_ref,
                "status" => "confirmed"
              }} =
               Confirmations.apply(
                 input!(
                   "/responder confirm #{record.ref}",
                   System.unique_integer([:positive]),
                   42
                 ),
                 options()
               )

      assert record_ref == record.ref
      assert String.starts_with?(resource_ref, resource_prefix)
    end

    assert Repo.aggregate(Behavior, :count, :id) == 3
    assert Repo.aggregate(Schedule, :count, :id) == 1
  end

  test "commands copied to another thread or pointing at unsupported records fail closed" do
    fixture = delivered_offers!()

    assert Confirmations.apply(
             input!("/responder confirm #{fixture.task.ref}", 9_201, 99),
             options()
           ) == {:ok, %{"status" => "invalid"}}

    unsupported = input!("/responder confirm record:publication_offer:abc123", 9_202, 42)

    assert Confirmations.apply(unsupported, options()) ==
             {:ok, %{"status" => "invalid"}}

    assert Confirmations.apply(input!("ordinary conversation", 9_203, 42), options()) ==
             {:ok, :not_confirmation}

    assert Confirmations.apply(input!("/responder confirm", 9_204, 42), options()) ==
             {:ok, %{"status" => "invalid"}}

    assert Confirmations.apply(unsupported, nil) == {:ok, %{"status" => "invalid"}}

    assert Confirmations.apply(input!("ordinary unconfigured conversation", 9_205, 42), nil) ==
             {:ok, :not_confirmation}

    assert Repo.get!(Record, fixture.task.id).status == :open
    assert Repo.aggregate(Session, :count, :id) == 1
  end

  test "confirmation configuration accepts only exact repository policies" do
    assert Confirmations.options!(
             repositories: %{
               "responder" => %{name: "responder-contributor", digest: @digest}
             }
           ) == %{
             repositories: %{
               "responder" => %{name: "responder-contributor", digest: @digest}
             }
           }

    for invalid <- [
          nil,
          [],
          [repositories: %{}, repositories: %{}],
          %{repositories: %{}, unknown: true},
          %{repositories: %{}},
          %{repositories: %{"octo/example with spaces" => %{name: "policy", digest: @digest}}},
          %{
            repositories: %{
              "responder" => %{contributor_policy: %{name: "policy", digest: "not-a-digest"}}
            }
          },
          %{repositories: %{"responder" => %{contributor_policy: :invalid}}},
          %{repositories: %{"responder" => :invalid}}
        ] do
      assert_raise ArgumentError, fn -> Confirmations.options!(invalid) end
    end

    assert Confirmations.apply(:invalid, nil) ==
             {:error, :invalid_github_confirmation_options}

    assert Confirmations.apply(input!("ordinary conversation", 9_206, 42), %{}) ==
             {:error, :invalid_github_confirmation_options}
  end

  defp delivered_offers! do
    episode_id = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 actor_ref: "github:user:github-user:7",
                 destination: %{
                   conversation_ref: "github:github-main:repository:99",
                   thread_ref: "github:github-main:pull:42",
                   transport: "github"
                 },
                 episode_id: episode_id,
                 episode_key: "github-confirmation:#{episode_id}",
                 native_input_id: "github-item:confirmation:#{episode_id}",
                 occurred_at: @now,
                 payload: %{"text" => "Prepare the exact offer."},
                 turn_ref: "turn:github-confirmation:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(
               episode_id,
               "github-conversation",
               String.duplicate("a", 64),
               "responder"
             )

    assert {:ok, claim} = Custody.claim_next("github-confirmation", 60, :work)

    assert {:ok, task} =
             Records.create(Records.token(claim.turn), "github-task", "task_offer", %{
               "kind" => "engineering",
               "prompt" => "Implement the GitHub adapter and run focused tests.",
               "repository" => "responder",
               "title" => "Complete the GitHub adapter"
             })

    assert {:ok, memory} =
             Records.create(Records.token(claim.turn), "github-memory", "memory_offer", %{
               "expires_in" => "30d",
               "kind" => "entity_relationship",
               "repository" => "responder",
               "scope" => "repository",
               "subject" => "github_adapter",
               "value" => "GitHub uses the generic ingress contract.",
               "visibility" => "workspace"
             })

    assert {:ok, preference} =
             Records.create(Records.token(claim.turn), "github-preference", "preference_offer", %{
               "expires_in" => "30d",
               "key" => "response_detail",
               "repository" => nil,
               "scope" => "conversation",
               "value" => "concise"
             })

    assert {:ok, guidance} =
             Records.create(Records.token(claim.turn), "github-guidance", "guidance_offer", %{
               "expires_in" => "30d",
               "repository" => nil,
               "scope" => "conversation",
               "subject" => "review_style",
               "summary" => "Lead with material risk.",
               "text" => "Lead with material risk and retain exact source references.",
               "visibility" => "conversation"
             })

    assert {:ok, assignment} =
             Records.create(
               Records.token(claim.turn),
               "github-assignment",
               "standing_assignment_offer",
               %{
                 "action" => "review_terraform_plan",
                 "expires_in" => "30d",
                 "repository" => "responder",
                 "source_filter" => "app",
                 "task" => "Review the exact posted Terraform plan and report material risk.",
                 "trigger" => "terraform_plan"
               }
             )

    assert {:ok, schedule} =
             Records.create(Records.token(claim.turn), "github-schedule", "schedule_offer", %{
               "authority" => "read_only",
               "catch_up" => "latest",
               "expires_at" => nil,
               "recurrence" => %{"kind" => "daily", "time" => "09:00:00"},
               "repository" => nil,
               "task" => "Inspect current service health.",
               "timezone" => "Etc/UTC",
               "title" => "Daily service health"
             })

    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => episode_id},
               "Prepare offers.",
               %{"type" => "object"},
               "work-final-v1"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:github-confirmation"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:github-confirmation"
             )

    candidate = Jason.encode!(%{"delivery" => "reply", "message" => "Offers ready."})
    sha256 = digest(candidate)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} =
             Result.new(:reply, %{
               "decision_reason" => nil,
               "delivery" => "reply",
               "message" => "Offers ready.",
               "outcome" => %{
                 "artifact_refs" => [],
                 "record_refs" =>
                   Enum.map(
                     [task, memory, preference, guidance, assignment, schedule],
                     & &1.ref
                   ),
                 "state" => "complete"
               }
             })

    assert {:ok, _turn} =
             Custody.prepare_validation(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               episode_id,
               transition.episode.key,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation:github-confirmation"
             )

    assert {:ok, delivery} = Custody.claim_next("github-confirmation-delivery", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "github",
               "github:github-main:repository:99",
               "github:github-main:pull:42",
               "github:pull_request_review:9100"
             )

    assert {:ok, _settled} =
             Custody.confirm_delivery(
               episode_id,
               transition.episode.key,
               turn.turn_ref,
               delivery.lease_ref,
               receipt
             )

    %{
      assignment: assignment,
      guidance: guidance,
      memory: memory,
      preference: preference,
      schedule: schedule,
      task: task
    }
  end

  defp input!(body, comment_id, issue_number) do
    assert {:ok, input} =
             Input.normalize(
               %{
                 delivery_ref: "delivery:#{comment_id}",
                 event_name: "issue_comment",
                 event_ref: "github-body:#{digest("event:#{comment_id}")}",
                 payload: %{
                   "action" => "created",
                   "comment" => %{
                     "body" => body,
                     "created_at" => "2026-08-28T12:05:00Z",
                     "id" => comment_id,
                     "updated_at" => "2026-08-28T12:05:00Z"
                   },
                   "installation" => %{"id" => 41},
                   "issue" => %{"number" => issue_number, "pull_request" => %{}},
                   "repository" => %{"full_name" => "octo/example", "id" => 99},
                   "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"}
                 }
               },
               binding!()
             )

    input
  end

  defp binding! do
    assert {:ok, binding} =
             Binding.new(%{
               authorized_actor_ids: [7],
               installation_id: 41,
               name: "github-main",
               repository_full_name: "octo/example",
               repository_id: 99,
               responder_actor_id: 99,
               secret: String.duplicate("s", 32)
             })

    binding
  end

  defp options do
    Confirmations.options!(%{
      repositories: %{
        "responder" => %{
          contributor_policy: %{digest: @digest, name: "responder-contributor"}
        }
      }
    })
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
