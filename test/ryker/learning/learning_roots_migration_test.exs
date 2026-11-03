defmodule Ryker.Learning.LearningRootsMigrationTest do
  @moduledoc """
  On the tenant install a summary citing 137 topics expanded to 20,513 source
  rows for 682 distinct sources, because topics store the sources of the
  topics they were learned from (2026-11-03). Retention parsed every copy each
  minute, and a briefing's related-summary recall took 8.6 s of its 15. Every
  reader treats the expansion as a set, so each stored receipt comes back once.
  """
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Learning.LearningSources

  @version 20_261_103_200_000
  @fenced 20_261_103_210_000

  test "a topic cited twice expands to each of its sources once, and a missing one still fails" do
    reference = topic_reference!()
    missing = %{reference | "knowledge_id" => Ecto.UUID.generate()}

    assert expanded([reference, reference]) == 1
    assert expanded([reference, missing, missing]) == 2
    assert null_rows([reference, missing]) == 1

    assert migrate_down(@version) == :ok
    assert expanded([reference, reference]) == 2

    assert migrate_up(@version) == :ok
    assert expanded([reference, reference]) == 1
  end

  # Retention's expiry check was pushed below the folding and still parsed every
  # copy: 1.05 million checks and 8.1 s of each minute (2026-11-03).
  test "a check on expanded sources runs once per distinct receipt, however often it is stored" do
    episode = episode!()
    {_source, first} = KnowledgeFixtures.learn!(episode, "tenant-infra", "first-topic")
    {_source, built} = KnowledgeFixtures.learn!(episode, "tenant-infra", "built-topic", [first])
    citing = Enum.map([first, built], &reference/1)

    # The built topic stores the first topic's source and its own: three
    # stored receipts, two distinct.
    assert checked(citing) == 2
    assert migrate_down(@fenced) == :ok
    assert checked(citing) == 3
    assert migrate_up(@fenced) == :ok
    assert checked(citing) == 2
  end

  # Stored receipts a filter that keeps none looked at, by the plan's own count;
  # the raw-receipt branch, which sees only the two references, is not one.
  defp checked(dependencies) do
    %{rows: [[[%{"Plan" => plan}]]]} =
      SQL.query!(
        Repo,
        "EXPLAIN (ANALYZE, FORMAT JSON) SELECT 1 FROM ryker_learning_roots($1) r WHERE r->>'retained_at' = 'never'",
        [CanonicalJSON.encode!(dependencies)]
      )

    plan
    |> nodes()
    |> Enum.filter(&(Map.get(&1, "Filter", "") =~ "retained_at"))
    |> Enum.reject(&(Map.get(&1, "Filter", "") =~ "knowledge_id"))
    |> Enum.map(&Map.get(&1, "Rows Removed by Filter", 0))
    |> Enum.sum()
  end

  defp nodes(plan), do: [plan | Enum.flat_map(Map.get(plan, "Plans", []), &nodes/1)]

  defp topic_reference! do
    {_source, document} = KnowledgeFixtures.learn!(episode!(), "tenant-infra")
    reference(document)
  end

  defp episode! do
    id = Ecto.UUID.generate()

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "learning-roots:#{id}",
          native_input_id: "source:#{id}",
          turn_ref: "turn:#{id}",
          payload: %{"text" => "Keep the alert history."},
          destination: %{
            transport: "slack",
            conversation_ref: "slack:T#{String.replace(id, "-", "")}:C0TENANTOPS",
            thread_ref: "roots"
          }
        })
      )

    episode
  end

  defp reference(%{"source_ref" => "knowledge:" <> id}) do
    topic = Repo.get!(ConversationKnowledge, id)
    LearningSources.knowledge_reference(id, topic.source_generation, topic.version)
  end

  defp expanded(dependencies),
    do: count("SELECT count(*) FROM ryker_learning_roots($1)", dependencies)

  defp null_rows(dependencies),
    do: count("SELECT count(*) FROM ryker_learning_roots($1) r WHERE r IS NULL", dependencies)

  defp count(sql, dependencies) do
    %{rows: [[count]]} = SQL.query!(Repo, sql, [CanonicalJSON.encode!(dependencies)])
    count
  end
end
