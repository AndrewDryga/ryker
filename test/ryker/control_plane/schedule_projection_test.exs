defmodule Ryker.ControlPlane.ScheduleProjectionTest do
  @moduledoc """
  The Schedules list and one schedule's page as the database answers them:
  which schedules each view holds, in which order, and the times the page
  words in the schedule's own time zone.
  """
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.ControlPlane.ScheduleProjection
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.QueryWork
  alias Ryker.Schedules.Schedule
  alias Ryker.Schedules.ScheduleOccurrenceChangeset
  alias Ryker.Work.{Session, Turn}

  test "current schedules put the next run first and paused ones after it, never alphabetical by status" do
    # Until 2026-09-24 the list sorted on the status column's text, so Paused
    # sat below Deleted and a live schedule could be buried under history.
    source = SavedEntities.source!("slack:T123:C456")
    SavedEntities.schedule!(source, "Later", 5)
    SavedEntities.schedule!(source, "Sooner", 1)
    SavedEntities.schedule!(source, "Paused", 0, status: :paused)

    for {status, index} <- [deleted: 2, completed: 3, expired: 4] do
      SavedEntities.schedule!(source, "Ended #{status}", index, status: status)
    end

    assert titles(ScheduleProjection.list(%{"view" => "current"})) == [
             "Sooner",
             "Later",
             "Paused"
           ]

    # Past is newest first: the schedule that ended most recently leads.
    assert titles(ScheduleProjection.list(%{"view" => "past"})) == [
             "Ended expired",
             "Ended completed",
             "Ended deleted"
           ]

    # Activity's "Coming up" still asks for active schedules by status alone.
    assert titles(ScheduleProjection.list(%{"status" => "active"})) == ["Sooner", "Later"]
    assert titles(ScheduleProjection.list(%{"view" => "current", "q" => "soon"})) == ["Sooner"]
  end

  test "a schedule's times are read in its own time zone, so the next run matches how often it runs" do
    # "Every day at 09:00 Berlin time" next to a next run of "07:00 UTC" reads
    # as a contradiction; the database converts, because the host has no zone
    # database of its own.
    source = SavedEntities.source!("slack:T123:C456")
    schedule = SavedEntities.schedule!(source, "Morning summary", 1)

    Repo.update_all(from(saved in Schedule, where: saved.id == ^schedule.id),
      set: [
        timezone: "Europe/Berlin",
        recurrence: %{"kind" => "daily", "time" => "09:00:00"},
        next_occurrence_at: ~U[2026-09-25 07:00:00.000000Z],
        expires_at: ~U[2026-10-31 08:00:00.000000Z]
      ]
    )

    %{
      id: Ecto.UUID.generate(),
      missed_reason: "outside_misfire_grace",
      ref: "schedule-run:missed:#{schedule.id}",
      schedule_id: schedule.id,
      scheduled_for: ~U[2026-09-24 07:00:00.000000Z],
      status: :missed
    }
    |> ScheduleOccurrenceChangeset.insert()
    |> Repo.insert!()

    assert [item] = ScheduleProjection.list(%{"view" => "current"})
    assert item.next_local == ~N[2026-09-25 09:00:00.000000]
    assert item.recurrence == %{"kind" => "daily", "time" => "09:00:00"}
    assert item.task == "Inspect Morning summary."
    assert %NaiveDateTime{} = item.now_local

    assert {:ok, %{schedule: detail, occurrences: [run]}} = ScheduleProjection.fetch(schedule.ref)
    assert detail.next_local == ~N[2026-09-25 09:00:00.000000]
    # The clocks change on 25 October, so the last day runs on winter time.
    assert detail.expires_local == ~N[2026-10-31 09:00:00.000000]
    assert run.due_local == ~N[2026-09-24 09:00:00.000000]
    assert run.status == :missed

    assert detail.source_request.href ==
             "/timeline/" <> source.episode.id
  end

  test "a one-time schedule says its moment in its own zone even after it has run" do
    source = SavedEntities.source!("slack:T123:C456")
    schedule = SavedEntities.schedule!(source, "Release check", 1, status: :completed)

    Repo.update_all(from(saved in Schedule, where: saved.id == ^schedule.id),
      set: [
        timezone: "America/New_York",
        recurrence: %{"at" => "2026-09-25T13:30:00Z", "kind" => "once"},
        next_occurrence_at: nil
      ]
    )

    assert [item] = ScheduleProjection.list(%{"view" => "past"})
    assert item.once_local == ~N[2026-09-25 09:30:00.000000]
    assert item.next_local == nil
  end

  # Each run's latest turn was found by ranking every turn in the database, so
  # a schedule's page read the whole turns table to show its ten newest runs,
  # and read it again on every refresh (2026-10-04 review).
  test "a schedule's page reads only its own runs' turns" do
    source = SavedEntities.source!("slack:T123:C456")
    schedule = SavedEntities.schedule!(source, "Nightly check", 1)
    run = episode!()
    turn!(run, :blocked, ~U[2026-10-01 08:00:00.000000Z])
    turn!(run, :pending, ~U[2026-10-02 08:00:00.000000Z])
    for _other <- 1..8, do: turn!(episode!(), :pending, ~U[2026-10-03 08:00:00.000000Z])

    %{
      id: Ecto.UUID.generate(),
      child_episode_id: run.id,
      ref: "schedule-run:#{schedule.id}:1",
      schedule_id: schedule.id,
      scheduled_for: ~U[2026-10-02 07:59:00.000000Z],
      status: :dispatched
    }
    |> ScheduleOccurrenceChangeset.insert()
    |> Repo.insert!()

    {{:ok, %{occurrences: [shown]}}, statements} =
      QueryWork.statements(fn -> ScheduleProjection.fetch(schedule.ref) end)

    assert shown.turn_status == :pending
    # The page shows the run and names the request the schedule came from.
    shown_episodes = [run.id, source.episode.id]
    own = Repo.aggregate(from(turn in Turn, where: turn.episode_id in ^shown_episodes), :count)
    assert Repo.aggregate(Turn, :count) > own * 3
    assert QueryWork.rows_read(statements, "episode_work_turns") <= own
  end

  defp episode! do
    id = Ecto.UUID.generate()

    assert {:ok, %{episode: episode}} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "schedule-projection:" <> id,
                 native_input_id: "source:schedule-projection:" <> id,
                 turn_ref: "turn:schedule-projection:" <> id
               })
             )

    episode
  end

  defp turn!(episode, status, inserted_at) do
    session =
      Repo.insert!(%Session{
        id: Ecto.UUID.generate(),
        episode_id: episode.id,
        execution_kind: :work,
        policy: "engineering",
        policy_digest: String.duplicate("a", 64),
        external_ref: "episode:#{episode.id}:session:#{System.unique_integer([:positive])}",
        generation: System.unique_integer([:positive]),
        create_generation: 1
      })

    Repo.insert!(%Turn{
      id: Ecto.UUID.generate(),
      episode_id: episode.id,
      session_id: session.id,
      turn_ref: "work-turn:#{System.unique_integer([:positive])}",
      status: status,
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end

  defp titles(items), do: Enum.map(items, & &1.title)
end
