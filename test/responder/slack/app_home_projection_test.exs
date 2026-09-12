defmodule Responder.Slack.AppHomeProjectionTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Fixtures.Publication, as: PublicationFixture
  alias Responder.Fixtures.SavedEntities
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

  # The collections card told every channel "open my App Home to see the
  # complete list" while Home showed five rows and stopped. The complete list
  # is read here, past the inline page, one bounded page at a time.
  test "the complete list reaches every item past the page an inline card shows" do
    source = SavedEntities.source!("slack:T123:C456")
    schedules = for index <- 1..12, do: SavedEntities.schedule!(source, "Check #{index}", index)

    _elsewhere =
      SavedEntities.schedule!(source, "Another channel", 13, destination: "slack:T123:C999")

    first = AppHomeProjection.collection(:schedules, "T123", MapSet.new(["C456"]), 0)

    assert first.outcome == :listed
    assert first.total == 12
    assert first.offset == 0
    assert first.page_size == 10
    assert length(first.rows) == 10
    assert Enum.map(first.rows, & &1.title) == Enum.map(1..10, &"Check #{&1}")
    assert Enum.map(first.rows, & &1.ref) == schedules |> Enum.take(10) |> Enum.map(& &1.ref)
    assert Enum.all?(first.rows, &(&1.detail == "Schedule active"))

    assert Enum.all?(
             first.rows,
             &(&1.url == "https://slack.com/app_redirect?team=T123&channel=C456")
           )

    second = AppHomeProjection.collection(:schedules, "T123", MapSet.new(["C456"]), 10)

    assert second.offset == 10
    assert second.total == 12
    assert Enum.map(second.rows, & &1.title) == ["Check 11", "Check 12"]
    refute Jason.encode!(first.rows ++ second.rows) =~ "Another channel"
  end

  # Each page is read with the authority the reader has now, not the authority
  # they had when the button was rendered: a channel they have left is gone
  # from the next page rather than carried along by the offset.
  test "every page of the complete list is read under the reader's current access" do
    source = SavedEntities.source!("slack:T123:C456")
    mine = SavedEntities.schedule!(source, "Mine", 1)
    shared = SavedEntities.schedule!(source, "Shared", 2, destination: "slack:T123:C999")

    both = AppHomeProjection.collection(:schedules, "T123", MapSet.new(["C456", "C999"]), 0)
    assert Enum.map(both.rows, & &1.ref) == [mine.ref, shared.ref]

    left = AppHomeProjection.collection(:schedules, "T123", MapSet.new(["C456"]), 0)
    assert Enum.map(left.rows, & &1.ref) == [mine.ref]
    assert left.total == 1
    refute Jason.encode!(left) =~ "Shared"
  end

  test "private guidance and another channel's knowledge are never in the complete list" do
    source = SavedEntities.source!("slack:T123:C456")

    here =
      SavedEntities.behavior!(
        source,
        :guidance,
        guidance("Deploy reviews", "Read the release notes first.", "conversation"),
        scope_ref: "slack:T123:C456"
      )

    _elsewhere =
      SavedEntities.behavior!(
        source,
        :guidance,
        guidance("Secret channel guidance", "Only for the other channel.", "conversation"),
        scope_ref: "slack:T123:GSECRET",
        source: "slack:T123:GSECRET"
      )

    _private =
      SavedEntities.behavior!(
        source,
        :guidance,
        guidance("Only mine", "Private.", "private"),
        scope_kind: :operator,
        scope_ref: "slack:user:U999"
      )

    listed = AppHomeProjection.collection(:knowledge, "T123", MapSet.new(["C456"]), 0)

    assert Enum.map(listed.rows, & &1.ref) == [here.ref]
    assert listed.total == 1
    rendered = Jason.encode!(listed)
    refute rendered =~ "Secret channel guidance"
    refute rendered =~ "Only mine"
  end

  # An empty channel and a query that never ran must not read the same, in the
  # complete list for the same reason they must not read the same in a thread.
  test "an empty complete list and one that could not be read are different answers" do
    empty = AppHomeProjection.collection(:schedules, "T123", MapSet.new(["C456"]), 0)

    assert empty.outcome == :empty
    assert empty.rows == []
    assert empty.total == 0

    Repo.query!("SET LOCAL search_path TO pg_temp")

    unavailable = AppHomeProjection.collection(:schedules, "T123", MapSet.new(["C456"]), 0)

    assert unavailable.outcome == :unavailable
    assert unavailable.rows == []
    assert unavailable.total == 0
  end

  test "an unreadable identity or offset is unavailable, never an empty list" do
    for arguments <- [
          {:schedules, "not a workspace", MapSet.new(["C456"]), 0},
          {:schedules, "T123", MapSet.new(["not a channel"]), 0},
          {:schedules, "T123", ["C456"], 0},
          {:schedules, "T123", MapSet.new(["C456"]), -1},
          {:everything, "T123", MapSet.new(["C456"]), 0}
        ] do
      {kind, workspace_ref, conversations, offset} = arguments

      assert AppHomeProjection.collection(kind, workspace_ref, conversations, offset).outcome ==
               :unavailable
    end
  end

  defp guidance(subject, text, visibility) do
    %{
      "expires_in" => "30d",
      "repository" => nil,
      "scope" => if(visibility == "private", do: "operator", else: "conversation"),
      "subject" => subject,
      "summary" => text,
      "text" => text,
      "visibility" => visibility
    }
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
