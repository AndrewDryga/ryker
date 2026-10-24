defmodule Ryker.Work.CheckpointRetryMigrationTest do
  use Ryker.MigrationCase
  alias Ryker.Fixtures.Corrections
  alias Ryker.Work.Turn

  @version 20_261_024_180_000

  test "existing completed-work identities retain generation zero across a reversible shape change" do
    turn = Corrections.correction!().claim.turn
    assert migrate_down(@version) == :ok
    assert migrate_up(@version) == :ok
    assert Repo.fetch!(Turn.Query.by_id(turn.id)).checkpoint_retry_generation == 0
  end

  test "rollback cannot forget an explicit retry's retained operation identity" do
    # Production's immutable failed snapshot needs a new key, without replaying
    # its completed model turn. Removing the counter would reuse the old key.
    turn = Corrections.correction!().claim.turn
    Repo.update_all(Turn.Query.by_id(turn.id), set: [checkpoint_retry_generation: 1])
    assert_raise Postgrex.Error, ~r/checkpoint retries exist/, fn -> migrate_down(@version) end
    assert Repo.fetch!(Turn.Query.by_id(turn.id)).checkpoint_retry_generation == 1
  end

  test "negative retry generations are rejected by the database" do
    turn = Corrections.correction!().claim.turn

    assert_raise Postgrex.Error, ~r/checkpoint_retry_generation_valid/, fn ->
      Repo.transaction(
        fn ->
          Repo.update_all(Turn.Query.by_id(turn.id), set: [checkpoint_retry_generation: -1])
        end,
        mode: :savepoint
      )
    end

    assert Repo.fetch!(Turn.Query.by_id(turn.id)).checkpoint_retry_generation == 0
  end
end
