defmodule Ryker.Work.CompletionRetryBudgetMigrationTest do
  use Ryker.MigrationCase
  alias Ryker.Fixtures.Corrections
  alias Ryker.Work.Turn

  @version 20_261_024_190_000

  test "existing work keeps its lifetime attempt budget until an explicit completion retry" do
    turn = Corrections.correction!().claim.turn
    assert migrate_down(@version) == :ok
    assert migrate_up(@version) == :ok
    assert Repo.fetch!(Turn.Query.by_id(turn.id)).completion_retry_base_count == 0
  end

  test "rollback cannot forget an explicitly authorized completion budget" do
    turn = Corrections.correction!().claim.turn
    Repo.update_all(Turn.Query.by_id(turn.id), set: [completion_retry_base_count: 1])

    assert_raise Postgrex.Error, ~r/completion retry budgets exist/, fn ->
      migrate_down(@version)
    end

    assert Repo.fetch!(Turn.Query.by_id(turn.id)).completion_retry_base_count == 1
  end

  test "the completion retry base stays within the retained lifetime attempt count" do
    turn = Corrections.correction!().claim.turn

    for invalid <- [-1, turn.work_attempt_count + 1] do
      assert_raise Postgrex.Error, ~r/completion_retry_base_count_valid/, fn ->
        Repo.transaction(
          fn ->
            Repo.update_all(Turn.Query.by_id(turn.id),
              set: [completion_retry_base_count: invalid]
            )
          end,
          mode: :savepoint
        )
      end
    end

    assert Repo.fetch!(Turn.Query.by_id(turn.id)).completion_retry_base_count == 0
  end
end
