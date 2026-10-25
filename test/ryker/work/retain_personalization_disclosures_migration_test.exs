defmodule Ryker.Work.RetainPersonalizationDisclosuresMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions

  @version 20_261_025_100_000

  # Upgrading an older native transcript must leave unknown custody NULL,
  # rather than silently claiming that no personal context was disclosed.
  test "old sessions retain unknown custody while only new host sessions start empty" do
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "personal-migration:#{id}",
                 native_input_id: "personal-migration:#{id}",
                 turn_ref: "personal-migration:#{id}"
               })
             )

    assert {:ok, session} =
             WorkSessions.pin_episode(id, "personal-migration", String.duplicate("a", 64))

    assert session.personalization_exposures == %{"facts" => %{}, "preferences" => %{}}
    assert migrate_down(@version) == :ok
    old_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO episode_work_sessions
        (id, episode_id, generation, create_generation, policy, policy_digest, external_ref, inserted_at, updated_at)
      SELECT $1, episode_id, generation + 1, 1, policy, policy_digest, $2, inserted_at, updated_at
      FROM episode_work_sessions WHERE id = $3
      """,
      [Ecto.UUID.dump!(old_id), "old-personal:#{old_id}", Ecto.UUID.dump!(session.id)]
    )

    assert migrate_up(@version) == :ok

    assert SQL.query!(
             Repo,
             "SELECT personalization_exposures FROM episode_work_sessions WHERE id = $1",
             [Ecto.UUID.dump!(old_id)]
           ).rows == [[nil]]
  end
end
