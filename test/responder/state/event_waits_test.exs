defmodule Responder.State.EventWaitsTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Episodes.Episode
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.State.{EventWaits, Record, Records}
  alias Responder.Work.Custody

  test "a due durable event wait resumes once with host-owned evidence" do
    {:ok, %{rows: [[now]]}} = Repo.query("SELECT clock_timestamp()")
    occurred_at = DateTime.add(now, -10, :second)
    deadline = DateTime.add(now, 3_600, :second)
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:event-wait-source:#{episode_id}"

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "event-wait-source:#{episode_id}",
                 native_input_id: "event-wait-input:#{episode_id}",
                 occurred_at: DateTime.add(occurred_at, -1, :second),
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "responder-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:event-wait", 60, :work)

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "wait", "event_wait", %{
               "deadline_at" => DateTime.to_iso8601(deadline),
               "event_matcher" => %{"deployment" => "responder"},
               "kind" => "deployment_health",
               "verification" => "Verify the deployment is healthy."
             })

    assert {:ok, waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 deadline_at: deadline,
                 episode_key: transition.episode.key,
                 expected_turn_ref: turn_ref,
                 kind: :event,
                 occurred_at: occurred_at,
                 wait_ref: record.ref
               })
             )

    assert waiting.episode.state == :waiting_for_event

    # Advance the durable deadline without sleeping; the worker itself still
    # decides eligibility from PostgreSQL time.
    Repo.update_all(
      from(episode in Episode, where: episode.id == ^episode_id),
      set: [owner_deadline_at: DateTime.add(now, -1, :second)]
    )

    assert {:ok, resumed} = EventWaits.resume_due()
    assert resumed.episode.state == :working
    assert resumed.episode.owner_kind == :turn
    assert resumed.record.status == :answered

    events = Episodes.list_events(transition.episode.key)

    assert Enum.map(events, & &1.kind) == [
             :input_admitted,
             :event_wait_started,
             :input_admitted,
             :wait_resumed
           ]

    assert List.last(events).payload["resolution_ref"] =~ "admit_input:"

    wakeup = Enum.at(events, 2)
    assert wakeup.payload["payload"]["content"]["kind"] == "deadline_elapsed"
    assert wakeup.payload["payload"]["content"]["event_wait_ref"] == record.ref

    assert Repo.get!(Record, record.id).status == :answered
    assert EventWaits.resume_due() == {:ok, :idle}
  end
end
