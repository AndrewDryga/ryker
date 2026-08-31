defmodule Responder.Slack.InteractionFeedbackTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.ControlPlane.Projection
  alias Responder.Repo

  alias Responder.Slack.{
    ConfigurationSession,
    Interaction,
    InteractionAudit,
    InteractionAudits,
    InteractionFeedbackWorker,
    InteractionRepaint
  }

  @now ~U[2026-08-29 12:00:00.000000Z]

  defmodule SlackAPI do
    def update_message(observer, channel_ref, message_ref, document, delivery_ref) do
      send(
        observer,
        {:updated_message, channel_ref, message_ref, document, delivery_ref}
      )

      :ok
    end
  end

  test "denied and stale controls are durable, idempotent, and conflict on crossed identity" do
    denied = interaction("interaction:denied")
    stale = interaction("interaction:stale")

    assert {:ok, %{audit: denied_audit, status: :recorded}} =
             InteractionAudits.record(denied, :denied)

    assert denied_audit.repaint_status == :none

    assert {:ok, %{audit: stale_audit, status: :recorded}} =
             InteractionAudits.record(stale, :invalid)

    assert stale_audit.repaint_status == :pending

    assert {:ok, %{audit: ^stale_audit, status: :duplicate}} =
             InteractionAudits.record(stale, :invalid)

    crossed = %{stale | action_value: "record:task_offer:other"}

    assert InteractionAudits.record(crossed, :invalid) ==
             {:error, :slack_interaction_event_conflict}

    assert Repo.aggregate(InteractionAudit, :count) == 2

    assert %{kind: :denied, ref: "interaction:denied", summary: action_id} =
             Enum.find(Projection.audit(%{}), &(&1.ref == "interaction:denied"))

    assert action_id == denied.action_id
  end

  test "the repaint worker leases and settles one stale interaction" do
    assert {:ok, %{audit: audit}} =
             interaction("interaction:worker")
             |> InteractionAudits.record(:invalid)

    options = %{
      api: SlackAPI,
      client: self(),
      lease_seconds: 30,
      max_attempts: 3,
      repaint: fn claimed, _options ->
        send(self(), {:repainted, claimed.event_ref, claimed.lease_ref})
        :ok
      end,
      retry_base_seconds: 1,
      worker_ref: "slack-interaction:test"
    }

    assert {:ok, {:repainted, "interaction:worker"}} =
             InteractionFeedbackWorker.run_once(options)

    assert_received {:repainted, "interaction:worker", lease_ref}
    assert is_binary(lease_ref)

    settled = Repo.get!(InteractionAudit, audit.id)
    assert settled.repaint_status == :settled
    assert settled.attempt_count == 1
    assert %DateTime{} = settled.repainted_at
    assert settled.lease_ref == nil
    assert {:ok, :idle} = InteractionFeedbackWorker.run_once(options)
  end

  test "a stale setup control repaints the exact message from current durable state" do
    session =
      Repo.insert!(%ConfigurationSession{
        id: Ecto.UUID.generate(),
        workspace_ref: "T123",
        channel_ref: "C456",
        membership_generation: 1,
        start_event_ref: "event:setup",
        start_fingerprint: String.duplicate("a", 64),
        initiator_ref: "U123",
        step: :participation,
        status: :cancelled,
        draft: %{
          "alert_policy" => nil,
          "customizing" => false,
          "default_repository" => "responder",
          "invite_user_group_refs" => [],
          "invite_user_refs" => [],
          "participation" => nil,
          "repository_options" => ["responder"],
          "repository_ref" => nil
        },
        revision: 2,
        root_message_ref: "1787832000.000100",
        response_thread_ref: "1787832000.000100",
        current_message_ref: "1787832001.000200",
        expires_at: ~U[2026-08-29 12:30:00.000000Z]
      })

    assert {:ok, %{audit: audit}} =
             interaction("interaction:setup")
             |> InteractionAudits.record(:invalid)

    assert :ok = InteractionRepaint.repaint(audit, %{api: SlackAPI, client: self()})

    assert_received {:updated_message, "C456", "1787832001.000200", document, delivery_ref}

    assert document["channel_setup"]["status"] == "cancelled"
    assert document["channel_setup"]["revision"] == 2
    assert delivery_ref == "slack-setup:#{session.id}:2"
  end

  test "a failed repaint defers with bounded durable diagnostics" do
    assert {:ok, %{audit: audit}} =
             interaction("interaction:failure")
             |> InteractionAudits.record(:invalid)

    assert {:ok, claim} = InteractionAudits.claim_next("worker", 30)

    reason = {:slack_unavailable, String.duplicate("😀", 2_000)}
    assert {:ok, deferred} = InteractionAudits.defer(audit.id, claim.lease_ref, 3, reason)
    assert deferred.repaint_status == :pending
    assert byte_size(deferred.last_error_detail) <= 4_096
    assert String.valid?(deferred.last_error_detail)
    assert %DateTime{} = deferred.next_attempt_at
    assert deferred.lease_ref == nil
  end

  test "the worker retries a repaint and then preserves a durable blocked diagnostic" do
    assert {:ok, %{audit: audit}} =
             interaction("interaction:retry-block")
             |> InteractionAudits.record(:invalid)

    options =
      worker_options(
        max_attempts: 2,
        repaint: fn _audit, _options -> {:error, :slack_unavailable} end
      )

    assert {:ok, {:deferred, "interaction:retry-block"}} =
             InteractionFeedbackWorker.run_once(options)

    Repo.update_all(
      from(stored in InteractionAudit, where: stored.id == ^audit.id),
      set: [next_attempt_at: DateTime.add(database_now!(), -1, :second)]
    )

    assert {:ok, {:blocked, "interaction:retry-block"}} =
             InteractionFeedbackWorker.run_once(options)

    blocked = Repo.get!(InteractionAudit, audit.id)
    assert blocked.repaint_status == :blocked
    assert blocked.attempt_count == 2
    assert blocked.last_error_code == "slack_unavailable"
    assert blocked.lease_ref == nil

    assert {:ok, %{action: :rearm, ref: "interaction:retry-block", status: :blocked}} =
             Projection.slack_interaction("interaction:retry-block")
  end

  test "an operator can rearm only the exact blocked stale-control repaint" do
    assert {:ok, %{audit: audit}} =
             interaction("interaction:operator-rearm")
             |> InteractionAudits.record(:invalid)

    assert {:ok, claim} = InteractionAudits.claim_next("worker:operator-rearm", 30)
    assert claim.id == audit.id
    assert {:ok, blocked} = InteractionAudits.block(audit.id, claim.lease_ref, :provider_down)
    assert blocked.repaint_status == :blocked

    assert {:ok, rearmed} = InteractionAudits.rearm(audit.event_ref)
    assert rearmed.repaint_status == :pending
    assert rearmed.attempt_count == 0
    assert rearmed.last_error_code == nil
    assert rearmed.lease_ref == nil

    assert {:error, :slack_interaction_audit_not_blocked} =
             InteractionAudits.rearm(audit.event_ref)
  end

  test "the supervised worker idles and rejects malformed runtime options" do
    options = worker_options(interval_ms: 300_000)

    worker =
      start_supervised!(
        {InteractionFeedbackWorker, Map.put(options, :name, nil)},
        id: {:interaction_feedback_worker, make_ref()}
      )

    assert Process.alive?(worker)
    assert {:noreply, ^options} = InteractionFeedbackWorker.handle_info(:work, options)

    assert InteractionFeedbackWorker.options!(Map.to_list(options)).worker_ref ==
             options.worker_ref

    for invalid <- [
          :invalid,
          Map.put(options, :lease_seconds, 0),
          Map.put(options, :repaint, :invalid),
          Map.put(options, :unknown, true)
        ] do
      assert_raise ArgumentError, fn -> InteractionFeedbackWorker.options!(invalid) end
    end

    assert_raise ArgumentError, fn ->
      InteractionFeedbackWorker.options!(api: SlackAPI, api: SlackAPI)
    end
  end

  test "repaint ignores vanished messages and refuses an untrusted API" do
    assert {:ok, %{audit: audit}} =
             interaction("interaction:vanished")
             |> InteractionAudits.record(:invalid)

    assert :ok = InteractionRepaint.repaint(audit, %{api: SlackAPI, client: self()})

    assert InteractionRepaint.repaint(audit, %{api: :missing_api, client: self()}) ==
             {:error, :slack_interaction_repaint_api_invalid}

    assert InteractionRepaint.repaint(:invalid, %{}) ==
             {:error, :slack_interaction_repaint_invalid}
  end

  defp worker_options(overrides) do
    %{
      api: SlackAPI,
      client: self(),
      interval_ms: 1_000,
      lease_seconds: 30,
      max_attempts: 3,
      name: nil,
      repaint: fn _audit, _options -> :ok end,
      retry_base_seconds: 1,
      worker_ref: "slack-interaction:test"
    }
    |> Map.merge(Map.new(overrides))
  end

  defp database_now! do
    {:ok, %{rows: [[now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end

  defp interaction(event_ref) do
    %Interaction{
      action_id: "responder_start_engineering_task",
      action_value: "record:task_offer:abc123",
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: event_ref,
      message_ref: "1787832001.000200",
      occurred_at: @now,
      thread_ref: "1787832000.000100",
      workspace_ref: "T123"
    }
  end
end
