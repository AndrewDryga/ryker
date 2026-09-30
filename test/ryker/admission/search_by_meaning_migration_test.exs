defmodule Ryker.Admission.SearchByMeaningMigrationTest do
  @moduledoc """
  Andrew, 2026-09-30: routing's search for earlier work "won't actually work
  in real life". Each request's digest now keeps a vector of what it is about,
  cleared when its text changes. The migration adds it with the model that
  made it and when; a vector without its model, or a model without a vector,
  is refused. Rolling back drops only what can be computed again.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @previous_version 20_260_930_010_000
  @version 20_260_930_020_000
  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)
  @at ~N[2026-09-30 09:00:00.000000]

  test "a digest keeps a vector with its model and time, and rolling back keeps the digest" do
    repo = start_migration_repo!()
    prefix = "search_by_meaning_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      migrate!(repo, prefix, @previous_version)
      episode = episode!(repo, prefix)
      digest!(repo, prefix, episode)
      assert @version in migrate!(repo, prefix, @version)

      embed!(repo, prefix, episode, [0.6, 0.8], "bge-m3", @at)
      assert vector(repo, prefix, episode) == {[0.6, 0.8], "bge-m3"}

      assert_raise Postgrex.Error, ~r/episode_routing_digest_embedding_valid/, fn ->
        embed!(repo, prefix, episode, [0.6, 0.8], nil, @at)
      end

      assert_raise Postgrex.Error, ~r/episode_routing_digest_embedding_valid/, fn ->
        embed!(repo, prefix, episode, nil, "bge-m3", nil)
      end

      assert down!(repo, prefix) == [@version]

      assert %{num_rows: 1} =
               SQL.query!(repo, "SELECT 1 FROM #{prefix}.episode_routing_digests", [])
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  defp episode!(repo, prefix) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_kernel_episodes
        (id, key, state, destination_transport, destination_conversation_ref,
         inserted_at, updated_at)
      VALUES ($1, $2, 'complete', 'slack', 'slack:T1:C1', $3, $3)
      """,
      [Ecto.UUID.dump!(id), "episode:#{id}", @at]
    )

    id
  end

  defp digest!(repo, prefix, episode) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_routing_digests
        (episode_id, objective, search_text, input_count, covered_through_sequence,
         covered_through_at, latest_revision, inserted_at, updated_at)
      VALUES ($1, 'Checkout returns 502', 'Checkout returns 502', 1, 1, $2, 1, $2, $2)
      """,
      [Ecto.UUID.dump!(episode), @at]
    )
  end

  defp embed!(repo, prefix, episode, vector, model, at) do
    SQL.query!(
      repo,
      """
      UPDATE #{prefix}.episode_routing_digests
      SET embedding = $2::real[], embedding_model = $3, embedded_at = $4
      WHERE episode_id = $1
      """,
      [Ecto.UUID.dump!(episode), vector, model, at]
    )
  end

  defp vector(repo, prefix, episode) do
    %{rows: [[vector, model]]} =
      SQL.query!(
        repo,
        "SELECT embedding, embedding_model FROM #{prefix}.episode_routing_digests WHERE episode_id = $1",
        [Ecto.UUID.dump!(episode)]
      )

    {Enum.map(vector, &Float.round(&1, 4)), model}
  end

  defp migrate!(repo, prefix, version),
    do: Ecto.Migrator.run(repo, @migrations_path, :up, to: version, prefix: prefix, log: false)

  defp down!(repo, prefix),
    do: Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false)

  defp start_migration_repo! do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end
end
