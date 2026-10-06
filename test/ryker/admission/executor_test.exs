defmodule Ryker.Admission.ExecutorTest do
  use Ryker.DataCase, async: true
  import Ecto.Query
  import Phoenix.LiveViewTest

  @moduletag isolation: "REPEATABLE READ"

  alias Ryker.Admission.{Executor, FleetSession, Runtime}
  alias Ryker.ControlPlane.{EpisodePage, ModelRequests}
  alias Ryker.FakeRetentionCoopAPI, as: RetentionAPI
  alias Ryker.Ingress.Inbox
  alias Ryker.Repo
  alias Ryker.Retention.Dispatcher, as: RetentionDispatcher
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.TestSupport.FakeCoopAPI, as: FakeAPI
  alias Ryker.Webhooks.{Input, Route}
  alias Ryker.Work.Session

  @now ~U[2026-08-27 12:00:00.000000Z]

  test "Coop schema validation and host semantic validation finish one admission turn" do
    assert {:ok, _} = Ryker.Instructions.save(:global, "Plain language.", 0, "operator:test")

    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please investigate the unfamiliar failure"},
               event_kind: :message,
               event_ref: "Ev-executor-valid",
               message_ref: "1787832000.000100",
               occurred_at: @now,
               revision: 1,
               thread_ref: nil,
               workspace_ref: "TE5D7C8842D32"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)
    lease_ref = claim!(entry)
    {:ok, fake} = FakeAPI.start_link([decision("start_episode")])

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert execution.result.entry.decision_action == :start_episode
    assert execution.result.entry.lease_ref == nil
    assert execution.result.episode.destination_thread_ref == "1787832000.000100"
    assert execution.cleanup == :closed

    assert %Session{policy: "admission-read-only"} =
             Repo.one!(
               from(session in Session,
                 where: session.episode_id == ^execution.result.episode.id
               )
             )

    state = FakeAPI.state(fake)

    assert Jason.decode!(state.submitted_prompt)["context"]["custom_instructions"]["global"][
             "text"
           ] == "Plain language."

    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:accept]
    assert state.closed
    assert "react" in state.schema["properties"]["action"]["enum"]

    # A minute spent admitting a greeting used to leave no inspectable request
    # or phase history. Retain the submitted artifact, not a rebuilt template.
    attempt = Repo.get_by!(Ryker.Admission.Attempt, input_id: entry.id, generation: 1)
    assert attempt.phase == "committed"
    assert attempt.submission["output_schema"] == state.schema
    assert attempt.submission["prompt"] == state.submitted_prompt
    assert attempt.session_ref == execution.session_id
    assert attempt.turn_ref == execution.turn_id
    assert Map.has_key?(attempt.milestones, "response_received")
    assert Map.has_key?(attempt.milestones, "committed")

    assert {:ok, inspector} =
             ModelRequests.project_input(entry.id, %{
               "disclosed" => ["admission-#{entry.id}-1-request"]
             })

    briefing = Enum.find(inspector.timeline, &(&1.id == "admission-#{entry.id}-1"))
    request = Enum.find(briefing.sections, &(&1.id == "request"))
    assert request.artifact.state == :retained
    assert request.artifact.text =~ "Please investigate the unfamiliar failure"

    html = render_component(&EpisodePage.message_page/1, view: inspector)

    # How the search found earlier work is a card of its own before the briefing.
    assert html =~ "Search for related history"
    refute html =~ "Selection evidence"
    assert html =~ "Raw routing response"
    refute html =~ "Observed execution milestones"
    assert html =~ "Routing briefing"
  end

  test "a completed admission closes a Coop session that exhausted its final turn" do
    entry = record_slack_input!("Ev-executor-exhausted-session")
    lease_ref = claim!(entry)

    {:ok, fake} =
      FakeAPI.start_link([decision("reply")], exhaust_after_validation: true)

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert execution.result.entry.decision_action == :reply
    assert execution.cleanup == :closed
    assert FakeAPI.state(fake).session["state"] == "closed"
  end

  # Live install, 2026-09-26: validating, closing the session and saving the
  # decision took 6.4 s of the 28.6 s a plain "hi" took, and the person waited
  # for the close although nothing they see depends on it. The decision is
  # saved first; the close follows.
  test "a routing decision is saved before its session is closed" do
    entry = record_slack_input!("Ev-executor-save-first")
    lease_ref = claim!(entry)
    {:ok, fake} = FakeAPI.start_link([decision("reply")])
    caller = self()

    options =
      executor_options(fake, lease_ref) ++
        [
          settle_execution_session: fn closed_for, _session_id ->
            {:ok, current} = Inbox.fetch(Inbox.ref(closed_for))
            send(caller, {:closed_when, current.status})
            :ok
          end
        ]

    assert {:ok, execution} = Executor.run(Inbox.ref(entry), options)
    assert execution.cleanup == :closed
    assert_receive {:closed_when, :decided}
  end

  # Once the decision is saved, a close that fails must not undo it or leave
  # the session open for good: cleanup closes the session of every decided
  # message. This is the guarantee the saved-first order stands on.
  test "a routing session left open after its decision was saved is closed by cleanup" do
    entry = record_slack_input!("Ev-executor-close-left-open")
    lease_ref = claim!(entry)
    {:ok, fake} = FakeAPI.start_link([decision("reply")], fail_first_close: true)

    options = Enum.to_list(Runtime.execution_callbacks()) ++ executor_options(fake, lease_ref)

    assert {:ok, execution} = Executor.run(Inbox.ref(entry), options)
    assert execution.result.entry.status == :decided
    assert execution.cleanup == :pending

    session = Repo.one!(from(session in Session, where: session.admission_input_id == ^entry.id))
    assert session.cleanup_status == :active

    {:ok, cleanup} =
      RetentionAPI.start_link(
        sessions: [
          %{
            "external_ref" => session.external_ref,
            "id" => session.coop_session_id,
            "job_ref" => session.external_ref,
            "job_digest" => session.worker_job_digest,
            "revision" => 2,
            "state" => "open"
          }
        ]
      )

    for step <- ~w(close plan discard) do
      assert {:ok, {:executed, _execution}} =
               RetentionDispatcher.run_once(
                 api: RetentionAPI,
                 client: cleanup,
                 closed_session_grace_seconds: 900,
                 lease_seconds: 60,
                 max_attempts: 8,
                 retained_recheck_seconds: 21_600,
                 retry_base_seconds: 1,
                 retry_max_seconds: 60,
                 worker_ref: "routing-cleanup:#{step}"
               )
    end

    assert Repo.get!(Session, session.id).cleanup_status == :discarded
    assert RetentionAPI.remote_session(cleanup, session.coop_session_id)["state"] == "discarded"
  end

  test "fleet execution identity is prepared, bound, and settled around the remote turn" do
    entry = record_slack_input!("Ev-executor-fleet-custody")
    entry_id = entry.id
    lease_ref = claim!(entry)
    {:ok, fake} = FakeAPI.start_link([decision("reply")])
    caller = self()

    options =
      executor_options(fake, lease_ref) ++
        [
          prepare_execution_session: fn prepared_entry, policy ->
            send(caller, {:fleet_prepared, prepared_entry.id, policy})
            FleetSession.ensure(prepared_entry, policy)
          end,
          bind_execution_session: fn bound_entry, session_id ->
            send(caller, {:fleet_bound, bound_entry.id, session_id})
            FleetSession.bind(bound_entry, session_id)
          end,
          settle_execution_session: fn settled_entry, session_id ->
            send(caller, {:fleet_settled, settled_entry.id, session_id})
            FleetSession.settle(settled_entry, session_id)
          end
        ]

    assert {:ok, execution} = Executor.run(Inbox.ref(entry), options)
    assert execution.result.entry.decision_action == :reply

    assert_receive {:fleet_prepared, ^entry_id, %{name: "admission-read-only", digest: digest}}

    assert digest == String.duplicate("a", 64)
    session_id = execution.session_id
    assert_receive {:fleet_bound, ^entry_id, ^session_id}
    assert_receive {:fleet_settled, ^entry_id, ^session_id}
  end

  test "admission pins adapter-owned work placement instead of its classifier policy" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please investigate this repository failure"},
               event_kind: :message,
               event_ref: "Ev-executor-work-placement",
               message_ref: "1787832002.000100",
               occurred_at: @now,
               revision: 1,
               thread_ref: nil,
               workspace_ref: "TE5D7C8842D32"
             })

    work_profile = %{
      authority_digest: String.duplicate("e", 64),
      policy: "incident-conversational",
      policy_digest: String.duplicate("b", 64),
      repository_ref: "owner/infrastructure",
      class_policies: %{
        conversational: %{
          authority_digest: String.duplicate("e", 64),
          policy: "incident-conversational",
          policy_digest: String.duplicate("b", 64)
        },
        standard: %{
          authority_digest: String.duplicate("e", 64),
          policy: "incident-standard",
          policy_digest: String.duplicate("c", 64)
        },
        deep: %{
          authority_digest: String.duplicate("e", 64),
          policy: "incident-deep",
          policy_digest: String.duplicate("d", 64)
        }
      }
    }

    assert {:ok, %{entry: entry}} = Inbox.record(input, work_profile: work_profile)
    lease_ref = claim!(entry)

    assert entry.work_profile == %{
             "class_policies" => %{
               "conversational" => %{
                 "authority_digest" => String.duplicate("e", 64),
                 "policy" => "incident-conversational",
                 "policy_digest" => String.duplicate("b", 64)
               },
               "deep" => %{
                 "authority_digest" => String.duplicate("e", 64),
                 "policy" => "incident-deep",
                 "policy_digest" => String.duplicate("d", 64)
               },
               "standard" => %{
                 "authority_digest" => String.duplicate("e", 64),
                 "policy" => "incident-standard",
                 "policy_digest" => String.duplicate("c", 64)
               }
             },
             "authority_digest" => String.duplicate("e", 64),
             "policy" => "incident-conversational",
             "policy_digest" => String.duplicate("b", 64),
             "repository_ref" => "owner/infrastructure"
           }

    {:ok, fake} = FakeAPI.start_link([decision("start_episode", nil, "deep")])

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert %Session{
             authority_digest: authority_digest,
             policy: "incident-deep",
             policy_digest: digest,
             repository_ref: "owner/infrastructure"
           } =
             Repo.one!(
               from(session in Session,
                 where: session.episode_id == ^execution.result.episode.id
               )
             )

    assert digest == String.duplicate("d", 64)
    assert authority_digest == String.duplicate("e", 64)
  end

  test "a repository-backed route offers the selector and pins the model's choice" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Review feature/payments before it merges."},
               event_kind: :message,
               event_ref: "Ev-executor-source-selection",
               message_ref: "1787832003.000100",
               occurred_at: @now,
               revision: 1,
               thread_ref: nil,
               workspace_ref: "TE5D7C8842D32"
             })

    work_profile = %{
      policy: "work-contributor",
      policy_digest: String.duplicate("b", 64),
      repository_ref: "ryker"
    }

    assert {:ok, %{entry: entry}} = Inbox.record(input, work_profile: work_profile)
    lease_ref = claim!(entry)
    branch = %{"kind" => "branch", "name" => "feature/payments"}

    {:ok, fake} =
      FakeAPI.start_link([
        decision("start_episode")
        |> Jason.decode!()
        |> Map.put("repository_source", branch)
        |> Jason.encode!()
      ])

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    state = FakeAPI.state(fake)
    assert state.schema["properties"]["repository_source"]["anyOf"] != nil

    assert Jason.decode!(state.submitted_prompt)["context"]["repository_source_kinds"] ==
             ~w(default branch pull_request commit)

    assert %Session{repository_ref: "ryker", repository_source: ^branch} =
             Repo.one!(
               from(session in Session,
                 where: session.episode_id == ^execution.result.episode.id
               )
             )
  end

  # A route in an environment with several repositories requires the new
  # episode to name the one it changes, from the list the prompt offered, and
  # the session is pinned to exactly that choice: its working copy, with the
  # others read-only. Before, every episode there changed the environment's
  # first repository whatever the event was about, so a task on any other
  # repository ran against the wrong working copy.
  test "a shared environment's route requires the repository choice and pins the session to it" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "The ledger export is failing since the last deploy."},
               event_kind: :message,
               event_ref: "Ev-executor-repository-choice",
               message_ref: "1787832004.000100",
               occurred_at: @now,
               revision: 1,
               thread_ref: nil,
               workspace_ref: "TE5D7C8842D32"
             })

    repositories = ["billing", "ledger"]

    work_profile = %{
      environment_ref: "platform",
      parallel_goal_limit: 2,
      policies:
        Map.new(repositories, fn repository ->
          {repository,
           Map.new([:conversational, :standard, :deep], fn work_class ->
             {work_class,
              %{
                authority_digest: String.duplicate("e", 64),
                policy: "#{repository}-#{work_class}",
                policy_digest: String.duplicate("b", 64)
              }}
           end)}
        end),
      repositories: repositories
    }

    assert {:ok, %{entry: entry}} = Inbox.record(input, work_profile: work_profile)
    lease_ref = claim!(entry)

    with_repository = fn repository ->
      decision("start_episode")
      |> Jason.decode!()
      |> Map.put("repository", repository)
      |> Jason.encode!()
    end

    {:ok, fake} =
      FakeAPI.start_link([
        with_repository.(nil),
        with_repository.("elsewhere"),
        with_repository.("ledger")
      ])

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert execution.result.entry.decision_action == :start_episode

    state = FakeAPI.state(fake)

    assert state.schema["properties"]["repository"]["anyOf"] == [
             %{"enum" => repositories, "type" => "string"},
             %{"type" => "null"}
           ]

    assert Jason.decode!(state.submitted_prompt)["context"]["repository_choices"] ==
             [%{"ref" => "billing"}, %{"ref" => "ledger"}]

    assert Enum.map(state.validations, & &1.verdict) == [:reject, :reject, :accept]
    [required, unknown | _accepted] = Enum.map(state.validations, &List.wrap(&1.violations))
    assert hd(required) =~ "repository is required"
    assert hd(unknown) =~ ~s("billing", "ledger")

    assert %Session{policy: "ledger-standard", repository_ref: "ledger"} =
             session =
             Repo.one!(
               from(session in Session,
                 where: session.episode_id == ^execution.result.episode.id
               )
             )

    assert session.repository_context["primary_repository"] == "ledger"
    assert session.repository_context["read_only_repositories"] == ["billing"]
  end

  test "a selector on a route without a repository is repaired in the same Coop turn" do
    entry = record_slack_input!("Ev-executor-source-unbacked")
    lease_ref = claim!(entry)

    with_selector =
      decision("start_episode")
      |> Jason.decode!()
      |> Map.put("repository_source", %{"kind" => "default"})
      |> Jason.encode!()

    {:ok, fake} = FakeAPI.start_link([with_selector, decision("start_episode")])

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert execution.result.entry.decision_action == :start_episode

    state = FakeAPI.state(fake)
    assert state.schema["properties"]["repository_source"] == %{"type" => "null"}

    refute Map.has_key?(
             Jason.decode!(state.submitted_prompt)["context"],
             "repository_source_kinds"
           )

    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]
    assert hd(state.validations).violations |> hd() =~ "repository_source is unavailable"
  end

  # Routing may now add up to three emoji beside a quick answer, and a source
  # that cannot take a reaction is offered its words only. A model that adds
  # emoji anyway must be told, in the same turn, which field to fix and how;
  # "The decision field reactions does not satisfy the attached response
  # schema" names the field but not what would satisfy it.
  test "emoji a source cannot take are refused in the same turn, in words the model can act on" do
    entry = record_slack_input!("Ev-executor-emoji-event", :event)
    lease_ref = claim!(entry)

    quick = fn reactions ->
      Jason.encode!(%{
        "action" => "quick_reply",
        "episode_ref" => nil,
        "messages" => ["Noted, thanks."],
        "reactions" => reactions,
        "relation" => "unrelated",
        "repository" => nil,
        "repository_source" => nil,
        "reason" => "A short acknowledgement is the whole answer.",
        "work_class" => nil
      })
    end

    {:ok, fake} = FakeAPI.start_link([quick.(["eyes"]), quick.(nil)])

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert execution.result.entry.decision_action == :quick_reply
    assert execution.result.entry.decision_document["reactions"] == nil

    state = FakeAPI.state(fake)
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]

    assert hd(state.validations).violations == [
             "This source cannot take a reaction. Set reactions to null; a quick_reply answers with its messages alone."
           ]

    [quick_reply] =
      Enum.filter(state.schema["oneOf"], &(&1["properties"]["action"]["const"] == "quick_reply"))

    assert quick_reply["properties"]["reactions"] == %{"type" => "null"}
  end

  test "each abstract work class selects only its host-owned policy" do
    work_profile = %{
      authority_digest: String.duplicate("e", 64),
      class_policies: %{
        conversational: %{
          authority_digest: String.duplicate("e", 64),
          policy: "conversation-terra-medium",
          policy_digest: String.duplicate("b", 64)
        },
        standard: %{
          authority_digest: String.duplicate("e", 64),
          policy: "standard-sol-medium",
          policy_digest: String.duplicate("c", 64)
        },
        deep: %{
          authority_digest: String.duplicate("e", 64),
          policy: "deep-sol-xhigh",
          policy_digest: String.duplicate("d", 64)
        }
      },
      policy: "conversation-terra-medium",
      policy_digest: String.duplicate("b", 64),
      repository_ref: "owner/service"
    }

    cases = [
      {"reply", "conversational", "conversation-terra-medium", String.duplicate("b", 64)},
      {"start_episode", "standard", "standard-sol-medium", String.duplicate("c", 64)},
      {"start_episode", "deep", "deep-sol-xhigh", String.duplicate("d", 64)}
    ]

    for {{action, work_class, expected_policy, expected_digest}, index} <-
          Enum.with_index(cases, 1) do
      assert {:ok, input} =
               SlackInput.new(%{
                 actor: %{kind: :user, ref: "U123"},
                 channel_ref: "C456",
                 content: %{"text" => "Route this request by bounded work class."},
                 event_kind: :message,
                 event_ref: "Ev-work-class-#{index}",
                 message_ref: "1787832010.00010#{index}",
                 occurred_at: DateTime.add(@now, index, :microsecond),
                 revision: 1,
                 thread_ref: nil,
                 workspace_ref: "TE5D7C8842D32"
               })

      assert {:ok, %{entry: entry}} = Inbox.record(input, work_profile: work_profile)
      lease_ref = claim!(entry)
      {:ok, fake} = FakeAPI.start_link([decision(action, nil, work_class)])

      assert {:ok, execution} =
               Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

      assert %Session{
               authority_digest: authority_digest,
               policy: ^expected_policy,
               policy_digest: ^expected_digest,
               repository_ref: "owner/service"
             } =
               Repo.one!(
                 from(session in Session,
                   where: session.episode_id == ^execution.result.episode.id
                 )
               )

      assert authority_digest == String.duplicate("e", 64)
    end
  end

  test "a schema-valid unknown candidate is rejected and repaired in the same Coop turn" do
    assert {:ok, route} =
             Route.new(%{
               auth: {:bearer, Ryker.Secret.new("a-secret-token-long-enough")},
               destination: %{
                 conversation_ref: "slack:TE5D7C8842D32:C456",
                 thread_ref: nil,
                 transport: "slack"
               },
               name: "universal"
             })

    assert {:ok, input} =
             Input.new(route, %{"unknown" => "payload"},
               event_id: "evt-semantic-repair",
               event_type: "unknown.event",
               occurred_at: @now,
               occurred_at_source: :source,
               revision: 1
             )

    assert {:ok, %{entry: entry}} = Inbox.record(input)
    lease_ref = claim!(entry)

    {:ok, fake} =
      FakeAPI.start_link([
        decision_with_candidate(
          "start_episode",
          "candidate-that-was-not-offered",
          "history_only"
        ),
        decision("start_episode")
      ])

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert execution.result.entry.decision_action == :start_episode

    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]
    assert hd(state.validations).violations |> hd() =~ "episode_ref"
    refute "react" in state.schema["properties"]["action"]["enum"]
  end

  test "byte-identical rejected attempts receive distinct validation identities" do
    entry = record_slack_input!("Ev-executor-identical-repair")
    lease_ref = claim!(entry)

    invalid =
      decision_with_candidate(
        "start_episode",
        "candidate-that-was-not-offered",
        "history_only"
      )

    {:ok, fake} =
      FakeAPI.start_link([
        invalid,
        invalid,
        decision("reply")
      ])

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert execution.result.entry.decision_action == :reply
    state = FakeAPI.state(fake)
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :reject, :accept]
    assert length(Enum.uniq(state.validation_keys)) == 3
    assert Enum.at(state.validation_keys, 0) =~ ":a1:"
    assert Enum.at(state.validation_keys, 1) =~ ":a2:"
    assert Enum.at(state.validation_keys, 2) =~ ":a3:"
    assert state.submit_count == 1
  end

  test "a Coop transport failure leaves the exact input pending for a clean retry" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please answer"},
               event_kind: :message,
               event_ref: "Ev-executor-retry",
               message_ref: "1787832001.000100",
               occurred_at: @now,
               revision: 1,
               thread_ref: nil,
               workspace_ref: "TE5D7C8842D32"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)
    lease_ref = claim!(entry)
    {:ok, fake} = FakeAPI.start_link([decision("reply")], fail_create: true)

    assert {:error, {:coop_unavailable, :simulated}} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert {:ok, pending} = Inbox.fetch(Inbox.ref(entry))
    assert pending.status == :pending
    assert pending.lease_ref == lease_ref

    FakeAPI.allow_create(fake)

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert execution.result.entry.decision_action == :reply
  end

  test "lost asynchronous responses reconcile the existing Coop session and turn" do
    entry = record_slack_input!("Ev-executor-reconcile")
    lease_ref = claim!(entry)

    {:ok, fake} =
      FakeAPI.start_link([decision("reply")],
        operation_mode: :pending_once,
        resume_operations: true
      )

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert execution.result.entry.decision_action == :reply
    assert FakeAPI.state(fake).submit_count == 0
    assert map_size(FakeAPI.state(fake).operation_calls) == 2
  end

  test "a failed Coop operation remains a retryable pending input" do
    entry = record_slack_input!("Ev-executor-operation-failed")
    lease_ref = claim!(entry)

    {:ok, fake} =
      FakeAPI.start_link([decision("reply")],
        operation_mode: :failed,
        resume_operations: true
      )

    assert {:error,
            {:admission_generation_spent,
             {:coop_operation_failed, "repository_unavailable",
              "temporary workspace preparation failure"}}} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert {:ok, pending} = Inbox.fetch(Inbox.ref(entry))
    assert pending.status == :pending
    assert pending.lease_ref == lease_ref
  end

  test "invalid candidate JSON is repaired in the same Coop turn" do
    entry = record_slack_input!("Ev-executor-json-repair")
    lease_ref = claim!(entry)
    {:ok, fake} = FakeAPI.start_link(["not-json", decision("reply")])

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert execution.result.entry.decision_action == :reply
    assert Enum.map(FakeAPI.state(fake).validations, & &1.verdict) == [:reject, :accept]

    assert hd(FakeAPI.state(fake).validations).violations == [
             "Return exactly one JSON object matching the attached response schema."
           ]
  end

  test "does not publish a completed turn without Coop's semantic validation receipt" do
    entry = record_slack_input!("Ev-executor-unvalidated-completion")
    lease_ref = claim!(entry)

    {:ok, fake} =
      FakeAPI.start_link([decision("reply")], omit_validation_receipt: true)

    assert {:error, {:admission_generation_spent, {:coop_protocol_error, :validation_receipt}}} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert {:ok, pending} = Inbox.fetch(Inbox.ref(entry))
    assert pending.status == :pending
  end

  test "does not commit a different candidate than Coop's validation receipt approved" do
    entry = record_slack_input!("Ev-executor-receipt-mismatch")
    lease_ref = claim!(entry)
    submitted = decision("reply")
    different = decision("start_episode")

    {:ok, fake} =
      FakeAPI.start_link([submitted], accepted_candidate_override: different)

    assert {:error,
            {:admission_execution_blocked, {:coop_protocol_error, :validated_candidate_mismatch}}} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert {:ok, pending} = Inbox.fetch(Inbox.ref(entry))
    assert pending.status == :pending
    assert pending.decision_ref == nil
  end

  test "a missing input fails before creating a Coop session" do
    {:ok, fake} = FakeAPI.start_link([decision("reply")])
    missing_ref = "ingress-input:#{Ecto.UUID.generate()}"

    assert {:error, {:admission_execution_failed, :input_not_found}} =
             Executor.run(missing_ref, executor_options(fake, "ingress-lease:unused"))

    assert FakeAPI.state(fake).submit_count == 0
  end

  test "admission polling stops at the configured elapsed budget and remains recoverable" do
    entry = record_slack_input!("Ev-executor-elapsed-budget")
    lease_ref = claim!(entry)
    {:ok, fake} = FakeAPI.start_link([decision("reply")], turn_wait_polls: 100)
    {:ok, monotonic} = Agent.start_link(fn -> 0 end)

    options =
      executor_options(fake, lease_ref)
      |> Keyword.merge(
        maximum_elapsed_ms: 500,
        poll_interval_ms: 250,
        monotonic_ms: fn -> Agent.get(monotonic, & &1) end,
        sleep: fn milliseconds -> Agent.update(monotonic, &(&1 + milliseconds)) end
      )

    assert Executor.run(Inbox.ref(entry), options) == {:error, {:coop_timeout, :turn}}
    assert Agent.get(monotonic, & &1) == 500

    assert {:ok, pending} = Inbox.fetch(Inbox.ref(entry))
    assert pending.status == :pending
    assert pending.lease_ref == lease_ref
  end

  test "malformed executor configuration and lease renewal fail before Coop" do
    {:ok, fake} = FakeAPI.start_link([decision("reply")])
    input_ref = "ingress-input:#{Ecto.UUID.generate()}"
    digest = String.duplicate("a", 64)

    assert Executor.run(input_ref, %{}) ==
             {:error, {:invalid_admission_executor, :options}}

    assert Executor.run(input_ref, []) ==
             {:error, {:invalid_admission_executor, :options}}

    base = [
      api: FakeAPI,
      client: fake,
      lease_ref: "ingress-lease:configuration",
      now: fn -> @now end,
      policy: "admission-read-only",
      policy_digest: digest,
      renew_lease: fn -> :ok end,
      sleep: fn _milliseconds -> :ok end
    ]

    invalid = [
      {:api, "not-an-api"},
      {:now, :not_a_clock},
      {:renew_lease, :not_a_callback},
      {:sleep, :not_a_callback},
      {:policy, ""},
      {:policy_digest, "bad"},
      {:lease_ref, ""},
      {:candidate_limit, 0},
      {:continuation_window, 0},
      {:history_window, 1},
      {:maximum_elapsed_ms, 0},
      {:max_polls, 0},
      {:monotonic_ms, :not_a_clock},
      {:poll_interval_ms, -1}
    ]

    Enum.each(invalid, fn {field, value} ->
      assert {:error, {:invalid_admission_executor, ^field}} =
               Executor.run(input_ref, Keyword.put(base, field, value))
    end)

    assert Executor.run(input_ref, Keyword.put(base, :unknown, true)) ==
             {:error, {:invalid_admission_executor, :options}}

    assert Executor.run(input_ref, Keyword.put(base, :monotonic_ms, fn -> :invalid end)) ==
             {:error, {:invalid_admission_executor, :monotonic_ms}}

    assert Executor.run(
             input_ref,
             Keyword.put(base, :renew_lease, fn -> :unexpected end)
           ) == {:error, {:admission_execution_failed, :lease_renewal}}

    assert FakeAPI.state(fake).submit_count == 0
  end

  test "an admission executor without an explicit Coop adapter refuses before Coop" do
    # A missing adapter used to fall back to the local Unix-socket client, which
    # is eval-only and left the release: the executor must refuse the input
    # before touching it, not fail at its first Coop call.
    entry = record_slack_input!("Ev-executor-no-adapter")
    lease_ref = claim!(entry)
    {:ok, fake} = FakeAPI.start_link([decision("reply")])
    options = executor_options(fake, lease_ref)

    assert Executor.run(Inbox.ref(entry), Keyword.delete(options, :api)) ==
             {:error, {:invalid_admission_executor, :options}}

    assert Executor.run(Inbox.ref(entry), Keyword.put(options, :api, nil)) ==
             {:error, {:invalid_admission_executor, :api}}

    assert {:ok, pending} = Inbox.fetch(Inbox.ref(entry))
    assert pending.status == :pending
    assert pending.decision_ref == nil
    assert FakeAPI.state(fake).submit_count == 0
  end

  # Manual testing, 2026-09-26: deleting a message sent it through a routing
  # model turn that was free to answer it, react to it or start work for it,
  # and while the model account was out the deletion sat "Retrying routing",
  # holding every later message in its conversation behind it.
  test "a deleted message no work owns is settled without a model turn" do
    original = record_slack_input!("Ev-deleted-unowned")
    {:ok, routed} = FakeAPI.start_link([decision("ignore")])

    assert {:ok, _execution} =
             Executor.run(Inbox.ref(original), executor_options(routed, claim!(original)))

    deletion = record_slack_deletion!("Ev-deleted-unowned-delete")
    {:ok, fake} = FakeAPI.start_link([])

    assert {:ok, execution} =
             Executor.run(Inbox.ref(deletion), executor_options(fake, claim!(deletion)))

    assert execution.result.entry.decision_action == :ignore
    assert execution.result.entry.lease_ref == nil
    assert FakeAPI.state(fake).create_keys == []
    assert FakeAPI.state(fake).submit_count == 0
  end

  # Admitting the deletion into its work is what withdraws everything derived
  # from the deleted text; a model that chose to ignore it left those in place.
  test "a deleted message joins the work that owns it without a model turn" do
    original = record_slack_input!("Ev-deleted-owned")
    {:ok, routed} = FakeAPI.start_link([decision("start_episode")])

    assert {:ok, %{result: %{episode: episode}}} =
             Executor.run(Inbox.ref(original), executor_options(routed, claim!(original)))

    deletion = record_slack_deletion!("Ev-deleted-owned-delete")
    {:ok, fake} = FakeAPI.start_link([])

    assert {:ok, execution} =
             Executor.run(Inbox.ref(deletion), executor_options(fake, claim!(deletion)))

    assert execution.result.entry.decision_action == :continue_episode
    assert execution.result.episode.id == episode.id
    assert FakeAPI.state(fake).create_keys == []
    assert FakeAPI.state(fake).submit_count == 0
  end

  # Manual testing, 2026-09-26: an edit routed as new work was refused with
  # "The host rejected this decision: {:admission_rejected, :source_item_owner,
  # [owner_ref: ...]}", an internal term for the model to decode on its one
  # repair, and the prompt never said an edit stays with the work that owns it.
  test "an edit routed away from the work that owns its message is corrected in words" do
    original = record_slack_input!("Ev-edit-owned")
    {:ok, routed} = FakeAPI.start_link([decision("start_episode")])

    assert {:ok, %{result: %{episode: episode}}} =
             Executor.run(Inbox.ref(original), executor_options(routed, claim!(original)))

    owner_ref =
      "candidate:" <>
        binary_part(
          Ryker.CanonicalJSON.digest(["ingress-admission-candidate", episode.id]),
          0,
          12
        )

    edit = record_slack_revision!("Ev-edit-owned-edit", :edit, "Please answer the other question")

    {:ok, fake} =
      FakeAPI.start_link([
        decision("start_episode"),
        decision_with_candidate("continue_episode", owner_ref, "same_work")
      ])

    assert {:ok, execution} = Executor.run(Inbox.ref(edit), executor_options(fake, claim!(edit)))
    assert execution.result.entry.decision_action == :continue_episode

    assert [%{verdict: :reject, violations: [violation]}, %{verdict: :accept}] =
             FakeAPI.state(fake).validations

    assert violation =~ "stays with that work"
    assert violation =~ owner_ref
    refute violation =~ "admission_rejected"

    # The refused answer is kept for training, with why and what was said back.
    assert [
             %{
               "attempt" => 1,
               "reason" => "rejected:source_item_owner",
               "correction" => ^violation
             }
           ] =
             Repo.get_by!(Ryker.Admission.Attempt, input_id: edit.id).rejections
  end

  test "a crossed Coop turn cannot decide another admission session" do
    entry = record_slack_input!("Ev-executor-crossed-turn")
    lease_ref = claim!(entry)

    {:ok, fake} =
      FakeAPI.start_link([decision("reply")], turn_session_id_override: "remote_other")

    assert Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref)) ==
             {:error, {:coop_protocol_error, :turn_session_identity}}

    assert {:ok, pending} = Inbox.fetch(Inbox.ref(entry))
    assert pending.status == :pending
    assert pending.decision_ref == nil
    assert FakeAPI.state(fake).validations == []
  end

  defp claim!(entry) do
    assert {:ok, %{entry: claimed, lease_ref: lease_ref}} =
             Inbox.claim_next("executor:test", @now, 300)

    assert claimed.id == entry.id
    lease_ref
  end

  defp record_slack_input!(event_ref, event_kind \\ :message) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please answer"},
               event_kind: event_kind,
               event_ref: event_ref,
               message_ref: "1787832001.000100",
               occurred_at: @now,
               revision: 1,
               thread_ref: nil,
               workspace_ref: "TE5D7C8842D32"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp record_slack_deletion!(event_ref),
    do: record_slack_revision!(event_ref, :delete, "Please answer")

  defp record_slack_revision!(event_ref, kind, text) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => text},
               event_kind: kind,
               event_ref: event_ref,
               message_ref: "1787832001.000100",
               occurred_at: DateTime.add(@now, 1),
               revision: 2,
               thread_ref: nil,
               workspace_ref: "TE5D7C8842D32"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp executor_options(fake, lease_ref) do
    [
      api: FakeAPI,
      client: fake,
      lease_ref: lease_ref,
      max_polls: 10,
      now: fn -> @now end,
      policy: "admission-read-only",
      policy_digest: String.duplicate("a", 64),
      poll_interval_ms: 0,
      renew_lease: fn -> :ok end,
      sleep: fn _milliseconds -> :ok end
    ]
  end

  defp decision(action, reactions \\ nil, work_class \\ :default) do
    %{
      "action" => action,
      "episode_ref" => nil,
      "messages" => nil,
      "reactions" => reactions,
      "relation" => "unrelated",
      "repository" => nil,
      "repository_source" => nil,
      "reason" => "This is the best action for the supplied event and candidates.",
      "work_class" => admission_work_class(action, work_class)
    }
    |> Jason.encode!()
  end

  defp decision_with_candidate(action, episode_ref, relation) do
    %{
      "action" => action,
      "episode_ref" => episode_ref,
      "messages" => nil,
      "reactions" => nil,
      "relation" => relation,
      "repository" => nil,
      "repository_source" => nil,
      "reason" => "This candidate appears related to the incoming event.",
      "work_class" => admission_work_class(action, :default)
    }
    |> Jason.encode!()
  end

  defp admission_work_class(action, :default) when action in ["react", "ignore"], do: nil
  defp admission_work_class("reply", :default), do: "conversational"
  defp admission_work_class(_action, :default), do: "standard"
  defp admission_work_class(_action, work_class), do: work_class
end
