defmodule Responder.Operator.WorkflowsTest do
  use Responder.DataCase, async: false

  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query

  alias Responder.Admission
  alias Responder.Admission.Decision
  alias Responder.Delivery.ReactionCustody
  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Ingress.WorkProfile
  alias Responder.Operator.{Actions, FailureDetail, Failures, Preflight, SlackReplay, Status}
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.Slack.{Interaction, InteractionAudits}

  @occurred_at ~U[2026-09-04 08:00:00Z]

  test "preflight reports every read-only check instead of hiding later failures" do
    checks = [
      {:configuration, fn -> {:ok, %{configured: [:slack, :work]}} end},
      {:database, fn -> {:error, :database_unavailable} end},
      {:schema, fn -> {:ok, %{pending: []}} end}
    ]

    assert {:error, report} = Preflight.run(checks: checks)
    assert report.status == :failed

    assert Enum.map(report.checks, &{&1.name, &1.status}) == [
             configuration: :ok,
             database: :failed,
             schema: :ok
           ]

    assert Enum.at(report.checks, 1).detail == ":database_unavailable"
  end

  test "preflight converts exceptional checks into bounded failures and keeps running" do
    checks = [
      {:plain_ok, fn -> :ok end},
      {:unexpected, fn -> :unexpected end},
      {:raised, fn -> raise "database password must stay private" end},
      {:thrown, fn -> throw(:stopped) end}
    ]

    assert {:error, report} = Preflight.run(checks: checks)

    assert Enum.map(report.checks, &{&1.name, &1.status}) == [
             plain_ok: :ok,
             unexpected: :failed,
             raised: :failed,
             thrown: :failed
           ]

    assert Enum.find(report.checks, &(&1.name == :raised)).detail =~ "exception"
    assert Enum.find(report.checks, &(&1.name == :thrown)).detail =~ "stopped"
  end

  test "status and preflight share current PostgreSQL and queue truth" do
    assert {:ok, preflight} =
             Preflight.run(check_progress: false, check_runtimes: false)

    assert preflight.status == :ok
    assert Enum.find(preflight.checks, &(&1.name == :database)).detail == %{database: :ok}
    assert Enum.find(preflight.checks, &(&1.name == :schema)).detail.pending == []

    assert {:ok, status} =
             Status.snapshot(check_progress: false, check_runtimes: false)

    assert status.preflight.status == :ok
    assert status.failures == %{by_kind: %{}, total: 0}
    assert status.queues == status.observability.queues
    assert is_map(status.overview.counts)

    assert Status.snapshot(stall_after_seconds: 0) ==
             {:error, {:invalid_operator_status, :options}}
  end

  test "stored failure diagnostics expose only a stable correlation hash" do
    assert FailureDetail.project(nil) == nil

    projected = FailureDetail.project("xoxb-private-provider-body")
    assert projected =~ ~r/\Astored diagnostic sha256:[0-9a-f]{64}\z/
    refute projected =~ "xoxb-private-provider-body"
  end

  test "operator services reject malformed calls before opening mutation custody" do
    operation = fn -> flunk("invalid operator action must not run") end

    action = %{
      action: :retry,
      action_ref: "operator-action:validation",
      actor_ref: "slack:user:U123",
      kind: "admission",
      request: %{"operation" => "retry"},
      resource_ref: "ingress-input:any"
    }

    identity = [actor_ref: "slack:user:U123", action_ref: "operator-action:validation"]

    assert Failures.list([]) == {:error, {:invalid_operator_failure, :params}}
    assert Actions.fetch(nil) == :error
    assert Actions.run([], operation) == {:error, {:invalid_operator_action, :arguments}}
    assert Actions.run(%{}, operation) == {:error, {:invalid_operator_action, :attributes}}

    assert Actions.run(%{action | actor_ref: <<0>>}, operation) ==
             {:error, {:invalid_operator_action, :actor_ref}}

    assert Actions.run(%{action | request: []}, operation) ==
             {:error, {:invalid_operator_action, :request}}

    assert Actions.run(%{action | request: %{"unsupported" => self()}}, operation) ==
             {:error, {:invalid_operator_action, :request}}

    assert Actions.run(action, fn -> {:ok, %{outcome: [], previous: %{}}} end) ==
             {:error, {:invalid_operator_action, :outcome}}

    assert {:ok, %{status: :ok}} = Preflight.run()
    assert Preflight.run(:invalid) == {:error, {:invalid_operator_preflight, :options}}
    assert Preflight.run(checks: []) == {:error, {:invalid_operator_preflight, :options}}

    assert Preflight.run(checks: [{:not_callable, :invalid}]) ==
             {:error, {:invalid_operator_preflight, :options}}

    assert Status.snapshot(:invalid) == {:error, {:invalid_operator_status, :options}}
    assert Status.snapshot(unknown: true) == {:error, {:invalid_operator_status, :options}}

    assert Failures.retry("admission", nil, identity) ==
             {:error, {:invalid_operator_failure, :ref}}

    assert Failures.retry("admission", <<0>>, identity) ==
             {:error, {:invalid_operator_failure, :ref}}

    assert Failures.retry("admission", "ingress-input:any", :invalid) ==
             {:error, {:invalid_operator_failure, :options}}

    assert Failures.retry("admission", "ingress-input:any", action_ref: "only") ==
             {:error, {:invalid_operator_failure, :options}}

    for fingerprint <- [nil, "old-tab", String.duplicate("Z", 64)] do
      assert Failures.retry(
               "work",
               "episode:any",
               Keyword.put(identity, :expected_recovery, fingerprint)
             ) ==
               {:error, {:invalid_operator_failure, :expected_recovery}}
    end

    assert Failures.retry("admission", "ingress-input:any",
             actor_ref: <<0>>,
             action_ref: "operator-action:invalid-actor"
           ) == {:error, {:invalid_operator_failure, :actor_ref}}
  end

  test "typed failure retry rearms the exact blocked admission" do
    assert {:ok, input} = slack_input("Ev-operator-retry", "1788512400.000100")
    assert {:ok, %{entry: entry}} = Inbox.record(input, work_profile: work_profile!())

    assert {:ok, %{lease_ref: lease_ref}} =
             Inbox.claim_next("operator-workflow-test", DateTime.utc_now(), 60)

    assert {:ok, blocked} =
             Inbox.block(Inbox.ref(entry), lease_ref, "model_contract", "inspect this failure")

    assert blocked.status == :blocked

    options = [actor_ref: "control-plane:test", action_ref: "operator-action:retry-admission"]

    assert {:ok,
            %{
              action_ref: "operator-action:retry-admission",
              actor_ref: "control-plane:test",
              outcome: %{
                "attempt_count" => 0,
                "kind" => "admission",
                "status" => "pending"
              },
              status: :recorded
            }} = Failures.retry("admission", Inbox.ref(entry), options)

    assert {:ok, %{status: :duplicate}} =
             Failures.retry("admission", Inbox.ref(entry), options)

    assert {:ok, action} = Actions.fetch("operator-action:retry-admission")
    assert action.previous["summary"] == "model_contract"
    assert action.previous["detail"] =~ "stored diagnostic sha256:"
    refute inspect(action) =~ "inspect this failure"

    assert action.action == :retry
    assert action.kind == "admission"
    assert action.actor_ref == "control-plane:test"
    assert action.resource_ref == Inbox.ref(entry)

    assert {:error, :operator_action_conflict} =
             Failures.retry(
               "work",
               Inbox.ref(entry),
               Keyword.put(options, :expected_recovery, String.duplicate("a", 64))
             )

    assert {:error, {:invalid_operator_failure, :kind}} =
             Failures.retry(
               "publication",
               "publication:not-generically-retryable",
               options
             )

    assert {:error, {:invalid_operator_failure, :options}} =
             Failures.retry("admission", Inbox.ref(entry), [])
  end

  test "typed failure retry preserves delivery and Slack interaction identity" do
    assert {:ok, input} = slack_input("Ev-operator-delivery", "1788512400.000150")
    assert {:ok, %{entry: entry}} = Inbox.record(input)

    assert {:ok, context} =
             Admission.context(Inbox.ref(entry),
               now: @occurred_at,
               continuation_window: 1_800,
               history_window: 2_592_000,
               candidate_limit: 8,
               lease_ref: nil
             )

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "react",
               "episode_ref" => nil,
               "reaction" => %{"emoji_name" => "eyes"},
               "relation" => "unrelated",
               "reason" => "Acknowledge without starting an episode.",
               "work_class" => nil
             })

    assert {:ok, _result} = Admission.commit(context, decision, "operator-delivery-decision")
    assert {:ok, claim} = ReactionCustody.claim_next("operator-delivery-worker", 60)

    assert {:ok, blocked_reaction} =
             ReactionCustody.block(
               claim.reaction.delivery_ref,
               claim.lease_ref,
               "slack_api_error",
               "missing_scope"
             )

    delivery_options = [
      actor_ref: "control-plane:test",
      action_ref: "operator-action:retry-delivery"
    ]

    assert {:ok, delivery} =
             Failures.retry("delivery", blocked_reaction.delivery_ref, delivery_options)

    assert delivery.outcome == %{
             "attempt_count" => 0,
             "kind" => "delivery",
             "ref" => blocked_reaction.delivery_ref,
             "retry_generation" => 1,
             "status" => "pending"
           }

    interaction = %Interaction{
      action_id: "responder_start_engineering_task",
      action_value: "record:task_offer:abc123",
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: "interaction:operator-retry",
      message_ref: "1788512400.000150",
      occurred_at: @occurred_at,
      thread_ref: "1788512390.000100",
      workspace_ref: "T123"
    }

    assert {:ok, %{audit: audit}} = InteractionAudits.record(interaction, :invalid)
    assert {:ok, claimed_audit} = InteractionAudits.claim_next("operator-interaction-worker", 30)
    assert claimed_audit.id == audit.id

    assert {:ok, _blocked_audit} =
             InteractionAudits.block(audit.id, claimed_audit.lease_ref, :provider_down)

    interaction_options = [
      actor_ref: "control-plane:test",
      action_ref: "operator-action:retry-slack-interaction"
    ]

    assert {:ok, interaction_result} =
             Failures.retry("slack_interaction", interaction.event_ref, interaction_options)

    assert interaction_result.outcome == %{
             "attempt_count" => 0,
             "kind" => "slack_interaction",
             "ref" => interaction.event_ref,
             "status" => "pending"
           }
  end

  test "private Slack replay preserves captured input under a fresh idempotent shadow identity" do
    profile = work_profile!()
    assert {:ok, input} = slack_input("Ev-replay-source", "1788512400.000200")
    assert {:ok, %{entry: source}} = Inbox.record(input, work_profile: profile)
    assert SlackReplay.fetch(Inbox.ref(source)) == {:error, :slack_replay_not_found}

    assert SlackReplay.enqueue(Inbox.ref(source), "request", []) ==
             {:error, {:invalid_slack_replay, :options}}

    options = [actor_ref: "slack:user:U123", action_ref: "operator-action:replay-slack"]

    assert {:ok, first} =
             SlackReplay.enqueue(Inbox.ref(source), "operator-request-1", options)

    assert first.status == :recorded
    assert first.outcome["source_input_ref"] == Inbox.ref(source)
    replay_input_ref = first.outcome["replay_input_ref"]

    assert {:ok, duplicate} =
             SlackReplay.enqueue(Inbox.ref(source), "operator-request-1", options)

    assert duplicate.status == :duplicate
    assert duplicate.outcome == first.outcome

    assert {:ok, replay_action} = Actions.fetch("operator-action:replay-slack")
    refute inspect(replay_action) =~ "Investigate checkout latency"
    refute inspect(replay_action) =~ "evidence.txt"

    assert {:ok, replay} = Inbox.fetch(replay_input_ref)
    assert replay.id != source.id
    assert replay.execution_mode == :shadow
    assert replay.content == source.content
    assert replay.actor_kind == source.actor_kind
    assert replay.actor_ref == source.actor_ref
    assert replay.destination_conversation_ref == source.destination_conversation_ref
    assert replay.destination_thread_ref == source.destination_thread_ref
    assert replay.native_input_id == source.native_input_id
    assert replay.source_item_ref == source.source_item_ref
    assert replay.source_capabilities == source.source_capabilities
    assert replay.work_profile == source.work_profile
    assert replay.event_ref =~ source.id

    assert {:ok, outcome} = SlackReplay.fetch(replay_input_ref)
    assert outcome.execution_mode == :shadow
    assert outcome.source_input_ref == Inbox.ref(source)
    assert outcome.admission_status == :pending
    assert outcome.episode_ref == nil
    assert outcome.outcome == nil

    assert {:ok, context} =
             Admission.context(replay_input_ref,
               now: DateTime.add(@occurred_at, 10, :second),
               continuation_window: 30 * 60,
               history_window: 30 * 24 * 60 * 60,
               candidate_limit: 8
             )

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "start_episode",
               "episode_ref" => nil,
               "reaction" => nil,
               "relation" => "unrelated",
               "reason" => "Evaluate the retained Slack input privately.",
               "work_class" => "standard"
             })

    assert {:ok, admitted} =
             Admission.commit(context, decision, "operator-replay-admission:one")

    assert {:ok, _accepted} =
             Episodes.apply(%Command.AcceptResult{
               decision_reason: "Would investigate checkout latency and report the evidence.",
               delivery: :none,
               delivery_ref: nil,
               episode_key: admitted.episode.key,
               expected_turn_ref: admitted.episode.owner_ref,
               next_turn_ref: nil,
               occurred_at: DateTime.add(@occurred_at, 20, :second),
               result_ref: "operator-replay-result:one"
             })

    assert {:ok, completed} = SlackReplay.fetch(replay_input_ref)

    assert completed.outcome == %{
             decision_reason: "Would investigate checkout latency and report the evidence.",
             delivery: :none,
             status: :accepted
           }
  end

  test "private replay rejects non-Slack and pruned sources before creating custody" do
    replay_identity = [
      actor_ref: "slack:user:U123",
      action_ref: "operator-action:invalid-replay"
    ]

    assert SlackReplay.enqueue(nil, "request", replay_identity) ==
             {:error, {:invalid_slack_replay, :source_input_ref}}

    assert SlackReplay.enqueue("ingress-input:any", "request", :invalid) ==
             {:error, {:invalid_slack_replay, :options}}

    assert {:ok, invalid_input} = slack_input("Ev-invalid-replay", "1788512400.000250")

    assert {:ok, %{entry: invalid_source}} =
             Inbox.record(invalid_input, work_profile: work_profile!())

    Repo.update_all(
      from(entry in Entry, where: entry.id == ^invalid_source.id),
      set: [source_kind: "github"]
    )

    assert SlackReplay.enqueue(Inbox.ref(invalid_source), "request-invalid", replay_identity) ==
             {:error, :slack_replay_source_invalid}

    assert {:error, :slack_replay_source_not_found} =
             SlackReplay.enqueue(
               "ingress-input:00000000-0000-0000-0000-000000000000",
               "request",
               actor_ref: "slack:user:U123",
               action_ref: "operator-action:missing-replay"
             )

    assert {:ok, input} = slack_input("Ev-pruned-replay", "1788512400.000300")
    assert {:ok, %{entry: source}} = Inbox.record(input, work_profile: work_profile!())

    Repo.update_all(
      from(entry in Entry, where: entry.id == ^source.id),
      set: [content: %{"retention" => "pruned"}, operational_pruned_at: DateTime.utc_now()]
    )

    assert {:error, :slack_replay_source_pruned} =
             SlackReplay.enqueue(Inbox.ref(source), "request-pruned",
               actor_ref: "slack:user:U123",
               action_ref: "operator-action:pruned-replay"
             )

    assert Repo.aggregate(Entry, :count) == 2
    assert Actions.fetch("operator-action:missing-replay") == :error
    assert Actions.fetch("operator-action:pruned-replay") == :error
  end

  test "private replay requires the frozen Work profile that governed the source" do
    assert {:ok, input} = slack_input("Ev-profileless-replay", "1788512400.000400")
    assert {:ok, %{entry: source}} = Inbox.record(input)

    assert {:error, :slack_replay_work_profile_missing} =
             SlackReplay.enqueue(Inbox.ref(source), "request-profileless",
               actor_ref: "slack:user:U123",
               action_ref: "operator-action:profileless-replay"
             )

    assert Actions.fetch("operator-action:profileless-replay") == :error
  end

  defp slack_input(event_ref, message_ref) do
    SlackInput.new(%{
      actor: %{kind: :user, ref: "U123"},
      channel_ref: "C456",
      content: %{
        "attachments" => [%{"fallback" => "retained"}],
        "blocks" => [],
        "files" => [%{"id" => "F123", "name" => "evidence.txt"}],
        "slack_event_kind" => "message",
        "subtype" => nil,
        "text" => "Investigate checkout latency"
      },
      event_kind: :message,
      event_ref: event_ref,
      message_ref: message_ref,
      occurred_at: @occurred_at,
      revision: 7,
      thread_ref: "1788512390.000100",
      workspace_ref: "T123"
    })
  end

  defp work_profile! do
    assert {:ok, profile} =
             WorkProfile.new(%{
               policy: "incident-read-v1",
               policy_digest: String.duplicate("a", 64),
               repository_ref: "responder"
             })

    profile
  end
end
