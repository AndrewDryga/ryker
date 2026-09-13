defmodule Ryker.Slack.IncidentRoomsConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Accounting.Execution
  alias Ryker.Episodes
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.Input
  alias Ryker.Repo
  alias Ryker.Slack.{IncidentRoom, IncidentRooms}
  alias Ryker.State.{KnowledgeSnapshot, Record, Records}
  alias Ryker.Work.{Custody, DeliveryReceipt, Result, Session, SubmissionBuilder, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @policy_digest String.duplicate("b", 64)

  # One incident offer carries two mutually exclusive controls, and the only
  # thing keeping a double click from starting both is `investigate_locked`'s
  # own locking: the workspace advisory lock, then `FOR UPDATE` on the offer.
  # Sequential tests cannot tell a lock from a lucky read order, and this state
  # had only sequential proof — the 2026-09-12 audit found a card state the
  # catalog claimed and nothing verified ("the parked state clears native
  # activity") was simply false, and a thread had been told "is working..."
  # every 90 seconds ever since. Two started paths would be worse than a wrong
  # line: an incident room and a thread investigation for one press, each
  # spending attempts on the same incident.
  test "two concurrent incident choices start exactly one path" do
    Sandbox.unboxed_run(Repo, fn ->
      occupied = non_empty_tables()
      fixture = delivered_offer!()
      parent = self()

      # Hold exactly the offer row `lock_offer` locks, so the in-place choice
      # has to wait for it rather than read the record as it was.
      holder = unboxed_task(fn -> hold_offer!(fixture.record.ref, parent) end)
      assert_receive {:holding, holder_backend}, 5_000

      investigation =
        unboxed_task(fn ->
          send(parent, {:investigation_backend, backend_pid()})
          IncidentRooms.investigate(investigate(fixture))
        end)

      assert_receive {:investigation_backend, investigation_backend}, 5_000
      await_blocked_by(investigation_backend, holder_backend)

      # The in-place choice now holds the workspace lock while it waits, so the
      # opposite click queues behind it instead of opening a room beside it.
      room =
        unboxed_task(fn ->
          send(parent, {:room_backend, backend_pid()})
          IncidentRooms.request(request(fixture))
        end)

      assert_receive {:room_backend, room_backend}, 5_000
      await_blocked_by(room_backend, investigation_backend)

      try do
        send(holder.pid, :release)
        assert {:ok, :released} = Task.await(holder, 10_000)

        assert {:ok, confirmation} = Task.await(investigation, 10_000)
        assert confirmation.status == :confirmed

        # The loser is refused, not served: no second room and no second offer.
        assert Task.await(room, 10_000) == {:error, :incident_offer_stale}

        record = Repo.get!(Record, fixture.record.id)
        assert record.status == :confirmed
        assert record.confirmed_episode_id == confirmation.episode.id
        refute Repo.get_by(IncidentRoom, record_id: record.id)

        assert Repo.aggregate(
                 from(episode in Episode,
                   where: episode.linked_episode_id == ^fixture.episode.id
                 ),
                 :count
               ) == 1
      after
        stop_tasks([holder, investigation, room])
        cleanup!(fixture)
      end

      # The check that would have caught the orphaned accounting row below on
      # its first run, stated as the invariant it belongs to rather than as a
      # list of tables somebody has to remember to extend, and naming the table
      # so the next reader is not left to find it the way this one was found.
      leaked = non_empty_tables() -- occupied

      assert leaked == [],
             "unboxed work must leave the database as it found it, " <>
               "but #{inspect(leaked)} still holds rows"
    end)
  end

  defp hold_offer!(record_ref, parent) do
    Repo.transaction(fn ->
      Repo.one!(from(record in Record, where: record.ref == ^record_ref, lock: "FOR UPDATE"))
      send(parent, {:holding, backend_pid()})

      receive do
        :release -> :released
      end
    end)
  end

  defp investigate(fixture) do
    %{
      actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:investigate",
      occurred_at: DateTime.add(@now, 2, :second),
      policy: %{digest: @policy_digest, name: "incident-investigate"},
      record_ref: fixture.record.ref,
      target: target(fixture),
      workspace_ref: "T123"
    }
  end

  defp request(fixture) do
    %{
      actor_ref: "slack:user:U123",
      bot_user_ref: "U-BOT",
      channel_prefix: "ems",
      confirmation_ref: "interaction:incident",
      invite_user_refs: ["U300"],
      maximum_open_rooms: 25,
      occurred_at: DateTime.add(@now, 2, :second),
      policy: %{digest: @policy_digest, name: "incident-investigate"},
      private: true,
      record_ref: fixture.record.ref,
      target: target(fixture),
      workspace_ref: "T123"
    }
  end

  defp target(fixture) do
    %{
      conversation_ref: "slack:T123:C456",
      message_ref: fixture.receipt["message_ref"],
      thread_ref: "1787832000.000100",
      transport: "slack"
    }
  end

  # The genuine producing condition: one incident offer recorded by a work turn
  # and settled by a real Slack delivery receipt, which is what both controls
  # are authorized against.
  defp delivered_offer! do
    episode_id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        actor_ref: "slack:user:U123",
        destination: %{
          conversation_ref: "slack:T123:C456",
          thread_ref: "1787832000.000100",
          transport: "slack"
        },
        episode_id: episode_id,
        episode_key: "incident-race-source:#{episode_id}",
        native_input_id: "slack-message:incident-race:#{episode_id}",
        occurred_at: @now,
        turn_ref: "turn:incident-race:#{episode_id}"
      })

    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U123"},
               content: command.payload,
               destination: command.destination,
               event_kind: :message,
               event_ref: "incident-race-source:#{episode_id}",
               native_input_id: command.native_input_id,
               occurred_at: command.occurred_at,
               occurred_at_source: :source,
               revision: command.revision,
               source: %{kind: "slack", ref: "T123"},
               source_capabilities: %{},
               source_item_ref: "1787832000.000100"
             })

    assert {:ok, source} = Inbox.record(input)
    command = %{command | payload: Input.document(input)}
    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "ryker-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:incident-race:#{episode_id}", 60, :work)

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "incident-offer", "task_offer", %{
               "kind" => "incident",
               "prompt" => "Investigate checkout errors and coordinate responders.",
               "repository" => nil,
               "title" => "Checkout errors"
             })

    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, frozen_turn} =
             Custody.freeze_submission(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert :ok = KnowledgeSnapshot.expose_submission(%{claim | turn: frozen_turn})

    assert {:ok, session} =
             Custody.bind_session(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:incident-race:#{episode_id}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:incident-race:#{episode_id}"
             )

    candidate = ~s({"delivery":"reply","message":"I can open an incident room."})
    sha256 = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} =
             Result.new(:reply, %{
               "decision_reason" => nil,
               "delivery" => "reply",
               "message" => "I can open an incident room.",
               "outcome" => %{
                 "artifact_refs" => [],
                 "record_refs" => [record.ref],
                 "state" => "complete"
               }
             })

    assert {:ok, _turn} =
             Custody.prepare_validation(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               episode_id,
               transition.episode.key,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:incident-race:#{episode_id}"
             )

    assert {:ok, delivery_claim} =
             Custody.claim_next("delivery:incident-race:#{episode_id}", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "slack",
               "slack:T123:C456",
               "1787832000.000100",
               "1787832001.000100"
             )

    assert {:ok, settled} =
             Custody.confirm_delivery(
               episode_id,
               transition.episode.key,
               turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    %{episode: settled.episode, input_entry: source.entry, receipt: receipt, record: record}
  end

  # Unboxed work commits for real and owns its cleanup: rows left behind here
  # fail the next suite that needs an empty database.
  defp cleanup!(fixture) do
    linked =
      Repo.all(
        from(episode in Episode,
          where: episode.linked_episode_id == ^fixture.episode.id,
          select: episode.id
        )
      )

    episode_ids = [fixture.episode.id | linked]

    Repo.delete_all(from(room in IncidentRoom, where: room.record_id == ^fixture.record.id))

    # Accounting deliberately has no cascading foreign key, so accepting a
    # result leaves a row that outlives every episode row keyed to it. Missing
    # it turned the repository gate red on 18376794: `Evals.WorldRunner` refuses
    # to start unless every application table is empty, and 45 of the 57
    # world-runner tests failed with
    # `:model_world_requires_an_empty_disposable_database` for one orphaned row.
    Repo.delete_all(
      from(usage in Execution,
        where: usage.episode_id in ^episode_ids or usage.source_id == ^fixture.input_entry.id
      )
    )

    Repo.delete_all(from(record in Record, where: record.episode_id in ^episode_ids))
    Repo.delete_all(from(turn in Turn, where: turn.episode_id in ^episode_ids))
    Repo.delete_all(from(session in Session, where: session.episode_id in ^episode_ids))
    Repo.delete_all(from(event in Event, where: event.episode_id in ^episode_ids))
    Repo.delete_all(from(episode in Episode, where: episode.id in ^linked))
    Repo.delete_all(from(episode in Episode, where: episode.id == ^fixture.episode.id))
    delete_entries!(from(entry in Entry, where: entry.id == ^fixture.input_entry.id))
  end

  # Exactly the query `Evals.WorldRunner.disposable_database/1` runs before a
  # world case, so this test is held to the standard that refused it.
  defp non_empty_tables do
    %{rows: rows} =
      Repo.query!("""
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = current_schema()
        AND table_type = 'BASE TABLE'
        AND table_name <> 'schema_migrations'
      ORDER BY table_name
      """)

    rows
    |> Enum.map(fn [table] -> table end)
    |> Enum.reject(fn table ->
      quoted = ~s("#{String.replace(table, "\"", "\"\"")}")
      %{rows: [[empty]]} = Repo.query!("SELECT NOT EXISTS (SELECT 1 FROM #{quoted} LIMIT 1)")
      empty
    end)
  end
end
