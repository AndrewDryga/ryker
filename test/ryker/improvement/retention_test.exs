defmodule Ryker.Improvement.RetentionTest do
  @moduledoc """
  What Ryker keeps about requests people were unhappy with follows the data
  it came from (`Ryker.Retention.Policy`): a candidate expires at the
  operational horizon after its last change, an accepted case lasts as long
  as training data is kept, an analysis's exact prompt and answer lose their
  words at the operational horizon, and a person forgetting a message wins
  at once.
  """
  # Retention takes one advisory lock for a whole pass.
  use Ryker.MigrationCase
  import Ecto.Query
  alias Ryker.CanonicalJSON
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Improvement
  alias Ryker.Improvement.{AnalysisRun, Candidate}
  alias Ryker.Inspectors
  alias Ryker.Retention.{Data, Policy}
  alias Ryker.Work.Session

  @workspace "TIMPROVERETENTION"
  @now ~U[2026-09-27 12:00:00.000000Z]
  @old ~U[2020-01-01 00:00:00.000000Z]

  @version 20_260_927_200_000

  test "a candidate expires at the operational horizon, and an accepted case lasts as long as training data" do
    assert {:ok, %{class: :operational}} = Policy.fetch("improvement_candidates")
    assert {:ok, %{class: :cascade}} = Policy.fetch("improvement_analysis_runs")

    old_open = candidate!("1790400100.000100")
    fresh_open = candidate!("1790400200.000100")
    old_accepted = candidate!("1790400300.000100")
    assert {:ok, _accepted} = Improvement.accept(old_accepted.id, "control-plane:local")

    Repo.update_all(from(c in Candidate, where: c.id == ^old_open.id), set: [updated_at: @old])

    Repo.update_all(from(c in Candidate, where: c.id == ^old_accepted.id),
      set: [updated_at: @old, decided_at: DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)]
    )

    # Training data is kept for a year here: the accepted case stays.
    assert {:ok, result} = Data.prune(settings(true))
    assert result.improvement == 1
    refute Repo.get(Candidate, old_open.id)
    assert Repo.get(Candidate, fresh_open.id)
    assert Repo.get(Candidate, old_accepted.id)

    # Turned off, it lasts as long as other operational data.
    assert {:ok, result} = Data.prune(settings(false))
    assert result.improvement == 1
    refute Repo.get(Candidate, old_accepted.id)
  end

  # Cleanup closes an analysis session only after its run stopped; deleting
  # the run under a session still on record would make every later pass fail
  # on the foreign key, as a rearmed learning session once did.
  test "a candidate waits while a session of its analysis is still on record, and the words of a stopped analysis expire" do
    candidate = candidate!("1790400400.000100")
    run = run!(candidate, @old)

    Repo.insert!(%Session{
      id: Ecto.UUID.generate(),
      execution_kind: :improvement,
      improvement_run_id: run.id,
      policy: "ryker-learning",
      policy_digest: String.duplicate("a", 64),
      external_ref: "ryker-improvement:#{run.id}"
    })

    Repo.update_all(from(c in Candidate, where: c.id == ^candidate.id), set: [updated_at: @old])

    assert {:ok, result} = Data.prune(settings(true))
    assert result.improvement == 0
    assert Repo.get(Candidate, candidate.id)

    run = Repo.get!(AnalysisRun, run.id)
    assert run.prompt == nil
    assert run.result == nil
    assert %DateTime{} = run.pruned_at
  end

  # "A person forgetting wins": deleting the message a case quotes erases the
  # case's words, the diagnosis and every analysis prompt in the same
  # transaction that records the deletion.
  test "a person deleting a message the case quotes erases what the candidate holds" do
    candidate = candidate!("1790400500.000100")
    run = run!(candidate, @now)

    Repo.update_all(from(c in Candidate, where: c.id == ^candidate.id),
      set: [
        analysis: :done,
        category: :prompt_bug,
        step: :work,
        confidence: :high,
        what_went_wrong: "It checked production when they asked about staging.",
        expected: "Checks the staging database.",
        analyzed_at: @now
      ]
    )

    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")
    assert is_map(accepted.case_evidence)
    :ok = Improvement.subscribe_improvement()

    Answers.slack_message!(
      workspace: @workspace,
      channel: "CRETENTION",
      text: "",
      ts: "1790400500.000100",
      kind: :delete,
      revision: 2,
      at: DateTime.add(@now, 600, :second)
    )

    forgotten = Repo.get!(Candidate, candidate.id)
    assert %DateTime{} = forgotten.forgotten_at
    assert forgotten.case_evidence == nil
    assert forgotten.what_went_wrong == nil
    assert forgotten.expected == nil
    assert Repo.get!(AnalysisRun, run.id).prompt == nil
    id = candidate.id
    assert_received {:improvement_updated, ^id}

    assert Improvement.accept(candidate.id, "control-plane:local") ==
             {:error, :improvement_candidate_forgotten}
  end

  # An edit replaces the words a person no longer wants said. Only deleting
  # reached a candidate, so an accepted case kept the replaced words for as
  # long as training data is kept, with the diagnosis written from them.
  test "a person editing the words of a message the case quotes erases what the candidate holds" do
    candidate = candidate!("1790400550.000100")
    run = run!(candidate, @now)

    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")
    assert CanonicalJSON.encode!(accepted.case_evidence) =~ "staging database"

    Answers.slack_message!(
      workspace: @workspace,
      channel: "CRETENTION",
      text: "Is the staging replica healthy?",
      ts: "1790400550.000100",
      kind: :edit,
      revision: 2,
      at: DateTime.add(@now, 600, :second)
    )

    forgotten = Repo.get!(Candidate, candidate.id)
    assert %DateTime{} = forgotten.forgotten_at
    assert forgotten.case_evidence == nil
    assert Repo.get!(AnalysisRun, run.id).prompt == nil
  end

  test "the migration refuses to roll back while candidates are kept, and returns cleanly without them" do
    candidate = candidate!("1790400600.000100")

    assert_raise Postgrex.Error, ~r/requests to improve are kept/, fn ->
      migrate_down(@version)
    end

    assert Repo.get(Candidate, candidate.id)
    Repo.delete_all(Candidate)

    assert :ok = migrate_down(@version)
    refute table?("improvement_candidates")
    assert :ok = migrate_up(@version)
    assert table?("improvement_candidates")
    assert candidate!("1790400700.000100")
  end

  defp candidate!(ts) do
    question =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CRETENTION",
        text: "Is the staging database healthy?",
        ts: ts
      )

    reply =
      Answers.work_reply!(
        question,
        "The production database is healthy.",
        String.replace(ts, ".000100", ".000200"),
        DateTime.add(@now, 30, :second)
      )

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :reaction_added,
               value: "-1",
               actor_ref: "UALICE",
               source: "slack",
               source_ref: "slack-event:retention-#{ts}",
               occurred_at: @now,
               request: {:episode, reply.episode.id}
             })

    Inspectors.improvement_candidate({:episode, reply.episode.id})
  end

  defp run!(candidate, at) do
    Repo.insert!(%AnalysisRun{
      id: Ecto.UUID.generate(),
      candidate_id: candidate.id,
      generation: 1,
      status: :applied,
      policy: "ryker-learning",
      policy_digest: String.duplicate("a", 64),
      prompt: ~s({"instructions":"Diagnose.","context":{}}),
      prompt_sha256: String.duplicate("b", 64),
      output_schema: %{"type" => "object"},
      manifest: %{},
      started_at: at,
      result: ~s({"category":"unclear"}),
      stop_receipt: %{"kind" => "terminal_turn"},
      remote_stopped_at: at,
      inserted_at: at,
      updated_at: at
    })
  end

  defp table?(name) do
    %{rows: [[exists]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = $1)",
        [name]
      )

    exists
  end

  defp settings(training?) do
    %{
      audit_data_seconds: 600,
      closed_work_seconds: 600,
      conversation_memory_seconds: 600,
      episode_history_seconds: 600,
      operational_data_seconds: 600,
      routing_examples_enabled: training?,
      routing_examples_seconds: 365 * 86_400,
      work_examples_enabled: false,
      work_examples_seconds: 365 * 86_400
    }
  end
end
