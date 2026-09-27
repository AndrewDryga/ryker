defmodule Ryker.Learning.WorkerTest do
  use Ryker.DataCase, async: false

  @moduletag isolation: "REPEATABLE READ"

  alias Ryker.Admission
  alias Ryker.Admission.Decision
  alias Ryker.Ingress.Inbox
  alias Ryker.Learning.Worker
  alias Ryker.Slack.Input

  @now ~U[2026-08-28 12:00:00.000000Z]

  # Stands in for the fleet: no worker takes the session, so the batch the
  # slot assembled is held rather than sent to a model.
  defmodule Fleet do
    def accepts_session?(test_pid, _session) do
      send(test_pid, :learning_batch_claimed)
      false
    end
  end

  # On 2026-09-27 an idle install committed about 125 transactions a second,
  # and the learning pool's poll alone read conversation_learning_inputs 129
  # times a second, once for every routed message it had ever kept. The slot
  # now sleeps until a message is routed, so that announcement has to wake it.
  test "a message routed while learning is idle is learned from at once, not at the next timer" do
    worker = start_supervised!({Worker, settings(quiet_seconds: 0)})
    # Its first poll found nothing, and its next timer is a minute away.
    _state = :sys.get_state(worker)

    routed_input!("Ev-learning-woken")
    assert_receive :learning_batch_claimed, 500
  end

  # A conversation is learned from once it has been quiet for a while, and
  # only the clock says when that is: a slot that slept its whole safety-net
  # interval would start every batch up to ten seconds late.
  test "a conversation that falls quiet is learned from then, not at the safety-net interval" do
    routed_input!("Ev-learning-due")
    start_supervised!({Worker, settings(quiet_seconds: 1)})

    refute_receive :learning_batch_claimed, 500
    assert_receive :learning_batch_claimed, 1_500
  end

  defp settings(overrides) do
    Map.merge(
      %{
        api: Fleet,
        batch_size: 16,
        client: self(),
        concurrency: 1,
        execution_timeout_seconds: 600,
        idle_interval_ms: 60_000,
        lease_seconds: 300,
        maximum_delay_seconds: 60,
        policy: "learning-read-only",
        policy_digest: String.duplicate("a", 64),
        poll_interval_ms: 60_000,
        quiet_seconds: 10,
        receive_timeout_ms: 30_000,
        step_delay_seconds: 2,
        worker_ref: "learning-worker:test"
      },
      Map.new(overrides)
    )
  end

  defp routed_input!(event_ref) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "The deploy is green again."},
        event_kind: :message,
        event_ref: event_ref,
        message_ref: "1787832001.000200",
        occurred_at: @now,
        revision: 1,
        thread_ref: "1787832000.000100",
        workspace_ref: "T123"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)

    {:ok, context} =
      Admission.context(Inbox.ref(entry),
        now: @now,
        continuation_window: 1_800,
        history_window: 2_592_000,
        candidate_limit: 8,
        lease_ref: nil
      )

    {:ok, decision} =
      Decision.parse(%{
        "action" => "react",
        "episode_ref" => nil,
        "messages" => nil,
        "reactions" => ["eyes"],
        "relation" => "unrelated",
        "repository" => nil,
        "repository_source" => nil,
        "reason" => "Acknowledge without starting work.",
        "work_class" => nil
      })

    {:ok, _result} = Admission.commit(context, decision, "decision:#{event_ref}")
    entry
  end
end
