defmodule Responder.State.LearningCreateThreadRaceTest do
  use Responder.DataCase, async: false

  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Repo
  alias Responder.State.{ConversationKnowledge, Knowledge, Learning, LearningRun}

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}

  test "a topic learned from the parent after preparation becomes an offered create alternative" do
    # Structural race over the exact draft thread: both runs were frozen before
    # either applied. The second valid host-contract candidate is deliberately
    # a new name with no shared lexical subject; it is not a captured model answer.
    [parent, reply | _] =
      "testdata/learning/retained-draft-keep-thread.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> Enum.take(2)
      |> Enum.map(&Fixtures.retained_input!(&1, @policy))

    assert {:ok, first} = Learning.prepare([parent.id], @policy)
    assert {:ok, second} = Learning.prepare([reply.id], @policy)
    assert second.knowledge == []

    original =
      "testdata/learning/recorded-draft-retention-create.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("result")

    assert {:ok, _} = Fixtures.accept(first.id, Jason.encode!(original), %{})
    assert [topic] = Knowledge.context(reply, reply.repository_ref)

    proposed = %{
      "reason" => "Retain the attributed prototyping explanation.",
      "updates" => [
        %{
          "action" => "create",
          "topic_key" => "league-ai-prototyping",
          "title" => "League AI prototype",
          "summary" => reply.content["text"],
          "topics" => ["League", "prototyping"],
          "anchors" => [],
          "target_ref" => nil,
          "expected_version" => 0,
          "source_input_ids" => [reply.id]
        }
      ]
    }

    result = Fixtures.accept(second.id, Jason.encode!(proposed), %{})
    assert result == {:error, :learning_match_required}
    assert Repo.aggregate(ConversationKnowledge, :count) == 1
    assert Repo.get!(LearningRun, second.id).match_refs == [topic["source_ref"]]
    assert {:ok, fresh} = Learning.prepare([reply.id], @policy)
    assert fresh.knowledge == [topic]
  end
end
