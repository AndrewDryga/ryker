defmodule Ryker.Evals.WorldEvidenceTest do
  use Ryker.DataCase, async: true
  alias Ryker.{Episodes, Repo}
  alias Ryker.Evals.{WorldDatabase, WorldEvidence}
  alias Ryker.Fixtures.Episodes, as: Fixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Work.{ActivityEvent, Custody}

  test "a routing model turn remains failed execution rather than unpaid unrun work" do
    report = %{runtime: %{turns: []}, status: :unrun}

    result = %{
      turn_id: "owned-admission-turn",
      decision: nil,
      reason: :routing_failed,
      cleanup_error: :close_unavailable,
      status: :failed
    }

    # The Work lane may never start, but a known remote admission turn still
    # ran and its separate cleanup diagnostic must reach the matrix summary.
    scenario =
      elem(Ryker.Evals.WorldCase.fetch("similar-alert-different-environment-stays-separate"), 1)

    {:ok, agent} = Agent.start_link(fn -> %{deliveries: %{}, order: []} end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    assert {:error, {:world_eval_assertions, failed}} =
             WorldEvidence.retain_failure_report(
               {:error, {:world_eval_admission, result}},
               scenario,
               "failed-admission-test",
               %{
                 policy: "world-test",
                 policy_digest: String.duplicate("a", 64),
                 cassette: nil,
                 tool_catalog_sha256: nil,
                 tool_names: nil
               },
               agent
             )

    assert failed.status == :failed
    assert failed.cleanup_error == {:world_eval_admission, :close_unavailable}
    assert failed.runtime.turns == report.runtime.turns
  end

  test "a failed judge preserves its independent remote cleanup failure" do
    report = %{runtime: %{turns: [%{id: "completed-world-turn"}]}, status: :unrun}

    judgment = %{
      decision: nil,
      reason: :judge_submission_unavailable,
      status: :failed,
      cleanup_error: {:eval_workspace_not_discardable, "owned-eval-session"}
    }

    assert {:error, {:world_eval_assertions, failed}} =
             WorldEvidence.apply_judgment({:ok, judgment}, report)

    assert failed.status == :failed
    assert failed.execution_error == {:world_eval_judge, :judge_submission_unavailable}
    assert failed.cleanup_error == {:world_eval_judge, judgment.cleanup_error}
  end

  test "later world cleanup cannot erase an earlier judge cleanup failure" do
    report = %{
      runtime: %{turns: [%{id: "completed-world-turn"}]},
      status: :failed,
      execution_error: {:world_eval_judge, :submission_unavailable},
      cleanup_error: {:world_eval_judge, :close_unavailable}
    }

    assert {:error, {:world_eval_assertions, failed}} =
             WorldDatabase.finish_result(
               {:error, {:world_eval_assertions, report}},
               {:error, :world_discard_unavailable}
             )

    assert failed.execution_error == report.execution_error

    assert failed.cleanup_error ==
             {:world_eval_cleanup_errors, report.cleanup_error, :world_discard_unavailable}
  end

  test "state-call evidence keeps only tool identity and outcome" do
    claim = claim!()

    event!(claim, 1, "controller-tools", "remember_answer", nil, %{
      "arguments" => %{"value" => "production secret"},
      "result" => %{"memory_ref" => "memory:secret"}
    })

    event!(claim, 2, "controller-tools", "complete_task", %{"message" => "denied"}, %{})
    event!(claim, 3, "github", "create_pull_request", nil, %{})

    assert WorldEvidence.state_calls(claim.episode.id) == [
             %{"outcome" => "succeeded", "tool" => "remember_answer"},
             %{"outcome" => "failed", "tool" => "complete_task"}
           ]
  end

  defp claim! do
    id = Ecto.UUID.generate()

    {:ok, started} =
      Episodes.apply(
        Fixtures.admit_input(%{
          episode_id: id,
          episode_key: id,
          native_input_id: id,
          turn_ref: id
        })
      )

    {:ok, session} =
      WorkSessions.pin_episode(
        started.episode.id,
        "policy:world-evidence",
        String.duplicate("a", 64)
      )

    {:ok, claim} = Custody.claim_next("world-evidence:#{id}", 60, :work)
    turn = Repo.update!(Ecto.Changeset.change(claim.turn, coop_turn_id: "remote:#{id}"))

    %{episode: started.episode, session: session, turn: turn}
  end

  defp event!(claim, sequence, server, tool, error, output) do
    Repo.insert!(%ActivityEvent{
      episode_id: claim.episode.id,
      session_id: claim.session.id,
      remote_event_id: Ecto.UUID.generate(),
      remote_session_id: claim.session.id,
      coop_turn_id: claim.turn.coop_turn_id,
      sequence: sequence,
      kind: "tool.completed",
      version: 1,
      occurred_at: DateTime.add(DateTime.utc_now(), sequence, :microsecond),
      payload: %{
        "input" => %{"server" => server, "tool" => tool},
        "output" => Map.put(output, "error", error),
        "status" => "completed"
      },
      payload_fingerprint: String.duplicate(Integer.to_string(sequence), 64)
    })
  end
end
