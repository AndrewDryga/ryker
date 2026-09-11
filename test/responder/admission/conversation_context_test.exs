defmodule Responder.Admission.ConversationContextTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Admission.{ConversationContext, ConversationSummaries}
  alias Responder.CanonicalJSON
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.State.ConversationSummary

  @workspace "TROUTE"
  @channel "CDEVOPS"
  @now ~U[2026-09-11 12:00:00.000000Z]

  test "a thread reply receives its root and the twenty messages that precede it in that thread" do
    # Admission saw only the message it was deciding. A reply that says "it is
    # still failing" is undecidable without the thread it belongs to, and a
    # relevance-ranked recall is not the same thing as the actual predecessors.
    root = record!("Database is unavailable", ts: "1789000000.000100")

    for index <- 1..25 do
      record!("Thread message #{index}",
        ts: "17890000#{String.pad_leading(Integer.to_string(index), 2, "0")}.000100",
        thread_ref: "1789000000.000100"
      )
    end

    current =
      record!("Is it still failing?",
        ts: "1789000100.000100",
        thread_ref: "1789000000.000100"
      )

    %{bundle: bundle, manifest: manifest} = ConversationContext.capture(current)

    assert manifest["kind"] == "thread_reply"
    assert manifest["requested"] == 20
    assert manifest["included"] == 20
    assert bundle["root"]["source_message_ref"] == root.source_item_ref
    assert bundle["root"]["status"] == "included"
    assert bundle["current"]["content"]["text"] == "Is it still failing?"

    occurred = Enum.map(bundle["messages"], & &1["occurred_at"])
    assert occurred == Enum.sort(occurred)
    refute Enum.any?(bundle["messages"], &(&1["source_message_ref"] == current.source_item_ref))
    assert List.last(bundle["messages"])["content"]["text"] == "Thread message 25"
  end

  test "a channel root receives previous top-level messages, never replies from other threads" do
    for index <- 1..3 do
      record!("Top level #{index}", ts: "178900010#{index}.000100")
    end

    record!("Reply inside another thread",
      ts: "1789000105.000100",
      thread_ref: "1789000101.000100"
    )

    current = record!("A new question", ts: "1789000200.000100")
    %{bundle: bundle, manifest: manifest} = ConversationContext.capture(current)

    assert manifest["kind"] == "channel_root"
    assert manifest["root"] == "not_applicable"

    texts = Enum.map(bundle["messages"], & &1["content"]["text"])
    assert texts == ["Top level 1", "Top level 2", "Top level 3"]
    refute "Reply inside another thread" in texts
  end

  test "later and queued messages never enter an earlier context" do
    record!("Earlier message", ts: "1789000001.000100")
    current = record!("Decide me", ts: "1789000002.000100")
    record!("Arrived while deciding", ts: "1789000003.000100")

    %{bundle: bundle, manifest: manifest} = ConversationContext.capture(current)

    texts = Enum.map(bundle["messages"], & &1["content"]["text"])
    assert texts == ["Earlier message"]
    assert manifest["cutoff"] == DateTime.to_iso8601(current.occurred_at)
  end

  test "an ignored message and a previous Responder answer are background without episode membership" do
    ignored = record!("Unrelated chatter nobody acted on", ts: "1789000010.000100")
    current = record!("Please look at the database", ts: "1789000011.000100")

    assert is_nil(Repo.get!(Entry, ignored.id).episode_id)

    %{bundle: bundle} = ConversationContext.capture(current)
    assert Enum.map(bundle["messages"], & &1["content"]["text"]) == [ignored.content["text"]]
  end

  test "the root is kept even when it is older than the twenty-message window" do
    root = record!("The original report", ts: "1789000000.000100")

    for index <- 1..30 do
      record!("Filler #{index}",
        ts: "17890001#{String.pad_leading(Integer.to_string(index), 2, "0")}.000100",
        thread_ref: "1789000000.000100"
      )
    end

    current = record!("Latest", ts: "1789000900.000100", thread_ref: "1789000000.000100")
    %{bundle: bundle} = ConversationContext.capture(current)

    assert bundle["root"]["source_message_ref"] == root.source_item_ref
    assert bundle["root"]["status"] == "included"
    refute Enum.any?(bundle["messages"], &(&1["source_message_ref"] == root.source_item_ref))
  end

  test "a bounded provider read fills what retention already reclaimed and says so" do
    current = record!("Only survivor", ts: "1789000500.000100")

    reader =
      {Responder.Admission.ConversationContextTest.FakeReader,
       [
         %{"ts" => "1789000400.000100", "text" => "Reclaimed one", "user" => "U1"},
         %{"ts" => "1789000450.000100", "text" => "Reclaimed two", "user" => "U1"}
       ]}

    %{bundle: bundle, manifest: manifest} = ConversationContext.capture(current, reader: reader)

    assert manifest["source_read"] == "provider_paged"
    texts = Enum.map(bundle["messages"], & &1["content"]["text"])
    assert texts == ["Reclaimed one", "Reclaimed two"]
    refute Enum.any?(bundle["messages"], & &1["retained"])
  end

  test "a failed provider read degrades to retained messages without inventing coverage" do
    record!("Retained one", ts: "1789000600.000100")
    current = record!("Current", ts: "1789000601.000100")

    reader = {Responder.Admission.ConversationContextTest.FailingReader, :denied}
    %{bundle: bundle, manifest: manifest} = ConversationContext.capture(current, reader: reader)

    assert manifest["source_read"] == "provider_unavailable:slack_api_error"
    assert Enum.map(bundle["messages"], & &1["content"]["text"]) == ["Retained one"]
  end

  test "summaries report absent, stale, current and after-cutoff without fabricating freshness" do
    current = record!("Decide me", ts: "1789000700.000100", thread_ref: "1789000650.000100")

    assert ConversationSummaries.thread(current, @now)["status"] == "unavailable"
    assert ConversationSummaries.thread(current, @now)["reason"] == "absent"
    assert ConversationSummaries.channel(current, @now)["reason"] == "absent"

    summary!(current, "1789000650.000100", "1789000660.000100", DateTime.add(@now, -60, :second))
    fresh = ConversationSummaries.thread(current, @now)
    assert fresh["status"] == "available"
    assert fresh["freshness"] == "current"
    assert fresh["document"]["state"]["situation"] == "Replication is stalled"

    summary!(
      current,
      "1789000650.000100",
      "1789000660.000100",
      DateTime.add(@now, -3 * 24 * 3600, :second)
    )

    assert ConversationSummaries.thread(current, @now)["freshness"] == "stale"

    summary!(current, "1789000650.000100", "1789000800.000100", DateTime.add(@now, -60, :second))
    after_cutoff = ConversationSummaries.thread(current, @now)
    assert after_cutoff["status"] == "unavailable"
    assert after_cutoff["reason"] == "after_cutoff"
    assert is_nil(after_cutoff["document"])
  end

  test "the captured bundle carries both summaries and their coverage in the manifest" do
    current = record!("Decide me", ts: "1789000900.000100", thread_ref: "1789000850.000100")
    summary!(current, "1789000850.000100", "1789000860.000100", DateTime.add(@now, -60, :second))

    captured =
      current
      |> ConversationContext.capture()
      |> ConversationContext.with_summaries(
        ConversationSummaries.thread(current, @now),
        ConversationSummaries.channel(current, @now)
      )

    assert captured.bundle["thread_summary"]["freshness"] == "current"
    assert is_nil(captured.bundle["channel_summary"])
    assert captured.manifest["thread_summary"]["status"] == "available"
    assert captured.manifest["channel_summary"]["reason"] == "absent"
    refute Map.has_key?(captured.manifest["thread_summary"], "document")
  end

  defmodule FakeReader do
    @moduledoc false
    def read_messages(messages, _channel_ref, _thread_ref, _document),
      do: {:ok, %{"messages" => messages, "cursor" => ""}}
  end

  defmodule FailingReader do
    @moduledoc false
    def read_messages(_client, _channel_ref, _thread_ref, _document),
      do: {:error, {:slack_api_error, "not_in_channel"}}
  end

  defp record!(text, options) do
    ts = Keyword.fetch!(options, :ts)
    thread_ref = Keyword.get(options, :thread_ref)

    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "U1"},
        channel_ref: @channel,
        content: %{"text" => text},
        event_kind: :message,
        event_ref: "Ev-#{ts}",
        message_ref: ts,
        occurred_at: slack_time(ts),
        revision: 1,
        thread_ref: thread_ref,
        workspace_ref: @workspace
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp summary!(entry, thread_ref, source_message_ref, updated_at) do
    identity =
      CanonicalJSON.digest(%{
        "conversation_ref" => entry.destination_conversation_ref,
        "thread_ref" => thread_ref,
        "transport" => entry.destination_transport
      })

    Repo.delete_all(
      from(summary in ConversationSummary, where: summary.identity_key == ^identity)
    )

    Repo.insert!(%ConversationSummary{
      id: Ecto.UUID.generate(),
      ref: "summary:#{System.unique_integer([:positive])}",
      identity_key: identity,
      transport: entry.destination_transport,
      workspace_ref: "slack:#{@workspace}",
      conversation_ref: entry.destination_conversation_ref,
      thread_ref: thread_ref,
      visibility: :conversation,
      state: summary_state(),
      source_dependencies: [],
      state_fingerprint: String.duplicate("a", 64),
      source_result_ref: "result:summary:#{System.unique_integer([:positive])}",
      source_message_ref: source_message_ref,
      inserted_at: updated_at,
      updated_at: updated_at
    })
  end

  defp summary_state do
    %{
      "active_topics" => ["database"],
      "decisions" => [],
      "evidence_refs" => [],
      "goal" => "Restore the primary",
      "open_loops" => [],
      "participants" => ["U1"],
      "purpose" => "Incident response",
      "situation" => "Replication is stalled",
      "topology" => [],
      "unresolved_questions" => []
    }
  end

  defp slack_time(ts) do
    {seconds, _rest} = Float.parse(ts)
    seconds |> Kernel.*(1_000_000) |> round() |> DateTime.from_unix!(:microsecond)
  end
end
