defmodule Ryker.Work.KeepDeliveryUploadsMigrationTest do
  # Slack shares uploaded images a moment after the upload completes, and a
  # retry that found no share yet uploaded them again (2026-10-04 review). A
  # turn keeps the files an attempt uploaded: none to begin with, five at most,
  # as a reply holds five images, and only on a turn that owes a reply.
  use Ryker.MigrationCase
  import Ecto.Query
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Work.{Custody, Turn}

  @version 20_261_007_160_000
  @delivery [
    delivery_ref: "delivery:uploads",
    delivery_document: %{"message" => "The chart is attached."},
    delivery_fingerprint: String.duplicate("a", 64)
  ]

  test "a turn keeps at most five uploads, and only for a reply it owes" do
    turn = working_turn!()

    assert migrate_down(@version) == :ok
    assert migrate_up(@version) == :ok

    assert Repo.get!(Turn, turn.id).delivery_upload_refs == []
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} = keep(turn, ["F101"])

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             keep(turn, ["F101", "F102", "F103", "F104", "F105", "F106"], @delivery)

    assert keep(turn, ["F101", "F102"], @delivery) == {:ok, 1}
    assert Repo.get!(Turn, turn.id).delivery_upload_refs == ["F101", "F102"]
  end

  defp working_turn! do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "uploads-migration:#{episode_id}",
                 native_input_id: "slack-message:uploads-migration:#{episode_id}",
                 turn_ref: "turn:uploads-migration:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             WorkSessions.pin_episode(
               episode_id,
               "conversation-read-only",
               String.duplicate("a", 64)
             )

    assert {:ok, claim} = Custody.claim_next("uploads-migration", 60, :work)
    claim.turn
  end

  # A savepoint keeps the refused write from aborting the test's transaction.
  defp keep(turn, upload_refs, delivery \\ []) do
    Repo.transaction(fn ->
      {count, nil} =
        Repo.update_all(from(row in Turn, where: row.id == ^turn.id),
          set: [{:delivery_upload_refs, upload_refs} | delivery]
        )

      count
    end)
  rescue
    error in Postgrex.Error -> {:error, error}
  end
end
