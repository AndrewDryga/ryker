defmodule Ryker.Emisar.ApprovalMessagesMigrationTest do
  use Ryker.MigrationCase
  alias Ryker.Emisar.ApprovalMessage
  alias Ryker.Fixtures.Corrections

  @version 20_261_024_181_000

  test "an empty independent-delivery store can be rolled back and recreated" do
    assert migrate_down(@version) == :ok
    assert migrate_up(@version) == :ok
    assert Repo.all(ApprovalMessage.Query.all()) == []
  end

  test "rollback preserves a review message's delivery custody" do
    # The original task held its completed reply while approvals had no card.
    # Once a separate message is retained, rollback must not lose its identity.
    claim = Corrections.correction!().claim

    attributes = %{
      episode_id: claim.episode.id,
      turn_id: claim.turn.id,
      connection_ref: "production",
      ref: "emisar-review:#{claim.turn.id}",
      transport: "slack",
      conversation_ref: claim.episode.destination_conversation_ref,
      thread_ref: claim.episode.destination_thread_ref
    }

    message = attributes |> ApprovalMessage.Changeset.insert() |> Repo.insert!()
    assert_raise Postgrex.Error, ~r/approval messages exist/, fn -> migrate_down(@version) end
    assert Repo.fetch!(ApprovalMessage.Query.by_id(message.id)).ref == message.ref
    assert {:error, duplicate} = Repo.insert(ApprovalMessage.Changeset.insert(attributes))
    assert duplicate.errors[:turn_id]
  end
end
