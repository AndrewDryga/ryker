defmodule Responder.ControlPlane.WorkRecoveryTest do
  use ExUnit.Case, async: true
  alias Responder.ControlPlane.{HTML, WorkRecovery}
  alias Responder.Work.Turn

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
    assert brief.setup_href == "/configuration#code-editing"
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
    assert ready.action_label == "Retry task"
    assert ready.next_step =~ "compatible coding worker"
    assert ready.cause =~ "could not save"
    refute ready.next_step =~ "will fail for the same reason"
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

    html = HTML.failure(row) |> IO.iodata_to_binary()
    assert html =~ brief.headline
    assert html =~ "Worker’s saved response"
    assert html =~ "lacks Docker"
    assert html =~ "What you need to do"
    refute html =~ "Retry work"
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

    html = HTML.failure(row) |> IO.iodata_to_binary()
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
        last_error_detail: "{:coop_unavailable, :offline}"
    }

    brief = WorkRecovery.project(turn, :ok)
    assert brief.cause =~ "connection"
    assert brief.next_step =~ "connection"
    refute brief.next_step =~ "storage"
    refute brief.workspace =~ "snapshot is required"
    unknown = WorkRecovery.project(%{turn | last_error_detail: "unknown failure"}, :ok)
    refute unknown.next_step =~ "storage"
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

  test "recovery puts the action before a collapsed safely formatted worker report" do
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

    html = HTML.failure(row) |> IO.iodata_to_binary()
    assert html =~ "<code>"
    assert html =~ "<details class=\"recovery-worker-report\">"
    {action, _} = :binary.match(html, "What you need to do")
    {report, _} = :binary.match(html, "Worker’s saved response")
    assert action < report
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
