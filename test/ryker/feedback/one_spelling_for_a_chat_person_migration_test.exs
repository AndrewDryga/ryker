defmodule Ryker.Feedback.OneSpellingForAChatPersonMigrationTest do
  use Ryker.MigrationCase

  import Ecto.Query

  alias Ryker.Episodes
  alias Ryker.Feedback
  alias Ryker.Feedback.Signal
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures

  @version 20_261_006_110_000

  # A Chat reaction recorded its person as `control-plane:user:`, and the turn
  # it reacted to was for `control_plane:user:`: one person, two references
  # (2026-10-04 review). A kept reaction moves to the one spelling; every other
  # actor is left as it was.
  test "a kept Chat reaction names its person the way a turn does" do
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())

    record = fn actor_ref, source_ref ->
      {:ok, %{signal: signal}} =
        Feedback.record(%{
          kind: :reaction_added,
          value: "+1",
          actor_ref: actor_ref,
          source: "control_plane",
          source_ref: source_ref,
          occurred_at: ~U[2026-10-01 12:00:00.000000Z],
          request: {:episode, episode.id}
        })

      signal
    end

    assert :ok = migrate_down(@version)
    chat = record.("control-plane:user:tailscale:andrew@example.com", "reaction-a")
    slack = record.("UALICE", "reaction-b")

    assert :ok = migrate_up(@version)

    actors =
      Repo.all(
        from(signal in Signal,
          where: signal.id in ^[chat.id, slack.id],
          select: {signal.id, signal.actor_ref}
        )
      )
      |> Map.new()

    assert actors[chat.id] == "control_plane:user:tailscale:andrew@example.com"
    assert actors[slack.id] == "UALICE"
  end
end
