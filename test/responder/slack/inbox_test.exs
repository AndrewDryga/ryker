defmodule Responder.Slack.InboxTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Slack.{Inbox, Input}
  alias Responder.Slack.Inbox.Entry

  @occurred_at ~U[2026-08-27 12:00:00Z]

  test "records an arbitrary Slack event without interpreting its provider" do
    content = %{
      "blocks" => [%{"type" => "rich_text", "vendor_state" => "something-new"}],
      "files" => [%{"id" => "F1", "mimetype" => "application/octet-stream"}],
      "text" => "A message from an app added tomorrow"
    }

    input = input!(content: content)

    assert {:ok, %{status: :recorded, entry: entry}} = Inbox.record(input)
    assert entry.content == content
    assert entry.status == :pending
    assert entry.episode_id == nil
    assert entry.occurred_at == ~U[2026-08-27 12:00:00.000000Z]

    assert {:ok, loaded} = Inbox.fetch(Inbox.ref(entry))
    assert loaded.id == entry.id
    assert loaded.content == content
  end

  test "returns the original durable record when Slack retries the exact event" do
    input = input!()

    assert {:ok, %{status: :recorded, entry: first}} = Inbox.record(input)
    assert {:ok, %{status: :duplicate, entry: retried}} = Inbox.record(input)

    assert retried.id == first.id
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "rejects a reused Slack event identity with changed content" do
    assert {:ok, %{entry: stored}} = Inbox.record(input!())

    assert {:error,
            {:input_conflict,
             dedupe_key: dedupe_key,
             stored_fingerprint: stored_fingerprint,
             submitted_fingerprint: submitted_fingerprint}} =
             Inbox.record(input!(content: %{"text" => "different bytes"}))

    assert dedupe_key == stored.dedupe_key
    assert stored_fingerprint == stored.event_fingerprint
    refute submitted_fingerprint == stored_fingerprint
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "keeps different Slack events independent even when they update one message" do
    assert {:ok, %{entry: first}} = Inbox.record(input!())

    assert {:ok, %{entry: edit}} =
             Inbox.record(
               input!(
                 event_kind: :edit,
                 event_ref: "Ev-edit",
                 revision: 2,
                 content: %{"text" => "edited"}
               )
             )

    refute first.id == edit.id

    assert Repo.all(from(entry in Entry, order_by: entry.revision, select: entry.revision)) ==
             [1, 2]
  end

  defp input!(overrides \\ []) do
    attributes =
      Keyword.merge(
        [
          actor: %{kind: :app, ref: "A123"},
          channel_ref: "C456",
          content: %{"text" => "A generic Slack message"},
          event_kind: :message,
          event_ref: "Ev123",
          message_ref: "1787832000.000100",
          occurred_at: @occurred_at,
          revision: 1,
          thread_ref: nil,
          workspace_ref: "T123"
        ],
        overrides
      )

    assert {:ok, input} = Input.new(attributes)
    input
  end
end
