defmodule Ryker.ComposeWorkerUpgradeTest do
  @moduledoc """
  `scripts/compose.sh worker-upgrade` swaps the bundled worker only while it
  carries out no command, counted by one query in the script. This runs that
  query, as the script holds it, against real rows.
  """
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.CoopFleet.{Command, Placement}
  alias Ryker.Episodes
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions

  # Two create_session commands of placements replaced on 2026-10-13 stayed
  # acknowledged on the tenant install, and every worker upgrade there waited
  # ten minutes for them and gave up (2026-10-16).
  test "a command whose placement was replaced or retired does not hold the worker upgrade" do
    assert {:ok, _worker} =
             CoopWorkers.authorize("ryker-compose", "workspace-main", digest("ryker-compose"))

    live = session!()
    command!(live, placement!(live, 1, :active))

    replaced = session!()
    command!(replaced, placement!(replaced, 1, :replaced))
    placement!(replaced, 2, :active)

    retired = session!()
    command!(retired, placement!(retired, 1, :retired))

    assert in_flight() == 1
  end

  defp in_flight do
    script = File.read!("scripts/compose.sh")

    [_whole, sql] =
      Regex.run(~r/worker_commands_in_flight\(\) \{.*?-Atc \\\s*"([^"]+)"/s, script)

    %{rows: [[count]]} = Repo.query!(sql)
    count
  end

  defp session! do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "worker-upgrade:#{episode_id}",
                 native_input_id: "source:worker-upgrade:#{episode_id}",
                 occurred_at: Repo.now!(),
                 turn_ref: "turn:worker-upgrade:#{episode_id}"
               })
             )

    assert {:ok, session} =
             WorkSessions.pin_episode(episode_id, "work-read-only", String.duplicate("b", 64))

    session
  end

  defp placement!(session, generation, state) do
    Repo.insert!(%Placement{
      session_id: session.id,
      worker_id: "ryker-compose",
      generation: generation,
      lease_ref: "lease:#{session.id}:#{generation}",
      lease_expires_at: DateTime.add(Repo.now!(), 60, :second),
      state: state,
      requirements: %{},
      requirements_fingerprint: digest("requirements:#{session.id}:#{generation}")
    })
  end

  defp command!(session, placement) do
    now = Repo.now!()

    Repo.insert!(%Command{
      placement_id: placement.id,
      worker_id: "ryker-compose",
      session_id: session.id,
      placement_generation: placement.generation,
      kind: "create_session",
      payload: %{},
      payload_fingerprint: digest("payload:#{placement.id}"),
      idempotency_key: "worker-upgrade:#{placement.id}",
      status: :acknowledged,
      delivered_at: now,
      acknowledged_at: now
    })
  end
end
