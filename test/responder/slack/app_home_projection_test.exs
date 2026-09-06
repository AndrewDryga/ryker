defmodule Responder.Slack.AppHomeProjectionTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Fixtures.Publication, as: PublicationFixture
  alias Responder.Repo
  alias Responder.Slack.AppHomeProjection

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "projects bounded operator state from the exact Slack workspace" do
    local = waiting_episode!("T123", "local")
    foreign = waiting_episode!("T999", "foreign")

    publication =
      PublicationFixture.published!("app-home-projection", conversation_ref: "slack:T123:C456")

    snapshot = AppHomeProjection.snapshot("T123", "U123", MapSet.new(["C456"]))

    assert snapshot.counts.active_commitments == 1
    assert snapshot.counts.published_work == 1

    assert Enum.any?(snapshot.needs_attention, fn row ->
             row.kind == :operator_input and row.ref == local.episode.key and
               row.title == "Choose local." and
               row.url == "https://slack.com/app_redirect?team=T123&channel=C456"
           end)

    assert Enum.any?(snapshot.work, fn row ->
             row.ref == local.episode.key and row.title == "Choose local." and
               row.url == "https://slack.com/app_redirect?team=T123&channel=C456"
           end)

    refute Enum.any?(snapshot.work, &(&1.ref == foreign.episode.key))
    refute Enum.any?(snapshot.work, &(&1.ref == publication.episode.key))

    assert length(snapshot.needs_attention) <= 8
    assert length(snapshot.work) <= 8
    assert length(snapshot.incidents) <= 5
    assert length(snapshot.behaviors) <= 5
    assert length(snapshot.memories) <= 5
    assert length(snapshot.memory_reviews) <= 2
    assert snapshot.memory_review_count >= length(snapshot.memory_reviews)
    assert length(snapshot.schedules) <= 5
  end

  test "invalid workspace identity returns an empty bounded projection" do
    assert AppHomeProjection.snapshot("not a Slack workspace", "U123", MapSet.new()) ==
             AppHomeProjection.empty()

    assert AppHomeProjection.snapshot("T123", "not a Slack user", MapSet.new()) ==
             AppHomeProjection.empty()

    assert AppHomeProjection.snapshot("T123", "U123", ["C456"]) ==
             AppHomeProjection.empty()
  end

  test "private conversation titles and counts are absent when Home user no longer shares them" do
    visible = waiting_episode!("T123", "visible", "C456")
    secret = waiting_episode!("T123", "secret", "GSECRET")

    %{publication: secret_publication} =
      PublicationFixture.published!("secret-home-publication",
        conversation_ref: "slack:T123:C456"
      )

    Repo.update_all(
      from(publication in Responder.Publication.Publication,
        where: publication.id == ^secret_publication.id
      ),
      set: [
        destination_conversation_ref: "slack:T123:GSECRET",
        expected_remote_head_sha: String.duplicate("9", 40)
      ]
    )

    snapshot = AppHomeProjection.snapshot("T123", "U123", MapSet.new(["C456"]))

    assert snapshot.counts.active_commitments == 1
    assert snapshot.counts.published_work == 0
    assert Enum.any?(snapshot.work, &(&1.ref == visible.episode.key))
    refute Enum.any?(snapshot.work, &(&1.ref == secret.episode.key))
    refute Jason.encode!(snapshot) =~ "Choose secret."
    refute Jason.encode!(snapshot) =~ "Implement secret-home-publication"
  end

  defp waiting_episode!(workspace_ref, suffix, channel_ref \\ "C456") do
    id = Ecto.UUID.generate()
    turn_ref = "turn:app-home:#{suffix}:#{id}"
    key = "app-home:#{suffix}:#{id}"

    {:ok, started} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: "slack:#{workspace_ref}:#{channel_ref}",
            thread_ref: "thread:#{suffix}",
            transport: "slack"
          },
          episode_id: id,
          episode_key: key,
          native_input_id: "source:app-home:#{suffix}:#{id}",
          occurred_at: @now,
          payload: %{"text" => "Choose #{suffix}."},
          turn_ref: turn_ref
        })
      )

    {:ok, waiting} =
      Episodes.apply(
        EpisodeFixtures.start_wait(%{
          episode_key: key,
          expected_turn_ref: turn_ref,
          occurred_at: DateTime.add(@now, 1, :second),
          wait_ref: "question:#{suffix}:#{id}"
        })
      )

    %{episode: waiting.episode, started: started.episode}
  end
end
