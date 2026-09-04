defmodule Responder.Slack.AppHomeProjectionTest do
  use Responder.DataCase, async: false

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Fixtures.Publication, as: PublicationFixture
  alias Responder.Slack.AppHomeProjection

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "projects bounded operator state from the exact Slack workspace" do
    local = waiting_episode!("T123", "local")
    foreign = waiting_episode!("T999", "foreign")
    publication = PublicationFixture.published!("app-home-projection")

    snapshot = AppHomeProjection.snapshot("T123", "U123")

    assert snapshot.counts.active_commitments == 1
    assert snapshot.counts.published_work == 1

    assert Enum.any?(snapshot.needs_attention, fn row ->
             row.kind == :operator_input and row.ref == local.episode.key
           end)

    assert Enum.any?(snapshot.work, &(&1.ref == local.episode.key))
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
    assert AppHomeProjection.snapshot("not a Slack workspace", "U123") ==
             AppHomeProjection.empty()

    assert AppHomeProjection.snapshot("T123", "not a Slack user") ==
             AppHomeProjection.empty()
  end

  defp waiting_episode!(workspace_ref, suffix) do
    id = Ecto.UUID.generate()
    turn_ref = "turn:app-home:#{suffix}:#{id}"
    key = "app-home:#{suffix}:#{id}"

    {:ok, started} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: "slack:#{workspace_ref}:C456",
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
