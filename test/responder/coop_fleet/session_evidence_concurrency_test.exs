defmodule Responder.CoopFleet.SessionEvidenceConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.CoopFleet.SessionEvidence
  alias Responder.Episodes
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Work.{Custody, Session}

  @authority_digest String.duplicate("d", 64)
  @policy_digest String.duplicate("b", 64)
  @fixture Path.expand("../../../testdata/protocol/coop-session-evidence-v1.json", __DIR__)

  test "concurrent captures of one state converge on a single recorded snapshot" do
    # Two workers polling, or one retrying while another capture is in flight,
    # both record the same session state. A read-then-write would have produced
    # two rows of identical evidence and a history the session never had; the
    # unique index is the arbiter, and every capture still counts once.
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      session = session!(suffix)

      try do
        tasks =
          Enum.map(1..8, fn index ->
            unboxed_task(fn ->
              SessionEvidence.record(session.id, evidence(index),
                worker_id: "worker-#{suffix}",
                placement_generation: 1
              )
            end)
          end)

        results = Enum.map(tasks, &Task.await(&1, 10_000))

        assert Enum.all?(results, &match?({:ok, _result}, &1)),
               "a concurrent capture failed: #{inspect(results)}"

        assert Enum.count(results, &match?({:ok, %{recorded: :inserted}}, &1)) == 1
        assert [stored] = SessionEvidence.for_session(session.id)
        assert stored.capture_count == 8

        # Every capture observed the same state, so the latest observation is the
        # newest clock among them and the first stays the earliest.
        assert DateTime.to_iso8601(stored.last_captured_at) =~ "15:00:08"
        assert DateTime.to_iso8601(stored.first_captured_at) =~ "15:00:0"
      after
        cleanup!(session)
      end
    end)
  end

  defp evidence(index) do
    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("captured_at", "2026-09-11T15:00:0#{index}Z")
  end

  defp session!(suffix) do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "evidence-race:#{suffix}",
        native_input_id: "source:evidence-race:#{suffix}",
        occurred_at: DateTime.utc_now(),
        turn_ref: "turn:evidence-race:#{suffix}"
      })

    {:ok, _transition} = Episodes.apply(command)

    {:ok, session} =
      Custody.pin_episode(
        command.episode_id,
        "work-read-only",
        @policy_digest,
        @authority_digest,
        "responder"
      )

    {:ok, bound} =
      session
      |> Ecto.Changeset.change(coop_session_id: "remote_01j9zq3f8m0c7e6kq9y2s4x1nt")
      |> Repo.update()

    bound
  end

  defp cleanup!(session) do
    Repo.delete_all(from(evidence in SessionEvidence, where: evidence.session_id == ^session.id))

    Repo.delete_all(from(value in Session, where: value.id == ^session.id))
    Repo.delete_all(from(event in Event, where: event.episode_id == ^session.episode_id))
    Repo.delete_all(from(episode in Episode, where: episode.id == ^session.episode_id))
  end
end
