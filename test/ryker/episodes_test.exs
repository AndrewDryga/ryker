defmodule Ryker.EpisodesTest do
  use Ryker.DataCase, async: true

  alias Ryker.Episodes
  alias Ryker.Episodes.{EpisodeChangeset, Event, EventChangeset, Reducer}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures

  test "a lost response retry returns one durable event" do
    # Production generated duplicate notices and repeated work when a write
    # succeeded but its response was lost. The natural source identity must be
    # enough to reconcile that retry without another event.
    command = EpisodeFixtures.admit_input()

    assert {:ok, first} = Episodes.apply(command)
    assert first.status == :applied
    assert {:ok, duplicate} = Episodes.apply(command)
    assert duplicate.status == :duplicate
    assert duplicate.event.id == first.event.id

    assert {:ok, episode} = Episodes.fetch_by_key(command.episode_key)
    assert episode.semantic_version == 1
    assert [%{sequence: 1, kind: :input_admitted}] = Episodes.list_events(command.episode_key)
  end

  test "reaction feedback is durably idempotent without creating another turn" do
    input = EpisodeFixtures.admit_input()
    assert {:ok, admitted} = Episodes.apply(input)

    reaction = EpisodeFixtures.record_reaction()
    assert {:ok, recorded} = Episodes.apply(reaction)
    assert recorded.status == :applied
    assert recorded.episode.owner_ref == admitted.episode.owner_ref

    assert {:ok, duplicate} = Episodes.apply(reaction)
    assert duplicate.status == :duplicate
    assert duplicate.event.id == recorded.event.id

    assert Enum.map(Episodes.list_events(input.episode_key), & &1.kind) == [
             :input_admitted,
             :reaction_recorded
           ]
  end

  test "ordinary whole-second timestamps persist without crashing" do
    # DateTimes parsed without a fractional part are valid input. Ecto's
    # utc_datetime_usec type requires precision six, so the kernel normalizes
    # the command before it reaches either fingerprints or persistence.
    command = EpisodeFixtures.admit_input(%{occurred_at: ~U[2026-08-27 12:00:00Z]})

    assert {:ok, transition} = Episodes.apply(command)
    assert transition.event.occurred_at.microsecond == {0, 6}

    assert {:ok, duplicate} = Episodes.apply(command)
    assert duplicate.status == :duplicate
    assert length(Episodes.list_events(command.episode_key)) == 1
  end

  test "invalid commands return tagged errors before identity or storage work" do
    scalar_payload = EpisodeFixtures.admit_input(%{payload: "not-an-object"})
    invalid_payload = EpisodeFixtures.admit_input(%{payload: %{"value" => {:tuple, 1}}})
    postgres_poison = EpisodeFixtures.admit_input(%{payload: %{"value" => <<0>>}})
    invalid_utf8 = EpisodeFixtures.admit_input(%{episode_key: <<255>>})

    assert Episodes.apply(scalar_payload) == {:error, {:invalid_command, :payload}}
    assert Episodes.apply(invalid_payload) == {:error, {:invalid_command, :payload}}
    assert Episodes.apply(postgres_poison) == {:error, {:invalid_command, :payload}}
    assert Episodes.apply(invalid_utf8) == {:error, {:invalid_command, :episode_key}}
    assert Episodes.apply(%{unknown: "command"}) == {:error, {:invalid_command, :type}}
    assert Episodes.fetch_by_key(invalid_payload.episode_key) == :error
  end

  test "a stale source revision is rejected without another durable event" do
    newest = EpisodeFixtures.admit_input(%{revision: 2})
    assert {:ok, _transition} = Episodes.apply(newest)

    stale =
      EpisodeFixtures.admit_input(%{
        occurred_at: ~U[2026-08-27 11:59:59.000000Z],
        payload: %{"status" => "older"},
        revision: 1
      })

    assert {:error, {:stale_input_revision, _details}} = Episodes.apply(stale)
    assert length(Episodes.list_events(newest.episode_key)) == 1
  end

  test "a changed retry cannot overwrite the accepted source revision" do
    command = EpisodeFixtures.admit_input()
    assert {:ok, first} = Episodes.apply(command)
    changed = %{command | payload: %{"status" => "resolved"}}

    assert {:error, {:idempotency_conflict, details}} = Episodes.apply(changed)
    assert details[:dedupe_key] == first.event.dedupe_key

    assert {:ok, episode} = Episodes.fetch_by_key(command.episode_key)
    assert episode.semantic_version == 1
    assert length(Episodes.list_events(command.episode_key)) == 1
  end

  test "the stored canonical command still matches its accepted fingerprint" do
    values = [%{"nested" => %{"value" => 1}}, %{"number" => -0.0}, %{"number" => 1.0e20}]

    Enum.with_index(values, fn payload, index ->
      command =
        EpisodeFixtures.admit_input(%{
          episode_id: Ecto.UUID.generate(),
          episode_key: "canonical-storage:#{index}",
          native_input_id: "canonical-source:#{index}",
          payload: payload
        })

      assert {:ok, accepted} = Episodes.apply(command)
      [stored] = Episodes.list_events(command.episode_key)
      assert stored.payload == accepted.event.payload
      assert Ryker.CanonicalJSON.digest(stored.payload) == stored.fingerprint
    end)
  end

  test "the destination and delivery owner survive every committed transition" do
    # Scheduled verification replies were widened to the channel in production.
    # This proves the bound thread and delivery custody are committed together.
    input = EpisodeFixtures.admit_input()
    assert {:ok, _transition} = Episodes.apply(input)
    assert {:ok, accepted} = Episodes.apply(EpisodeFixtures.accept_result())
    assert accepted.episode.owner_kind == :delivery
    assert accepted.episode.state == :working

    assert {:ok, delivered} = Episodes.apply(EpisodeFixtures.confirm_delivery())
    assert delivered.episode.state == :complete
    assert delivered.episode.destination_thread_ref == input.destination.thread_ref
    assert Enum.map(Episodes.list_events(input.episode_key), & &1.sequence) == [1, 2, 3]
  end

  test "a failed linked-history write leaves no ownerless episode" do
    invalid =
      EpisodeFixtures.admit_input(%{
        linked_episode_id: "01993d45-d400-7000-8000-000000009999"
      })

    assert {:error, {:persistence_failed, :episode, errors}} = Episodes.apply(invalid)

    assert {:linked_episode_id, {"does not exist", _metadata}} =
             List.keyfind(errors, :linked_episode_id, 0)

    assert Episodes.fetch_by_key(invalid.episode_key) == :error
  end

  test "database integrity rejects a self-linked episode even outside the reducer" do
    input = EpisodeFixtures.admit_input()
    assert {:ok, transition} = Reducer.decide(nil, input)
    self_linked = %{transition.episode | linked_episode_id: transition.episode.id}

    assert {:error, changeset} = Repo.insert(EpisodeChangeset.insert(self_linked))

    assert {:linked_episode_id, {"is invalid", _metadata}} =
             List.keyfind(changeset.errors, :linked_episode_id, 0)

    assert Episodes.fetch_by_key(input.episode_key) == :error
  end

  test "a reused episode id returns a tagged conflict instead of raising" do
    first = EpisodeFixtures.admit_input()
    assert {:ok, _transition} = Episodes.apply(first)

    reused =
      EpisodeFixtures.admit_input(%{
        episode_key: "grafana:rule-2:fingerprint-2:cycle-1",
        native_input_id: "slack:event:other",
        turn_ref: "turn-other"
      })

    assert {:error, {:persistence_failed, :episode, errors}} = Episodes.apply(reused)
    assert {:id, {"has already been taken", _metadata}} = List.keyfind(errors, :id, 0)
    assert Episodes.fetch_by_key(reused.episode_key) == :error
  end

  test "an event insert failure rolls the projection update back" do
    input = EpisodeFixtures.admit_input()
    assert {:ok, admitted} = Episodes.apply(input)

    occupied = %Event{
      sequence: admitted.episode.next_sequence,
      kind: :owner_transferred,
      dedupe_key: "owner-transfer:occupied-sequence",
      fingerprint: String.duplicate("a", 64),
      payload: %{"kind" => "test-sequence-occupant"},
      occurred_at: ~U[2026-08-27 12:00:01.000000Z]
    }

    assert {:ok, _event} =
             occupied
             |> EventChangeset.insert(admitted.episode.id)
             |> Repo.insert()

    assert {:error, {:persistence_failed, :event, _errors}} =
             Episodes.apply(EpisodeFixtures.transfer_owner())

    assert {:ok, stored} = Episodes.fetch_by_key(input.episode_key)
    assert stored.owner_ref == "turn-1"
    assert stored.next_sequence == 2
  end

  test "a related command batch either commits every transition or none" do
    input =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "atomic-batch:#{Ecto.UUID.generate()}",
        native_input_id: "slack:event:atomic-batch"
      })

    invalid_wait =
      EpisodeFixtures.start_wait(%{
        episode_key: input.episode_key,
        expected_turn_ref: "a-turn-that-never-owned-this-episode"
      })

    assert {:error, {:stale_turn, _details}} = Episodes.apply_batch([input, invalid_wait])
    assert Episodes.fetch_by_key(input.episode_key) == :error
    assert Episodes.list_events(input.episode_key) == []
  end

  test "a rejected no-op does not consume durable owner handoff custody" do
    input = EpisodeFixtures.admit_input()
    assert {:ok, _transition} = Episodes.apply(input)

    unchanged =
      EpisodeFixtures.transfer_owner(%{
        new_owner: %{kind: :turn, ref: "turn-1"},
        transfer_ref: "no-op-transfer"
      })

    assert Episodes.apply(unchanged) == {:error, :owner_unchanged}
    assert {:ok, moved} = Episodes.apply(EpisodeFixtures.transfer_owner())
    assert moved.episode.owner_ref == "turn-1-replacement"

    assert Enum.map(Episodes.list_events(input.episode_key), & &1.kind) == [
             :input_admitted,
             :owner_transferred
           ]
  end

  test "cancellation is persisted once and rejects the old turn" do
    input = EpisodeFixtures.admit_input()
    assert {:ok, _admitted} = Episodes.apply(input)
    cancel = EpisodeFixtures.cancel_episode()
    assert {:ok, applied} = Episodes.apply(cancel)
    assert applied.episode.state == :cancelled

    assert {:ok, duplicate} = Episodes.apply(cancel)
    assert duplicate.status == :duplicate
    assert duplicate.event.id == applied.event.id

    assert {:error, {:stale_turn, _details}} = Episodes.apply(EpisodeFixtures.accept_result())

    assert Enum.map(Episodes.list_events(input.episode_key), & &1.kind) == [
             :input_admitted,
             :episode_cancelled
           ]
  end
end
