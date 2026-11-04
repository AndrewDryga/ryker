defmodule Ryker.Knowledge.OldestSourceMigrationTest do
  # Retention reads the stored oldest source and nothing else, so a row the migration left
  # without one would never expire (2026-11-04).
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.Continuity.ConversationSummary
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Fixtures.RetainedMemory
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Learning.LearningSources

  @version 20_261_104_110_000

  test "a summary kept from before keeps expiring, and a pruned one gives up its sources" do
    [entry | _] = LearningFixtures.inputs!(isolate: true)
    source = Repo.get_by!(ConversationObservation, source_input_id: entry.id)
    [receipt] = sources = LearningSources.for_entry(entry)
    {:ok, retained_at, 0} = DateTime.from_iso8601(receipt["retained_at"])

    assert migrate_down(@version) == :ok
    kept = RetainedMemory.retained!(ConversationSummary, sources, source)
    pruned = RetainedMemory.retained!(ConversationSummary, sources, source)

    Repo.update!(Ecto.Changeset.change(pruned, state: %{"retention" => "pruned"}))
    assert migrate_up(@version) == :ok

    assert [[oldest, _kept_sources]] = stored(kept)
    assert DateTime.compare(oldest, retained_at) == :eq
    assert stored(pruned) == [[nil, "[]"]]
  end

  defp stored(summary) do
    SQL.query!(
      Repo,
      "SELECT oldest_source_at, source_dependencies FROM conversation_summaries WHERE id = $1",
      [Ecto.UUID.dump!(summary.id)]
    ).rows
  end
end
