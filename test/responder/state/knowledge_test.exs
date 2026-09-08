defmodule Responder.State.KnowledgeTest do
  use Responder.DataCase, async: false
  @moduletag isolation: "REPEATABLE READ"
  import Ecto.Query
  alias Responder.{Admission, Repo}
  alias Responder.Admission.{Context, Decision, Prompt}
  alias Responder.ControlPlane.{ConversationMemory, HTML, Projection}
  alias Responder.Episodes.Episode
  alias Responder.Fixtures.DatabaseClock
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.RecallText
  alias Responder.Retention.Data
  alias Responder.Slack.{ChannelMembership, Input}

  alias Responder.State.{
    Continuity,
    ConversationKnowledge,
    ConversationObservation,
    Knowledge,
    KnowledgeRetention,
    KnowledgeRevision,
    KnowledgeSnapshot,
    KnowledgeSource,
    LearningSources,
    MemorySearchPage,
    Observations
  }

  # The replay made 931 notes from 1,034 messages. These two actual observations
  # (bec3eb2b... and 62a54f69...) described one alert as two unrelated memories.
  # The knowledge proposal below is a host-contract test, not a claimed model recording.
  @firing %{
    "summary" =>
      "Grafana bot B0910HETYAH reported a historical VA1 warning starting 2026-09-05 at 17:18:50 UTC: the kernel OOM-killed website/haproxy-edge process haproxy on nomad-hvn01. CONSTRAINT_MEMCG indicates the workload cgroup reached its limit; it does not establish host RAM exhaustion. [Alert](https://grafana.tail7c930.ts.net/alerting/grafana/va1-host-oom/view?orgId=1).",
    "topics" => [
      "VA1",
      "website",
      "haproxy-edge",
      "haproxy",
      "nomad-hvn01",
      "OOM",
      "CONSTRAINT_MEMCG"
    ]
  }
  @resolved %{
    "summary" =>
      "Grafana bot B0910HETYAH reported the VA1 OOM warning for website/haproxy-edge (haproxy) on nomad-hvn01 resolved at 2026-09-05 17:28:50 UTC, after starting at 17:18:50 UTC. This supersedes the firing alert's status; no remediation or service recovery details were supplied. [Alert](https://grafana.tail7c930.ts.net/alerting/grafana/va1-host-oom/view?orgId=1).",
    "topics" => [
      "VA1",
      "website",
      "haproxy-edge",
      "haproxy",
      "nomad-hvn01",
      "OOM",
      "alert resolution"
    ]
  }
  @now ~U[2026-09-05 17:19:24.248029Z]

  test "saved topic versions are immediately searchable when the database clock trails the host" do
    # Full-gate confirmation searches exposed mixed host/database timestamps.
    # Topic creation and later revisions must obey that same cursor cutoff.
    database_time = DatabaseClock.behind_host!()
    first = input!(1, @firing)
    learn!(first, @firing)
    page = MemorySearchPage.first("haproxy", "current_channel")

    assert {:ok, {:ok, before, _}} =
             Repo.transaction(fn -> Knowledge.search_page(first, "blitz-infra", page) end)

    assert before["version"] == 1

    second = input!(2, @resolved)
    learn!(second, @resolved, before)

    assert {:ok, {:ok, after_update, _}} =
             Repo.transaction(fn ->
               Knowledge.search_page(
                 second,
                 "blitz-infra",
                 MemorySearchPage.first("haproxy", "current_channel")
               )
             end)

    assert after_update["version"] == 2
    assert after_update["latest_source_at"] == DateTime.to_iso8601(second.occurred_at)
    assert Repo.one!(ConversationKnowledge).inserted_at == database_time
    assert Repo.one!(ConversationKnowledge).updated_at == database_time
    assert Enum.all?(Repo.all(KnowledgeRevision), &(&1.inserted_at == database_time))
  end

  test "related matching does not disclose unrelated recent topics to fill empty slots" do
    # In the replay a new topic inherited 114 roots. Filling the candidate
    # budget with unrelated recent prose spreads those roots into every update.
    first = input!(1, @firing)
    learn!(first, @firing)

    assert Knowledge.context(first, "blitz-infra", {:related, "quasar billing subscription"}) ==
             []
  end

  test "late supporting input is incorporated without moving the latest source time backward" do
    # Source event time is not ingestion time. A late message or edit can add
    # useful evidence to an already newer topic; silently returning :ok loses it.
    latest = input!(2, @resolved)
    learn!(latest, @resolved)
    [before] = Knowledge.context(latest, "blitz-infra")
    older = input!(1, @resolved)
    learn!(older, @resolved, before)

    [after_update] = Knowledge.context(latest, "blitz-infra")
    assert after_update["version"] == before["version"] + 1
    assert after_update["source_count"] == 2
    assert after_update["latest_source_at"] == before["latest_source_at"]
  end

  test "silent updates maintain one topic with both sources and immutable revisions" do
    first = input!(1, @firing, mode: :shadow)
    learn!(first, @firing)
    [before] = Knowledge.context(first, "blitz-infra")
    assert before["version"] == 1
    assert before["source_count"] == 1

    second = input!(2, @resolved)
    context = context!(second)
    assert context.knowledge == [before]
    assert Prompt.build(context)["context"]["conversation_knowledge"] == [before]

    assert {:ok, restored} =
             Context.restore(Context.snapshot(context), context.input, second, %{})

    assert restored.knowledge == [before]
    learn!(second, @resolved, before)

    assert [after_update] = Knowledge.context(second, "blitz-infra")
    assert after_update["source_ref"] == before["source_ref"]
    assert after_update["version"] == 2
    assert after_update["source_count"] == 2
    assert after_update["summary"] == @resolved["summary"]
    assert [old, new] = Knowledge.history(after_update["source_ref"])
    assert old.state["summary"] == @firing["summary"]
    assert new.state["summary"] == @resolved["summary"]
    assert old.source_input_id == first.id
    assert new.source_input_id == second.id
    assert Repo.aggregate(Episode, :count) == 0

    destination =
      struct!(
        Episode,
        Map.take(
          Map.from_struct(second),
          [:destination_transport, :destination_conversation_ref, :destination_thread_ref]
        )
      )

    assert Continuity.model_context(destination, "blitz-infra", [
             RecallText.from(second.content)
           ])["knowledge"] == [after_update]

    found = Continuity.search_context(destination, "blitz-infra", "haproxy", "workspace", 10)
    assert Enum.filter(found, &(&1["kind"] == "conversation_knowledge")) == [after_update]
    # Explicit historical search also keeps both originals reachable after
    # consolidation; automatic briefing still avoids repeating covered excerpts.
    assert MapSet.new(
             for item <- found,
                 item["kind"] == "conversation_observation",
                 do: item["source_input_id"]
           ) ==
             MapSet.new([first.id, second.id])
  end

  test "a stale new-topic proposal cannot overwrite an intervening update" do
    first = input!(1, @firing)
    second = input!(2, @resolved)
    stale = context!(second)
    learn!(first, @firing)

    assert {:error, {:admission_rejected, :context_stale}} =
             Responder.Fixtures.Knowledge.commit_topic(
               stale,
               decision!(@resolved),
               "stale-create"
             )

    assert {:ok, %{status: :pending}} = Inbox.fetch(Inbox.ref(second))
    assert [item] = Knowledge.context(first, "blitz-infra")
    assert item["version"] == 1
  end

  test "updates must name an exact offered version and cannot invent target identities" do
    first = input!(1, @firing)
    learn!(first, @firing)
    [item] = Knowledge.context(first, "blitz-infra")
    second = input!(2, @resolved)
    stale = context!(second)
    third = input!(3, @resolved)
    learn!(third, @resolved, item)

    assert {:error, {:admission_rejected, :context_stale}} =
             Responder.Fixtures.Knowledge.commit_topic(
               stale,
               decision!(@resolved, item),
               "stale-update"
             )

    forged = %{item | "source_ref" => "knowledge:" <> Ecto.UUID.generate()}

    assert {:error, {:admission_rejected, :context_stale}} =
             Responder.Fixtures.Knowledge.commit_topic(
               context!(second),
               decision!(@resolved, forged),
               "forged"
             )
  end

  test "a late alert can support the current understanding without erasing its resolution" do
    latest = input!(2, @resolved)
    learn!(latest, @resolved)
    [item] = Knowledge.context(latest, "blitz-infra")
    older = input!(1, @firing)

    # The host must not infer the proposed summary's meaning from source time.
    # The learning judgment sees the current resolution and incorporates the
    # historical firing message. Semantic regression is a model-eval concern.
    learn!(older, @resolved, item)
    assert [current] = Knowledge.context(latest, "blitz-infra")
    assert current["summary"] == item["summary"]
    assert current["version"] == item["version"] + 1
    assert current["source_count"] == 2
    assert current["latest_source_at"] == item["latest_source_at"]
    assert Repo.aggregate(ConversationObservation, :count) == 2
  end

  test "edits and deletions invalidate derived facts even if they were not the latest source" do
    first = input!(1, @firing)
    learn!(first, @firing)
    [item] = Knowledge.context(first, "blitz-infra")
    second = input!(2, @resolved)
    learn!(second, @resolved, item)
    [current] = Knowledge.context(second, "blitz-infra")

    edited = input!(1, @resolved, revision: 2, kind: :edit)
    learn!(edited, @resolved, nil, knowledge: false)
    assert Knowledge.context(second, "blitz-infra") == []

    assert {:error, {:admission_rejected, :context_stale}} =
             Knowledge.reauthorize(second, "blitz-infra", [current])

    assert length(Knowledge.history(item["source_ref"])) == 2
  end

  test "expired or removed supporting sources cannot be recalled through a newer aggregate" do
    previous = Application.get_env(:responder, :retention)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:responder, :retention, previous),
        else: Application.delete_env(:responder, :retention)
    end)

    Application.put_env(:responder, :retention, %{conversation_memory_seconds: 3600})
    first = input!(1, @firing)
    learn!(first, @firing)
    [item] = Knowledge.context(first, "blitz-infra")
    assert is_binary(item["expires_at"])

    Repo.update_all(ConversationObservation,
      set: [updated_at: DateTime.add(DateTime.utc_now(), -3601)]
    )

    assert Knowledge.context(first, "blitz-infra") == []
    Application.delete_env(:responder, :retention)
    assert [_] = Knowledge.context(first, "blitz-infra")
    Repo.delete_all(ConversationObservation)
    assert Knowledge.context(first, "blitz-infra") == []
  end

  test "cross-channel knowledge recall rechecks membership without merging ownership" do
    joined!("C1")
    joined!("C2")
    first = input!(1, @firing)
    learn!(first, @firing)
    target = input!(2, @resolved, channel: "C2")
    assert [item] = Knowledge.context(target, "blitz-infra")

    assert {:error, {:admission_rejected, :context_stale}} =
             Responder.Fixtures.Knowledge.commit_topic(
               context!(target),
               decision!(@resolved, item),
               "cross-channel-write"
             )

    Repo.update_all(from(m in ChannelMembership, where: m.channel_ref == "C1"),
      set: [private: true]
    )

    assert Knowledge.context(target, "blitz-infra") == []

    assert {:error, {:admission_rejected, :context_stale}} =
             Knowledge.reauthorize(target, "blitz-infra", [item])

    assert Knowledge.context(
             %{target | destination_conversation_ref: "slack:OTHER:C2"},
             "blitz-infra"
           ) == []
  end

  for kind <- [:knowledge, :observation] do
    test "copying foreign knowledge into #{kind} never sheds its source-channel access fence" do
      joined!("C1")
      joined!("C2")
      first = input!(1, @firing)
      learn!(first, @firing)
      copy = input!(2, @resolved, channel: "C2")
      assert [_] = context!(copy).knowledge
      # A structurally valid result can copy supplied prose despite a prompt prohibition.
      learn!(copy, @firing, nil, knowledge: unquote(kind) == :knowledge)

      Repo.update_all(from(m in ChannelMembership, where: m.channel_ref == "C1"),
        set: [private: true]
      )

      assert Knowledge.context(copy, "blitz-infra") == []

      assert [%{"source_input_id" => id, "summary" => text}] =
               Observations.context(copy, "blitz-infra")

      assert id == copy.id
      assert text == copy.content["text"]
    end
  end

  test "copying another topic in the same channel preserves its exact source revision" do
    first = input!(1, @firing)
    learn!(first, @firing)
    copy = input!(2, @resolved)
    decision = decision!(@firing)
    decision = %{decision | knowledge: Map.put(decision.knowledge, "topic_key", "copied-topic")}

    assert {:ok, _} =
             Responder.Fixtures.Knowledge.commit_topic(
               context!(copy),
               decision,
               "copied-topic-result"
             )

    _edit = input!(1, @resolved, revision: 2, kind: :delete)
    assert Knowledge.context(copy, "blitz-infra") == []
    # The copied derived topic is revoked, but this separate original message
    # remains an eligible excerpt: it did not inherit the older model prose.
    assert [%{"source_input_id" => source_id, "summary" => summary}] =
             Observations.context(copy, "blitz-infra")

    assert source_id == copy.id
    assert summary == copy.content["text"]
  end

  test "learning from an episode input preview keeps that input's withdrawal fence" do
    first = input!(1, @firing)

    {:ok, decision} =
      Decision.parse(%{
        "action" => "start_episode",
        "episode_ref" => nil,
        "reaction" => nil,
        "relation" => "unrelated",
        "reason" => "Investigate the reported alert.",
        "work_class" => "standard"
      })

    assert {:ok, _} = Admission.commit(context!(first), decision, "preview-source-result")
    second = input!(2, @resolved)
    context = context!(second)
    assert length(context.candidates) == 1
    assert [%{"source_input_id" => source_id}] = context.observations
    assert source_id == first.id
    assert context.knowledge == []
    assert Enum.any?(context.source_dependencies, &(&1["source_input_id"] == first.id))
    learn!(second, @firing)
    _deleted = input!(1, @resolved, revision: 2, kind: :delete)
    assert Knowledge.context(second, "blitz-infra") == []
    assert [%{"source_input_id" => id}] = Observations.context(second, "blitz-infra")
    assert id == second.id
  end

  test "a fresh source cannot silently reset a known unavailable topic" do
    # Resetting an invalid head hid lost history behind a successful write. A
    # new input is not permission to discard the earlier topic's dependencies.
    first = input!(1, @firing)
    learn!(first, @firing)
    [before] = Knowledge.context(first, "blitz-infra")
    edited = input!(1, @resolved, revision: 2, kind: :delete)
    learn!(edited, @resolved, nil, knowledge: false)
    assert Knowledge.context(first, "blitz-infra") == []

    fresh = input!(3, @resolved)

    assert {:error, :knowledge_target_unavailable} =
             Responder.Fixtures.Knowledge.commit_topic(
               context!(fresh),
               decision!(@resolved),
               "unavailable-topic"
             )

    assert Knowledge.context(fresh, "blitz-infra") == []
    assert length(Knowledge.history(before["source_ref"])) == 1
  end

  for boundary <- [:text, :attachments, :batch] do
    test "#{boundary} recalls a relevant older topic ahead of unrelated recent knowledge" do
      first = input!(1, @resolved)
      learn!(first, @resolved)

      for n <- 2..12 do
        note = %{
          "summary" => "An unrelated project discussion #{n}.",
          "topics" => ["Other project #{n}"]
        }

        entry = input!(n, note)
        decision = decision!(note)
        decision = %{decision | knowledge: Map.put(decision.knowledge, "topic_key", "other-#{n}")}

        assert {:ok, _} =
                 Responder.Fixtures.Knowledge.commit_topic(
                   context!(entry),
                   decision,
                   "unrelated:#{n}"
                 )
      end

      items =
        case unquote(boundary) do
          :text ->
            Knowledge.context(
              first,
              "blitz-infra",
              {:related, "What happened to HAProxy OOM?"},
              8
            )

          :batch ->
            Knowledge.context(
              first,
              "blitz-infra",
              {:related,
               [
                 String.duplicate("An unrelated project discussion. ", 200),
                 "What happened to HAProxy OOM?"
               ]},
              8
            )

          :attachments ->
            [raw | _] =
              File.read!("testdata/learning/retained-haproxy-lifecycle.json")
              |> Jason.decode!()
              |> Map.fetch!("inputs")

            entry = input!(20, @resolved, content: raw["content"])
            assert entry.content["text"] == ""
            context!(entry).knowledge
        end

      assert Enum.any?(items, &(&1["topic_key"] == "website-haproxy-oom"))
      if unquote(boundary) == :text, do: assert(hd(items)["topic_key"] == "website-haproxy-oom")
    end
  end

  test "a saturated topic advances from newly supplied sources without blocking the inbox" do
    # A long-lived alert topic must not trap input 129 in an endless context-stale retry.
    first = input!(1, @firing)
    learn!(first, @firing)

    for n <- 2..128 do
      entry = input!(n, @resolved)
      [current] = Knowledge.context(entry, "blitz-infra")
      learn!(entry, @resolved, current)
    end

    next = input!(129, @resolved)

    stale_recall_statistics!()

    handler = "saturated-recall:" <> Ecto.UUID.generate()
    reference = make_ref()
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        [:responder, :repo, :query],
        &__MODULE__.record_recall_query/4,
        {self(), reference}
      )

    frozen =
      try do
        context!(next)
      after
        :telemetry.detach(handler)
      end

    assert_receive {^reference, query, params}

    %{rows: [[[explanation]]]} =
      Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> query, params, log: false)

    # A full gate timed out after 60 seconds: the actual plan revalidated this
    # one topic 128 times (16,384 inherited-root visits) before excluding notes.
    # The current-generation fence also reads the head for a compact reference.
    # Allow a small constant number of head scans, never one per inherited root.
    # Assert bounded work, not an exact plan shape or elapsed-time budget.
    # A later full gate chose every historical revision before matching the one
    # descriptor: 8,256 membership visits for 128 roots, plus 128 head probes.
    # Eight visits per root allow the separate validity, disclosure and exclusion
    # scans, but not triangular expansion of every earlier revision's roots.
    assert membership_scan_work(explanation["Plan"]) <= 128 * 8
    assert knowledge_scan_loops(explanation["Plan"]) <= 4
    assert [current] = frozen.knowledge
    assert {:ok, restored} = Context.restore(Context.snapshot(frozen), frozen.input, next, %{})

    assert {:ok, %{entry: %{status: :decided}}} =
             Responder.Fixtures.Knowledge.commit_topic(
               restored,
               decision!(@resolved, current),
               "at-capacity"
             )

    assert [%{"version" => 129, "source_count" => 129}] = Knowledge.context(next, "blitz-infra")
    assert Repo.aggregate(KnowledgeRevision, :count) == 129
    assert Enum.all?(Repo.all(KnowledgeRevision), &(length(&1.source_dependencies) == 1))
    assert Repo.aggregate(KnowledgeSource, :count) == 129
  end

  test "retry topic keys do not widen the authorized update conversation" do
    joined!("C1")
    joined!("C2")
    first = input!(1, @firing, channel: "C1")
    second = input!(2, @firing, channel: "C2")
    learn!(first, @firing)
    learn!(second, @firing)
    assert length(Knowledge.context(first, "blitz-infra")) == 2

    assert [item] =
             Knowledge.context(first, "blitz-infra", {:topic_keys, ["website-haproxy-oom"]}, 16)

    assert item["conversation_ref"] == first.destination_conversation_ref
    assert item["can_update"]
  end

  test "an inherited-only withdrawal does not authorize a silent new generation" do
    joined!("C1")
    joined!("C2")
    first = input!(1, @firing)
    learn!(first, @firing)
    copy = input!(2, @resolved, channel: "C2")
    learn!(copy, @firing)

    Repo.update_all(from(m in ChannelMembership, where: m.channel_ref == "C1"),
      set: [private: true]
    )

    fresh = input!(3, @resolved, channel: "C2")
    assert context!(fresh).knowledge == []

    assert {:error, :knowledge_target_unavailable} =
             Responder.Fixtures.Knowledge.commit_topic(
               context!(fresh),
               decision!(@resolved),
               "unavailable-inherited-topic"
             )

    assert Knowledge.context(fresh, "blitz-infra") == []
  end

  test "an omitted foreign topic does not reserve the same topic key in this channel" do
    joined!("C1")
    joined!("C2")
    first = input!(1, @firing)
    learn!(first, @firing)
    second = input!(2, @resolved, channel: "C2")
    context = context!(second)
    [foreign] = context.knowledge

    omission =
      foreign
      |> Map.take(~w(source_ref version topic_key conversation_ref repository_ref))
      |> Map.put("reason", "source_capacity")

    # Same host-owned omission produced by the 129-source boundary above, but foreign-owned.
    context = %{
      context
      | knowledge: [],
        observations: [],
        knowledge_omissions: [omission],
        source_dependencies: LearningSources.for_entry(second)
    }

    assert {:ok, restored} =
             Context.restore(Context.snapshot(context), context.input, second, %{})

    refute Map.has_key?(Context.for_model(restored), "knowledge_omissions")

    assert {:ok, %{entry: %{status: :decided}}} =
             Responder.Fixtures.Knowledge.commit_topic(
               restored,
               decision!(@resolved),
               "foreign-capacity"
             )

    assert Enum.count(Knowledge.context(second, "blitz-infra"), & &1["can_update"]) == 1
  end

  for kind <- [:knowledge, :observation] do
    test "#{kind} recall revokes inherited prose but preserves independent original excerpts" do
      joined!("C1")
      joined!("C2")
      first = input!(1, @firing)
      learn!(first, @firing)

      for n <- 2..5 do
        copy = input!(n, @firing, channel: "C2")
        decision = decision!(@firing)

        knowledge =
          if unquote(kind) == :knowledge,
            do: Map.put(decision.knowledge, "topic_key", "copied-#{n}")

        assert {:ok, _} =
                 Responder.Fixtures.Knowledge.commit_topic(
                   context!(copy),
                   %{decision | knowledge: knowledge},
                   "copy:#{n}"
                 )
      end

      # A recorded source-only fact predating those copies remains valid.
      old = input!(0, @resolved, channel: "C2")

      {:ok, _} =
        Repo.transaction(fn ->
          Observations.record_excerpt_in_transaction(%{old | status: :decided})

          if unquote(kind) == :knowledge do
            proposal = decision!(@resolved).knowledge |> Map.put("topic_key", "independent")
            Responder.Fixtures.Knowledge.record_topic(%{old | status: :decided}, proposal, [])
          end
        end)

      Repo.update_all(from(m in ChannelMembership, where: m.channel_ref == "C1"),
        set: [private: true]
      )

      module = if unquote(kind) == :knowledge, do: Knowledge, else: Observations
      assert [%{"summary" => summary}] = module.context(old, "blitz-infra", "", 1)
      # Topics inherited C1's disclosure and must yield to the older valid fact.
      # The C2 source excerpts are independent original messages, not copies of
      # the model's C1 knowledge, so making C1 private must not revoke them.
      assert summary ==
               if(unquote(kind) == :knowledge, do: @resolved["summary"], else: @firing["summary"])
    end
  end

  test "Memory shows one current topic, source count, expiry and readable revision history" do
    first = input!(1, @firing)
    learn!(first, @firing)
    [before] = Knowledge.context(first, "blitz-infra")
    second = input!(2, @resolved)
    learn!(second, @resolved, before)
    view = ConversationMemory.project(%{})
    assert view.kind == "knowledge"
    assert view.counts.knowledge == 1
    assert [%{source_count: 2, version: 2, available: true} = item] = view.items
    # Inspection removes URL queries, but must preserve the readable linked summary.
    assert item.text == String.replace(@resolved["summary"], "?orgId=1", "")

    html =
      HTML.memory(Projection.memory(%{"kind" => "knowledge", "item" => item.id}), "test-secret")
      |> IO.iodata_to_binary()

    assert html =~ "Current knowledge"
    assert html =~ "Sources: 2 direct · 0 inherited"
    assert html =~ "Update history"
    assert html =~ @firing["summary"] |> String.split(" [Alert]") |> hd()
    refute html =~ "Source result ref"
    Repo.delete_all(ConversationObservation)
    assert [%{available: false}] = ConversationMemory.project(%{"kind" => "knowledge"}).items
  end

  test "Memory availability includes inherited sources and their current visibility" do
    # The topic's own source can remain valid while copied context has been withdrawn.
    joined!("C1")
    joined!("C2")
    first = input!(1, @firing)
    learn!(first, @firing)
    copy = input!(2, @resolved, channel: "C2")
    learn!(copy, @resolved)

    Repo.update_all(from(m in ChannelMembership, where: m.channel_ref == "C1"),
      set: [private: true]
    )

    view = ConversationMemory.project(%{"kind" => "knowledge"})

    copied =
      Enum.find(
        view.items,
        &(&1.id ==
            Repo.get_by!(ConversationKnowledge,
              conversation_ref: copy.destination_conversation_ref
            ).id)
      )

    assert copied.available == false
  end

  test "all memory revisions remain reachable after the latest fifty" do
    # An update count must not promise history that the operator cannot open.
    first = input!(1, @firing)
    learn!(first, @firing)

    for n <- 2..51 do
      entry = input!(n, @resolved)
      [current] = Knowledge.context(entry, "blitz-infra")
      learn!(entry, @resolved, current)
    end

    [item] = ConversationMemory.project(%{"kind" => "knowledge"}).items
    params = %{"kind" => "knowledge", "item" => item.id, "history_page" => "2"}
    view = ConversationMemory.project(params)
    assert Enum.map(view.history, & &1.version) == [1]
    html = HTML.memory(Projection.memory(params), "test-secret") |> IO.iodata_to_binary()
    assert html =~ "Newer updates"
    assert html =~ "Page 2 of 2"
  end

  test "expired memory history explains the missing text without erasing its revision" do
    first = input!(1, @firing)
    learn!(first, @firing)
    [item] = ConversationMemory.project(%{"kind" => "knowledge"}).items
    Repo.update_all(ConversationKnowledge, set: [state: %{"retention" => "pruned"}])
    Repo.update_all(KnowledgeRevision, set: [state: %{"retention" => "pruned"}])
    view = ConversationMemory.project(%{"kind" => "knowledge", "item" => item.id})

    assert [
             %{
               title: "Expired knowledge",
               text: "Saved text expired under the conversation memory retention policy."
             }
           ] = view.items

    assert [
             %{
               version: 1,
               text: "Saved text expired under the conversation memory retention policy."
             }
           ] = view.history
  end

  test "received edits revoke knowledge before classification and old results cannot revive it" do
    first = input!(1, @firing)
    learn!(first, @firing)
    edited = input!(1, @resolved, revision: 2, kind: :edit)
    assert edited.status == :pending
    assert Knowledge.context(first, "blitz-infra") == []
    {:ok, decided} = Inbox.fetch(Inbox.ref(first))

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Observations.record_excerpt_in_transaction(decided)
             end)

    assert Knowledge.context(first, "blitz-infra") == []

    assert {:error, :knowledge_target_unavailable} =
             Responder.Fixtures.Knowledge.commit_topic(
               context!(edited),
               decision!(@resolved),
               "edited-unavailable-topic"
             )

    assert Knowledge.context(edited, "blitz-infra") == []
  end

  test "a newer source received before the first classifier prevents resurrection" do
    first = input!(1, @firing)
    _deleted = input!(1, @resolved, revision: 2, kind: :delete)

    assert {:error, {:admission_rejected, :context_stale}} =
             Responder.Fixtures.Knowledge.commit_topic(
               context!(first),
               decision!(@firing),
               "stale-first-result"
             )

    assert Observations.context(first, "blitz-infra") == []
    assert Knowledge.context(first, "blitz-infra") == []
    assert [%{revision: 2, note: nil}] = Repo.all(ConversationObservation)
  end

  test "memory expiry removes every copied payload without losing revision fences or episode history" do
    # A source's expiry must cover aggregate and revision copies, not merely hide recall.
    first = input!(1, @firing)
    learn!(first, @firing)
    [item] = Knowledge.context(first, "blitz-infra")
    old = DateTime.add(DateTime.utc_now(), -3601)
    Repo.update_all(ConversationObservation, set: [updated_at: old])
    Repo.update_all(KnowledgeSource, set: [retained_at: old])

    settings = %{
      operational_data_seconds: 3600,
      closed_work_seconds: 3600,
      episode_history_seconds: 3600,
      audit_data_seconds: 3600,
      conversation_memory_seconds: 3600
    }

    assert {:ok, _} = Data.prune(settings)
    assert Knowledge.context(first, "blitz-infra") == []
    assert [%{state: %{"retention" => "pruned"}}] = Knowledge.history(item["source_ref"])

    assert [%{state: %{"retention" => "pruned"}}] =
             Repo.all(ConversationKnowledge)

    assert [%{source_note: nil}] = Repo.all(KnowledgeSource)
    assert [%{note: nil, revision: 1, updated_at: ^old}] = Repo.all(ConversationObservation)
    {:ok, decided} = Inbox.fetch(Inbox.ref(first))

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Observations.record_excerpt_in_transaction(decided)
             end)

    assert Observations.context(first, "blitz-infra") == []
    assert {:ok, _} = Inbox.fetch(Inbox.ref(first))
  end

  test "frozen Work knowledge survives a newer source but never a withdrawn dependency" do
    first = input!(1, @firing)
    learn!(first, @firing)
    [frozen] = Knowledge.context(first, "blitz-infra")
    second = input!(2, @resolved)
    learn!(second, @resolved, frozen)
    assert :ok = KnowledgeSnapshot.reauthorize(first, "blitz-infra", [frozen])
    _edit = input!(1, @resolved, revision: 2, kind: :delete)

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.reauthorize(first, "blitz-infra", [frozen])
  end

  test "copying into a fresh topic cannot retain expired source prose or refresh its displayed expiry" do
    # Replay must not turn an old message into immortal copies by summarizing it again.
    first = input!(1, @firing)
    learn!(first, @firing)
    old = DateTime.add(DateTime.utc_now(), -1800)
    [receipt] = LearningSources.for_entry(first)
    dependencies = [Map.put(receipt, "retained_at", DateTime.to_iso8601(old))]

    Repo.update_all(ConversationObservation,
      set: [updated_at: old, source_dependencies: dependencies]
    )

    Repo.update_all(ConversationKnowledge, set: [source_dependencies: dependencies])
    Repo.update_all(KnowledgeRevision, set: [source_dependencies: dependencies])
    Repo.update_all(KnowledgeSource, set: [retained_at: old])
    copy = input!(2, @resolved)
    decision = decision!(@firing)
    decision = %{decision | knowledge: Map.put(decision.knowledge, "topic_key", "copied-topic")}

    assert {:ok, _} =
             Responder.Fixtures.Knowledge.commit_topic(
               context!(copy),
               decision,
               "copied-topic-result"
             )

    previous = Application.get_env(:responder, :retention)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:responder, :retention, previous),
        else: Application.delete_env(:responder, :retention)
    end)

    Application.put_env(:responder, :retention, %{conversation_memory_seconds: 3600})
    expected_expiry = old |> DateTime.add(3600) |> DateTime.to_iso8601()

    copied =
      Enum.find(Knowledge.context(copy, "blitz-infra"), &(&1["topic_key"] == "copied-topic"))

    assert copied["expires_at"] == expected_expiry

    assert Enum.all?(
             ConversationMemory.project(%{"kind" => "knowledge"}).items,
             &(DateTime.to_iso8601(&1.expires_at) == expected_expiry)
           )

    # A shorter operator-selected TTL now expires the root, although the copy is new.
    assert {:ok, _} =
             Repo.transaction(fn ->
               KnowledgeRetention.prune_in_transaction(1200)
             end)

    assert Enum.all?(Repo.all(ConversationKnowledge), &(&1.state == %{"retention" => "pruned"}))

    assert Enum.all?(
             Repo.all(KnowledgeRevision),
             &(&1.state == %{"retention" => "pruned"})
           )

    assert Enum.all?(Repo.all(KnowledgeSource), &is_nil(&1.source_note))
    assert is_nil(Repo.get!(ConversationObservation, first.id).note)
    # The later original message has its own lifetime; unlike the derived topic,
    # it did not copy or inherit the expired message's prose.
    assert Repo.get!(ConversationObservation, copy.id).note["summary"] == @resolved["summary"]
    assert Repo.aggregate(Inbox.Entry, :count) == 2
  end

  defp learn!(entry, note, item \\ nil, options \\ []) do
    decision = decision!(note, item)

    decision =
      if Keyword.get(options, :knowledge, true), do: decision, else: %{decision | knowledge: nil}

    assert {:ok, %{entry: %{status: :decided}}} =
             Responder.Fixtures.Knowledge.commit_topic(
               context!(entry),
               decision,
               "learn:#{entry.id}"
             )
  end

  def record_recall_query(_event, _measurements, %{query: query, params: params}, {owner, ref}) do
    source = query |> String.split(" FROM ", parts: 2) |> List.last()

    if self() == owner && String.starts_with?(query, "SELECT") &&
         String.starts_with?(source, "\"conversation_observations\"") &&
         String.contains?(query, "conversation_knowledge") do
      send(owner, {ref, query, params})
    end
  end

  defp knowledge_scan_loops(plan) do
    own =
      if plan["Relation Name"] == "conversation_knowledge",
        do: plan["Actual Loops"],
        else: 0

    own + Enum.sum(Enum.map(plan["Plans"] || [], &knowledge_scan_loops/1))
  end

  defp membership_scan_work(plan) do
    own =
      if plan["Relation Name"] == "conversation_knowledge_sources",
        do: plan["Actual Rows"] * plan["Actual Loops"],
        else: 0

    own + Enum.sum(Enum.map(plan["Plans"] || [], &membership_scan_work/1))
  end

  defp stale_recall_statistics! do
    # Captured from the failed full gate (seed 872694). PostgreSQL 18's restore
    # API is pinned by compose.test.yml; Sandbox rollback restores the catalog.
    # No source/model data or planner switches are changed by this fault seed.
    for {table, pages} <- [
          {"conversation_knowledge", 0},
          {"conversation_knowledge_revisions", 10},
          {"conversation_knowledge_sources", 0},
          {"conversation_observations", 1713}
        ] do
      assert %{rows: [[true]]} =
               Repo.query!(
                 """
                 SELECT pg_catalog.pg_restore_relation_stats(
                   'version', current_setting('server_version_num')::integer,
                   'schemaname', 'public', 'relname', $1::text,
                   'relpages', $2::integer, 'reltuples', 0::real,
                   'relallvisible', 0::integer, 'relallfrozen', 0::integer)
                 """,
                 [table, pages]
               )
    end
  end

  defp decision!(note, item \\ nil) do
    %{
      knowledge: %{
        "topic_key" => "website-haproxy-oom",
        "title" => "Website HAProxy memory limits",
        "summary" => note["summary"],
        "topics" => note["topics"],
        "target_ref" => item && item["source_ref"],
        "anchors" => [],
        "expected_version" => if(item, do: item["version"], else: 0)
      }
    }
  end

  defp input!(n, note, options \\ []) do
    revision = Keyword.get(options, :revision, 1)

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :app, ref: "B0910HETYAH"},
        channel_ref: Keyword.get(options, :channel, "C1"),
        workspace_ref: "TKNOWLEDGE",
        message_ref: "1788632364.#{String.pad_leading(to_string(n), 6, "0")}",
        thread_ref: nil,
        event_ref: "knowledge-#{n}-#{revision}",
        revision: revision,
        event_kind: Keyword.get(options, :kind, :message),
        occurred_at: DateTime.add(@now, n * 600),
        content: Keyword.get(options, :content, %{"text" => note["summary"]})
      })

    {:ok, %{entry: entry}} =
      Inbox.record(input,
        execution_mode: Keyword.get(options, :mode, :live),
        work_profile: %{
          policy: "test-read-only",
          policy_digest: String.duplicate("a", 64),
          repository_ref: "blitz-infra"
        }
      )

    entry
  end

  defp context!(entry) do
    {:ok, context} =
      Admission.context(Inbox.ref(entry),
        now: DateTime.add(@now, 86_400),
        continuation_window: 1800,
        history_window: 604_800,
        candidate_limit: 20
      )

    context
  end

  defp joined!(channel) do
    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: "TKNOWLEDGE",
      channel_ref: channel,
      private: false,
      external_shared: false,
      generation: 1,
      status: :joined,
      joined_at: @now
    })
  end
end
