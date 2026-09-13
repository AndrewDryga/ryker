defmodule Ryker.State.ContinuityConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Accounting.Execution
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo

  alias Ryker.State.{
    Continuity,
    ConversationSummary,
    ConversationSummaryDraft,
    KnowledgeExposure,
    KnowledgeSnapshot,
    MemorySearchPage,
    Record,
    SourceExposure
  }

  alias Ryker.State.Continuity.Recall
  alias Ryker.Work.{Custody, Result, Session, SubmissionBuilder, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]

  # The channel fence serializes Slack channels only. Two episodes on the same
  # pull request, lab or direct message could both find no summary for their
  # destination and both insert one; the second insert failed on the unique
  # index, and the accepted reply it belonged to was rolled back with it — a
  # memory failure discarding a validated Work result.
  test "two episodes on one destination both keep their accepted replies and share one summary" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      conversation_ref = "control-plane:lab:continuity-race-#{suffix}"
      first = open_work!("race-one-#{suffix}", conversation_ref)
      second = open_work!("race-two-#{suffix}", conversation_ref)
      {:ok, context} = Continuity.destination_context(first.episode, nil)

      try do
        assert {:ok, _draft} = Continuity.stage(second.state_token, state("Race two"))
        parent = self()

        # The first episode's acceptance, caught between inserting its summary
        # and committing.
        holder =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              insert_summary!(first, context, "Race one")
              send(parent, {:summary_inserted, backend_pid()})

              receive do
                :commit -> :ok
              end
            end)
          end)

        assert_receive {:summary_inserted, holder_backend}, 5_000

        contender =
          unboxed_task(fn ->
            send(parent, {:accepting, backend_pid()})
            accept!(second)
          end)

        assert_receive {:accepting, contender_backend}, 5_000
        await_blocked_by(contender_backend, holder_backend)
        send(holder.pid, :commit)

        assert {:ok, _} = Task.await(holder, 5_000)
        accepted = Task.await(contender, 5_000)
        assert is_binary(accepted.turn.result_ref)
        assert Repo.get!(Turn, second.claim.turn.id).summary_error_code == nil

        assert [summary] =
                 Repo.all(
                   from(summary in ConversationSummary,
                     where: summary.identity_key == ^context.identity_key
                   )
                 )

        assert summary.state["situation"] == "Race two"
        assert summary.source_episode_id == second.episode.id
        assert Repo.aggregate(ConversationSummaryDraft, :count) == 0
      after
        cleanup!([first, second], context.identity_key)
      end
    end)
  end

  # A search read its summary hit FOR SHARE and then counted the recall with an
  # UPDATE. Two searches on the same summary from two episodes each held the
  # share lock the other's UPDATE needed, and PostgreSQL aborted one of them —
  # reported to the model as memory_search_budget_exceeded, which is not what
  # happened. The search takes no lock now; the recall count is best effort and
  # the visibility recheck locks the observations, not the summary.
  test "two searches counting the same summary do not deadlock each other" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      conversation_ref = "control-plane:lab:continuity-search-#{suffix}"
      first = open_work!("search-one-#{suffix}", conversation_ref)
      second = open_work!("search-two-#{suffix}", conversation_ref)
      {:ok, context} = Continuity.destination_context(first.episode, nil)

      try do
        assert {:ok, _draft} = Continuity.stage(first.state_token, state("Search race"))
        accept!(first)
        summary = Repo.get_by!(ConversationSummary, identity_key: context.identity_key)
        parent = self()

        # Another episode's search, caught between reading the hit and
        # counting the recall.
        holder =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              Repo.one!(
                from(row in ConversationSummary, where: row.id == ^summary.id, lock: "FOR SHARE")
              )

              send(parent, {:hit_read, backend_pid()})

              receive do
                :count -> :ok
              end

              Repo.update_all(from(row in ConversationSummary, where: row.id == ^summary.id),
                inc: [recall_count: 1]
              )

              :counted
            end)
          end)

        assert_receive {:hit_read, holder_backend}, 5_000

        searcher =
          unboxed_task(fn ->
            send(parent, {:searching, backend_pid()})

            Repo.transaction(fn ->
              Recall.search_page(
                :summary,
                second.claim.episode,
                nil,
                MemorySearchPage.first("Search race", "current_channel")
              )
            end)
          end)

        assert_receive {:searching, searcher_backend}, 5_000
        await_blocked_by(searcher_backend, holder_backend)
        send(holder.pid, :count)

        assert {:ok, :counted} = Task.await(holder, 5_000)
        assert {:ok, {:ok, document, _position}} = Task.await(searcher, 5_000)
        assert document["state"]["situation"] == "Search race"
        assert Repo.get!(ConversationSummary, summary.id).recall_count == 2
      after
        cleanup!([first, second], context.identity_key)
      end
    end)
  end

  defp open_work!(suffix, conversation_ref) do
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:continuity-race:#{suffix}"

    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: conversation_ref,
          thread_ref: nil,
          transport: "control_plane"
        },
        episode_id: episode_id,
        episode_key: "continuity-race:#{suffix}",
        native_input_id: "control-plane:continuity-race:#{suffix}",
        occurred_at: @now,
        turn_ref: turn_ref
      })

    {:ok, input} =
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
        source: %{kind: "control_plane", ref: "continuity-race"},
        source_capabilities: %{},
        source_item_ref: command.native_input_id
      })

    {:ok, _receipt} = Inbox.record(input, execution_mode: :live)
    {:ok, transition} = Episodes.apply(%{command | payload: Input.document(input)})

    {:ok, _session} =
      Custody.pin_episode(episode_id, "ryker-read", String.duplicate("a", 64), nil)

    {:ok, claim} = Custody.claim_next("worker:continuity-race:#{suffix}", 60, :work)
    {:ok, submission} = SubmissionBuilder.build(claim)

    %{
      claim: claim,
      episode: transition.episode,
      native_input_id: command.native_input_id,
      submission: submission,
      state_token: "state:#{claim.turn.id}",
      suffix: suffix
    }
  end

  defp accept!(work) do
    candidate = ~s({"delivery":"none","decision_reason":"continuity updated"})
    sha256 = digest(candidate)
    claim = work.claim

    {:ok, frozen} =
      Custody.freeze_submission(
        work.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        work.submission
      )

    :ok = KnowledgeSnapshot.expose_submission(%{claim | turn: frozen})

    {:ok, session} =
      Custody.bind_session(
        work.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        claim.session.generation,
        claim.session.create_generation,
        "coop-session:continuity-race:#{work.suffix}"
      )

    {:ok, turn} =
      Custody.bind_turn(
        work.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        claim.turn.submit_generation,
        "coop-turn:continuity-race:#{work.suffix}"
      )

    {:ok, _turn} =
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

    {:ok, result} = Result.new(:none, nil, "continuity updated")

    {:ok, _turn} =
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
               "validation-receipt:continuity-race:#{work.suffix}"
             )

    accepted
  end

  defp insert_summary!(work, context, situation) do
    id = Ecto.UUID.generate()
    state = state(situation)

    Repo.insert!(%ConversationSummary{
      conversation_ref: context.conversation_ref,
      id: id,
      identity_key: context.identity_key,
      ref: "continuity:#{id}",
      source_dependencies: [],
      source_episode_id: work.episode.id,
      source_result_ref: "result:continuity-race:#{work.suffix}",
      state: state,
      state_fingerprint: CanonicalJSON.digest(state),
      thread_ref: context.thread_ref,
      transport: context.transport,
      visibility: context.visibility,
      workspace_ref: context.workspace_ref
    })
  end

  defp state(situation) do
    %{
      "active_topics" => ["Ryker"],
      "decisions" => ["Keep continuity derived"],
      "evidence_refs" => [],
      "goal" => "Ship the requested behavior",
      "open_loops" => [],
      "participants" => ["operator"],
      "purpose" => "Product development",
      "situation" => situation,
      "topology" => ["Ryker uses PostgreSQL"],
      "unresolved_questions" => []
    }
  end

  defp cleanup!(works, identity_key) do
    episode_ids = Enum.map(works, & &1.episode.id)
    native_input_ids = Enum.map(works, & &1.native_input_id)

    Repo.delete_all(
      from(draft in ConversationSummaryDraft, where: draft.episode_id in ^episode_ids)
    )

    Repo.delete_all(
      from(summary in ConversationSummary, where: summary.identity_key == ^identity_key)
    )

    session_ids =
      Repo.all(
        from(session in Session, where: session.episode_id in ^episode_ids, select: session.id)
      )

    Repo.delete_all(from(row in KnowledgeExposure, where: row.session_id in ^session_ids))
    Repo.delete_all(from(row in SourceExposure, where: row.session_id in ^session_ids))
    Repo.delete_all(from(record in Record, where: record.episode_id in ^episode_ids))
    Repo.delete_all(from(turn in Turn, where: turn.episode_id in ^episode_ids))
    Repo.delete_all(from(session in Session, where: session.episode_id in ^episode_ids))
    Repo.delete_all(from(event in Event, where: event.episode_id in ^episode_ids))
    Repo.delete_all(from(episode in Episode, where: episode.id in ^episode_ids))
    delete_entries!(from(entry in Entry, where: entry.native_input_id in ^native_input_ids))
    Repo.delete_all(from(usage in Execution, where: usage.episode_id in ^episode_ids))
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
