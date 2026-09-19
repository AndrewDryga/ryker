defmodule Ryker.State.MemoriesConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Accounting.Execution
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

  alias Ryker.State.Memories.Reviews
  alias Ryker.Work.{Custody, DeliveryReceipt, Result, Session, Submission, Turn}

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

  # Two offers for the same fact confirmed at once. Before confirm/1 took the
  # review maintenance lock, both passed supersede_existing (neither row was
  # committed yet) and the second insert died on the active-identity index:
  # the operator's second Save press failed instead of replacing the first.
  test "a confirmation that races another of the same fact supersedes it instead of failing" do
    Sandbox.unboxed_run(Repo, fn ->
      fixture = delivered_offer_fixture!()
      parent = self()

      # The first confirmation, caught after inserting its fact and before
      # committing, holding the lock every confirmation takes first.
      first =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock($1)", [@review_advisory_lock])
            insert_confirmed_entry!(fixture, fixture.first_offer)
            send(parent, {:first_inserted, backend_pid()})

            receive do
              :commit -> :ok
            end
          end)
        end)

      assert_receive {:first_inserted, first_backend}, 5_000

      second =
        unboxed_task(fn ->
          send(parent, {:second_started, backend_pid()})
          Memories.confirm(confirmation(fixture, fixture.second_offer, "second"))
        end)

      try do
        assert_receive {:second_started, second_backend}, 5_000
        await_blocked_by(second_backend, first_backend)
        send(first.pid, :commit)
        assert {:ok, :ok} = Task.await(first, 5_000)
        assert {:ok, %{status: :confirmed, memory: replacement}} = Task.await(second, 5_000)
        assert replacement.payload["value"] == "second"

        assert Repo.get_by!(MemoryEntry, offer_record_id: fixture.first_offer.id).status ==
                 :superseded
      after
        send(first.pid, :commit)
        stop_tasks([first, second])
        cleanup_fixture!(fixture)
      end
    end)
  end

  # Two open memory offers for one fact, on a turn accepted and delivered
  # through custody so the card's receipt names the episode's channel.
  defp delivered_offer_fixture! do
    suffix = Ecto.UUID.generate()
    episode_id = Ecto.UUID.generate()
    workspace_ref = "slack:TCONF#{String.replace(suffix, "-", "")}"
    slack_workspace_ref = String.replace_prefix(workspace_ref, "slack:", "")
    conversation_ref = "#{workspace_ref}:C1"
    thread_ref = "thread:confirm-concurrency"
    now = DateTime.utc_now()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: conversation_ref,
                   thread_ref: thread_ref,
                   transport: "slack"
                 },
                 episode_id: episode_id,
                 episode_key: "confirm-concurrency:#{suffix}",
                 native_input_id: "source:confirm-concurrency:#{suffix}",
                 occurred_at: now,
                 turn_ref: "turn:confirm-concurrency:#{suffix}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "confirm-concurrency", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:confirm-concurrency:#{suffix}", 60, :work)

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

    [first_offer, second_offer] =
      Enum.map(["first", "second"], fn value ->
        assert {:ok, record} =
                 Records.create(
                   Records.token(claim.turn),
                   "confirm-concurrency-#{value}",
                   "memory_offer",
                   %{
                     "expires_in" => "30d",
                     "kind" => "repository_binding",
                     "repository" => nil,
                     "scope" => "conversation",
                     "subject" => "primary_repository",
                     "value" => value,
                     "visibility" => "conversation"
                   }
                 )

        record
      end)

    receipt =
      deliver!(
        claim,
        transition.episode,
        suffix,
        [first_offer, second_offer],
        conversation_ref,
        thread_ref
      )

    %{
      channel_ref: "C1",
      conversation_ref: conversation_ref,
      episode: transition.episode,
      episode_id: episode_id,
      first_offer: first_offer,
      receipt: receipt,
      second_offer: second_offer,
      slack_workspace_ref: slack_workspace_ref,
      thread_ref: thread_ref,
      turn_id: claim.turn.id,
      workspace_ref: workspace_ref
    }
  end

  defp deliver!(claim, episode, suffix, records, conversation_ref, thread_ref) do
    {:ok, submission} =
      Submission.new(
        %{"episode_id" => episode.id},
        "Offer the exact memory mappings for confirmation.",
        %{"type" => "object"},
        "work-final-live-v2"
      )

    {:ok, _turn} =
      Custody.freeze_submission(episode.id, claim.turn.turn_ref, claim.lease_ref, submission)

    {:ok, session} =
      Custody.bind_session(
        episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        claim.session.generation,
        claim.session.create_generation,
        "coop-session:confirm-concurrency:#{suffix}"
      )

    {:ok, turn} =
      Custody.bind_turn(
        episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        claim.turn.submit_generation,
        "coop-turn:confirm-concurrency:#{suffix}"
      )

    candidate = ~s({"delivery":"reply","message":"I can remember that after confirmation."})
    sha256 = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)

    {:ok, _turn} =
      Custody.stage_candidate(
        episode.id,
        turn.turn_ref,
        claim.lease_ref,
        nil,
        nil,
        candidate,
        sha256,
        1
      )

    {:ok, result} =
      Result.new(:reply, %{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "I can remember that after confirmation.",
        "outcome" => %{
          "artifact_refs" => [],
          "record_refs" => Enum.map(records, & &1.ref),
          "state" => "complete"
        }
      })

    {:ok, _turn} =
      Custody.prepare_validation(
        episode.id,
        turn.turn_ref,
        claim.lease_ref,
        sha256,
        1,
        :accept,
        result
      )

    {:ok, accepted} =
      Custody.accept_result(
        episode.id,
        episode.key,
        turn.turn_ref,
        claim.lease_ref,
        sha256,
        1,
        "validation-receipt:confirm-concurrency:#{suffix}"
      )

    {:ok, delivery_claim} =
      Custody.claim_next("delivery:confirm-concurrency:#{suffix}", 60, :delivery)

    {:ok, receipt} =
      DeliveryReceipt.new(
        accepted.turn.delivery_ref,
        "slack",
        conversation_ref,
        thread_ref,
        "1787832001.000200"
      )

    {:ok, _settled} =
      Custody.confirm_delivery(
        episode.id,
        episode.key,
        turn.turn_ref,
        delivery_claim.lease_ref,
        receipt
      )

    %{
      "conversation_ref" => conversation_ref,
      "message_ref" => "1787832001.000200",
      "thread_ref" => thread_ref,
      "transport" => "slack"
    }
  end

  defp confirmation(fixture, record, suffix) do
    %{
      actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:confirm-concurrency:#{suffix}",
      occurred_at: DateTime.utc_now(),
      record_ref: record.ref,
      target: %{
        conversation_ref: fixture.receipt["conversation_ref"],
        message_ref: fixture.receipt["message_ref"],
        thread_ref: fixture.receipt["thread_ref"],
        transport: fixture.receipt["transport"]
      }
    }
  end

  # The row confirm/1 inserts for an offer, as the first confirmation would
  # have it just before committing.
  defp insert_confirmed_entry!(fixture, offer) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()
    payload = %{"value" => offer.payload["value"]}

    %{
      confirmation_ref: "interaction:confirm-concurrency:first",
      confirmed_at: now,
      confirmed_by_actor_ref: "slack:user:U123",
      expires_at: DateTime.add(now, 30, :day),
      id: id,
      kind: :repository_binding,
      offer_record_id: offer.id,
      payload: payload,
      payload_fingerprint: CanonicalJSON.digest(payload),
      ref: "memory:#{id}",
      scope_kind: :conversation,
      scope_ref: fixture.conversation_ref,
      source_conversation_ref: fixture.conversation_ref,
      source_message_ref: fixture.receipt["message_ref"],
      source_thread_ref: fixture.thread_ref,
      source_transport: "slack",
      status: :active,
      subject: "primary_repository",
      visibility: :conversation,
      workspace_ref: fixture.workspace_ref
    }
    |> MemoryEntryChangeset.insert()
    |> Repo.insert!()
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

    assert {:ok, %{created: 2}} = Reviews.refresh_reviews(workspace_ref, 60)
    review_refs = Enum.map(Reviews.list_reviews(workspace_ref), & &1["review_ref"])

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
    Repo.delete_all(from(usage in Execution, where: usage.episode_id == ^fixture.episode_id))
  end
end
