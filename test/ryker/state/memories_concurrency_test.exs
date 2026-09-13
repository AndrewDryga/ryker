defmodule Ryker.State.MemoriesConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelConfigurations, ChannelMembership, ChannelMembershipEvent}

  alias Ryker.State.{
    Continuity,
    ConversationSummaryDraft,
    Memories,
    MemoryEntry,
    MemoryEntryChangeset,
    MemoryReviewItem,
    Record,
    Records
  }

  alias Ryker.Work.{Custody, Session, Turn}

  @review_advisory_lock 7_152_019_552_843_112

  test "independent review resolutions serialize before taking review row locks" do
    Sandbox.unboxed_run(Repo, fn ->
      fixture = review_fixture!()
      parent = self()

      blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock($1)", [@review_advisory_lock])
            send(parent, {:review_lock_held, backend_pid()})

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive {:review_lock_held, blocker_backend}, 5_000

      contenders =
        Enum.map(fixture.review_refs, fn review_ref ->
          unboxed_task(fn ->
            backend = backend_pid()
            send(parent, {:review_resolution_started, self(), backend})

            Memories.resolve_review(
              review_ref,
              :keep,
              "operator:concurrency",
              fixture.workspace_ref
            )
          end)
        end)

      try do
        Enum.each(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:review_resolution_started, ^contender_pid, backend}, 5_000
          await_blocked_by(backend, blocker_backend)
        end)

        send(blocker.pid, :release)
        assert {:ok, _transaction} = Task.await(blocker, 5_000)

        assert Enum.all?(Enum.map(contenders, &Task.await(&1, 5_000)), fn
                 {:ok, %{status: :resolved}} -> true
                 _other -> false
               end)
      after
        send(blocker.pid, :release)
        stop_tasks([blocker | contenders])
        cleanup_fixture!(fixture)
      end
    end)
  end

  test "channel deletion takes the review lock before removing continuity" do
    Sandbox.unboxed_run(Repo, fn ->
      fixture = review_fixture!()
      parent = self()

      blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock($1)", [@review_advisory_lock])
            send(parent, {:review_lock_held, backend_pid()})

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive {:review_lock_held, blocker_backend}, 5_000

      deletion =
        unboxed_task(fn ->
          backend = backend_pid()
          send(parent, {:channel_deletion_started, backend})

          ChannelConfigurations.observe_membership(
            %{
              actor_ref: nil,
              channel_ref: fixture.channel_ref,
              event_ref: "event:delete-review-concurrency:#{Ecto.UUID.generate()}",
              kind: :deleted,
              occurred_at: DateTime.utc_now(),
              workspace_ref: fixture.slack_workspace_ref
            },
            %{default_repository: "ryker", repository_refs: ["ryker"]}
          )
        end)

      try do
        assert_receive {:channel_deletion_started, deletion_backend}, 5_000
        await_blocked_by(deletion_backend, blocker_backend)

        assert Repo.aggregate(
                 from(draft in ConversationSummaryDraft,
                   where: draft.episode_id == ^fixture.episode_id
                 ),
                 :count
               ) == 1

        send(blocker.pid, :release)
        assert {:ok, _transaction} = Task.await(blocker, 5_000)
        assert {:ok, %{membership: %{status: :deleted}}} = Task.await(deletion, 5_000)

        assert Repo.aggregate(
                 from(draft in ConversationSummaryDraft,
                   where: draft.episode_id == ^fixture.episode_id
                 ),
                 :count
               ) == 0
      after
        send(blocker.pid, :release)
        stop_tasks([blocker, deletion])
        cleanup_fixture!(fixture)
      end
    end)
  end

  defp review_fixture! do
    suffix = Ecto.UUID.generate()
    episode_id = Ecto.UUID.generate()
    workspace_ref = "slack:TREV#{String.replace(suffix, "-", "")}"
    slack_workspace_ref = String.replace_prefix(workspace_ref, "slack:", "")
    conversation_ref = "#{workspace_ref}:C1"
    now = DateTime.utc_now()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: conversation_ref,
                   thread_ref: "thread:review-concurrency",
                   transport: "slack"
                 },
                 episode_id: episode_id,
                 episode_key: "review-concurrency:#{suffix}",
                 native_input_id: "source:review-concurrency:#{suffix}",
                 occurred_at: now,
                 turn_ref: "turn:review-concurrency:#{suffix}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "review-concurrency", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:review-concurrency:#{suffix}", 60, :work)

    Repo.insert!(%ChannelMembership{
      channel_ref: "C1",
      external_shared: false,
      generation: 1,
      id: Ecto.UUID.generate(),
      joined_at: now,
      private: false,
      status: :joined,
      workspace_ref: slack_workspace_ref
    })

    assert {:ok, _draft} =
             Continuity.stage(Records.token(claim.turn), %{
               "active_topics" => ["Concurrency"],
               "decisions" => [],
               "evidence_refs" => [],
               "goal" => "Protect lock ordering",
               "open_loops" => ["Delete the channel"],
               "participants" => ["operator"],
               "purpose" => "Regression test",
               "situation" => "A continuity draft is staged",
               "topology" => ["PostgreSQL advisory locks"],
               "unresolved_questions" => []
             })

    entries =
      Enum.map(1..2, fn index ->
        payload = %{
          "expires_in" => "30d",
          "kind" => "entity_relationship",
          "repository" => nil,
          "scope" => "workspace",
          "subject" => "review-concurrency-#{index}",
          "value" => "Value #{index}",
          "visibility" => "workspace"
        }

        assert {:ok, record} =
                 Records.create(
                   Records.token(claim.turn),
                   "review-concurrency-#{index}",
                   "memory_offer",
                   payload
                 )

        id = Ecto.UUID.generate()

        %{
          confirmation_ref: "confirmation:review-concurrency:#{index}",
          confirmed_at: now,
          confirmed_by_actor_ref: "operator:concurrency",
          expires_at: DateTime.add(now, 86_400, :second),
          id: id,
          kind: :entity_relationship,
          offer_record_id: record.id,
          payload: payload,
          payload_fingerprint: CanonicalJSON.digest(payload),
          ref: "memory:#{id}",
          scope_kind: :workspace,
          scope_ref: workspace_ref,
          source_conversation_ref: conversation_ref,
          source_message_ref: "message:review-concurrency:#{index}",
          source_thread_ref: "thread:review-concurrency",
          source_transport: "slack",
          status: :active,
          subject: "review-concurrency-#{index}",
          visibility: :workspace,
          workspace_ref: workspace_ref
        }
        |> MemoryEntryChangeset.insert()
        |> Repo.insert!()
      end)

    old = DateTime.add(now, -3_600, :second)

    Repo.update_all(from(entry in MemoryEntry, where: entry.id in ^Enum.map(entries, & &1.id)),
      set: [inserted_at: old, updated_at: old]
    )

    assert {:ok, %{created: 2}} = Memories.refresh_reviews(workspace_ref, 60)
    review_refs = Enum.map(Memories.list_reviews(workspace_ref), & &1["review_ref"])

    %{
      episode_id: transition.episode.id,
      channel_ref: "C1",
      review_refs: review_refs,
      slack_workspace_ref: slack_workspace_ref,
      workspace_ref: workspace_ref
    }
  end

  defp cleanup_fixture!(fixture) do
    Repo.delete_all(
      from(event in ChannelMembershipEvent,
        where: event.workspace_ref == ^fixture.slack_workspace_ref
      )
    )

    Repo.delete_all(
      from(membership in ChannelMembership,
        where: membership.workspace_ref == ^fixture.slack_workspace_ref
      )
    )

    Repo.delete_all(
      from(review in MemoryReviewItem, where: review.workspace_ref == ^fixture.workspace_ref)
    )

    Repo.delete_all(
      from(entry in MemoryEntry, where: entry.workspace_ref == ^fixture.workspace_ref)
    )

    Repo.delete_all(from(record in Record, where: record.episode_id == ^fixture.episode_id))
    Repo.delete_all(from(turn in Turn, where: turn.episode_id == ^fixture.episode_id))
    Repo.delete_all(from(session in Session, where: session.episode_id == ^fixture.episode_id))
    Repo.delete_all(from(event in Event, where: event.episode_id == ^fixture.episode_id))
    Repo.delete_all(from(episode in Episode, where: episode.id == ^fixture.episode_id))
  end
end
