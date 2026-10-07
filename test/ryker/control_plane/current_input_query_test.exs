defmodule Ryker.ControlPlane.CurrentInputQueryTest do
  @moduledoc """
  A message as the console shows it: its current revision, read for each
  message a page shows rather than by ranking every revision in the inbox.
  """
  use Ryker.DataCase, async: true
  import Ecto.Query
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{Activity, AdmissionProgress, ConversationProjection}
  alias Ryker.ControlPlane.CurrentInputQuery
  alias Ryker.Episodes
  alias Ryker.Fixtures.Answers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.Input
  alias Ryker.QueryWork

  @table "ingress_inbox_entries"

  # The rest of the inbox: other channels' Slack messages, which none of the
  # pages below shows. They were other Chat conversations' messages until the
  # test failed under load (2026-10-06): the shared test database's statistics,
  # drawn from rows other suites commit, can make Chat messages look rare, and
  # PostgreSQL then rightly reads every Chat message through the source index.
  # Reading only Chat messages is not reading the whole inbox; Slack's are.
  setup do
    for channel <- 1..12 do
      Answers.slack_message!(
        workspace: "TOTHER",
        channel: "COTHER#{channel}",
        text: "Is the queue draining?",
        ts: "17907#{10_000 + channel}.000100"
      )
    end

    :ok
  end

  test "a message reads as its newest revision" do
    ref = conversation()
    edit!(message!(ref, "Is checkout healthy?"), "Is checkout healthy in eu-west?")

    assert ConversationProjection.titles([ref]) == %{ref => "Is checkout healthy in eu-west?"}

    assert [_ | _] = progress = AdmissionProgress.conversation(ref)
    assert Enum.all?(progress, &(&1.title == "Is checkout healthy in eu-west?"))

    episode = episode!()

    edit!(
      associate!(message!(conversation(), "Deploy failed"), episode.id),
      "Deploy failed twice"
    )

    assert [%{content: %{"text" => "Deploy failed twice"}}] =
             Repo.all(CurrentInputQuery.for_episode(episode.id))
  end

  # Ranking every revision in the inbox to find each message's current one
  # read the whole table: four times for each Activity load, and again for
  # every Chat refresh, case file and request title (2026-10-04 review).
  test "a conversation's pages read its own messages' revisions, not the whole inbox" do
    ref = conversation()
    edit!(message!(ref, "Is checkout healthy?"), "Is checkout healthy in eu-west?")
    message!(ref, "And payments?")

    own =
      Repo.aggregate(
        from(entry in Entry, where: entry.destination_conversation_ref == ^ref),
        :count
      )

    assert Repo.aggregate(Entry, :count) > own * 4

    {_titles, statements} = QueryWork.statements(fn -> ConversationProjection.titles([ref]) end)

    assert QueryWork.most_rows_read(statements, @table) <= own * 2

    {_progress, statements} = QueryWork.statements(fn -> AdmissionProgress.conversation(ref) end)
    assert QueryWork.most_rows_read(statements, @table) <= own * 2
  end

  test "a request's case file and title read its own messages' revisions, not the whole inbox" do
    episode = episode!()

    edit!(
      associate!(message!(conversation(), "Deploy failed"), episode.id),
      "Deploy failed twice"
    )

    own = Repo.aggregate(from(entry in Entry, where: entry.episode_id == ^episode.id), :count) + 1
    assert Repo.aggregate(Entry, :count) > own * 4

    {_messages, statements} =
      QueryWork.statements(fn -> Repo.all(CurrentInputQuery.for_episode(episode.id)) end)

    assert QueryWork.most_rows_read(statements, @table) <= own * 2

    {titles, statements} = QueryWork.statements(fn -> Activity.request_titles([episode.key]) end)
    assert %{title: "Deploy failed twice"} = titles[episode.key]
    assert QueryWork.most_rows_read(statements, @table) <= own * 2
  end

  defp conversation, do: "control-plane:lab:" <> Ecto.UUID.generate()

  # A message sent in Chat, as ConversationLab records one.
  defp message!(conversation, text) do
    id = Ecto.UUID.generate()

    record!(
      conversation,
      :message,
      "control-plane-message:" <> id,
      "control-plane-item:" <> id,
      text
    )
  end

  # An edit of `entry`, recorded the way ConversationLab records one.
  defp edit!(entry, text) do
    record!(
      entry.destination_conversation_ref,
      :edit,
      entry.native_input_id,
      entry.source_item_ref,
      text
    )
  end

  defp record!(conversation, kind, native_input_id, source_item_ref, text) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "local-operator"},
        content: %{"text" => text},
        destination: %{
          transport: "control_plane",
          conversation_ref: conversation,
          thread_ref: conversation
        },
        event_kind: kind,
        event_ref: "control-plane-event:" <> Ecto.UUID.generate(),
        native_input_id: native_input_id,
        occurred_at: DateTime.utc_now(),
        occurred_at_source: :ingress,
        revision: 1,
        source: %{kind: "control_plane", ref: "local"},
        source_capabilities: %{
          "post_slack_message" => %{"destination_refs" => [conversation]},
          "react" => %{"emoji_names" => nil}
        },
        source_item_ref: source_item_ref
      })

    {:ok, %{entry: entry}} = Inbox.record(input, revision_ties: :receipt_order)
    entry
  end

  defp episode! do
    id = Ecto.UUID.generate()

    assert {:ok, %{episode: episode}} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "current-inputs:" <> id,
                 native_input_id: "source:current-inputs:" <> id,
                 turn_ref: "turn:current-inputs:" <> id
               })
             )

    episode
  end

  # What routing records when it files a message under existing work.
  defp associate!(entry, episode_id) do
    decision = %{"action" => "continue_episode", "reason" => "Current inputs fixture."}

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        decision_action: :continue_episode,
        decision_document: decision,
        decision_fingerprint: CanonicalJSON.digest(decision),
        decision_ref: "decision:#{entry.id}",
        episode_id: episode_id,
        status: :decided
      ]
    )

    Repo.get!(Entry, entry.id)
  end
end
