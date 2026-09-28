defmodule Ryker.Slack.InteractionFeedbackTest do
  use Ryker.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ryker.ControlPlane.FailureProjection
  alias Ryker.Repo

  alias Ryker.Slack.{
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

    def post_ephemeral(observer, channel_ref, actor_ref, thread_ref, text) do
      send(observer, {:ephemeral, channel_ref, actor_ref, thread_ref, text})
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

    assert %{outcome: :denied, event_ref: "interaction:denied", action_id: action_id} =
             Repo.get!(InteractionAudit, denied_audit.id)

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

  test "a successful confirmation retains one durable repaint across duplicate acknowledgements" do
    click = %{interaction("interaction:confirmed") | action_id: "ryker_confirm_behavior"}
    assert {:ok, %{audit: audit, status: :recorded}} = InteractionAudits.record(click, :confirmed)
    assert audit.outcome == :confirmed
    assert audit.repaint_status == :pending

    assert {:ok, %{audit: ^audit, status: :duplicate}} =
             InteractionAudits.record(click, :confirmed)

    redelivery = %{click | occurred_at: DateTime.add(click.occurred_at, 5, :second)}

    assert {:ok, %{audit: ^audit, status: :duplicate}} =
             InteractionAudits.record(redelivery, :confirmed)

    assert {:ok, claim} = InteractionAudits.claim_next("confirmation-worker", 30)
    assert claim.id == audit.id
    assert {:ok, settled} = InteractionAudits.settle(audit.id, claim.lease_ref)
    assert settled.repaint_status == :settled
    assert settled.attempt_count == 1
    assert {:ok, nil} = InteractionAudits.claim_next("confirmation-worker", 30)
  end

  test "a stale setup control repaints the exact message from current durable state" do
    session =
      Repo.insert!(%ConfigurationSession{
        id: Ecto.UUID.generate(),
        workspace_ref: "T7E5D2338E2F5",
        channel_ref: "C456",
        membership_generation: 1,
        start_event_ref: "event:setup",
        start_fingerprint: String.duplicate("a", 64),
        initiator_ref: "U123",
        step: :participation,
        status: :cancelled,
        draft: %{
          "alert_policy" => nil,
          "environment_options" => [
            %{
              "emisar" => false,
              "name" => "Production",
              "ref" => "production",
              "repositories" => ["ryker"]
            }
          ],
          "invite_user_group_refs" => [],
          "invite_user_refs" => [],
          "participation" => nil
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

    assert InteractionRepaint.repaint(audit, %{api: SlackAPI, client: self()}) ==
             {:error, :slack_setup_presentation_unavailable}

    assert :ok =
             InteractionRepaint.repaint(audit, %{
               api: SlackAPI,
               client: self(),
               setup: %{bot_user_ref: "UBOT"}
             })

    assert_received {:updated_message, "C456", "1787832001.000200", document, delivery_ref}

    assert document["channel_setup"]["status"] == "cancelled"
    assert document["channel_setup"]["revision"] == 2
    assert document["channel_setup"]["bot_user_ref"] == "UBOT"
    assert delivery_ref == "slack-setup:#{session.id}"
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
      set: [next_attempt_at: DateTime.add(Repo.now!(), -1, :second)]
    )

    assert {:ok, {:blocked, "interaction:retry-block"}} =
             InteractionFeedbackWorker.run_once(options)

    blocked = Repo.get!(InteractionAudit, audit.id)
    assert blocked.repaint_status == :blocked
    assert blocked.attempt_count == 2
    assert blocked.last_error_code == "slack_unavailable"
    assert blocked.lease_ref == nil

    assert {:ok, %{action: :rearm, ref: "interaction:retry-block", status: :blocked}} =
             FailureProjection.slack_interaction("interaction:retry-block")
  end

  test "a repaint the host gave up on tells the person who pressed the button" do
    # The click acknowledgement is optimistic: it says the press was accepted
    # before the repaint is attempted. When the repaint then failed for good,
    # nothing ever spoke again, so the operator saw an accepted press and a card
    # that never changed, with no way to tell the two apart.
    assert {:ok, %{audit: audit}} =
             interaction("interaction:blocked-speaks")
             |> InteractionAudits.record(:invalid)

    options =
      worker_options(
        max_attempts: 1,
        repaint: fn _audit, _options -> {:error, :slack_unavailable} end
      )

    assert {:ok, {:blocked, "interaction:blocked-speaks"}} =
             InteractionFeedbackWorker.run_once(options)

    assert_receive {:ephemeral, channel_ref, actor_ref, thread_ref, text}
    assert channel_ref == audit.channel_ref
    assert actor_ref == audit.actor_ref
    assert thread_ref == audit.thread_ref
    assert text =~ "recorded"
    refute text =~ "slack_unavailable"
  end

  defmodule RefusingAPI do
    def update_message(_observer, _channel_ref, _message_ref, _document, _delivery_ref), do: :ok

    def post_ephemeral(_observer, _channel_ref, _actor_ref, _thread_ref, _text),
      do: {:error, {:slack_api_error, "channel_not_found"}}
  end

  defmodule CrashingAPI do
    def update_message(_observer, _channel_ref, _message_ref, _document, _delivery_ref), do: :ok

    def post_ephemeral(_observer, _channel_ref, _actor_ref, _thread_ref, _text),
      do: raise("socket closed while posting")
  end

  # The note is best effort, and it failed in silence: a refused or crashed
  # post left no trace, so nobody could tell that the person was never told.
  test "a courtesy note Slack refuses or that crashes is logged, never hidden" do
    for {api, named} <- [{RefusingAPI, "channel_not_found"}, {CrashingAPI, "RuntimeError"}] do
      ref = "interaction:note-#{named}"
      assert {:ok, %{audit: _audit}} = interaction(ref) |> InteractionAudits.record(:invalid)

      options =
        worker_options(
          api: api,
          max_attempts: 1,
          repaint: fn _audit, _options -> {:error, :slack_unavailable} end
        )

      log =
        capture_log(fn ->
          assert {:ok, {:blocked, ^ref}} = InteractionFeedbackWorker.run_once(options)
        end)

      assert log =~ "could not tell the person who pressed"
      assert log =~ named
    end
  end

  test "a repaint that succeeds says nothing extra" do
    assert {:ok, %{audit: _audit}} =
             interaction("interaction:quiet-success")
             |> InteractionAudits.record(:invalid)

    assert {:ok, {:repainted, "interaction:quiet-success"}} =
             InteractionFeedbackWorker.run_once(worker_options([]))

    refute_receive {:ephemeral, _channel, _actor, _thread, _text}
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
    # Observe the first queued poll, not merely the PID returned by start_link.
    # Without shared sandbox ownership the supervised DB worker dies on that poll.
    assert :sys.get_state(worker) == options
    assert {:noreply, ^options} = InteractionFeedbackWorker.handle_info(:poll, options)

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

  # On 2026-09-27 an idle install committed about 125 transactions a second;
  # every Slack worker polled its table once a second. The repaint worker now
  # sleeps until a press is recorded, so recording one has to wake it.
  test "a press recorded while the repaint worker is idle is repainted at once" do
    worker = start_supervised!({InteractionFeedbackWorker, sleeping_options()})
    # Its first poll found nothing, and its next timer is five minutes away.
    _state = :sys.get_state(worker)

    {:ok, _recorded} = InteractionAudits.record(interaction("interaction:woken"), :invalid)
    assert_receive {:repainted, "interaction:woken"}, 500
  end

  # A failed repaint is retried after a backoff, and only the clock says
  # when: a worker sleeping its whole safety-net interval would repaint late.
  test "a repaint whose retry falls due runs then, not at the safety-net interval" do
    {:ok, _recorded} = InteractionAudits.record(interaction("interaction:due"), :invalid)
    {:ok, claimed} = InteractionAudits.claim_next("slack-interaction:earlier", 30)
    {:ok, _deferred} = InteractionAudits.defer(claimed.id, claimed.lease_ref, 1, :slack_down)

    start_supervised!({InteractionFeedbackWorker, sleeping_options()})

    refute_receive {:repainted, "interaction:due"}, 500
    assert_receive {:repainted, "interaction:due"}, 1_500
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

  defp sleeping_options do
    test_pid = self()

    worker_options(
      idle_interval_ms: 300_000,
      interval_ms: 300_000,
      repaint: fn audit, _options ->
        send(test_pid, {:repainted, audit.event_ref})
        :ok
      end
    )
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

  defp interaction(event_ref) do
    %Interaction{
      action_id: "ryker_start_engineering_task",
      action_value: "record:task_offer:abc123",
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: event_ref,
      message_ref: "1787832001.000200",
      occurred_at: @now,
      thread_ref: "1787832000.000100",
      workspace_ref: "T7E5D2338E2F5"
    }
  end
end
