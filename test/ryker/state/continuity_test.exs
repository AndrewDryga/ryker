defmodule Ryker.State.ContinuityTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{HTML, Projection}
  alias Ryker.Episodes
  alias Ryker.Fixtures.DatabaseClock
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelConfigurations, ChannelMembership, SourceRef}

  alias Ryker.State.{
    Continuity,
    ConversationObservation,
    ConversationRollup,
    ConversationSummary,
    ConversationSummaryDraft,
    ConversationSummaryState,
    Knowledge,
    KnowledgeRetention,
    KnowledgeSnapshot,
    LearningSources,
    MemorySearchPage,
    Observations,
    SourceExposure
  }

  alias Ryker.State.Continuity.{Compaction, Recall}
  alias Ryker.Work.{Custody, FinalPreflight, Result, Submission, SubmissionBuilder}

  @now ~U[2026-09-04 12:00:00.000000Z]

  for kind <- [:summary, :rollup], existing? <- [false, true] do
    test "#{if existing?, do: "updated", else: "new"} #{kind} is immediately searchable under host clock skew" do
      assert_searchable_clock_continuity!(unquote(kind), unquote(existing?))
    end
  end

  defp assert_searchable_clock_continuity!(kind, existing?) do
    # Database-cutoff search must see a just-saved summary/rollup, even when
    # the application host runs ahead. Old snapshots still exclude new writes.
    {entry, work, submission} = raw_work!()
    database_time = DatabaseClock.behind_host!()
    assert {:ok, _} = Continuity.stage(work.state_token, state("website/haproxy-edge OOM"))
    accept!(work, submission)
    old = DateTime.add(database_time, -120, :second)
    schema = if kind == :summary, do: ConversationSummary, else: ConversationRollup

    if kind == :rollup, do: compact_clock_summary!(old)

    if existing? do
      Repo.update_all(schema, set: [inserted_at: old, updated_at: old])

      next =
        open_work!(
          "database-clock-update",
          work.episode.destination_conversation_ref,
          work.episode.destination_thread_ref,
          "blitz-infra"
        )

      assert {:ok, _} =
               Continuity.stage(next.state_token, state("website/haproxy-edge OOM resolution"))

      accept!(next)
      if kind == :rollup, do: compact_clock_summary!(old)
    end

    page = MemorySearchPage.first("haproxy", "repository")

    assert {:ok, {:ok, match, _position}} =
             Repo.transaction(fn ->
               Recall.search_page(kind, work.episode, "blitz-infra", page)
             end)

    saved = Repo.one!(schema)
    assert match["source_ref"] == saved.ref
    assert match["workspace_ref"] == saved.workspace_ref
    assert [%{"tool" => "read_slack_source", "arguments" => read} | _] = match["source_reads"]
    assert length(match["source_reads"]) <= 3
    ["slack", workspace, channel] = String.split(entry.destination_conversation_ref, ":")
    assert read["anchor_ref"] == SourceRef.message(workspace, channel, entry.source_item_ref)

    if kind == :summary do
      assert match["conversation_ref"] == saved.conversation_ref
      assert match["thread_ref"] == saved.thread_ref
      assert match["source_message_ref"] == saved.source_message_ref
      assert match["coverage"]["basis"] == "derived_handover"
    else
      assert match["scope_kind"] == Atom.to_string(saved.scope_kind)
      assert match["scope_ref"] == saved.scope_ref
      assert match["expires_at"] == DateTime.to_iso8601(saved.expires_at)
      assert match["coverage"]["basis"] == "compacted_continuity"
      refute Map.has_key?(match, "thread_ref")
    end

    assert saved.updated_at == database_time
    assert saved.inserted_at == if(existing?, do: old, else: database_time)

    assert {:ok, :done} =
             Repo.transaction(fn ->
               Recall.search_page(kind, work.episode, "blitz-infra", %{
                 page
                 | cutoff: DateTime.add(database_time, -1)
               })
             end)

    if kind == :rollup do
      assert saved.period_end == old
      assert saved.expires_at == DateTime.add(old, 7200, :second)
    end
  end

  defp compact_clock_summary!(old) do
    Repo.update_all(ConversationSummary, set: [inserted_at: old, updated_at: old])

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7200) end)
  end

  test "inherited topic roots do not invalidate a warm session or rewrite earlier attribution" do
    # Fable found the normalized read counted all roots while the frozen
    # document counted direct support. Every warm session inheriting a topic
    # would then fail, despite its original sources remaining authorized.
    work =
      open_work!(
        "inherited-session",
        "control-plane:lab:inherited-session",
        nil,
        "ryker",
        "control_plane"
      )

    {original, offered} = KnowledgeFixtures.learn!(work.episode, "ryker")
    id = Ecto.UUID.generate()
    input = %{original | id: id, native_input_id: id, event_fingerprint: CanonicalJSON.digest(id)}
    assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(input) end)

    proposal =
      offered
      |> Map.take(~w(title summary topics))
      |> Map.merge(%{
        "topic_key" => "separate-context",
        "target_ref" => nil,
        "expected_version" => 0,
        "anchors" => []
      })

    dependencies =
      LearningSources.merge([
        LearningSources.for_entry(input),
        LearningSources.document_sources(offered)
      ])

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Ryker.State.Knowledge.record_sources_in_transaction(
                 [input],
                 proposal,
                 [offered],
                 %{
                   result_ref: "host-inherited-session-fixture",
                   source_dependencies: dependencies,
                   omissions: []
                 }
               )
             end)

    topic =
      Ryker.State.Knowledge.context(work.episode, "ryker")
      |> Enum.find(&(&1["topic_key"] == "separate-context"))

    assert topic["source_count"] == 1
    assert :ok = KnowledgeSnapshot.expose(work.claim, [topic])
    assert :ok = KnowledgeSnapshot.authorize_session(work.episode, work.claim.session)

    # The inherited root becomes direct support only in revision 2. Revision 1
    # must keep its one-source attribution and remain valid in the warm session.
    proposal = %{proposal | "target_ref" => topic["source_ref"], "expected_version" => 1}

    dependencies =
      LearningSources.merge([
        LearningSources.for_entry(original),
        LearningSources.document_sources(topic)
      ])

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Ryker.State.Knowledge.record_sources_in_transaction(
                 [original],
                 proposal,
                 [topic],
                 %{
                   result_ref: "host-promoted-source-fixture",
                   source_dependencies: dependencies,
                   omissions: []
                 }
               )
             end)

    assert :ok = KnowledgeSnapshot.authorize_session(work.episode, work.claim.session)
    assert :ok = KnowledgeSnapshot.reauthorize(work.episode, "ryker", [topic])
    KnowledgeFixtures.revoke!(original)

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_session(work.episode, work.claim.session)
  end

  for compact? <- [false, true], missing <- [[], nil, %{}] do
    test "a #{inspect(missing)}-sourced #{if compact?, do: "rollup", else: "summary"} remains history, not model context" do
      # Retained replay summaries defaulted to [] and could reintroduce prose with no revocable source.
      {_entry, work, submission} = raw_work!()
      assert {:ok, _} = Continuity.stage(work.state_token, state("website/haproxy-edge OOM"))
      accept!(work, submission)

      if unquote(compact?) do
        Repo.update_all(ConversationSummary,
          set: [updated_at: DateTime.add(DateTime.utc_now(), -120)]
        )

        assert {:ok, {:ok, 1}} =
                 Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7200) end)
      end

      schema = if unquote(compact?), do: ConversationRollup, else: ConversationSummary
      original = Repo.one!(schema)
      context = Continuity.model_context(work.episode, "blitz-infra")
      document = if unquote(compact?), do: hd(context["rollups"]), else: context["current"]

      Repo.update!(
        Ecto.Changeset.change(original, source_dependencies: unquote(Macro.escape(missing)))
      )

      current = Continuity.model_context(work.episode, "blitz-infra")
      assert current["current"] == nil
      assert current["related"] == []
      assert current["rollups"] == []

      for kind <- [:summary, :rollup] do
        assert search!(kind, work.episode, "blitz-infra", "haproxy", "workspace", 20) == []
      end

      frozen = %{
        "context" => %{"operator_context" => %{"continuity" => %{"related" => [document]}}}
      }

      assert {:error, :work_knowledge_context_stale} =
               KnowledgeSnapshot.authorize_submission(work.episode, "blitz-infra", frozen)

      assert {:error, :work_knowledge_context_stale} =
               KnowledgeSnapshot.expose(work.claim, [document])

      preserved = Repo.get!(schema, original.id)
      assert preserved.state == original.state
      assert preserved.state_fingerprint == original.state_fingerprint
      assert preserved.source_dependencies == unquote(Macro.escape(missing))
    end
  end

  test "a source-free Work result does not publish a reusable conversation summary" do
    # Kernel tasks may run without ingress, but their lack of receipts must not become reusable prose.
    work =
      open_work!(
        "source-free",
        "control-plane:lab:source-free",
        nil,
        "ryker",
        "control_plane",
        :live,
        false
      )

    assert KnowledgeSnapshot.session_sources(work.claim.session.id) == []
    assert {:ok, _} = Continuity.stage(work.state_token, state("Unattributed retained prose"))
    assert %{turn: %{result_ref: result}} = accept!(work)
    assert is_binary(result)
    assert Repo.aggregate(ConversationSummary, :count) == 0
    assert Repo.aggregate(ConversationSummaryDraft, :count) == 0

    assert Map.get(Repo.get!(Ryker.Work.Turn, work.claim.turn.id), :summary_error_code) ==
             "no_sources"
  end

  test "receiptless summaries cannot consume recall or compaction slots ahead of healthy sources" do
    {_entry, work, submission} = raw_work!()
    assert {:ok, _} = Continuity.stage(work.state_token, state("website/haproxy-edge OOM"))
    accept!(work, submission)
    original = Repo.one!(ConversationSummary)
    old = DateTime.add(DateTime.utc_now(), -300)
    Repo.update!(Ecto.Changeset.change(original, updated_at: old))

    # The old compaction window was 100 rows, and automatic related recall was 64.
    for index <- 1..101 do
      id = Ecto.UUID.generate()

      Repo.insert!(%{
        original
        | id: id,
          identity_key: CanonicalJSON.digest(id),
          ref: "continuity:#{id}",
          thread_ref: "receiptless-#{index}",
          source_dependencies: [],
          updated_at: DateTime.add(old, index),
          inserted_at: DateTime.add(old, index)
      })
    end

    reader = %{work.episode | destination_thread_ref: "reader-thread"}
    assert [related] = Continuity.model_context(reader, "blitz-infra")["related"]
    assert related["source_ref"] == original.ref

    assert [match] = search!(:summary, reader, "blitz-infra", "haproxy", "workspace", 1)
    assert match["source_ref"] == original.ref

    # Recall sorts newest first; compaction sorts oldest first. Exercise both full windows.
    Repo.update_all(from(item in ConversationSummary, where: item.id != ^original.id),
      set: [updated_at: DateTime.add(old, -120)]
    )

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7200) end)

    rollup = Repo.one!(ConversationRollup)
    assert rollup.source_refs == [original.ref]
    assert rollup.source_count == 1
    assert rollup.state == original.state
    assert Repo.aggregate(ConversationSummary, :count) == 101
    assert Repo.all(ConversationSummary) |> Enum.all?(&(&1.source_dependencies == []))
  end

  for scope <- [
        :public,
        :private,
        :private_membership,
        :external_shared,
        :left,
        :other_transport,
        :ambiguous_workspace,
        :colon_channel,
        :without_repository
      ] do
    test "an unsourced #{scope} rollup cannot absorb sourced prose or block another compaction group" do
      {_entry, work, submission} = raw_work!()
      assert {:ok, _} = Continuity.stage(work.state_token, state("website/haproxy-edge OOM"))
      accept!(work, submission)
      {summary, scope_kind} = compaction_scope!(Repo.one!(ConversationSummary), unquote(scope))
      old = DateTime.add(DateTime.utc_now(), -8 * 86_400)
      summary = Repo.update!(Ecto.Changeset.change(summary, updated_at: old))

      assert {:ok, {:ok, 1}} =
               Repo.transaction(fn -> Compaction.compact_in_transaction(60, 14 * 86_400) end)

      rollup = Repo.one!(ConversationRollup)
      assert rollup.scope_kind == scope_kind
      rollup = Repo.update!(Ecto.Changeset.change(rollup, source_dependencies: []))
      Repo.insert!(summary)

      blocked =
        for index <- 1..99 do
          id = Ecto.UUID.generate()

          Repo.insert!(%{
            summary
            | id: id,
              identity_key: CanonicalJSON.digest(id),
              ref: "continuity:#{id}",
              thread_ref: "blocked-#{index}"
          })
        end

      healthy_id = Ecto.UUID.generate()

      healthy =
        Repo.insert!(%{
          summary
          | id: healthy_id,
            identity_key: CanonicalJSON.digest(healthy_id),
            ref: "continuity:#{healthy_id}",
            thread_ref: "healthy-independent",
            updated_at: DateTime.add(old, 7 * 86_400)
        })

      assert {:ok, {:ok, 1}} =
               Repo.transaction(fn -> Compaction.compact_in_transaction(60, 14 * 86_400) end)

      assert Repo.get!(ConversationRollup, rollup.id) == rollup
      assert Repo.get!(ConversationSummary, summary.id) == summary
      assert Enum.all?(blocked, &(Repo.get!(ConversationSummary, &1.id) == &1))
      assert Repo.get(ConversationSummary, healthy.id) == nil

      assert [%ConversationRollup{source_refs: [ref]}] =
               Repo.all(from(item in ConversationRollup, where: item.id != ^rollup.id))

      assert ref == healthy.ref
    end
  end

  defp compaction_scope!(summary, scope) do
    # Storage fixtures vary only host scope metadata. Their state and receipts remain
    # the same captured-input-derived data; this checks query/locked classifier parity.
    {changes, kind} = compaction_scope_changes(scope)

    {Repo.update!(Ecto.Changeset.change(summary, changes)), kind}
  end

  defp compaction_scope_changes(:public), do: {[], :repository}
  defp compaction_scope_changes(:private), do: {[visibility: :private], :conversation}
  defp compaction_scope_changes(:other_transport), do: {[transport: "webhook"], :conversation}
  defp compaction_scope_changes(:without_repository), do: {[repository_ref: nil], :conversation}

  defp compaction_scope_changes(:private_membership) do
    Repo.update_all(ChannelMembership, set: [private: true])
    {[], :conversation}
  end

  defp compaction_scope_changes(:external_shared) do
    Repo.update_all(ChannelMembership, set: [external_shared: true])
    {[], :conversation}
  end

  defp compaction_scope_changes(:left) do
    Repo.update_all(ChannelMembership, set: [status: :left, left_at: @now])
    {[], :conversation}
  end

  defp compaction_scope_changes(:ambiguous_workspace) do
    joined!("T:extra", "CANY")
    {[workspace_ref: "slack:T:extra", conversation_ref: "slack:T:extra:CANY"], :conversation}
  end

  defp compaction_scope_changes(:colon_channel) do
    joined!("TANY", "C:extra")
    {[workspace_ref: "slack:TANY", conversation_ref: "slack:TANY:C:extra"], :repository}
  end

  test "raw Work inputs establish source receipts even when admission learned no note" do
    # Actual replay messages with nil observation notes still enter Work. Without
    # raw receipts their facts survived deletion when copied into a later summary.
    {entry, work, _submission} = raw_work!()
    receipts = KnowledgeSnapshot.session_sources(work.claim.session.id)
    assert Enum.any?(receipts, &(&1["source_input_id"] == entry.id))
  end

  for event_kind <- [:edit, :delete] do
    test "a #{event_kind} to raw input withdraws its summary without requiring prior knowledge" do
      {entry, work, submission} = raw_work!()
      situation = "Grafana reported website/haproxy-edge OOM on nomad-hvn01."
      assert {:ok, _} = Continuity.stage(work.state_token, state(situation))
      accept!(work, submission)
      assert Continuity.model_context(work.episode, "blitz-infra")["current"] != nil

      changed = %{
        entry
        | id: Ecto.UUID.generate(),
          revision: entry.revision + 1,
          event_kind: unquote(event_kind),
          event_fingerprint: String.duplicate("f", 64)
      }

      assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(changed) end)
      assert Continuity.model_context(work.episode, "blitz-infra")["current"] == nil

      for kind <- [:summary, :rollup] do
        assert search!(kind, work.episode, "blitz-infra", "nomad-hvn01", "workspace", 20) == []
      end
    end
  end

  for field <- ["source_event_id", "source_dependencies"] do
    test "raw Work authorization rejects missing #{field} instead of treating it as unsourced" do
      {_entry, work, submission} = raw_work!()

      changed =
        update_in(submission, ["context", "inputs", "items"], fn [input] ->
          [Map.delete(input, unquote(field))]
        end)

      assert {:error, :work_knowledge_context_stale} =
               KnowledgeSnapshot.authorize_submission(work.episode, "blitz-infra", changed)
    end
  end

  test "raw Work authorization rejects erased and falsified host receipts" do
    {_entry, work, submission} = raw_work!()

    for replacement <- [[], [%{"fingerprint" => String.duplicate("f", 64)}], nil] do
      changed =
        update_in(submission, ["context", "inputs", "items"], fn [input] ->
          [Map.put(input, "source_dependencies", replacement)]
        end)

      assert {:error, :work_knowledge_context_stale} =
               KnowledgeSnapshot.authorize_submission(work.episode, "blitz-infra", changed)
    end
  end

  test "payload receipt fields cannot replace the host's raw input lineage" do
    {entry, work, submission} = raw_work!()
    [item] = get_in(submission, ["context", "inputs", "items"])
    event = Repo.get!(Ryker.Episodes.Event, item["source_event_id"])
    payload = Map.put(event.payload["payload"], "source_dependencies", [])

    Repo.update!(
      Ecto.Changeset.change(event, payload: Map.put(event.payload, "payload", payload))
    )

    assert {:ok, rebuilt} = SubmissionBuilder.build(work.claim)
    [item] = get_in(rebuilt, ["context", "inputs", "items"])
    assert item["content"]["source_dependencies"] == []
    assert Enum.any?(item["source_dependencies"], &(&1["source_input_id"] == entry.id))
    assert :ok = KnowledgeSnapshot.authorize_submission(work.episode, "blitz-infra", rebuilt)
  end

  test "historical truncation retains exact raw lineage and malformed ingress fails closed" do
    {entry, work, _submission} = raw_work!()
    claim = %{work.claim | episode: %{work.episode | active_input_refs: []}}
    assert {:ok, rebuilt} = SubmissionBuilder.build(claim)
    [historical] = get_in(rebuilt, ["context", "inputs", "items"])
    assert historical["content"]["truncated"]
    assert Enum.any?(historical["source_dependencies"], &(&1["source_input_id"] == entry.id))
    assert :ok = KnowledgeSnapshot.authorize_submission(work.episode, "blitz-infra", rebuilt)

    event = Repo.get!(Ryker.Episodes.Event, historical["source_event_id"])
    payload = Map.delete(event.payload["payload"], "native_input_id")

    Repo.update!(
      Ecto.Changeset.change(event, payload: Map.put(event.payload, "payload", payload))
    )

    assert {:ok, malformed} = SubmissionBuilder.build(work.claim)

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_submission(work.episode, "blitz-infra", malformed)
  end

  test "withdrawn historical inputs become no-prose tombstones but active requests fail closed" do
    {entry, work, _submission} = raw_work!()
    withdraw_raw!(entry)

    assert {:ok, active} = SubmissionBuilder.build(work.claim)
    [active_input] = get_in(active, ["context", "inputs", "items"])
    assert active_input["current"]
    assert active_input["source_dependencies"] == nil

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_submission(work.episode, "blitz-infra", active)

    claim = %{work.claim | episode: %{work.episode | active_input_refs: []}}
    assert {:ok, rebuilt} = SubmissionBuilder.build(claim)
    [historical] = get_in(rebuilt, ["context", "inputs", "items"])
    assert historical["content"] == %{"unavailable" => "source_not_current"}
    refute Jason.encode!(historical) =~ "nomad-hvn01"
    assert :ok = KnowledgeSnapshot.authorize_submission(work.episode, "blitz-infra", rebuilt)
  end

  test "a delta's withdrawn first input cannot reintroduce its original prose" do
    {entry, work, submission} = raw_work!()
    accepted = accept!(work, submission)
    withdraw_raw!(entry)

    claim = %{
      work.claim
      | episode: accepted.episode,
        turn: %{work.claim.turn | id: Ecto.UUID.generate()}
    }

    assert {:ok, delta} = SubmissionBuilder.build(claim)
    assert delta["context"]["mode"] == "continuation"
    first = get_in(delta, ["context", "continuity", "first_input"])
    assert first["content"] == %{"unavailable" => "source_not_current"}
    refute Jason.encode!(first) =~ "nomad-hvn01"
    assert :ok = KnowledgeSnapshot.authorize_submission(work.episode, "blitz-infra", delta)

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_session(work.episode, work.claim.session)
  end

  test "a current delete envelope cannot reintroduce the retained body it withdraws" do
    {entry, work, submission} = raw_work!()

    deleted = %{
      entry
      | id: Ecto.UUID.generate(),
        revision: entry.revision + 1,
        event_kind: :delete,
        dedupe_key: entry.dedupe_key <> ":deleted",
        decision_ref: entry.decision_ref <> ":deleted"
    }

    Repo.insert!(deleted)
    assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(deleted) end)
    [original] = get_in(submission, ["context", "inputs", "items"])
    event = Repo.get!(Ryker.Episodes.Event, original["source_event_id"])

    envelope =
      original["content"]
      |> Map.put("revision", deleted.revision)
      |> Map.put("event_kind", "delete")

    assert Jason.encode!(envelope) =~ "nomad-hvn01"

    Repo.update!(
      Ecto.Changeset.change(event, payload: Map.put(event.payload, "payload", envelope))
    )

    assert LearningSources.for_work_input(envelope) == nil

    raw =
      put_in(submission, ["context", "inputs", "items"], [%{original | "content" => envelope}])

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_submission(work.episode, "blitz-infra", raw)

    assert {:ok, current} = SubmissionBuilder.build(work.claim)
    [notice] = get_in(current, ["context", "inputs", "items"])
    assert notice["content"] == %{"event_kind" => "delete", "unavailable" => "source_deleted"}
    refute Jason.encode!(current) =~ "nomad-hvn01"
    assert :ok = KnowledgeSnapshot.authorize_submission(work.episode, "blitz-infra", current)

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_session(work.episode, work.claim.session)

    claim = %{work.claim | episode: %{work.episode | active_input_refs: []}}
    assert {:ok, historical} = SubmissionBuilder.build(claim)
    [tombstone] = get_in(historical, ["context", "inputs", "items"])
    assert tombstone["content"] == notice["content"]
    refute Jason.encode!(tombstone) =~ "nomad-hvn01"
  end

  for {kind, source_ref, actor_ref, content_kind} <- [
        {"schedule", "schedule:01993d45-d400-7000-8000-000000000001", "schedule",
         "scheduled_task"},
        {"system", "ryker", "event-wait-deadline", "deadline_elapsed"},
        # Wake-ups recorded before the 2026-09-13 rename carry the retained
        # source ref and must keep sorting as host-origin work, by explicit rule.
        {"system", "responder", "event-wait-deadline", "deadline_elapsed"},
        {"system", "emisar", "emisar-approval-monitor", "emisar_approval_terminal"},
        {"system", "publication-lifecycle", "publication-lifecycle", "publication_lifecycle"}
      ] do
    test "host-origin #{source_ref} work does not require a nonexistent ingress receipt" do
      # These are the source contracts authored by Schedules, EventWaits, Approvals
      # and Followups. They use Input.document but deliberately bypass the inbox.
      work =
        open_work!(
          unquote(content_kind),
          "control-plane:lab:host-input",
          nil,
          nil,
          "control_plane",
          :live,
          false
        )

      assert {:ok, input} =
               Input.new(%{
                 actor: %{kind: :system, ref: unquote(actor_ref)},
                 content: %{"kind" => unquote(content_kind)},
                 destination: %{
                   transport: "control_plane",
                   conversation_ref: work.episode.destination_conversation_ref,
                   thread_ref: nil
                 },
                 event_kind: :event,
                 event_ref: "host-event:#{work.episode.id}",
                 native_input_id: "host-input:#{work.episode.id}",
                 occurred_at: @now,
                 occurred_at_source: :source,
                 revision: 1,
                 source: %{kind: unquote(kind), ref: unquote(source_ref)},
                 source_capabilities: %{},
                 source_item_ref: nil
               })

      event = Repo.get_by!(Ryker.Episodes.Event, episode_id: work.episode.id)

      Repo.update!(
        Ecto.Changeset.change(event,
          payload: Map.put(event.payload, "payload", Input.document(input))
        )
      )

      assert Repo.aggregate(ConversationObservation, :count) == 0
      assert {:ok, submission} = SubmissionBuilder.build(work.claim)
      [item] = get_in(submission, ["context", "inputs", "items"])
      assert item["content"]["content"]["kind"] == unquote(content_kind)
      assert item["source_dependencies"] == []
      claim = %{work.claim | turn: %{work.claim.turn | submission: submission}}
      assert :ok = KnowledgeSnapshot.expose_submission(claim)
    end
  end

  defp withdraw_raw!(entry) do
    changed = %{
      entry
      | id: Ecto.UUID.generate(),
        revision: entry.revision + 1,
        event_kind: :delete,
        event_fingerprint: String.duplicate("f", 64)
    }

    assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(changed) end)
  end

  defp raw_work! do
    [entry | _] = LearningFixtures.inputs!()
    ["slack", workspace, channel] = String.split(entry.destination_conversation_ref, ":")
    joined!(workspace, channel)
    episode = Repo.get!(Ryker.Episodes.Episode, entry.episode_id)

    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: entry.actor_kind, ref: entry.actor_ref},
               content: entry.content,
               destination: %{
                 transport: entry.destination_transport,
                 conversation_ref: entry.destination_conversation_ref,
                 thread_ref: entry.destination_thread_ref
               },
               event_kind: entry.event_kind,
               event_ref: entry.event_ref,
               native_input_id: entry.native_input_id,
               occurred_at: entry.occurred_at,
               occurred_at_source: entry.occurred_at_source,
               revision: entry.revision,
               source: %{kind: entry.source_kind, ref: entry.source_ref},
               source_capabilities: entry.source_capabilities,
               source_item_ref: entry.source_item_ref
             })

    # The retained fixture seeds the kernel with content only. Production admission
    # submits the authenticated envelope; retain its exact harvested content here.
    event =
      Repo.one!(
        from(event in Ryker.Episodes.Event,
          where: event.episode_id == ^episode.id and event.kind == :input_admitted
        )
      )

    Repo.update!(
      Ecto.Changeset.change(event,
        payload: Map.put(event.payload, "payload", Input.document(input))
      )
    )

    assert {:ok, _} =
             Custody.pin_episode(
               episode.id,
               "ryker-read",
               String.duplicate("a", 64),
               "blitz-infra"
             )

    assert {:ok, claim} = Custody.claim_next("raw-source-review", 60, :work)
    assert claim.episode.id == episode.id
    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert Enum.any?(
             get_in(submission, ["context", "inputs", "items"]),
             &(&1["content"] == Input.document(input))
           )

    assert get_in(submission, ["context", "operator_context", "continuity", "knowledge"]) in [
             nil,
             []
           ]

    assert {:ok, turn} =
             Custody.freeze_submission(
               episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    claim = %{claim | turn: turn}
    assert :ok = KnowledgeSnapshot.expose_submission(claim)

    work = %{
      claim: claim,
      episode: episode,
      state_token: "state:#{turn.id}",
      suffix: "raw-source-review"
    }

    {entry, work, submission}
  end

  for boundary <- [:count, :bytes] do
    # Overflow proofs, not per-commit checks: sixteen seconds of the serial suite.
    @tag :slow
    test "#{boundary} source overflow cannot publish a summary without its expiry receipts" do
      # Reproduce an already-running historical oversized transcript. New
      # disclosure is now refused by KnowledgeSnapshot before this can happen.
      work =
        open_work!(
          "summary-capacity",
          "control-plane:lab:summary-capacity",
          nil,
          "ryker",
          "control_plane"
        )

      {entry, document} = KnowledgeFixtures.learn!(work.claim.episode, "ryker")
      original = Repo.get!(ConversationObservation, entry.id)
      [receipt] = LearningSources.for_entry(entry)
      dependencies = receipt_group(receipt, unquote(boundary))

      overflow_after_submission = fn ->
        for dependency <- dependencies do
          source =
            original
            |> Map.from_struct()
            |> Map.delete(:__meta__)
            |> Map.merge(%{
              id: dependency["observation_id"],
              identity_key: CanonicalJSON.digest(dependency),
              source_input_id: dependency["source_input_id"],
              repository_ref: dependency["repository_ref"],
              source_dependencies: [dependency]
            })

          Repo.insert!(struct!(ConversationObservation, source))

          Repo.insert!(%SourceExposure{
            session_id: work.claim.session.id,
            observation_id: source.id,
            source_input_id: source.source_input_id,
            receipt: dependency
          })
        end

        assert {:error, :work_knowledge_context_stale} =
                 KnowledgeSnapshot.authorize_session(work.claim.episode, work.claim.session)

        # The structural historical transcript includes its exact custody
        # attestation. Unaccounted writes above must still fail closed; the
        # production disclosure path cannot append this oversized source set.
        count =
          Repo.aggregate(
            from(e in SourceExposure, where: e.session_id == ^work.claim.session.id),
            :count
          )

        work.claim.session
        |> then(&Repo.get!(Ryker.Work.Session, &1.id))
        |> Ecto.Changeset.change(source_exposure_count: count)
        |> Repo.update!()

        assert KnowledgeSnapshot.session_sources(work.claim.session.id) == nil
        assert {:ok, _} = Continuity.stage(work.state_token, state(document["summary"]))
      end

      assert %{turn: %{result_ref: result}} = accept!(work, nil, overflow_after_submission)
      assert is_binary(result)
      assert Repo.aggregate(ConversationSummary, :count) == 0
      assert Repo.aggregate(ConversationSummaryDraft, :count) == 0

      assert Map.get(Repo.get!(Ryker.Work.Turn, work.claim.turn.id), :summary_error_code) ==
               "source_capacity"
    end

    test "#{boundary} rollup overflow preserves the source summaries instead of stripping lineage" do
      work =
        open_work!(
          "rollup-capacity",
          "control-plane:lab:rollup-capacity",
          nil,
          "ryker",
          "control_plane"
        )

      {entry, document} = KnowledgeFixtures.learn!(work.claim.episode, "ryker")
      assert {:ok, _} = Continuity.stage(work.state_token, state(document["summary"]))
      accept!(work)
      summary = Repo.one!(ConversationSummary)
      [receipt] = LearningSources.for_entry(entry)

      {left, right} =
        receipt_group(receipt, unquote(boundary))
        |> then(&Enum.split(&1, div(length(&1), 2)))

      assert is_list(LearningSources.merge([left]))
      assert is_list(LearningSources.merge([right]))
      old = DateTime.add(DateTime.utc_now(), -120)
      Repo.update!(Ecto.Changeset.change(summary, source_dependencies: left, updated_at: old))

      duplicate = %{
        summary
        | id: Ecto.UUID.generate(),
          identity_key: CanonicalJSON.digest(Ecto.UUID.generate()),
          ref: "continuity:#{Ecto.UUID.generate()}",
          source_dependencies: right,
          updated_at: old
      }

      Repo.insert!(duplicate)

      assert {:ok, {:ok, 0}} =
               Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7200) end)

      assert Repo.aggregate(ConversationRollup, :count) == 0
      assert Repo.aggregate(ConversationSummary, :count) == 2

      assert Enum.all?(
               Repo.all(ConversationSummary),
               &(Map.get(&1, :compaction_error_code) == "source_capacity")
             )
    end
  end

  test "a capacity-blocked oldest window cannot starve a later healthy conversation" do
    # Structural expansion of retained topic prose: 100 older summaries used to
    # monopolize every maintenance pass, leaving later conversations untouched.
    work =
      open_work!(
        "compaction-fairness",
        "control-plane:lab:compaction-fairness",
        nil,
        "ryker",
        "control_plane"
      )

    {entry, document} = KnowledgeFixtures.learn!(work.claim.episode, "ryker")
    assert {:ok, _} = Continuity.stage(work.state_token, state(document["summary"]))
    accept!(work)
    summary = Repo.one!(ConversationSummary)
    [receipt] = LearningSources.for_entry(entry)
    [extra | rest] = receipt_group(receipt, :count)
    [first | chunks] = Enum.chunk_every(rest, 100)
    chunks = [[extra | first] | chunks]
    assert length(chunks) == 100
    old = DateTime.add(DateTime.utc_now(), -180)

    Enum.with_index(chunks, fn sources, index ->
      attrs = %{source_dependencies: sources, updated_at: old}

      if index == 0 do
        Repo.update!(Ecto.Changeset.change(summary, attrs))
      else
        id = Ecto.UUID.generate()

        Repo.insert!(
          struct!(
            summary,
            Map.merge(attrs, %{
              id: id,
              ref: "continuity:#{id}",
              identity_key: CanonicalJSON.digest(id)
            })
          )
        )
      end
    end)

    id = Ecto.UUID.generate()

    healthy =
      Repo.insert!(%{
        summary
        | id: id,
          ref: "continuity:#{id}",
          identity_key: CanonicalJSON.digest(id),
          conversation_ref: "control-plane:lab:later-healthy",
          updated_at: DateTime.add(old, 60)
      })

    assert {:ok, {:ok, 0}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7200) end)

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7200) end)

    assert Repo.get(ConversationSummary, healthy.id) == nil
    assert Repo.aggregate(ConversationSummary, :count) == 100
    assert Repo.one!(ConversationRollup).scope_ref == healthy.conversation_ref
  end

  test "one rollup exceeding its scope budget does not roll back healthy maintenance" do
    joined!("T123", "CSCOPE")
    work = open_work!("scope-overflow", "slack:T123:CSCOPE", nil, "ryker")
    assert {:ok, _} = Continuity.stage(work.state_token, state("Scope capacity fixture"))
    accept!(work)
    summary = Repo.one!(ConversationSummary)
    old = DateTime.add(DateTime.utc_now(), -120)
    Repo.update!(Ecto.Changeset.change(summary, updated_at: old))

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7200) end)

    rollup = Repo.one!(ConversationRollup)

    # Structural expansion of host scope descriptors, never a model response.
    scopes =
      for n <- 1..10_000,
          do: %{"transport" => "slack", "workspace_ref" => "T123", "channel_ref" => "CHIST#{n}"}

    Repo.update!(Ecto.Changeset.change(rollup, source_scopes: scopes))
    pending = Repo.insert!(%{summary | updated_at: old})

    healthy =
      open_work!("healthy-scope", "control-plane:lab:healthy-scope", nil, nil, "control_plane")

    assert {:ok, _} = Continuity.stage(healthy.state_token, state("Healthy maintenance"))
    accept!(healthy)
    Repo.update_all(ConversationSummary, set: [updated_at: old])

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7200) end)

    assert %{compaction_error_code: "scope_capacity"} = Repo.get!(ConversationSummary, pending.id)
    assert Repo.aggregate(ConversationSummary, :count) == 1
    assert Repo.aggregate(ConversationRollup, :count) == 2
  end

  test "a retention-pruned rollup can be rebuilt by later sources in the same week" do
    work =
      open_work!(
        "pruned-rollup",
        "control-plane:lab:pruned-rollup",
        nil,
        "ryker",
        "control_plane"
      )

    {_entry, document} = KnowledgeFixtures.learn!(work.claim.episode, "ryker")
    assert {:ok, _} = Continuity.stage(work.state_token, state(document["summary"]))
    accept!(work)

    Repo.update_all(ConversationSummary,
      set: [updated_at: DateTime.add(DateTime.utc_now(), -120)]
    )

    summary = Repo.one!(ConversationSummary)

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7200) end)

    rollup = Repo.one!(ConversationRollup)

    Repo.update!(
      Ecto.Changeset.change(rollup,
        state: %{"retention" => "pruned"},
        source_dependencies: nil,
        state_fingerprint: CanonicalJSON.digest(%{"retention" => "pruned"})
      )
    )

    Repo.insert!(%{summary | id: Ecto.UUID.generate(), ref: "continuity:#{Ecto.UUID.generate()}"})

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7200) end)

    assert Repo.one!(ConversationRollup).state == summary.state
    assert Repo.one!(ConversationRollup).id == rollup.id
  end

  defp receipt_group(receipt, boundary) do
    count = if boundary == :count, do: 10_001, else: 8_192

    for _ <- 1..count do
      id = Ecto.UUID.generate()

      %{
        receipt
        | "observation_id" => id,
          "source_input_id" => id,
          "repository_ref" =>
            if(boundary == :bytes, do: String.duplicate("r", 1024), else: "ryker")
      }
    end
    |> Enum.sort_by(&CanonicalJSON.encode!/1)
  end

  test "repeated source disclosure keeps the earliest expiry in subsequent summaries" do
    # A newer tool result must not refresh source facts already inherited from older memory.
    work =
      open_work!(
        "earliest-source",
        "control-plane:lab:earliest-source",
        nil,
        "ryker",
        "control_plane"
      )

    {entry, document} = KnowledgeFixtures.learn!(work.claim.episode, "ryker")
    assert :ok = KnowledgeSnapshot.expose(work.claim, [document])
    [receipt] = KnowledgeSnapshot.session_sources(work.claim.session.id)

    earlier =
      Map.put(receipt, "retained_at", DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -600)))

    source = Repo.get_by!(ConversationObservation, source_input_id: entry.id)
    Repo.update!(Ecto.Changeset.change(source, source_dependencies: [earlier]))

    assert :ok =
             KnowledgeSnapshot.expose(work.claim, [Observations.document(source)])

    assert KnowledgeSnapshot.session_sources(work.claim.session.id) == [earlier]
  end

  for compact? <- [false, true] do
    test "a fresh #{if compact?, do: "rollup", else: "summary"} loses copied prose when its original source expires" do
      # Copying an old learned fact must not restart its configured retention clock.
      work =
        open_work!(
          "summary-expiry",
          "control-plane:lab:summary-expiry",
          nil,
          "ryker",
          "control_plane"
        )

      {_source, document} = KnowledgeFixtures.learn!(work.claim.episode, "ryker")
      assert :ok = KnowledgeSnapshot.expose(work.claim, [document])
      assert {:ok, _} = Continuity.stage(work.state_token, state(document["summary"]))
      accept!(work)
      summary = Repo.one!(ConversationSummary)

      # The expiry fault changes terminal receipt lifetimes, never the fields
      # of a compact topic-generation reference. Keep that reference alongside
      # the earlier raw receipts so this still exercises inherited custody.
      earlier =
        summary.source_dependencies
        |> LearningSources.expand()
        |> Enum.map(
          &Map.put(
            &1,
            "retained_at",
            DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -3601))
          )
        )

      dependencies = LearningSources.merge([summary.source_dependencies, earlier])

      Repo.update!(Ecto.Changeset.change(summary, source_dependencies: dependencies))

      if unquote(compact?) do
        Repo.update_all(ConversationSummary,
          set: [updated_at: DateTime.add(DateTime.utc_now(), -120)]
        )

        assert {:ok, {:ok, 1}} =
                 Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7200) end)
      end

      schema = if unquote(compact?), do: ConversationRollup, else: ConversationSummary

      assert {:ok, _} =
               Repo.transaction(fn ->
                 KnowledgeRetention.prune_in_transaction(3600)
               end)

      assert Repo.one!(schema).state == %{"retention" => "pruned"}
    end

    test "a #{if compact?, do: "rollup", else: "summary"} cannot launder knowledge from a withdrawn source" do
      joined!("T123", "CSOURCE")
      joined!("T123", "CTARGET")
      work = open_work!("summary-lineage", "slack:T123:CTARGET", nil, "ryker")
      destination = %{work.claim.episode | destination_conversation_ref: "slack:T123:CSOURCE"}
      {source, document} = KnowledgeFixtures.learn!(destination, "ryker")
      assert :ok = KnowledgeSnapshot.expose(work.claim, [document])
      assert {:ok, _} = Continuity.stage(work.state_token, state(document["summary"]))
      accept!(work)

      if unquote(compact?) do
        Repo.update_all(ConversationSummary,
          set: [updated_at: DateTime.add(DateTime.utc_now(), -120)]
        )

        assert {:ok, {:ok, 1}} =
                 Repo.transaction(fn -> Compaction.compact_in_transaction(60, 3600) end)
      end

      KnowledgeFixtures.revoke!(source)
      context = Continuity.model_context(work.claim.episode, "ryker")
      assert context["current"] == nil
      assert context["related"] == []
      assert context["rollups"] == []

      for kind <- [:summary, :rollup] do
        assert search!(kind, work.claim.episode, "ryker", "draft-ai-suggestions", "workspace", 20) ==
                 []
      end
    end

    @tag :summary_generation
    test "an accepted #{if compact?, do: "rollup", else: "summary"} cannot reintroduce a superseded topic generation" do
      # A real accepted handover used to retain only raw source receipts. A
      # later topic rebuild could therefore leave that old understanding usable
      # through a fresh summary/rollup even though its native session was stale.
      joined!("T123", "CSOURCE")
      joined!("T123", "CTARGET")
      work = open_work!("summary-generation", "slack:T123:CTARGET", nil, "ryker")
      destination = %{work.claim.episode | destination_conversation_ref: "slack:T123:CSOURCE"}
      {source, document} = KnowledgeFixtures.learn!(destination, "ryker")
      assert :ok = KnowledgeSnapshot.expose(work.claim, [document])
      assert {:ok, _} = Continuity.stage(work.state_token, state(document["summary"]))
      accept!(work)

      if unquote(compact?) do
        Repo.update_all(ConversationSummary,
          set: [updated_at: DateTime.add(DateTime.utc_now(), -120)]
        )

        assert {:ok, {:ok, 1}} =
                 Repo.transaction(fn -> Compaction.compact_in_transaction(60, 3600) end)
      end

      schema = if unquote(compact?), do: ConversationRollup, else: ConversationSummary
      saved = Repo.one!(schema)
      rebuild_topic_after_later_source_withdrawal!(source, document)

      # Only the later root was withdrawn. This raw original is still eligible,
      # so rejection must come from retaining the original topic generation.
      assert [%{"version" => 3}] = Knowledge.context(source, source.repository_ref)

      assert {:error, :work_knowledge_context_stale} =
               KnowledgeSnapshot.authorize_session(work.claim.episode, work.claim.session)

      fresh = open_work!("fresh-generation", "slack:T123:CTARGET", nil, "ryker")
      context = get_in(fresh.submission, ["context", "operator_context", "continuity"])
      assert context["current"] == nil
      assert context["related"] == []
      assert context["rollups"] == []
      assert Repo.get!(schema, saved.id).state == saved.state
    end
  end

  defp rebuild_topic_after_later_source_withdrawal!(source, document) do
    id = Ecto.UUID.generate()

    # Structural source-membership expansion of the same harvested text, not a
    # fabricated second model answer. The real writer performs both revisions.
    later = %{source | id: id, source_ref: "generation-fixture:#{id}", native_input_id: id}
    proposal = Map.take(document, ~w(topic_key title summary topics anchors))

    update =
      Map.merge(proposal, %{
        "target_ref" => document["source_ref"],
        "expected_version" => document["version"]
      })

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               :ok = Observations.record_excerpt_in_transaction(later)
               KnowledgeFixtures.record_topic(later, update, [document])
             end)

    [current] = Knowledge.context(source, source.repository_ref)
    "knowledge:" <> topic_id = current["source_ref"]
    KnowledgeFixtures.revoke!(later)
    assert Knowledge.context(source, source.repository_ref) == []
    head = Repo.get!(Ryker.State.ConversationKnowledge, topic_id)

    context = %{
      result_ref: "host-rebuild-summary:#{id}",
      source_dependencies: LearningSources.for_entry(source),
      omissions: [],
      rebuild_source_entries: [source],
      rebuild: %{topic_id: head.id, version: head.version, generation: head.source_generation}
    }

    create = Map.merge(proposal, %{"target_ref" => nil, "expected_version" => 0})

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.rebuild_sources_in_transaction([source], create, [], context)
             end)
  end

  test "shadow work can publish derived summaries without creating a visible result" do
    # Observe-only work used to be unable to save its own conversation summary.
    joined!("T123", "CSHADOW")
    work = open_work!("shadow-memory", "slack:T123:CSHADOW", nil, "ryker", "slack", :shadow)

    assert {:ok, _} =
             Continuity.stage(work.state_token, state("Observed a keep-service decision"))

    assert %{turn: %{delivery_document: nil}} = accept!(work)
    assert Repo.one!(ConversationSummary).state["situation"] == "Observed a keep-service decision"
    assert Repo.aggregate(Ryker.Delivery.Reaction, :count) == 0
  end

  test "validated result acceptance atomically publishes the latest staged situation" do
    joined!("T123", "C111")
    work = open_work!("atomic", "slack:T123:C111", "1710000000.000001", "ryker")
    state = state("Investigate delivery", ["deploy:receipt:1"])

    assert {:ok, first} = Continuity.stage(work.state_token, state)
    assert first.revision == 1
    assert {:ok, duplicate} = Continuity.stage(work.state_token, state)
    assert duplicate.revision == 1

    revised = %{state | "open_loops" => ["Verify production delivery"]}
    assert {:ok, staged} = Continuity.stage(work.state_token, revised)
    assert staged.revision == 2
    assert Repo.aggregate(ConversationSummary, :count) == 0

    accept!(work)

    assert Repo.aggregate(ConversationSummaryDraft, :count) == 0
    assert %ConversationSummary{} = summary = Repo.one!(ConversationSummary)
    assert summary.state == revised
    assert summary.repository_ref == "ryker"
    assert summary.visibility == :public
    assert summary.source_result_ref == "result:#{work.claim.turn.id}"

    # Hundreds of saved summaries were invisible on Memory, making replay look empty.
    html =
      Projection.memory()
      |> HTML.memory("test-secret")
      |> IO.iodata_to_binary()

    assert html =~ "Conversation memory"
    assert html =~ "Verify production delivery"

    recalled = Continuity.model_context(work.claim.episode, "ryker")
    assert recalled["current"]["state"] == revised
    assert recalled["current"]["source_ref"] == summary.ref
    assert Repo.get!(ConversationSummary, summary.id).recall_count == 1

    assert search!(:summary, work.claim.episode, "ryker", "does-not-match", "current_channel", 20) ==
             []

    assert Repo.get!(ConversationSummary, summary.id).recall_count == 1

    assert [match] =
             search!(
               :summary,
               work.claim.episode,
               "ryker",
               "verify production delivery",
               "current_channel",
               20
             )

    assert match["kind"] == "continuity"
    assert Repo.get!(ConversationSummary, summary.id).recall_count == 2

    assert [_workspace_match] =
             search!(
               :summary,
               work.claim.episode,
               "ryker",
               "verify production delivery",
               "workspace",
               20
             )

    replacement =
      open_work!("atomic-replacement", "slack:T123:C111", "1710000000.000001", "ryker")

    assert {:ok, _draft} =
             Continuity.stage(replacement.state_token, state("Replacement situation"))

    accept!(replacement)

    assert Repo.aggregate(ConversationSummary, :count) == 1
    assert Repo.one!(ConversationSummary).state["situation"] == "Replacement situation"

    assert Continuity.stage(replacement.state_token, state("Too late")) ==
             {:error, :conversation_summary_unauthorized}
  end

  test "invalid and unaccepted drafts never become conversation memory" do
    work = open_work!("rejected", "slack:T123:C222", "1710000000.000002", nil)

    assert {:error, {:invalid_conversation_summary, :fields}} =
             Continuity.stage(work.state_token, %{"goal" => "too little"})

    assert {:ok, _draft} = Continuity.stage(work.state_token, state("Unaccepted"))
    assert Repo.aggregate(ConversationSummary, :count) == 0
    assert Repo.aggregate(ConversationSummaryDraft, :count) == 1

    assert {:error, :conversation_summary_unauthorized} =
             Continuity.stage("state:#{Ecto.UUID.generate()}", state("Unknown"))

    assert Continuity.stage("state:not-a-uuid", state("Invalid token")) ==
             {:error, :conversation_summary_unauthorized}

    assert Continuity.stage("invalid", state("Invalid prefix")) ==
             {:error, :conversation_summary_unauthorized}
  end

  test "public continuity boundaries fail closed outside their custody transaction" do
    work = open_work!("transaction-fences", "slack:T123:C223", nil, nil)

    assert Continuity.model_context(:invalid, nil) == %{
             "current" => nil,
             "related" => [],
             "rollups" => []
           }

    assert Compaction.compact_in_transaction(60, 3_600) ==
             {:error, :conversation_summary_transaction_required}

    assert Compaction.compact_in_transaction(0, 3_600) ==
             {:error, :invalid_conversation_summary_retention}

    assert Continuity.delete_slack_channel_in_transaction("T123", "C223") ==
             {:error, :conversation_summary_transaction_required}

    assert Continuity.delete_slack_channel_in_transaction(nil, nil) ==
             {:error, :conversation_summary_destination}

    assert Continuity.candidate_staged_in_transaction(
             work.claim.turn,
             String.duplicate("a", 64),
             1
           ) == {:error, :conversation_summary_transaction_required}

    assert Continuity.accept_staged_in_transaction(%{}, %{}, %{}, nil) ==
             {:error, :conversation_summary_invalid_acceptance}

    invalid_destination = %{work.claim.episode | destination_transport: nil}
    assert Continuity.model_context(invalid_destination, nil)["current"] == nil

    for kind <- [:summary, :rollup] do
      assert search!(kind, invalid_destination, nil, "query", "workspace", 20) == []
    end

    malformed_slack = %{
      work.claim.episode
      | destination_conversation_ref: "slack:T123",
        destination_transport: "slack"
    }

    assert Continuity.model_context(malformed_slack, nil)["current"] == nil

    malformed_github = %{
      work.claim.episode
      | destination_conversation_ref: "github:",
        destination_transport: "github"
    }

    assert Continuity.model_context(malformed_github, nil)["current"] == nil
  end

  test "a universal transport retains exact-conversation continuity without gaining cross-channel scope" do
    work =
      open_work!(
        "universal",
        "webhook:configured-route:item-1",
        "occurrence-1",
        nil,
        "webhook"
      )

    assert {:ok, _draft} = Continuity.stage(work.state_token, state("Universal input"))
    accept!(work)

    assert %ConversationSummary{visibility: :conversation} = Repo.one!(ConversationSummary)
    context = Continuity.model_context(work.claim.episode, nil)
    assert context["current"]["state"]["situation"] == "Universal input"
    assert context["related"] == []

    old = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update_all(ConversationSummary, set: [inserted_at: old, updated_at: old])

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 3_600) end)

    assert %ConversationRollup{scope_kind: :conversation, visibility: :conversation} =
             Repo.one!(ConversationRollup)

    assert [rollup] =
             search!(:rollup, work.claim.episode, nil, "universal input", "current_channel", 20)

    assert rollup["kind"] == "continuity"
  end

  test "Slack direct-message continuity never crosses into another direct message" do
    source = open_work!("direct-source", "slack:T123:D111", nil, "ryker")
    assert {:ok, _draft} = Continuity.stage(source.state_token, state("Direct state"))
    accept!(source)

    assert Repo.one!(ConversationSummary).visibility == :direct

    same_direct = open_work!("direct-same", "slack:T123:D111", "reply", "ryker")
    other_direct = open_work!("direct-other", "slack:T123:D222", nil, "ryker")

    assert [related] = Continuity.model_context(same_direct.claim.episode, "ryker")["related"]
    assert related["state"]["situation"] == "Direct state"
    assert Continuity.model_context(other_direct.claim.episode, "ryker")["related"] == []
  end

  test "cross-channel recall prefers the same repository and never crosses private boundaries" do
    joined!("T123", "C222")
    joined!("T123", "C333")
    joined!("T123", "C111")
    joined!("T123", "G444", true)

    public_same =
      open_work!("public-same", "slack:T123:C222", "1710000000.000010", "ryker")

    public_other =
      open_work!("public-other", "slack:T123:C333", "1710000000.000011", "other")

    private = open_work!("private", "slack:T123:G444", "1710000000.000012", "ryker")

    Enum.each(
      [
        {public_same, state("Same repository")},
        {public_other, state("Other repository")},
        {private, state("Private detail")}
      ],
      fn {work, summary} ->
        assert {:ok, _draft} = Continuity.stage(work.state_token, summary)
        accept!(work)
      end
    )

    current = open_work!("current", "slack:T123:C111", "1710000000.000013", "ryker")
    context = Continuity.model_context(current.claim.episode, "ryker")

    assert Enum.map(context["related"], & &1["state"]["situation"]) == [
             "Same repository",
             "Other repository"
           ]

    refute inspect(context) =~ "Private detail"

    Repo.update_all(
      from(membership in ChannelMembership,
        where: membership.workspace_ref == "T123" and membership.channel_ref == "C222"
      ),
      set: [status: :left, left_at: @now]
    )

    after_leave = Continuity.model_context(current.claim.episode, "ryker")
    assert Enum.map(after_leave["related"], & &1["state"]["situation"]) == ["Other repository"]

    private_context = Continuity.model_context(private.claim.episode, "ryker")
    assert private_context["current"]["state"]["situation"] == "Private detail"
  end

  test "retention compaction creates a durable sourced rollup before deleting summaries" do
    joined!("T123", "C555")
    joined!("T123", "C777")
    work = open_work!("rollup", "slack:T123:C555", "1710000000.000020", "ryker")
    summary_state = state("Old situation", ["source:one"])
    assert {:ok, _draft} = Continuity.stage(work.state_token, summary_state)
    accept!(work)

    old = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update_all(ConversationSummary, set: [inserted_at: old, updated_at: old])

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 3_600) end)

    assert Repo.aggregate(ConversationSummary, :count) == 0
    assert %ConversationRollup{} = rollup = Repo.one!(ConversationRollup)
    assert rollup.scope_kind == :repository
    assert rollup.scope_ref == "ryker"
    assert rollup.source_count == 1
    assert length(rollup.source_refs) == 1
    assert rollup.state["situation"] == "Old situation"
    assert DateTime.diff(rollup.expires_at, DateTime.add(old, 3_600, :second), :second) == 0

    current = open_work!("rollup-current", "slack:T123:C777", "1710000000.000021", "ryker")
    context = Continuity.model_context(current.claim.episode, "ryker")
    assert [recalled] = context["rollups"]
    assert recalled["source_refs"] == rollup.source_refs
    assert recalled["state"]["evidence_refs"] == ["source:one"]

    Repo.update_all(
      from(membership in ChannelMembership,
        where: membership.workspace_ref == "T123" and membership.channel_ref == "C555"
      ),
      set: [status: :left, left_at: @now]
    )

    assert Continuity.model_context(current.claim.episode, "ryker")["rollups"] == []

    assert {:ok, _deleted} =
             ChannelConfigurations.observe_membership(
               %{
                 actor_ref: nil,
                 channel_ref: "C555",
                 event_ref: "event:delete-continuity",
                 kind: :deleted,
                 occurred_at: DateTime.add(@now, 1, :second),
                 workspace_ref: "T123"
               },
               %{default_repository: "ryker", repository_refs: ["ryker"]}
             )

    assert Repo.aggregate(ConversationRollup, :count) == 0
  end

  test "compaction never extends source content beyond its configured horizon" do
    joined!("T123", "C556")
    work = open_work!("expired-rollup", "slack:T123:C556", nil, "ryker")
    assert {:ok, _draft} = Continuity.stage(work.state_token, state("Expired source"))
    accept!(work)

    old = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update_all(ConversationSummary, set: [inserted_at: old, updated_at: old])

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 60) end)

    assert Repo.aggregate(ConversationSummary, :count) == 0
    assert Repo.aggregate(ConversationRollup, :count) == 0
  end

  test "later summaries merge into an existing rollup without losing source custody" do
    joined!("T123", "C557")

    first = open_work!("rollup-first", "slack:T123:C557", nil, "ryker")
    assert {:ok, _draft} = Continuity.stage(first.state_token, state("First", ["source:first"]))
    accept!(first)

    # Term-order sorting ranked microseconds before the actual clock time,
    # letting an older conversation replace the newest situation in a rollup.
    # At Monday 00:02:30 these offsets straddled the weekly bucket boundary.
    # Anchor both in the preceding hour, with a horizon covering that hour.
    now = DateTime.from_unix!(div(DateTime.to_unix(DateTime.utc_now()), 3600) * 3600)
    first_time = %{DateTime.add(now, -180, :second) | microsecond: {900_000, 6}}
    Repo.update_all(ConversationSummary, set: [inserted_at: first_time, updated_at: first_time])

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7_200) end)

    first_rollup = Repo.one!(ConversationRollup)

    second = open_work!("rollup-second", "slack:T123:C557", nil, "ryker")

    assert {:ok, _draft} =
             Continuity.stage(second.state_token, state("Second", ["source:second"]))

    accept!(second)

    second_time = %{DateTime.add(now, -120, :second) | microsecond: {100_000, 6}}
    Repo.update_all(ConversationSummary, set: [inserted_at: second_time, updated_at: second_time])

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7_200) end)

    rollup = Repo.one!(ConversationRollup)
    assert rollup.id == first_rollup.id
    assert rollup.source_count == 2
    assert length(rollup.source_refs) == 2
    assert rollup.state["evidence_refs"] == ["source:second", "source:first"]
    assert DateTime.compare(rollup.period_end, second_time) == :eq

    current = open_work!("rollup-search", "slack:T123:C557", nil, "ryker")

    assert [match] =
             search!(:rollup, current.claim.episode, "ryker", "source:first", "repository", 20)

    assert match["source_count"] == 2

    for kind <- [:summary, :rollup] do
      assert search!(kind, current.claim.episode, "ryker", "source", "invalid", 20) == []
    end
  end

  test "private continuity crosses threads only inside the same authenticated channel" do
    joined!("T123", "G555", true)
    joined!("T123", "G666", true)

    source = open_work!("private-source", "slack:T123:G555", "1710000000.000030", "ryker")
    assert {:ok, _draft} = Continuity.stage(source.state_token, state("Private channel state"))
    accept!(source)

    same_channel =
      open_work!("private-same", "slack:T123:G555", "1710000000.000031", "ryker")

    other_channel =
      open_work!("private-other", "slack:T123:G666", "1710000000.000032", "ryker")

    assert [related] =
             Continuity.model_context(same_channel.claim.episode, "ryker")["related"]

    assert related["state"]["situation"] == "Private channel state"
    assert Continuity.model_context(other_channel.claim.episode, "ryker")["related"] == []
  end

  test "Slack Connect continuity stays inside the externally shared channel" do
    joined!("T123", "CEXT", false, true)
    joined!("T123", "CINT")

    source = open_work!("connect-source", "slack:T123:CEXT", "1710000000.000040", "ryker")
    assert {:ok, _draft} = Continuity.stage(source.state_token, state("Partner-only state"))
    accept!(source)

    assert Repo.one!(ConversationSummary).visibility == :private

    same_channel =
      open_work!("connect-same", "slack:T123:CEXT", "1710000000.000041", "ryker")

    internal = open_work!("connect-internal", "slack:T123:CINT", nil, "ryker")

    assert [related] =
             Continuity.model_context(same_channel.claim.episode, "ryker")["related"]

    assert related["state"]["situation"] == "Partner-only state"
    assert Continuity.model_context(internal.claim.episode, "ryker")["related"] == []
  end

  test "an unknown Slack channel fails closed and first-seen deletion removes its continuity" do
    work = open_work!("unknown-private", "slack:T123:CSECRET", nil, "ryker")
    assert {:ok, _draft} = Continuity.stage(work.state_token, state("Unknown visibility"))
    accept!(work)

    assert Repo.one!(ConversationSummary).visibility == :conversation

    assert {:ok, deleted} =
             ChannelConfigurations.observe_membership(
               %{
                 actor_ref: nil,
                 channel_ref: "CSECRET",
                 event_ref: "event:delete-unknown-continuity",
                 kind: :deleted,
                 occurred_at: DateTime.add(@now, 1, :second),
                 workspace_ref: "T123"
               },
               %{default_repository: "ryker", repository_refs: ["ryker"]}
             )

    assert deleted.membership.status == :deleted
    assert Repo.aggregate(ConversationSummary, :count) == 0
  end

  test "channel deletion removes staged continuity and fences every later write" do
    joined!("T123", "CDELETED")
    # This kernel-only acceptance checks the deleted-channel write fence, independently
    # of the source-disclosure fence that rejects a stale Slack model submission.
    work =
      open_work!(
        "deleted-channel",
        "slack:T123:CDELETED",
        nil,
        "ryker",
        "slack",
        :live,
        false
      )

    summary = state("Delete before acceptance")

    assert {:ok, _draft} = Continuity.stage(work.state_token, summary)
    assert Repo.aggregate(ConversationSummaryDraft, :count) == 1

    assert {:ok, deleted} =
             ChannelConfigurations.observe_membership(
               %{
                 actor_ref: nil,
                 channel_ref: "CDELETED",
                 event_ref: "event:delete-staged-continuity",
                 kind: :deleted,
                 occurred_at: DateTime.add(@now, 1, :second),
                 workspace_ref: "T123"
               },
               %{default_repository: "ryker", repository_refs: ["ryker"]}
             )

    assert deleted.membership.status == :deleted
    assert Repo.aggregate(ConversationSummaryDraft, :count) == 0
    assert Continuity.stage(work.state_token, summary) == {:error, :slack_channel_deleted}

    accepted = accept!(work)
    assert accepted.turn.result_ref == "result:#{work.claim.turn.id}"
    assert Repo.aggregate(ConversationSummary, :count) == 0
  end

  test "a replaced candidate cannot publish an earlier attempt's summary" do
    joined!("T123", "C888")
    work = open_work!("candidate-fence", "slack:T123:C888", nil, "ryker")
    assert {:ok, _draft} = Continuity.stage(work.state_token, state("First attempt only"))

    claim = bind_work!(work)
    first = ~s({"delivery":"none","decision_reason":"first"})
    second = ~s({"delivery":"none","decision_reason":"second"})
    first_sha = digest(first)
    second_sha = digest(second)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               first,
               first_sha,
               1
             )

    bound_turn = Repo.get!(Ryker.Work.Turn, claim.turn.id)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Continuity.candidate_staged_in_transaction(bound_turn, first_sha, 1)
             end)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               first_sha,
               1,
               second,
               second_sha,
               2
             )

    assert Repo.aggregate(ConversationSummaryDraft, :count) == 0
    assert {:ok, result} = Result.new(:none, nil, "second")

    assert {:ok, _turn} =
             Custody.prepare_validation(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               second_sha,
               2,
               :accept,
               result
             )

    assert {:ok, _accepted} =
             Custody.accept_result(
               work.episode.id,
               work.episode.key,
               claim.turn.turn_ref,
               claim.lease_ref,
               second_sha,
               2,
               "validation-receipt:candidate-fence"
             )

    assert Repo.aggregate(ConversationSummary, :count) == 0
  end

  test "final preflight rejects a summary changed after validation" do
    joined!("T123", "C999")
    work = open_work!("preflight-fence", "slack:T123:C999", nil, "ryker")
    assert {:ok, _draft} = Continuity.stage(work.state_token, state("Before validation"))
    candidate_sha = String.duplicate("b", 64)

    ledger_sha =
      FinalPreflight.ledger_sha256(
        work.episode.id,
        work.episode.semantic_version,
        [],
        work.claim.turn.id
      )

    assert {:ok, _turn} =
             Custody.record_final_preflight(
               work.episode.id,
               work.claim.turn.turn_ref,
               work.claim.lease_ref,
               candidate_sha,
               ledger_sha,
               work.episode.semantic_version
             )

    assert {:ok, _draft} = Continuity.stage(work.state_token, state("After validation"))

    assert Custody.verify_final_preflight(
             work.episode.id,
             work.claim.turn.turn_ref,
             work.claim.lease_ref,
             candidate_sha,
             []
           ) == {:error, :work_final_preflight_required}
  end

  test "compaction applies one deterministic byte budget across merged summaries" do
    joined!("T123", "C901")
    joined!("T123", "C902")

    for {channel, suffix} <- [{"C901", "one"}, {"C902", "two"}] do
      work = open_work!("large-#{suffix}", "slack:T123:#{channel}", nil, "ryker")
      summary = %{state("Large #{suffix}") | "decisions" => large_values(suffix)}
      assert {:ok, _draft} = Continuity.stage(work.state_token, summary)
      accept!(work)
    end

    old = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update_all(ConversationSummary, set: [inserted_at: old, updated_at: old])

    assert {:ok, {:ok, 2}} =
             Repo.transaction(fn -> Compaction.compact_in_transaction(60, 3_600) end)

    rollup = Repo.one!(ConversationRollup)
    assert byte_size(CanonicalJSON.encode!(rollup.state)) <= 32 * 1_024
    assert {:ok, _state} = ConversationSummaryState.prepare(rollup.state)
  end

  defp open_work!(
         suffix,
         conversation_ref,
         thread_ref,
         repository_ref,
         transport \\ "slack",
         mode \\ :live,
         source? \\ true
       ) do
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:continuity:#{suffix}:#{episode_id}"

    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: conversation_ref,
          thread_ref: thread_ref,
          transport: transport
        },
        episode_id: episode_id,
        execution_mode: mode,
        episode_key: "continuity:#{suffix}:#{episode_id}",
        native_input_id: "slack-message:continuity:#{suffix}:#{episode_id}",
        occurred_at: @now,
        turn_ref: turn_ref
      })

    command = if source?, do: received_command!(command), else: command
    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(
               episode_id,
               "ryker-read",
               String.duplicate("a", 64),
               repository_ref
             )

    assert {:ok, claim} = Custody.claim_next("worker:continuity:#{suffix}", 60, :work)
    assert {:ok, submission} = SubmissionBuilder.build(claim)

    %{
      claim: claim,
      episode: transition.episode,
      submission: submission,
      state_token: "state:#{claim.turn.id}",
      suffix: suffix
    }
  end

  defp received_command!(command) do
    # These positive summary tests model a real input that the host received and later
    # disclosed, rather than attributing synthetic kernel-only work to an unrelated note.
    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U1"},
               content: command.payload,
               destination: command.destination,
               event_kind: :message,
               event_ref: command.native_input_id,
               native_input_id: command.native_input_id,
               occurred_at: command.occurred_at,
               occurred_at_source: :source,
               revision: command.revision,
               source: %{kind: command.destination.transport, ref: "continuity-test"},
               source_capabilities: %{},
               source_item_ref: command.native_input_id
             })

    assert {:ok, _receipt} = Inbox.record(input, execution_mode: command.execution_mode)
    %{command | payload: Input.document(input)}
  end

  defp accept!(work, submission \\ nil, after_exposure \\ fn -> :ok end) do
    candidate = ~s({"delivery":"none","decision_reason":"continuity updated"})
    sha256 = digest(candidate)

    submission = submission || work.submission

    claim = work.claim

    assert {:ok, frozen} =
             Custody.freeze_submission(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert :ok = KnowledgeSnapshot.expose_submission(%{claim | turn: frozen})
    after_exposure.()

    assert {:ok, session} =
             Custody.bind_session(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:continuity:#{work.suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:continuity:#{work.suffix}"
             )

    assert {:ok, _turn} =
             Custody.stage_candidate(
               work.episode.id,
               turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} = Result.new(:none, nil, "continuity updated")

    assert {:ok, _turn} =
             Custody.prepare_validation(
               work.episode.id,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               work.episode.id,
               work.episode.key,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:continuity:#{work.suffix}"
             )

    accepted
  end

  defp bind_work!(work) do
    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => work.episode.id},
               "Update continuity.",
               %{"type" => "object"},
               "work-final-v1"
             )

    claim = work.claim

    assert {:ok, _turn} =
             Custody.freeze_submission(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:continuity:#{work.suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               work.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:continuity:#{work.suffix}"
             )

    %{claim | session: session, turn: turn}
  end

  defp joined!(workspace_ref, channel_ref, private \\ false, external_shared \\ false) do
    now = @now

    Repo.insert!(%ChannelMembership{
      channel_ref: channel_ref,
      external_shared: external_shared,
      generation: 1,
      id: Ecto.UUID.generate(),
      joined_at: now,
      private: private,
      status: :joined,
      workspace_ref: workspace_ref
    })
  end

  defp state(situation, evidence_refs \\ []) do
    %{
      "active_topics" => ["Ryker"],
      "decisions" => ["Keep continuity derived"],
      "evidence_refs" => evidence_refs,
      "goal" => "Ship the requested behavior",
      "open_loops" => [],
      "participants" => ["operator"],
      "purpose" => "Product development",
      "situation" => situation,
      "topology" => ["Ryker uses PostgreSQL"],
      "unresolved_questions" => []
    }
  end

  defp large_values(prefix) do
    Enum.map(1..20, fn index -> "#{prefix}-#{index}-#{String.duplicate("x", 1_350)}" end)
  end

  # Explicit continuity search is one lane of a memory search page, read the
  # way `Ryker.State.MemorySearch` reads the summary and rollup kinds.
  defp search!(kind, episode, repository_ref, query, scope, limit) do
    page = MemorySearchPage.first(query, scope)

    {:ok, found} =
      Repo.transaction(fn ->
        MemorySearchPage.read(page, limit, &Recall.search_page(kind, episode, repository_ref, &1))
      end)

    found
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
