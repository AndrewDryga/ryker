defmodule Responder.Learning.CandidateCustodyTest do
  use Responder.DataCase, async: false
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Learning.FleetSession
  alias Responder.Repo
  alias Responder.State.{KnowledgeRevision, Learning, LearningRun, Observations}

  test "recording and checking a candidate do not apply it before the exact remote receipt" do
    %{run: run, candidate: candidate, completed: completed} = prepared!()
    assert {:ok, saved} = Learning.record_candidate(run.id, candidate, %{})
    assert saved.status == :responded
    assert Repo.aggregate(KnowledgeRevision, :count) == 0
    assert {:ok, _} = Learning.check_candidate(run.id)
    assert Repo.aggregate(KnowledgeRevision, :count) == 0
    assert {:error, :learning_validation_unconfirmed} = Learning.apply_result(run.id)
    assert Repo.get!(LearningRun, run.id).status == :responded

    for field <-
          ~w(id session_id validation_attempt validation_candidate_sha256 validation_receipt assistant_message) do
      invalid = Map.put(completed, field, nil)

      assert {:error, :learning_validation_unconfirmed} =
               Learning.confirm_candidate(run.id, invalid)
    end

    assert {:ok, verified} = Learning.confirm_candidate(run.id, completed)
    assert verified.validation_receipt["validation_receipt"] == "host-contract-validation"
    assert Repo.aggregate(KnowledgeRevision, :count) == 0
    assert {:ok, applied} = Learning.apply_result(run.id)
    assert applied.status == :applied
    assert Repo.aggregate(KnowledgeRevision, :count) == 1
    assert {:ok, ^applied} = Learning.apply_result(run.id)
  end

  test "remote acceptance cannot resurrect a source withdrawn before local application" do
    %{run: run, candidate: candidate, completed: completed, entry: entry} = prepared!()
    assert {:ok, _} = Learning.record_candidate(run.id, candidate, %{})
    assert {:ok, _} = Learning.check_candidate(run.id)
    assert {:ok, _} = Learning.confirm_candidate(run.id, completed)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Observations.receive_in_transaction(%{
                 entry
                 | id: Ecto.UUID.generate(),
                   revision: entry.revision + 1,
                   event_kind: :delete
               })
             end)

    assert {:error, :learning_source_stale} = Learning.apply_result(run.id)
    assert Repo.aggregate(KnowledgeRevision, :count) == 0
    assert Repo.get!(LearningRun, run.id).validation_receipt != nil
  end

  defp prepared! do
    entry = hd(Fixtures.inputs!())

    assert {:ok, run} =
             Learning.prepare([entry.id], %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("a", 64)
             })

    assert {:ok, _} = FleetSession.ensure(run)
    assert {:ok, _} = FleetSession.bind(run, "host-contract-session")
    # Constructed transport/host-contract output using the recorded alert subject.
    # This fixture does not claim to be a live model or provider acknowledgment.
    body =
      Jason.encode!(%{
        "reason" => "Retain the reported condition.",
        "updates" => [
          %{
            "action" => "create",
            "source_input_ids" => [entry.id],
            "topic_key" => "website-haproxy-oom",
            "title" => "Website HAProxy OOM",
            "summary" => "Grafana reported a workload memory-limit breach.",
            "topics" => ["website", "OOM"],
            "anchors" => [],
            "target_ref" => nil,
            "expected_version" => 0
          }
        ]
      })

    sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    candidate = %{
      "id" => "host-contract-turn",
      "session_id" => "host-contract-session",
      "candidate" => %{"attempt" => 1, "message" => body, "sha256" => sha}
    }

    completed = %{
      "id" => "host-contract-turn",
      "session_id" => "host-contract-session",
      "state" => "completed",
      "assistant_message" => body,
      "validation_attempt" => 1,
      "validation_candidate_sha256" => sha,
      "validation_receipt" => "host-contract-validation"
    }

    %{run: run, candidate: candidate, completed: completed, entry: entry}
  end
end
