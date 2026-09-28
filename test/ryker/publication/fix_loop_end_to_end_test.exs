defmodule Ryker.Publication.FixLoopEndToEndTest do
  @moduledoc """
  The whole fix loop through the running parts: a Slack-confirmed task commits,
  Coop's trusted review refuses the change because the repository's checks
  failed, and the publication Dispatcher sends it back to the task's own Work,
  which the Work Executor runs as a new turn in the same Coop session. Its new
  commit is reviewed by the ordinary path and opens the task's draft pull
  request. Coop is the recorded fake throughout; no model is called.
  """
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Delivery.Adapters
  alias Ryker.Delivery.Dispatcher, as: DeliveryDispatcher
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.Publication.{Dispatcher, Publication}
  alias Ryker.Records
  alias Ryker.Records.{Record, TaskOffers}
  alias Ryker.Repo

  alias Ryker.Slack.{Gateway, InteractionHandler, Operators, Publisher, WorkControls}

  alias Ryker.TestSupport.{FakeSlackAPI, FakeWorkCoopAPI}
  alias Ryker.Work.{Custody, Executor, Session, SubmissionBuilder}

  @now ~U[2026-09-28 13:00:00.000000Z]
  @read_policy_digest String.duplicate("a", 64)
  @write_policy_digest String.duplicate("b", 64)

  defmodule Directory do
    @behaviour Ryker.Slack.MemberDirectory

    @impl true
    def user_allowed(_client, "U123", "T123"), do: {:ok, true}
    def user_allowed(_client, _actor_ref, "T123"), do: {:ok, false}
  end

  # Coop's review answers in order, one per review generation.
  defmodule PublicationCoop do
    def get_session({agent, _publisher}, _session_id), do: {:ok, Agent.get(agent, & &1.session)}

    def run_review({agent, _publisher}, _session_id, key, expected_revision) do
      Agent.get_and_update(agent, fn %{reviews: [review | reviews]} = state ->
        response = %{
          "operation" => %{
            "id" => review["operation_id"],
            "method" => "RunReview",
            "resource_id" => review["session_id"],
            "resource_type" => "review",
            "state" => "succeeded"
          },
          "review" => review
        }

        {{:ok, response},
         %{
           state
           | reviews: reviews,
             review_calls: state.review_calls ++ [{key, expected_revision}]
         }}
      end)
    end

    # The failed gate's output, one page per cursor, as the adapter will read it.
    def read_review_gate_output({agent, _publisher}, _session_id, _operation_id, cursor) do
      {:ok, Agent.get(agent, &Map.fetch!(&1.gate_output, cursor))}
    end

    def publish_review({_coop, agent}, _session_id, _review_key, _review_id, _key, body) do
      Agent.get_and_update(agent, fn state ->
        receipt = %{
          "branch_ref" => "refs/heads/" <> body["branch"],
          "candidate_tree" => body["candidate_tree"],
          "commit_sha" => body["candidate_head"],
          "pull_request_number" => 91,
          "pull_request_url" => "https://github.com/acme/ryker/pull/91",
          "repository" => "ryker"
        }

        {{:ok, receipt}, %{state | requests: state.requests ++ [body]}}
      end)
    end
  end

  # Andrew's request, 2026-09-28: "why I should ask it myself, it should be
  # automatic feedback loop, agent needs to get errors from CI, fix them without
  # me doing a man in the middle." Before this every refused change posted a
  # card asking a person to reply, and nothing moved until someone did.
  test "a confirmed task's failing checks are fixed in its own session and published, without a person" do
    {task_episode, task_session, task_api, adapters} = committed_task!()

    refused =
      task_session
      |> review_document()
      |> Map.merge(%{
        "candidate_head" => String.duplicate("8", 40),
        "gate" => "failed",
        "not_publishable_reasons" => ["gate_failed"],
        "operation_id" => "operation:review:refused",
        "publishable" => false
      })

    passed = review_document(task_session)
    failure = "FAILED test/parser_test.exs:12 expected :ok, got :retry\n"

    gate_output = %{
      nil => %{"output" => String.duplicate("compiling\n", 500), "next_cursor" => "2"},
      "2" => %{"output" => failure, "next_cursor" => nil}
    }

    {:ok, publication_coop} =
      Agent.start_link(fn ->
        %{
          gate_output: gate_output,
          reviews: [refused, passed],
          review_calls: [],
          session:
            Map.merge(FakeWorkCoopAPI.state(task_api).session, %{
              "revision" => 7,
              "state" => "open"
            })
        }
      end)

    {:ok, draft_publisher} = Agent.start_link(fn -> %{requests: []} end)
    publication_options = publication_options(publication_coop, draft_publisher, adapters)

    assert {:ok, {:executed, %{phase: :reviewed}}} = Dispatcher.run_once(publication_options)
    assert {:ok, {:executed, %{phase: :delivered}}} = Dispatcher.run_once(publication_options)

    receive_post_containing!(
      "The repository's checks failed on the committed change. I'm fixing it now, attempt 1 of 3, and I'll check the new change when I'm done."
    )

    blocked = Repo.get_by!(Publication, episode_id: task_episode.id)
    assert {blocked.status, blocked.fix_rounds} == {:blocked, 1}

    # The fix is the task's next turn, in the same Coop session.
    assert {:ok, fix_claim} = Custody.claim_next("fix-loop-e2e-fix", 60, :work)
    assert fix_claim.episode.id == task_episode.id
    assert fix_claim.session.id == task_session.id

    {:ok, fix_api} =
      FakeWorkCoopAPI.start_link([fixed_reply()],
        workspace_task: native_task_binding(task_session),
        changes: [workspace_changes()]
      )

    FakeWorkCoopAPI.update(fix_api, fn state ->
      remote_session =
        Map.merge(FakeWorkCoopAPI.state(task_api).session, %{"revision" => 9, "state" => "open"})

      %{state | session: remote_session, submit_count: 1, turn: nil}
    end)

    assert {:ok, submission} = SubmissionBuilder.build(fix_claim)

    assert {:ok, frozen} =
             Custody.freeze_submission(
               fix_claim.episode.id,
               fix_claim.turn.turn_ref,
               fix_claim.lease_ref,
               submission
             )

    assert {:ok, fixed} =
             Executor.run(%{fix_claim | turn: frozen}, executor_options(fix_api))

    assert fixed.turn.status == :delivery_pending
    assert fixed.turn.session_id == task_session.id
    assert FakeWorkCoopAPI.state(fix_api).create_count == 0
    assert Repo.aggregate(Session, :count, :id) == 2

    assert [current] = fixed.turn.submission["context"]["current_inputs"]["items"]
    request = current["content"]["content"]["correction_request"]

    assert request =~
             "Ryker's trusted review refused the committed change: the repository's checks failed on the committed change."

    assert request =~
             "The gate's complete output is the attached gate-output.txt, and its end is in review.gate_output_end."

    assert String.ends_with?(current["content"]["content"]["review"]["gate_output_end"], failure)

    # The whole output went to the worker with the turn, as the file it names.
    assert [%{artifacts: [file]}] = FakeWorkCoopAPI.state(fix_api).submissions
    assert file["name"] == "gate-output.txt"
    assert file["data"] == String.duplicate("compiling\n", 500) <> failure

    assert {:ok, {:delivered, :message, _fix_delivery_ref}} = deliver_once(adapters)
    receive_post_containing!("Fixed the failing parser test and committed the change.")

    # The fixed commit is reviewed by the ordinary path and becomes the draft.
    rearmed = Repo.get!(Publication, blocked.id)
    assert rearmed.status == :review_pending
    assert rearmed.review_generation == blocked.review_generation + 1

    for phase <- [:reviewed, :delivered, :published, :delivered] do
      assert {:ok, {:executed, %{phase: ^phase}}} = Dispatcher.run_once(publication_options)
    end

    published = Repo.get!(Publication, blocked.id)
    assert published.status == :published
    assert published.pull_request_url == "https://github.com/acme/ryker/pull/91"
    assert published.fix_rounds == 1

    assert [{"ryker:publication:review:" <> _first, 7}, {second_key, 7}] =
             Agent.get(publication_coop, & &1.review_calls)

    assert second_key == "ryker:publication:review:#{blocked.id}:g2"
    assert [%{"candidate_head" => head}] = Agent.get(draft_publisher, & &1.requests)
    assert head == passed["candidate_head"]
  end

  # A Slack-confirmed task whose first turn committed a change, delivered, with
  # its publication queued for the trusted review.
  defp committed_task! do
    claim = claim_episode!()
    assert :ok = KnowledgeSnapshot.expose(claim, [])

    assert {:ok, offer} =
             Records.create(Records.token(claim.turn), "parser-task", "task_offer", %{
               "authority_limits" => ["Only change parser-owned files."],
               "instruction_ref" => "slack-message:fix-loop-e2e",
               "kind" => "engineering",
               "prompt" => "Fix parser retry handling and run focused tests.",
               "repository" => "ryker",
               "source_refs" => ["slack-message:fix-loop-e2e"],
               "success_checks" => ["The parser retry regression passes."],
               "title" => "Fix parser retries"
             })

    {:ok, offer_api} = FakeWorkCoopAPI.start_link([task_offer_reply(offer.ref)])
    assert {:ok, _accepted} = Executor.run(claim, executor_options(offer_api))

    {:ok, slack_api} =
      FakeSlackAPI.start_link(
        observer: self(),
        render: true,
        message_ref: fn n ->
          "1788268001." <> String.pad_leading(Integer.to_string(n + 199), 6, "0")
        end
      )

    adapters = adapters!(slack_api)
    assert {:ok, {:delivered, :message, _offer_delivery}} = deliver_once(adapters)

    assert Gateway.handle_envelope(task_interaction("U123", offer.ref), gateway_settings()) ==
             {:ack, {:interaction, :confirmed}}

    confirmed = Repo.get!(Record, offer.id)
    assert {:ok, task_episode} = Episodes.fetch_by_key("task-offer:#{offer.ref}")
    assert task_episode.id == confirmed.confirmed_episode_id
    task_session = Repo.get_by!(Session, episode_id: task_episode.id)

    assert {:ok, task_claim} = Custody.claim_next("fix-loop-e2e-task", 60, :work)
    assert task_claim.episode.id == task_episode.id
    assert :ok = KnowledgeSnapshot.expose(task_claim, [])

    {:ok, task_api} =
      FakeWorkCoopAPI.start_link([writable_task_reply()],
        workspace_task: native_task_binding(task_session),
        changes: [workspace_changes()]
      )

    FakeWorkCoopAPI.update(task_api, fn state ->
      state
      |> put_in([:session, "id"], "remote_fix_loop_work")
      |> put_in([:session, "policy_digest"], @write_policy_digest)
    end)

    assert {:ok, %{status: :accepted}} = Executor.run(task_claim, executor_options(task_api))
    assert {:ok, {:delivered, :message, _task_delivery}} = deliver_once(adapters)

    assert %Publication{status: :review_pending} =
             Repo.one(from(p in Publication, where: p.episode_id == ^task_episode.id))

    {task_episode, Repo.get!(Session, task_session.id), task_api, adapters}
  end

  defp claim_episode! do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:T123:C456",
                   thread_ref: "1788268000.000100",
                   transport: "slack"
                 },
                 episode_id: episode_id,
                 episode_key: "fix-loop-e2e:#{episode_id}",
                 native_input_id: "slack-message:fix-loop-e2e",
                 occurred_at: @now,
                 payload: %{"text" => "Please propose a task to fix parser retries."},
                 turn_ref: "turn:fix-loop-e2e:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "conversation-read-only", @read_policy_digest)

    assert {:ok, claim} = Custody.claim_next("fix-loop-e2e-parent", 60, :work)
    claim
  end

  defp task_interaction(actor_ref, offer_ref) do
    %{
      "envelope_id" => "fix-loop-e2e",
      "payload" => %{
        "actions" => [
          %{
            "action_id" => "ryker_start_engineering_task",
            "type" => "button",
            "value" => offer_ref
          }
        ],
        "container" => %{
          "channel_id" => "C456",
          "is_ephemeral" => false,
          "message_ts" => "1788268001.000200",
          "thread_ts" => "1788268000.000100",
          "type" => "message"
        },
        "team" => %{"id" => "T123"},
        "type" => "block_actions",
        "user" => %{"id" => actor_ref}
      },
      "type" => "interactive"
    }
  end

  defp gateway_settings do
    %{
      client: :directory,
      directory: Directory,
      identity: %{workspace_ref: "T123"},
      interaction_audit: fn _interaction, _outcome -> {:ok, %{}} end,
      interaction_handler: InteractionHandler,
      interaction_options: %{
        client: :directory,
        confirm_task_offer: &TaskOffers.confirm/1,
        directory: Directory,
        operators:
          Operators.new(chosen: ["U123"], workspace_admins: false, workspace_ref: "T123"),
        approve_task_publication: &WorkControls.approve_publication/1,
        records: Records,
        conversation_environment: fn "T123", "C456" -> "production" end,
        environments: %{
          "production" => %{
            contributor_policies: %{
              "ryker" => %{
                digest: @write_policy_digest,
                environment_ref: "production",
                name: "ryker-contributor",
                repository_context: %{
                  "context_ref" => "production",
                  "parallel_goal_limit" => 3,
                  "primary_repository" => "ryker",
                  "read_only_repositories" => []
                },
                repository_ref: "ryker"
              }
            },
            work_profile: %WorkProfile{
              environment_ref: "production",
              parallel_goal_limit: 3,
              policy: "conversation-read-only",
              policy_digest: @read_policy_digest,
              repository_ref: "ryker"
            }
          }
        }
      }
    }
  end

  defp adapters!(slack_api) do
    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{workspaces: %{"T123" => %{api: FakeSlackAPI, client: slack_api}}},
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    adapters
  end

  defp deliver_once(adapters) do
    DeliveryDispatcher.run_once(
      adapters: adapters,
      kind: :message,
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "fix-loop-e2e-delivery"
    )
  end

  defp publication_options(coop, publisher, adapters) do
    [
      executor_options: [
        adapters: adapters,
        api: PublicationCoop,
        client: {coop, publisher},
        repositories: %{"ryker" => %{base_branch: "main", branch_prefix: "ryker"}}
      ],
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "fix-loop-e2e-publication"
    ]
  end

  defp executor_options(api) do
    [
      api: FakeWorkCoopAPI,
      client: api,
      max_block_ms: 1_000,
      max_polls: 20,
      monotonic_ms: fn -> 0 end,
      now: fn -> @now end,
      poll_interval_ms: 0,
      sleep: fn _milliseconds -> :ok end
    ]
  end

  defp receive_post_containing!(expected) do
    receive do
      {:slack_posted, _channel, _thread, document, _delivery_ref, _message_ref} = message ->
        if Jason.encode!(document) =~ expected,
          do: message,
          else: receive_post_containing!(expected)
    after
      1_000 -> flunk("did not receive Slack post containing #{inspect(expected)}")
    end
  end

  defp task_offer_reply(offer_ref) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "I prepared a repository-scoped task for your confirmation.",
      "outcome" => %{"artifact_refs" => [], "record_refs" => [offer_ref], "state" => "complete"}
    })
  end

  defp writable_task_reply do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "The parser retry fix is committed and ready for review.",
      "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
    })
  end

  defp fixed_reply do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "Fixed the failing parser test and committed the change.",
      "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
    })
  end

  defp native_task_binding(session) do
    %{
      "offer_ref" => session.workspace_task["offer_ref"],
      "id" => "task-binding-fix-loop",
      "queue_id" => "queue-fix-loop",
      "task_id" => "task-fix-loop",
      "draft_sha256" => String.duplicate("d", 64)
    }
  end

  defp workspace_changes do
    %{
      "base_commit" => "base-commit",
      "committed" => [%{"path" => "lib/parser.ex", "status" => "modified"}],
      "conflicts" => [],
      "fork_head" => "task-commit",
      "fork_tree" => "task-tree",
      "parent_head" => "base-commit",
      "parent_divergence" => %{
        "ahead" => 1,
        "base_to_fork" => 1,
        "base_to_parent" => 0,
        "behind" => 0,
        "diverged" => false
      },
      "patch_bytes" => 0,
      "patch_has_more" => false,
      "patch_next_offset" => 0,
      "patch_offset" => 0,
      "staged" => [],
      "truncated" => false,
      "unstaged" => [],
      "untracked" => []
    }
  end

  defp review_document(session) do
    %{
      "candidate_head" => String.duplicate("6", 40),
      "candidate_tree" => String.duplicate("7", 40),
      "creation_base" => String.duplicate("1", 40),
      "gate" => "passed",
      "not_publishable_reasons" => [],
      "operation_id" => "operation:review:#{session.id}",
      "parent_head" => String.duplicate("5", 40),
      "parent_tree" => String.duplicate("4", 40),
      "candidate_retained" => true,
      "patch_truncated" => false,
      "job_digest" => session.worker_job_digest,
      "policy_findings" => [],
      "publishable" => true,
      "pull_request" => nil,
      "rebase" => "clean",
      "session_id" => session.coop_session_id,
      "session_revision" => 7,
      "source_head" => String.duplicate("2", 40),
      "source_tree" => String.duplicate("3", 40)
    }
  end
end
