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

  test "a topic cited twice expands to each of its sources once, and a missing one still fails" do
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

    {_source, document} = KnowledgeFixtures.learn!(episode, "tenant-infra")
    "knowledge:" <> id = document["source_ref"]
    topic = Repo.get!(ConversationKnowledge, id)
    reference = LearningSources.knowledge_reference(id, topic.source_generation, topic.version)
    missing = %{reference | "knowledge_id" => Ecto.UUID.generate()}

    assert expanded([reference, reference]) == 1
    assert expanded([reference, missing, missing]) == 2
    assert null_rows([reference, missing]) == 1

    assert migrate_down(@version) == :ok
    assert expanded([reference, reference]) == 2

    assert migrate_up(@version) == :ok
    assert expanded([reference, reference]) == 1
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
