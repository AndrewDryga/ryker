defmodule Ryker.Knowledge.OldestSourceTest do
  @moduledoc """
  Retention prunes a summary or rollup once any source it was written from is
  past its time. It found those by expanding every row's sources each minute:
  1.5 s of every minute on the tenant install with nothing to prune
  (2026-11-04), more with each topic a summary cites. The row now holds the
  oldest of its sources, so a pass reads the rows it prunes.
  """
  use Ryker.DataCase, async: false
  alias Ryker.Continuity.ConversationRollup
  alias Ryker.Continuity.ConversationSummary
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Fixtures.RetainedMemory
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Knowledge.KnowledgeRetention
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Learning.LearningSources
  alias Ryker.QueryWork

  @retention_seconds 3_600

  for schema <- [ConversationSummary, ConversationRollup] do
    test "a pass over #{inspect(schema)} reads the rows past their time, not every row's sources" do
      schema = unquote(schema)
      table = schema.__schema__(:source)
      {expired_sources, current_sources, source} = sources!()
      expired = RetainedMemory.retained!(schema, expired_sources, source)
      current = for _ <- 1..30, do: RetainedMemory.retained!(schema, current_sources, source)

      {result, statements} =
        QueryWork.statements(fn ->
          Repo.transaction(fn -> KnowledgeRetention.prune_in_transaction(@retention_seconds) end)
        end)

      assert result == {:ok, 1}
      assert Repo.get!(schema, expired.id).state == %{"retention" => "pruned"}
      assert Repo.get!(schema, hd(current).id).state != %{"retention" => "pruned"}

      assert [pass] = Enum.filter(statements, &(&1.sql =~ "UPDATE #{table} m"))
      # Run again it finds nothing left to prune, and reads at most the row its join starts from.
      assert QueryWork.rows_scanned([pass], table) <= 1
    end

    test "a pruned #{inspect(schema)} row has no oldest source, and a pass never reads it again" do
      schema = unquote(schema)
      {expired_sources, _current_sources, source} = sources!()
      expired = RetainedMemory.retained!(schema, expired_sources, source)

      assert %DateTime{} = oldest(schema, expired.id)

      assert Repo.transaction(fn ->
               KnowledgeRetention.prune_in_transaction(@retention_seconds)
             end) == {:ok, 1}

      assert oldest(schema, expired.id) == nil
      assert Repo.get!(schema, expired.id).source_dependencies == []

      assert Repo.transaction(fn ->
               KnowledgeRetention.prune_in_transaction(@retention_seconds)
             end) == {:ok, 0}
    end
  end

  test "the oldest source follows the sources through a topic, an edit and a bad clock" do
    {_expired_sources, [receipt], source} = sources!()
    {:ok, retained_at, 0} = DateTime.from_iso8601(receipt["retained_at"])
    summary = RetainedMemory.retained!(ConversationSummary, [receipt], source)
    assert same_instant?(oldest(ConversationSummary, summary.id), retained_at)

    earlier = DateTime.add(retained_at, -60, :second)

    changed =
      Repo.update!(
        Ecto.Changeset.change(summary,
          source_dependencies: [
            receipt,
            Map.merge(receipt, %{
              "observation_id" => Ecto.UUID.generate(),
              "retained_at" => DateTime.to_iso8601(earlier)
            })
          ]
        )
      )

    assert same_instant?(oldest(ConversationSummary, summary.id), earlier)

    # `now` is a time to PostgreSQL and no receipt's clock, so it never expires a row.
    bad_clock = Map.put(receipt, "retained_at", "now")
    Repo.update!(Ecto.Changeset.change(changed, source_dependencies: [bad_clock]))
    assert oldest(ConversationSummary, summary.id) == nil

    {topic_source, document} = KnowledgeFixtures.learn!(episode!(), "tenant-infra")
    "knowledge:" <> topic_id = document["source_ref"]
    topic = Repo.get!(ConversationKnowledge, topic_id)

    reference =
      LearningSources.knowledge_reference(topic_id, topic.source_generation, topic.version)

    [topic_receipt] = LearningSources.expand([reference])
    {:ok, topic_retained_at, 0} = DateTime.from_iso8601(topic_receipt["retained_at"])
    assert topic_source

    cited = RetainedMemory.retained!(ConversationSummary, [reference], source)
    assert same_instant?(oldest(ConversationSummary, cited.id), topic_retained_at)
  end

  defp same_instant?(left, right), do: DateTime.compare(left, right) == :eq

  defp sources! do
    [expired_entry, current_entry] = LearningFixtures.inputs!(isolate: true)
    old = DateTime.add(DateTime.utc_now(), -2 * @retention_seconds, :second)
    source = Repo.get_by!(ConversationObservation, source_input_id: expired_entry.id)
    Repo.update!(Ecto.Changeset.change(source, updated_at: old))

    {LearningSources.for_entry(expired_entry), LearningSources.for_entry(current_entry), source}
  end

  defp oldest(schema, id) do
    %{rows: [[oldest]]} =
      Repo.query!(
        "SELECT oldest_source_at FROM #{schema.__schema__(:source)} WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    oldest
  end

  defp episode! do
    id = Ecto.UUID.generate()

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "oldest-source:#{id}",
          native_input_id: "source:#{id}",
          turn_ref: "turn:#{id}",
          payload: %{"text" => "Keep the alert history."},
          destination: %{
            transport: "slack",
            conversation_ref: "slack:T#{String.replace(id, "-", "")}:C0TENANTOPS",
            thread_ref: "oldest"
          }
        })
      )

    episode
  end
end
