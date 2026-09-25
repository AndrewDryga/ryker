defmodule Ryker.ControlPlane.WorkRecoveryTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.{FailuresPage, WorkRecovery}
  alias Ryker.Work.Turn

  test "a confirmed task that never started explains setup without implying lost changes" do
    # The second runner request showed Working and suggested blind retries even
    # though the checkpoint guard stopped it before creating a coding session.
    turn = not_started_turn()
    brief = WorkRecovery.project(turn, :ok)
    assert brief.headline == "I couldn’t start the code changes"
    assert brief.cause =~ "save a recoverable copy"
    assert brief.next_step =~ "administrator"
    assert brief.workspace == "No files changed. No checks ran."
    assert brief.model_output == nil
    assert brief.action == nil
    assert brief.setup_href == "/settings/advanced#code-editing"
    assert WorkRecovery.not_started?(turn)
  end

  test "missing or expired evidence never proves that code work did not start" do
    turn = not_started_turn()

    for changed <- [
          %{turn | cancellation_receipt: nil},
          %{turn | operational_pruned_at: DateTime.utc_now()},
          %{turn | submission: %{}},
          %{turn | coop_turn_id: "remote-turn"},
          %{turn | remote_started_at: DateTime.utc_now()},
          %{turn | completion_receipt: %{}}
        ] do
      refute WorkRecovery.not_started?(changed)
      refute WorkRecovery.project(changed, :ok).workspace =~ "No files changed"
    end
  end

  test "the setup blocker stops hiding retry only after the running connection is corrected" do
    turn = not_started_turn()
    assert WorkRecovery.project(turn, :ok, false).action == nil
    ready = WorkRecovery.project(turn, :ok, true)
    assert ready.action == :retry
    assert ready.action_label == "Start the task"
    assert ready.next_step =~ "compatible coding worker"
    assert ready.cause =~ "could not save"
    refute ready.next_step =~ "will fail for the same reason"
  end

  test "a blocked task with a portable snapshot is offered a resume, not a fresh start" do
    # `blocked-task-recovery.md` state 2. The retry said "Inspect and preserve
    # unfinished changes first", which reads as a warning that pressing it loses
    # the work — while the host was holding a checkpoint that the next placement
    # would have restored. The operator has to know which of the two it is.
    turn = %{incident_turn() | last_error_detail: "{:coop_protocol_error, :turn}"}
    plain = WorkRecovery.project(turn, :ok, true)
    assert plain.action == :retry
    assert plain.action_label == "Run the task again"
    assert plain.retry_effect =~ "preserve any unfinished changes"

    resumable = WorkRecovery.project(turn, :ok, true, snapshot())
    assert resumable.action == :retry
    assert resumable.action_label == "Continue on another worker"
    assert resumable.retry_effect =~ "ryker"
    assert resumable.retry_effect =~ "saved working copy"
    # The confirmation has to say what it does not do, because a snapshot whose
    # checks never ran is exactly what an operator might read it as waiving.
    assert resumable.retry_effect =~ "does not waive"
    refute resumable.retry_effect =~ "unfinished changes"
    assert resumable.retry_effect =~ "4.0 KB"

    # A state with no action of its own is not given one by a snapshot.
    held = WorkRecovery.project(incident_turn(), :ok, false, snapshot())
    assert held.action == nil
    assert held.action_label == "Run the task again"
  end

  defp snapshot do
    %{byte_size: 4_096, checkpoint_ref: "checkpoint:portable", repository_ref: "ryker"}
  end

  defp not_started_turn do
    source = "testdata/work/hosted-runner-not-started.json" |> File.read!() |> Jason.decode!()

    %Turn{
      status: :blocked,
      last_error_code: source["last_error_code"],
      last_error_detail: source["last_error_detail"],
      cancellation_receipt: source["cancellation_receipt"]
    }
  end

  test "recovery explains the host failure separately from the retained worker answer" do
    # The runner's actionable Docker question was hidden behind work_execution_blocked.
    turn = incident_turn()
    brief = WorkRecovery.project(turn, {:error, :work_completed_workspace_recovery_required})
    assert brief.headline == "The worker finished, but its workspace could not be saved"
    assert brief.next_step =~ "Preserve the existing working copy"
    assert brief.model_output =~ "lacks Docker"
    assert brief.action == nil
    assert brief.delivery == "This response has not been sent."

    row = %{
      kind: "work",
      ref: "episode:runner",
      episode_ref: "episode:runner",
      status: :blocked,
      summary: turn.last_error_code,
      updated_at: nil,
      attempt_count: 1,
      action: brief.action,
      diagnosis: nil,
      work_recovery: brief
    }

    html = row |> FailuresPage.detail() |> IO.iodata_to_binary()
    assert html =~ brief.headline
    assert html =~ "The worker’s last answer"
    assert html =~ "lacks Docker"
    assert html =~ "What you can do"
    assert html =~ "Preserve the existing working copy"
    refute html =~ "Run the task again"
    refute html =~ "No recognized error explanation"
  end

  test "recovery never exposes raw diagnostics or expired or rejected model output" do
    turn = incident_turn()

    for changed <- [
          %{turn | operational_pruned_at: DateTime.utc_now()},
          %{turn | validation_intent: %{"verdict" => "reject"}}
        ] do
      brief = WorkRecovery.project(changed, :ok)
      assert brief.model_output == nil
    end

    brief = WorkRecovery.project(%{turn | last_error_detail: "Authorization: secret-token"}, :ok)
    refute inspect(brief) =~ "secret-token"

    turn =
      put_in(
        turn.validation_intent["result"]["delivery_document"]["message"],
        "Preserved <script>unsafe()</script> response"
      )

    brief = WorkRecovery.project(turn, :ok)

    row = %{
      kind: "work",
      ref: "episode:runner",
      status: :blocked,
      summary: "work_execution_blocked",
      updated_at: nil,
      attempt_count: 1,
      action: nil,
      work_recovery: brief
    }

    html = row |> FailuresPage.detail() |> IO.iodata_to_binary()
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>unsafe()"
  end

  test "accepted worker prose is redacted before the recovery page displays it" do
    turn =
      put_in(
        incident_turn().validation_intent["result"]["delivery_document"]["message"],
        "The request used Bearer private-recovery-token and https://example.test/run?token=private-url-token"
      )

    brief = WorkRecovery.project(turn, :ok)
    refute brief.model_output =~ "private-recovery-token"
    refute brief.model_output =~ "private-url-token"
    assert brief.model_output =~ "[redacted]"
  end

  test "completed connection failures explain connectivity rather than inventing a storage failure" do
    # Save-only recovery can fail before it reaches workspace storage at all.
    turn = %{
      incident_turn()
      | completion_receipt: %{},
        cancellation_receipt: nil,
        last_error_code: "coop_unavailable",
        last_error_detail: "{:coop_unavailable, :offline}"
    }

    brief = WorkRecovery.project(turn, :ok)
    assert brief.cause =~ "connection"
    assert brief.next_step =~ "connection"
    refute brief.next_step =~ "storage"
    refute brief.workspace =~ "snapshot is required"

    unknown =
      WorkRecovery.project(
        %{turn | last_error_code: "work_execution_failed", last_error_detail: "unknown failure"},
        :ok
      )

    refute unknown.next_step =~ "storage"
  end

  # The dispatcher records why a completion stopped as the turn's error code;
  # the detail beside it is an inspected term for a reader's eyes. Reading the
  # cause back out of that term by prefix worked only for the exact spellings
  # the dispatcher happened to produce, so a completion parked with a plain
  # sentence, or a reason nested one level deeper, explained nothing.
  test "a completion block is explained by its recorded error code, never by parsing the detail" do
    explanations = [
      {"coop_transport_error", "connection failed while Ryker was saving"},
      {"coop_session_replacement_required", "no longer available on its recorded worker"},
      {"coop_protocol_error", "did not match the completed turn's recorded state"}
    ]

    for {code, cause} <- explanations do
      brief =
        WorkRecovery.project(
          %{
            incident_turn()
            | completion_receipt: %{},
              cancellation_receipt: nil,
              last_error_code: code,
              last_error_detail: "Worker unavailable."
          },
          :ok
        )

      assert brief.kind == :completion
      assert brief.headline == "The worker finished, but saving its result stopped"
      assert brief.cause =~ cause, "#{code} was explained as: #{brief.cause}"
    end
  end

  test "an accepted reply awaiting delivery is no longer awaiting result finalization" do
    turn = %{
      incident_turn()
      | completion_receipt: %{},
        result_ref: "result:one",
        delivery_ref: "delivery:one",
        last_error_detail: "delivery failure"
    }

    refute WorkRecovery.project(turn, :ok).kind == :completion
  end

  test "only a finished worker's unsaved workspace or unreleased reply is a hold" do
    # Slack and the recovery page have to describe one failure. When each decided
    # separately, the card said "Task work is blocked and needs operator
    # attention. Open the episode for details." over a page that already knew the
    # working copy was stranded, the session closed and the answer retained.
    held = WorkRecovery.workspace_hold(incident_turn())
    assert held.held == :workspace
    assert held.closed
    assert held.report =~ "lacks Docker"

    open_session =
      WorkRecovery.workspace_hold(%{
        incident_turn()
        | cancellation_receipt: %{"remote_state" => "completed", "session_state" => "open"}
      })

    refute open_session.closed

    stopped_finalization =
      WorkRecovery.workspace_hold(%{
        incident_turn()
        | completion_receipt: %{},
          last_error_code: "coop_unavailable",
          last_error_detail: "{:coop_unavailable, :offline}"
      })

    assert stopped_finalization.held == :reply

    # Nothing was edited and nothing was answered, so nothing is being held.
    assert WorkRecovery.workspace_hold(not_started_turn()) == nil

    # Neither is an ordinary failure with no retained completion behind it.
    assert WorkRecovery.workspace_hold(%{
             incident_turn()
             | last_error_detail: "{:coop_protocol_error, :turn}"
           }) == nil

    assert WorkRecovery.workspace_hold(%Turn{status: :settled}) == nil
    assert WorkRecovery.workspace_hold(nil) == nil
  end

  test "recovery names what happened before a collapsed safely formatted worker report" do
    brief =
      WorkRecovery.project(incident_turn(), {:error, :work_completed_workspace_recovery_required})

    row = %{
      kind: "work",
      ref: "episode:runner",
      status: :blocked,
      summary: "blocked",
      updated_at: nil,
      action: nil,
      work_recovery: brief
    }

    html = row |> FailuresPage.detail() |> IO.iodata_to_binary()
    assert html =~ "<code>"
    assert html =~ ~s(<details class="recovery-worker-report failure-report">)
    refute html =~ ~s(<details class="recovery-worker-report failure-report" open)
    # What happened is read first; the worker's own words sit, closed, under it.
    {happened, _} = :binary.match(html, "What happened")
    {report, _} = :binary.match(html, "The worker’s last answer")
    {options, _} = :binary.match(html, "What you can do")
    assert happened < report and report < options
  end

  # Found 2026-09-12 — the card told the operator no specific cause existed
  # while the host held the exact refusal, and the operator had no next move.
  # All three details are harvested verbatim from production turns blocked that
  # night; each one is the sentence the operator needed and did not get.
  test "a blocked task explains itself with the cause its saved error already names" do
    refusal =
      blocked(
        ~S|work_retry_exhausted: {:work_retry_exhausted, {:coop_operation_failed, "invalid_request", "invalid_request: policy \"emisar-standard-v1\" has no operator-configured remote, so only its default source can be selected"}}|
      )

    assert refusal.headline == "The task stopped before it could finish"

    assert refusal.cause =~
             ~S|policy "emisar-standard-v1" has no operator-configured remote|

    refute refusal.cause =~ "does not establish a specific cause"
    assert refusal.next_step =~ "retry"
    # The enum and the raw tuple are the host's bookkeeping, never the answer.
    refute refusal.cause =~ "coop_operation_failed"
    refute refusal.cause =~ "work_retry_exhausted"

    capacity =
      blocked(
        ~S|coop_worker_capacity_unavailable: {:coop_worker_capacity_unavailable, "8faf8d81-a6b4-42a5-91e6-2bf27e82a6c3"}|
      )

    assert capacity.cause =~ "No eligible worker"
    assert capacity.next_step =~ "worker"
    # A session identifier is not something an operator can act on, and the
    # card design forbids printing one at them.
    refute inspect(capacity) =~ "8faf8d81"
    refute capacity.cause =~ "coop_worker_capacity_unavailable"

    in_flight = blocked("work_remote_operation_in_flight: :work_remote_operation_in_flight")
    assert in_flight.cause =~ "unresolved"
    assert in_flight.next_step =~ "before retrying"
    refute in_flight.cause =~ "work_remote_operation_in_flight"
  end

  # Harvested from the turn blocked on 2026-09-18, when the only worker stopped
  # polling for ninety seconds: its request page, its task card and the
  # Failures list all told the operator no cause was recorded.
  test "a worker that stopped taking a task's commands is named as the cause" do
    stalled =
      blocked(
        ~S|coop_worker_command_timeout: {:coop_worker_command_timeout, "cd9cfbb8-da8c-4f42-82a8-4a78c007cc9b"}|
      )

    assert stalled.cause =~ "worker did not take"
    assert stalled.explained
    assert stalled.next_step =~ "polling"
    refute stalled.cause =~ "does not establish a specific cause"
    refute inspect(stalled) =~ "cd9cfbb8"
    refute stalled.cause =~ "coop_worker_command_timeout"
  end

  test "a refusal the host repeats is bounded, and one that names nothing stays generic" do
    flood =
      blocked(
        ~s|work_execution_blocked: {:coop_operation_failed, "invalid_request", "#{String.duplicate("a", 4_000)}"}|
      )

    # The refusal is a provider's text, so it is quoted under a bound.
    assert flood.cause =~ "aaaa"
    assert byte_size(flood.cause) <= 600

    silent = blocked("work_execution_failed: {:work_execution_failed, :unknown}")
    assert silent.cause =~ "does not establish a specific cause"
    refute silent.explained
    assert silent.next_step =~ "Inspect the saved response"
  end

  defp blocked(detail) do
    WorkRecovery.project(
      %{incident_turn() | last_error_code: "work_execution_blocked", last_error_detail: detail},
      :ok
    )
  end

  defp incident_turn do
    source = "testdata/work/hosted-runner-waiting.json" |> File.read!() |> Jason.decode!()

    %Turn{
      status: :blocked,
      candidate: Jason.encode!(source["candidate"]),
      last_error_code: source["last_error_code"],
      last_error_detail: source["last_error_detail"],
      validation_intent: %{
        "verdict" => "accept",
        "result" => %{"delivery_document" => source["candidate"]}
      },
      cancellation_receipt: %{"remote_state" => "completed", "session_state" => "closed"}
    }
  end
end
