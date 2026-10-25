defmodule Ryker.Continuity.PreserveContinuityEnvironmentsMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @previous 20_261_024_210_000
  @version 20_261_024_230_000
  @digest String.duplicate("a", 64)

  # The raw and compacted context lanes still crossed products after topics
  # were isolated. Missing or replaced old receipts must not become bare scope.
  test "only exact uniform retained roots backfill original and derived provenance" do
    in_scratch_schema("continuity_provenance", fn repo, prefix ->
      migrate!(repo, prefix, @previous)
      a = message!(repo, prefix, "product-a")
      b = message!(repo, prefix, "product-b")
      bare = message!(repo, prefix, nil)
      gone = message!(repo, prefix, "product-a")

      SQL.query!(
        repo,
        "UPDATE #{prefix}.ingress_inbox_entries SET operational_pruned_at=now() WHERE id=$1",
        [gone]
      )

      uniform = summary!(repo, prefix, [a])
      mixed = summary!(repo, prefix, [a, b])
      missing = summary!(repo, prefix, [gone])
      unscoped = summary!(repo, prefix, [bare])
      rollup = rollup!(repo, prefix, [b])
      assert @version in migrate!(repo, prefix, @version)
      assert provenance(repo, prefix, "conversation_observations", a) == ["product-a", true]
      assert provenance(repo, prefix, "conversation_observations", bare) == [nil, true]
      assert provenance(repo, prefix, "conversation_observations", gone) == [nil, false]
      assert provenance(repo, prefix, "conversation_summaries", uniform) == ["product-a", true]
      assert provenance(repo, prefix, "conversation_summaries", mixed) == [nil, false]
      assert provenance(repo, prefix, "conversation_summaries", missing) == [nil, false]
      assert provenance(repo, prefix, "conversation_summaries", unscoped) == [nil, true]
      assert provenance(repo, prefix, "conversation_rollups", rollup) == ["product-b", true]

      assert %{rows: [[4]]} =
               SQL.query!(repo, "SELECT count(*) FROM #{prefix}.conversation_summaries", [])

      assert rollback!(repo, prefix) == [@version]
    end)
  end

  test "a replaced original cannot relabel its earlier derived receipt" do
    in_scratch_schema("continuity_replaced", fn repo, prefix ->
      migrate!(repo, prefix, @previous)
      a = message!(repo, prefix, "product-a")
      summary = summary!(repo, prefix, [a])

      SQL.query!(
        repo,
        "UPDATE #{prefix}.conversation_observations SET revision=2,source_fingerprint=$1 WHERE id=$2",
        [String.duplicate("b", 64), a]
      )

      migrate!(repo, prefix, @version)
      assert provenance(repo, prefix, "conversation_observations", a) == [nil, false]
      assert provenance(repo, prefix, "conversation_summaries", summary) == [nil, false]
    end)
  end

  test "a known producer cannot be relabeled by uniform foreign roots during backfill" do
    in_scratch_schema("continuity_producer", fn repo, prefix ->
      migrate!(repo, prefix, @previous)
      source = message!(repo, prefix, "product-a")
      own = summary!(repo, prefix, [source])
      foreign = summary!(repo, prefix, [source])
      producer!(repo, prefix, own, "product-a")
      producer!(repo, prefix, foreign, "product-b")
      migrate!(repo, prefix, @version)
      assert provenance(repo, prefix, "conversation_summaries", own) == ["product-a", true]
      assert provenance(repo, prefix, "conversation_summaries", foreign) == [nil, false]
    end)
  end

  for table <- ["conversation_summaries", "conversation_rollups"] do
    test "environment-separated #{table} identities survive and refuse collapsing rollback" do
      table = unquote(table)

      in_scratch_schema("continuity_identity", fn repo, prefix ->
        migrate!(repo, prefix, @previous)
        a = message!(repo, prefix, "product-a")

        original =
          if table == "conversation_summaries",
            do: summary!(repo, prefix, [a]),
            else: rollup!(repo, prefix, [a])

        migrate!(repo, prefix, @version)

        columns =
          SQL.query!(
            repo,
            "SELECT column_name FROM information_schema.columns WHERE table_schema=$1 AND table_name=$2 ORDER BY ordinal_position",
            [prefix, table]
          ).rows
          |> List.flatten()

        selection =
          Enum.map_join(columns, ",", fn
            "id" -> "gen_random_uuid()"
            "ref" -> "'continuity:' || gen_random_uuid()::text"
            "environment_ref" -> "'product-b'"
            column -> column
          end)

        SQL.query!(
          repo,
          "INSERT INTO #{prefix}.#{table} SELECT #{selection} FROM #{prefix}.#{table} WHERE id=$1",
          [original]
        )

        assert %{rows: [[2]]} = SQL.query!(repo, "SELECT count(*) FROM #{prefix}.#{table}", [])

        assert_raise Postgrex.Error, ~r/rollback would merge history/, fn ->
          rollback!(repo, prefix)
        end
      end)
    end
  end

  defp message!(repo, prefix, environment) do
    id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    profile =
      if environment do
        classes =
          Map.new(
            ~w(conversational standard deep),
            &{&1, %{"policy" => "read", "policy_digest" => @digest}}
          )

        Jason.encode!(%{
          "environment_ref" => environment,
          "parallel_goal_limit" => 2,
          "repositories" => ["shared-infra"],
          "policies" => %{"shared-infra" => classes}
        })
      end

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.ingress_inbox_entries
        (id,dedupe_key,event_fingerprint,source_kind,source_ref,event_ref,event_kind,native_input_id,actor_kind,actor_ref,destination_transport,destination_conversation_ref,revision,occurred_at,content,status,inserted_at,updated_at,source_capabilities,repository_ref,work_policy,work_policy_digest,work_profile)
      VALUES ($1,$2,$3,'slack','T0ENV',$2,'message',$2,'bot','B0TENANTBT3','slack','slack:T0ENV:C0ENV',1,now(),'{}','pending',now(),now(),'{}','shared-infra','read',$3,$4)
      """,
      [id, Ecto.UUID.load!(id), @digest, profile]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.conversation_observations
        (id,identity_key,transport,workspace_ref,conversation_ref,repository_ref,visibility,source_input_id,source_message_ref,source_fingerprint,actor_ref,execution_mode,revision,occurred_at,inserted_at,updated_at)
      VALUES ($1,$2,'slack','slack:T0ENV','slack:T0ENV:C0ENV','shared-infra','conversation',$1,$2,$3,'B0TENANTBT3','shadow',1,now(),now(),now())
      """,
      [id, Ecto.UUID.load!(id), @digest]
    )

    id
  end

  defp producer!(repo, prefix, summary, environment) do
    id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    ref = Ecto.UUID.load!(id)

    SQL.query!(
      repo,
      "INSERT INTO #{prefix}.episode_kernel_episodes (id,key,state,destination_transport,destination_conversation_ref,inserted_at,updated_at) VALUES ($1,$2,'complete','slack','slack:T0ENV:C0ENV',now(),now())",
      [id, ref]
    )

    SQL.query!(
      repo,
      "INSERT INTO #{prefix}.episode_work_sessions (id,episode_id,policy,policy_digest,external_ref,inserted_at,updated_at,environment_ref) VALUES ($1,$1,'read',$2,$3,now(),now(),$4)",
      [id, @digest, ref, environment]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_work_turns
        (id,episode_id,session_id,turn_ref,status,submit_generation,validation_generation,cancel_generation,work_attempt_count,cancel_attempt_count,delivery_attempt_count,inserted_at,updated_at)
      VALUES ($1,$1,$1,$2,'blocked',1,1,1,0,0,0,now(),now())
      """,
      [id, "turn:" <> ref]
    )

    SQL.query!(
      repo,
      "UPDATE #{prefix}.conversation_summaries SET source_episode_id=$1,source_turn_id=$1 WHERE id=$2",
      [id, summary]
    )
  end

  defp roots(sources) do
    Enum.map(sources, fn source ->
      id = Ecto.UUID.load!(source)

      %{
        "observation_id" => id,
        "source_input_id" => id,
        "revision" => 1,
        "fingerprint" => @digest,
        "transport" => "slack",
        "workspace_ref" => "slack:T0ENV",
        "conversation_ref" => "slack:T0ENV:C0ENV",
        "repository_ref" => "shared-infra",
        "visibility" => "conversation",
        "retained_at" => "2026-10-24T12:00:00Z"
      }
    end)
    |> Jason.encode!()
  end

  defp summary!(repo, prefix, sources) do
    id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.conversation_summaries
        (id,ref,identity_key,transport,workspace_ref,conversation_ref,repository_ref,visibility,state,state_fingerprint,source_dependencies,source_result_ref,inserted_at,updated_at)
      VALUES ($1,$2,$3,'slack','slack:T0ENV','slack:T0ENV:C0ENV','shared-infra','conversation','{}',$4,$5,$2,now(),now())
      """,
      [
        id,
        "continuity:" <> Ecto.UUID.load!(id),
        Ryker.CanonicalJSON.digest(Ecto.UUID.load!(id)),
        @digest,
        roots(sources)
      ]
    )

    id
  end

  defp rollup!(repo, prefix, sources) do
    id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.conversation_rollups
        (id,ref,workspace_ref,scope_kind,scope_ref,repository_ref,visibility,period_start,period_end,state,state_fingerprint,source_dependencies,source_refs,source_scopes,source_count,expires_at,inserted_at,updated_at)
      VALUES ($1,$2,'slack:T0ENV','conversation','slack:T0ENV:C0ENV','shared-infra','conversation',now(),now(),'{}',$3,$4,'[]','[]',1,now()+interval '1 day',now(),now())
      """,
      [id, "continuity-rollup:" <> Ecto.UUID.load!(id), @digest, roots(sources)]
    )

    id
  end

  defp provenance(repo, prefix, table, id) do
    %{rows: [result]} =
      SQL.query!(
        repo,
        "SELECT environment_ref,environment_known FROM #{prefix}.#{table} WHERE id=$1",
        [id]
      )

    result
  end
end
