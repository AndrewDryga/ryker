defmodule Responder.Admission.ExecutorTest do
  use Responder.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  alias Responder.Admission.Executor
  alias Responder.Ingress.Inbox
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.TestSupport.FakeCoopAPI, as: FakeAPI
  alias Responder.Webhooks.{Input, Route}

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

    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:accept]
    assert state.closed
    assert "react" in state.schema["properties"]["action"]["enum"]
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
      poll_interval_ms: 0,
      renew_lease: fn -> :ok end,
      sleep: fn _milliseconds -> :ok end
    ]
  end

  defp decision(action, reaction \\ nil) do
    %{
      "action" => action,
      "episode_ref" => nil,
      "reaction" => reaction,
      "relation" => "unrelated",
      "reason" => "This is the best action for the supplied event and candidates."
    }
    |> Jason.encode!()
  end

  defp decision_with_candidate(action, episode_ref, relation) do
    %{
      "action" => action,
      "episode_ref" => episode_ref,
      "reaction" => nil,
      "relation" => relation,
      "reason" => "This candidate appears related to the incoming event."
    }
    |> Jason.encode!()
  end
end
