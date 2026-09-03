defmodule Responder.Admission.ExecutorTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  @moduletag isolation: "REPEATABLE READ"

  alias Responder.Admission.Executor
  alias Responder.Ingress.Inbox
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.TestSupport.FakeCoopAPI, as: FakeAPI
  alias Responder.Webhooks.{Input, Route}
  alias Responder.Work.Session

  @now ~U[2026-08-27 12:00:00.000000Z]

  test "Coop schema validation and host semantic validation finish one admission turn" do
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
               workspace_ref: "T123"
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
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:accept]
    assert state.closed
    assert "react" in state.schema["properties"]["action"]["enum"]
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
            :ok
          end,
          bind_execution_session: fn bound_entry, session_id ->
            send(caller, {:fleet_bound, bound_entry.id, session_id})
            :ok
          end,
          settle_execution_session: fn settled_entry, session_id ->
            send(caller, {:fleet_settled, settled_entry.id, session_id})
            :ok
          end
        ]

    assert {:ok, execution} = Executor.run(Inbox.ref(entry), options)
    assert execution.result.entry.decision_action == :reply

    assert_receive {:fleet_prepared, ^entry_id, %{name: "admission-read-only", digest: digest}}

    assert digest == String.duplicate("a", 64)
    assert_receive {:fleet_bound, ^entry_id, "remote_test"}
    assert_receive {:fleet_settled, ^entry_id, "remote_test"}
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
               workspace_ref: "T123"
             })

    work_profile = %{
      policy: "incident-conversational",
      policy_digest: String.duplicate("b", 64),
      repository_ref: "owner/infrastructure",
      class_policies: %{
        conversational: %{
          policy: "incident-conversational",
          policy_digest: String.duplicate("b", 64)
        },
        standard: %{
          policy: "incident-standard",
          policy_digest: String.duplicate("c", 64)
        },
        deep: %{policy: "incident-deep", policy_digest: String.duplicate("d", 64)}
      }
    }

    assert {:ok, %{entry: entry}} = Inbox.record(input, work_profile: work_profile)
    lease_ref = claim!(entry)

    assert entry.work_profile == %{
             "class_policies" => %{
               "conversational" => %{
                 "policy" => "incident-conversational",
                 "policy_digest" => String.duplicate("b", 64)
               },
               "deep" => %{
                 "policy" => "incident-deep",
                 "policy_digest" => String.duplicate("d", 64)
               },
               "standard" => %{
                 "policy" => "incident-standard",
                 "policy_digest" => String.duplicate("c", 64)
               }
             },
             "policy" => "incident-conversational",
             "policy_digest" => String.duplicate("b", 64),
             "repository_ref" => "owner/infrastructure"
           }

    {:ok, fake} = FakeAPI.start_link([decision("start_episode", nil, "deep")])

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

    assert %Session{
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
  end

  test "each abstract work class selects only its host-owned policy" do
    work_profile = %{
      class_policies: %{
        conversational: %{
          policy: "conversation-terra-medium",
          policy_digest: String.duplicate("b", 64)
        },
        standard: %{
          policy: "standard-sol-medium",
          policy_digest: String.duplicate("c", 64)
        },
        deep: %{policy: "deep-sol-xhigh", policy_digest: String.duplicate("d", 64)}
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
                 workspace_ref: "T123"
               })

      assert {:ok, %{entry: entry}} = Inbox.record(input, work_profile: work_profile)
      lease_ref = claim!(entry)
      {:ok, fake} = FakeAPI.start_link([decision(action, nil, work_class)])

      assert {:ok, execution} =
               Executor.run(Inbox.ref(entry), executor_options(fake, lease_ref))

      assert %Session{
               policy: ^expected_policy,
               policy_digest: ^expected_digest,
               repository_ref: "owner/service"
             } =
               Repo.one!(
                 from(session in Session,
                   where: session.episode_id == ^execution.result.episode.id
                 )
               )
    end
  end

  test "a schema-valid unknown candidate is rejected and repaired in the same Coop turn" do
    assert {:ok, route} =
             Route.new(%{
               auth: {:bearer, "a-secret-token-long-enough"},
               destination: %{
                 conversation_ref: "slack:T123:C456",
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
               workspace_ref: "T123"
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
      {:max_polls, 0},
      {:poll_interval_ms, -1}
    ]

    Enum.each(invalid, fn {field, value} ->
      assert {:error, {:invalid_admission_executor, ^field}} =
               Executor.run(input_ref, Keyword.put(base, field, value))
    end)

    assert Executor.run(input_ref, Keyword.put(base, :unknown, true)) ==
             {:error, {:invalid_admission_executor, :options}}

    assert Executor.run(
             input_ref,
             Keyword.put(base, :renew_lease, fn -> :unexpected end)
           ) == {:error, {:admission_execution_failed, :lease_renewal}}

    assert FakeAPI.state(fake).submit_count == 0
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

  defp record_slack_input!(event_ref) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please answer"},
               event_kind: :message,
               event_ref: event_ref,
               message_ref: "1787832001.000100",
               occurred_at: @now,
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
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

  defp decision(action, reaction \\ nil, work_class \\ :default) do
    %{
      "action" => action,
      "episode_ref" => nil,
      "reaction" => reaction,
      "relation" => "unrelated",
      "reason" => "This is the best action for the supplied event and candidates.",
      "work_class" => admission_work_class(action, work_class)
    }
    |> Jason.encode!()
  end

  defp decision_with_candidate(action, episode_ref, relation) do
    %{
      "action" => action,
      "episode_ref" => episode_ref,
      "reaction" => nil,
      "relation" => relation,
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
