defmodule Ryker.Fixtures.Personalization do
  @moduledoc "Host personal context backed by harvested correction and notification bytes."
  import ExUnit.Assertions
  import Ecto.Query
  alias Ryker.Behaviors
  alias Ryker.Episodes
  alias Ryker.Fixtures.{Corrections, SavedEntities}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Ingress
  alias Ryker.Inspectors
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.People
  alias Ryker.People.PersonFact
  alias Ryker.Repo
  alias Ryker.Slack
  alias Ryker.Work
  alias Ryker.Work.Custody

  def personal_context! do
    correction = Corrections.correction!()
    entry = correction.entry

    fact =
      Repo.insert!(%PersonFact{
        person_ref: People.person_ref(entry),
        key: "review-style",
        fact: correction.arguments["instruction"],
        status: :kept,
        source_input_id: entry.id,
        source_message_ref: entry.native_input_id,
        conversation_ref: entry.destination_conversation_ref,
        private: false,
        said_at: entry.occurred_at
      })

    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 actor_ref: fact.person_ref,
                 destination: %{
                   transport: "slack",
                   conversation_ref: fact.conversation_ref,
                   thread_ref: "1792900000.000001"
                 },
                 episode_id: id,
                 episode_key: "personal-context:#{id}",
                 native_input_id: "personal-context:#{id}",
                 payload: notification(),
                 turn_ref: "personal-context:#{id}"
               })
             )

    assert {:ok, _} = WorkSessions.pin_episode(id, "profile-context", String.duplicate("a", 64))
    assert {:ok, claim} = Custody.claim_next("profile:#{id}", 60, :work)
    assert claim.episode.id == id
    claim = current_context!(claim)

    assert get_in(claim.turn.submission, [
             "context",
             "operator_context",
             "person_asking",
             "said_about_themselves"
           ]) == [fact.fact]

    {claim, fact}
  end

  def preference_context! do
    correction = Corrections.correction!()
    claim = correction.claim
    assert KnowledgeSnapshot.expose(claim, []) == :ok

    source = %{
      episode: claim.episode,
      turn: claim.turn,
      conversation_ref: claim.episode.destination_conversation_ref
    }

    preference =
      SavedEntities.behavior!(
        source,
        :preference,
        %{
          "expires_in" => "90d",
          "key" => "response_detail",
          "repository" => nil,
          "scope" => "conversation",
          "value" => "detailed"
        },
        scope_ref: source.conversation_ref
      )

    claim = current_context!(claim)

    assert get_in(claim.turn.submission, [
             "context",
             "operator_context",
             "preferences",
             "response_detail",
             "behavior_ref"
           ]) == preference.ref

    {claim, preference}
  end

  defp current_context!(claim) do
    assert {:ok, submission} = Inspectors.submission(claim)

    assert {:ok, _} =
             Custody.thaw_stale_submission(claim.episode.id, claim.turn.turn_ref, claim.lease_ref)

    assert {:ok, turn} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission,
               selected_input_refs: claim.episode.active_input_refs
             )

    %{claim | turn: turn}
  end

  defp notification do
    "testdata/learning/retained-rollout-correction.json"
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["notification", "content"])
  end

  @doc "Remove only this fixture's unique workspace after an unboxed concurrency test."
  def cleanup!(claim) do
    conversation = claim.episode.destination_conversation_ref
    {:ok, workspace, _channel} = Ryker.ConversationRef.parse_slack(conversation)

    ids =
      Repo.all(
        from(e in Episodes.Episode,
          where: e.destination_conversation_ref == ^conversation,
          select: e.id
        )
      )

    Repo.delete_all(from(f in PersonFact, where: f.conversation_ref == ^conversation))

    Repo.delete_all(
      from(b in Behaviors.Behavior, where: b.source_conversation_ref == ^conversation)
    )

    Repo.delete_all(from(r in Ryker.Records.Record, where: r.episode_id in ^ids))

    Ryker.ConcurrencyCase.delete_entries!(
      from(e in Ingress.Inbox.Entry, where: e.destination_conversation_ref == ^conversation)
    )

    Repo.delete_all(from(t in Work.Turn, where: t.episode_id in ^ids))
    Repo.delete_all(from(s in Work.Session, where: s.episode_id in ^ids))
    Repo.delete_all(from(e in Episodes.Event, where: e.episode_id in ^ids))
    Repo.delete_all(from(e in Episodes.Episode, where: e.id in ^ids))
    Repo.delete_all(from(m in Slack.ChannelMembership, where: m.workspace_ref == ^workspace))
  end
end
