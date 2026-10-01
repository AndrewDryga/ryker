defmodule Ryker.Admission.ConversationContextTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Admission.{ConversationContext, ConversationSummaries}
  alias Ryker.CanonicalJSON
  alias Ryker.Continuity.ConversationSummary
  alias Ryker.Delivery.RoutingResponse
  alias Ryker.Episodes
  alias Ryker.Episodes.Scope
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.Input
  alias Ryker.Ingress.MessageText
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.{Custody, Turn}

  @workspace "TCONTEXT"
  # This module's own channel: its Ryker replies admit episodes, and async
  # modules that share a conversation take its admission lock in opposite
  # orders and deadlock under load.
  @channel "CCONVERSATIONCONTEXT"
  # A summary names its newest input the way the Work handover records it, by
  # the input's episode key and never by the message's own timestamp. This one
  # is production's, from the thread summary of 2026-09-28 below.
  @handover_ref "admit_input:87ee48596c232b8344bce82c8c1bb5c147000e534b7c9a02a9fb15239f007f04"

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

  test "an ignored message and a previous Ryker answer are background without episode membership" do
    ignored = record!("Unrelated chatter nobody acted on", ts: "1789000010.000100")
    current = record!("Please look at the database", ts: "1789000011.000100")

    assert is_nil(Repo.get!(Entry, ignored.id).episode_id)

    %{bundle: bundle} = ConversationContext.capture(current)
    assert Enum.map(bundle["messages"], & &1["content"]["text"]) == [ignored.content["text"]]
  end

  test "Ryker's own delivered replies sit between the messages they answered" do
    # Routing and Work saw what people said but never what Ryker had answered, so
    # "add the word confirmed after the reply above" was decided without the reply.
    record!("What is the deploy status?", ts: "1789000020.000100")
    reply!("The deploy is healthy.", ts: "1789000021.000100")
    record!("And the database?", ts: "1789000022.000100")
    current = record!("Add the word confirmed after your last reply", ts: "1789000023.000100")
    # Sent after the message being decided: never part of its context.
    reply!("Arrived while deciding.", ts: "1789000024.000100")

    %{bundle: bundle, manifest: manifest} = ConversationContext.capture(current)

    assert Enum.map(bundle["messages"], &{&1["actor_ref"] == "ryker", &1["content"]["text"]}) == [
             {false, "What is the deploy status?"},
             {true, "The deploy is healthy."},
             {false, "And the database?"}
           ]

    assert manifest["included"] == 3
  end

  test "Ryker's replies follow the thread scope and are not repeated by a provider read" do
    root = record!("Database is unavailable", ts: "1789000030.000100")

    reply!("Looking at the primary now.",
      ts: "1789000031.000100",
      thread_ref: root.source_item_ref
    )

    reply!("A reply in another thread.", ts: "1789000032.000100", thread_ref: "1789000001.000100")

    current =
      record!("Any update?", ts: "1789000033.000100", thread_ref: root.source_item_ref)

    # Slack's own history returns Ryker's post under its bot identity; the
    # delivered reply is the same message and keeps Ryker's name.
    reader =
      {Ryker.Admission.ConversationContextTest.FakeReader,
       [%{"ts" => "1789000031.000100", "text" => "Looking at the primary now.", "bot_id" => "B1"}]}

    %{bundle: bundle} = ConversationContext.capture(current, reader: reader)

    assert Enum.map(bundle["messages"], &{&1["actor_ref"] == "ryker", &1["content"]["text"]}) == [
             {false, "Database is unavailable"},
             {true, "Looking at the primary now."}
           ]
  end

  # Routing answered "hi" itself and the person replied in the thread. The
  # context held their "hi" and their follow-up but not what Ryker had said
  # between them, so the follow-up was decided as if Ryker had never answered.
  test "Ryker's quick replies sit in the thread they answered" do
    root = record!("hi", ts: "1789000040.000100")
    quick_reply!(root, "Hi! What can I help with?", "1789000041.000100")

    elsewhere = record!("hello", ts: "1789000042.000100")
    quick_reply!(elsewhere, "Hello! Anything I can do?", "1789000043.000100")

    current =
      record!("Can you check the deploy?",
        ts: "1789000044.000100",
        thread_ref: root.source_item_ref
      )

    %{bundle: bundle} = ConversationContext.capture(current)

    assert Enum.map(bundle["messages"], &{&1["actor_ref"] == "ryker", &1["content"]["text"]}) == [
             {false, "hi"},
             {true, "Hi! What can I help with?"}
           ]
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

  # Andrew asked "And now?" in a #test thread on 2026-09-28. Routing read the
  # thread's first message as "<@U0C1LCVNF52> check health of our infra\n
  # check health of our infra": its text, then the same words again from the
  # rich text blocks Slack sends beside a person's message.
  test "a person's Slack message enters the conversation once, as its text" do
    record_retained!("check_health")
    record_retained!("pretty_much_all_access")
    record_retained!("which_tools")
    current = record_retained!("and_now")

    %{bundle: bundle} = ConversationContext.capture(current)

    assert Enum.map(bundle["messages"], & &1["content"]["text"]) == [
             "<@U0C1LCVNF52> check health of our infra",
             "You have pretty much all possible access via emisar mcp",
             "Which tools are available? List runners and packs"
           ]

    assert bundle["current"]["content"]["text"] == "And now?"
  end

  # Tenant's VA1 alert of 2026-09-05 carries 1,033 characters in its
  # attachment. Routing read the alert that fired before its recovery as its
  # first 512, stopping at "*Alert:", with its links gone and nothing saying
  # the message went on.
  test "an earlier message reaches routing whole, or cut where it says so" do
    [firing, resolved] =
      "testdata/learning/retained-haproxy-lifecycle.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")

    record_harvested!(firing)
    current = record_harvested!(resolved)

    %{bundle: bundle} = ConversationContext.capture(current)
    [attachment] = firing["content"]["attachments"]
    whole = attachment["title"] <> "\n" <> attachment["text"]

    assert [%{"content" => %{"text" => text}}] = bundle["messages"]
    assert text == String.byte_slice(whole, 0, 1_021) <> "..."
  end

  # HCP Terraform posts its run notifications as attachments with an empty
  # text, as its "Run Planning" notice of 2026-09-27 shows. Read back from
  # Slack after retention reclaimed Ryker's copy, it reached routing as "":
  # a provider read took only the message's text.
  test "a message read back from Slack reads as the words Ryker keeps for it" do
    kept = retained_message("terraform_run_planning")
    current = record_retained!("and_now")
    reader = {Ryker.Admission.ConversationContextTest.FakeReader, [kept["envelope"]]}

    %{bundle: bundle, manifest: manifest} = ConversationContext.capture(current, reader: reader)

    assert manifest["source_read"] == "provider_paged"

    assert [%{"content" => %{"text" => text}, "retained" => false}] = bundle["messages"]
    assert text == MessageText.from(kept["content"])
    assert text =~ "Run run-QJuP3FdKmSeFzoxM"
  end

  test "a bounded provider read fills what retention already reclaimed and says so" do
    current = record!("Only survivor", ts: "1789000500.000100")

    reader =
      {Ryker.Admission.ConversationContextTest.FakeReader,
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

    reader = {Ryker.Admission.ConversationContextTest.FailingReader, :denied}
    %{bundle: bundle, manifest: manifest} = ConversationContext.capture(current, reader: reader)

    assert manifest["source_read"] == "provider_unavailable:slack_api_error"
    assert Enum.map(bundle["messages"], & &1["content"]["text"]) == ["Retained one"]
  end

  test "summaries report absent, stale, current and after-cutoff without fabricating freshness" do
    current = record!("Decide me", ts: "1789000700.000100", thread_ref: "1789000650.000100")
    routed_at = DateTime.add(current.occurred_at, 1, :second)

    assert ConversationSummaries.thread(current, routed_at)["status"] == "unavailable"
    assert ConversationSummaries.thread(current, routed_at)["reason"] == "absent"

    summary!(current, "1789000650.000100", @handover_ref, saved(current, -60))
    fresh = ConversationSummaries.thread(current, routed_at)
    assert fresh["status"] == "available"
    assert fresh["freshness"] == "current"
    assert fresh["document"]["state"]["situation"] == "Replication is stalled"

    summary!(current, "1789000650.000100", @handover_ref, saved(current, -3 * 24 * 3600))
    assert ConversationSummaries.thread(current, routed_at)["freshness"] == "stale"

    summary!(current, "1789000650.000100", @handover_ref, saved(current, 1))
    after_cutoff = ConversationSummaries.thread(current, saved(current, 2))
    assert after_cutoff["status"] == "unavailable"
    assert after_cutoff["reason"] == "after_cutoff"
    assert is_nil(after_cutoff["document"])
  end

  # On 2026-09-28 Andrew's "And now?" was routed as if its Slack thread had no
  # summary, though Ryker had saved one there thirteen hours before. The cutoff
  # compared the summary's newest input, which the Work handover records as an
  # "admit_input:<digest>" key, with the message's Slack timestamp as text, and
  # letters sort after digits: every Slack thread summary looked newer than
  # every message. From 2026-09-11 no Slack routing decision got its thread
  # summary (all seven in production that had one refused it), and the
  # Timeline said each was "created after this request". Production's row and
  # message.
  test "a thread summary saved before a reply reaches that reply's routing" do
    current = record!("And now?", ts: "1790569786.896249", thread_ref: "1790504146.985239")

    summary!(current, "1790504146.985239", @handover_ref, ~U[2026-09-27 15:16:01.430657Z])

    selected = ConversationSummaries.thread(current, ~U[2026-09-28 04:29:47.774293Z])

    assert selected["status"] == "available",
           "routing left the thread summary out as #{selected["reason"]}"

    assert selected["covered_through"] == "2026-09-27T15:16:01.430657Z"
    assert selected["freshness"] == "current"
  end

  # The same comparison never refused a Conversation Lab summary: its
  # "admit_input:" key sorts before every "control-plane-item:" message, so a
  # summary saved while a Lab message waited to be routed reached that routing
  # and could describe what came after it. Production's Lab message and key;
  # the later save is the case the cutoff exists for.
  test "a summary saved after a message arrived stays out of that message's routing" do
    current =
      lab_record!(
        "What is the temporary validation codename? Answer with only the codename.",
        "24e68e99-5b48-46f7-90a2-d4d6016f2b67",
        ~U[2026-09-20 22:19:18.407470Z]
      )

    summary!(
      current,
      current.destination_thread_ref,
      "admit_input:73bb706189c91db0d7fcfecbb77ca39a5cf649096083ec365d81d82b6b4b8979",
      saved(current, 60)
    )

    selected = ConversationSummaries.thread(current, saved(current, 120))

    assert selected["status"] == "unavailable",
           "a summary saved a minute after the message reached its routing"

    assert selected["reason"] == "after_cutoff"
    assert is_nil(selected["document"])
  end

  # Routing also looked up a summary of the whole channel, which nothing ever
  # saves: summaries are Work handovers kept per thread, and every Slack
  # message has one. The slot was empty on every request since 2026-09-11 and
  # the Timeline showed "Channel summary: None saved" on each; it is gone.
  test "the captured bundle carries the thread summary, the one summary Ryker saves" do
    current = record!("Decide me", ts: "1789000900.000100", thread_ref: "1789000850.000100")
    summary!(current, "1789000850.000100", @handover_ref, saved(current, -60))

    captured =
      current
      |> ConversationContext.capture()
      |> ConversationContext.with_thread_summary(
        ConversationSummaries.thread(current, saved(current, 1))
      )

    assert captured.bundle["thread_summary"]["freshness"] == "current"
    assert captured.manifest["thread_summary"]["status"] == "available"
    refute Map.has_key?(captured.manifest["thread_summary"], "document")
    refute Map.has_key?(captured.bundle, "channel_summary")
    refute Map.has_key?(captured.manifest, "channel_summary")
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

  # A Conversation Lab message as the Lab records one: the conversation is its
  # own thread and the item is named after the message.
  defp lab_record!(text, id, occurred_at) do
    conversation_ref = "control-plane:lab:72eff4a2-1020-4168-b337-be0450c0f467"

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "local-operator"},
        content: %{"text" => text},
        destination: %{
          transport: "control_plane",
          conversation_ref: conversation_ref,
          thread_ref: conversation_ref
        },
        event_kind: :message,
        event_ref: "control-plane-event:#{id}",
        native_input_id: "control-plane-message:#{id}",
        occurred_at: occurred_at,
        occurred_at_source: :ingress,
        revision: 1,
        source: %{kind: "control_plane", ref: "local"},
        source_capabilities: %{},
        source_item_ref: "control-plane-item:#{id}"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  # When a summary was saved, relative to the message being decided.
  defp saved(entry, seconds), do: DateTime.add(entry.occurred_at, seconds, :second)

  # A message Ryker recorded in #test on 2026-09-27, with its original sender,
  # time, thread and content, in this module's own channel.
  defp record_retained!(name) do
    message = retained_message(name)

    record_content!(
      message["content"],
      message["actor"],
      message["ts"],
      message["thread_ts"]
    )
  end

  defp retained_message(name) do
    "testdata/slack/retained-messages-2026-09-27.json"
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["messages", name])
  end

  # An input harvested from Tenant, with its original sender, time and content.
  defp record_harvested!(input) do
    record_content!(
      input["content"],
      %{"kind" => input["actor_kind"], "ref" => input["actor_ref"]},
      input["source_item_ref"],
      input["destination_thread_ref"]
    )
  end

  defp record_content!(content, actor, ts, thread_ts) do
    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: String.to_existing_atom(actor["kind"]), ref: actor["ref"]},
        channel_ref: @channel,
        content: content,
        event_kind: :message,
        event_ref: "Ev-#{ts}",
        message_ref: ts,
        occurred_at: slack_time(ts),
        revision: 1,
        thread_ref: if(thread_ts != ts, do: thread_ts),
        workspace_ref: @workspace
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  # A reply Ryker delivered into this Slack conversation. Only the turn's
  # delivered receipt matters to context capture.
  defp reply!(text, options) do
    ts = Keyword.fetch!(options, :ts)
    thread_ref = Keyword.get(options, :thread_ref)
    conversation_ref = "slack:#{@workspace}:#{@channel}"
    episode_id = Ecto.UUID.generate()

    {:ok, _transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: conversation_ref,
            thread_ref: thread_ref || ts,
            transport: "slack"
          },
          episode_id: episode_id,
          episode_key: "reply-context:#{episode_id}",
          native_input_id: "reply-context:#{episode_id}",
          occurred_at: slack_time(ts),
          turn_ref: "turn:reply-context:#{episode_id}"
        })
      )

    {:ok, _session} = Custody.pin_episode(episode_id, "reply-context", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("reply-context:#{episode_id}", 60, :work)

    Repo.update_all(from(turn in Turn, where: turn.id == ^claim.turn.id),
      set: [
        delivery_document: %{"delivery" => "reply", "message" => text},
        external_receipt: %{
          "conversation_ref" => conversation_ref,
          "delivery_ref" => "delivery:#{episode_id}",
          "message_ref" => ts,
          "thread_ref" => thread_ref,
          "transport" => "slack"
        },
        delivered_at: slack_time(ts)
      ]
    )
  end

  # A quick reply routing delivered in the thread of the message it answered.
  defp quick_reply!(entry, text, ts) do
    id = Ecto.UUID.generate()
    document = %{"message" => text}

    receipt = %{
      "conversation_ref" => entry.destination_conversation_ref,
      "delivery_ref" => "ingress-message:#{entry.id}:1",
      "message_ref" => ts,
      "thread_ref" => entry.destination_thread_ref,
      "transport" => "slack"
    }

    Repo.insert!(%RoutingResponse{
      id: id,
      input_id: entry.id,
      position: 1,
      kind: :message,
      decision_ref: "decision:#{id}",
      delivery_ref: "ingress-message:#{entry.id}:1",
      transport: "slack",
      conversation_ref: entry.destination_conversation_ref,
      thread_ref: entry.destination_thread_ref,
      source_item_ref: entry.source_item_ref,
      document: document,
      document_fingerprint: CanonicalJSON.digest(document),
      status: :delivered,
      attempt_count: 1,
      external_receipt: receipt,
      external_receipt_fingerprint: CanonicalJSON.digest(receipt),
      delivered_at: slack_time(ts)
    })
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
      workspace_ref:
        Scope.workspace_ref(
          entry.destination_transport,
          entry.destination_conversation_ref
        ),
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
