defmodule Ryker.Learning.AutomaticSourceExposuresMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @previous 20_261_025_050_000
  @version 20_261_025_060_000
  @digest String.duplicate("a", 64)

  # Old custody proves original inputs but cannot distinguish automatic memory
  # from explicit history. Preserve the frozen receipts and that known input role.
  test "existing original inputs keep their role while old memory remains conservative" do
    in_scratch_schema("automatic_source_roles", fn repo, prefix ->
      migrate!(repo, prefix, @previous)
      session_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
      session_ref = Ecto.UUID.load!(session_id)

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.episode_kernel_episodes
          (id,key,state,destination_transport,destination_conversation_ref,inserted_at,updated_at)
        VALUES ($1,$2,'complete','slack','slack:T0ENV:C0ENV',now(),now())
        """,
        [session_id, session_ref]
      )

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.episode_work_sessions
          (id,episode_id,policy,policy_digest,external_ref,inserted_at,updated_at)
        VALUES ($1,$1,'read',$2,$3,now(),now())
        """,
        [session_id, @digest, session_ref]
      )

      [original, remembered] =
        "testdata/learning/retained-output-contract-failure.json"
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["learning_run", "source_dependencies"])
        |> Jason.decode!()
        |> Enum.take(2)
        |> Enum.map(&Jason.encode!/1)

      for {receipt, input_only} <- [{original, true}, {remembered, false}] do
        source = Jason.decode!(receipt)

        SQL.query!(
          repo,
          """
          INSERT INTO #{prefix}.episode_work_source_exposures
            (session_id,observation_id,source_input_id,receipt,input_only)
          VALUES ($1,$2,$3,$4,$5)
          """,
          [
            session_id,
            Ecto.UUID.dump!(source["observation_id"]),
            Ecto.UUID.dump!(source["source_input_id"]),
            receipt,
            input_only
          ]
        )
      end

      assert @version in migrate!(repo, prefix, @version)

      assert %{rows: [[^remembered, false, true], [^original, true, false]]} =
               SQL.query!(
                 repo,
                 "SELECT receipt,input_only,automatic_context FROM #{prefix}.episode_work_source_exposures ORDER BY input_only",
                 []
               )

      assert rollback!(repo, prefix) == [@version]

      assert %{rows: [[^remembered, false], [^original, true]]} =
               SQL.query!(
                 repo,
                 "SELECT receipt,input_only FROM #{prefix}.episode_work_source_exposures ORDER BY input_only",
                 []
               )
    end)
  end
end
