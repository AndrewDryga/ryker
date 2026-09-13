defmodule Ryker.State.LearningWorkBoundaryTest do
  use Ryker.DataCase, async: false
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures

  alias Ryker.State.{
    Knowledge,
    KnowledgeSnapshot,
    LearningSources,
    Observations,
    SourceExposure
  }

  alias Ryker.Work.{Custody, SubmissionBuilder}

  test "background learning cannot leak a queued input into an earlier Work turn" do
    # Harvested inputs; only execution placement and topic structure are host
    # fixtures. Learning may finish while Work still owns the preceding input.
    [first, second] = LearningFixtures.inputs!()

    assert {:ok, _} =
             Custody.pin_episode(
               first.episode_id,
               "read-only",
               String.duplicate("a", 64),
               first.repository_ref
             )

    assert {:ok, claim} = Custody.claim_next("learning-work-boundary", 60)
    second = Repo.update!(Ecto.Changeset.change(second, episode_id: first.episode_id))

    assert {:ok, %{episode: queued}} =
             Ryker.Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: claim.episode.id,
                 episode_key: claim.episode.key,
                 destination: %{
                   transport: claim.episode.destination_transport,
                   conversation_ref: claim.episode.destination_conversation_ref,
                   thread_ref: claim.episode.destination_thread_ref
                 },
                 native_input_id: second.native_input_id,
                 revision: second.revision,
                 occurred_at: second.occurred_at,
                 payload: second.content,
                 turn_ref: "unused:queued-learning"
               })
             )

    assert queued.queued_input_refs != []

    summary = "FUTURE_TOPIC_FROM_QUEUED_INPUT: recovery is not verified."

    proposal = %{
      "topic_key" => "website-haproxy-oom",
      "title" => "Website HAProxy OOM",
      "summary" => summary,
      "topics" => ["website", "OOM"],
      "anchors" => [],
      "target_ref" => nil,
      "expected_version" => 0
    }

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               :ok = Observations.record_excerpt_in_transaction(second)

               Knowledge.record_sources_in_transaction([second], proposal, [], %{
                 result_ref: "host-queued-source-fixture",
                 source_dependencies: LearningSources.for_entry(second),
                 omissions: []
               })
             end)

    [document] = Knowledge.context(second, second.repository_ref)
    assert document["summary"] == summary
    assert Knowledge.context(claim.episode, first.repository_ref) == []
    assert Knowledge.context(queued, first.repository_ref) == []
    assert Observations.context(claim.episode, first.repository_ref) == []
    assert {:ok, submission} = SubmissionBuilder.build(claim)
    refute submission["prompt"] =~ summary
    assert {:error, :work_knowledge_context_stale} = KnowledgeSnapshot.expose(claim, [document])
    assert Repo.aggregate(SourceExposure, :count) == 0
  end
end
