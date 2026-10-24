defmodule Ryker.Learning.PreserveSourceEnvironmentsMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Memories.CaseRecord

  @previous 20_261_024_190_000
  @version 20_261_024_210_000
  @digest String.duplicate("a", 64)

  # Product health findings crossed environments. A missing receipt must remain
  # unknown rather than becoming global knowledge when old history is migrated.
  test "migration preserves uniform, bare and unknown provenance without making unknown topics writable" do
    in_scratch_schema("source_environments", fn repo, prefix ->
      migrate!(repo, prefix, @previous)
      a = message!(repo, prefix, "product-a")
      b = message!(repo, prefix, "product-b")
      bare = message!(repo, prefix, nil)
      uniform = topic!(repo, prefix, "uniform", [a])
      unscoped = topic!(repo, prefix, "bare", [bare])
      mixed = topic!(repo, prefix, "mixed", [a, b])
      missing = topic!(repo, prefix, "missing", [])
      batch = batch!(repo, prefix, "deferred", [b])
      known_case = case!(repo, prefix, "product-a")
      bare_case = case!(repo, prefix, nil)
      unknown_case = case!(repo, prefix, :missing)
      assert @version in migrate!(repo, prefix, @version)
      assert environment(repo, prefix, "conversation_knowledge", uniform) == "product-a"
      assert environment(repo, prefix, "conversation_learning_batches", batch) == "product-b"

      scope_key =
        Ryker.Learning.Batches.scope_key(%{
          transport: "slack",
          conversation_ref: "slack:T0ENV:C0ENV",
          repository_ref: "shared-infra",
          environment_ref: "product-b",
          execution_mode: :shadow
        })

      assert %{rows: [[^scope_key]]} =
               SQL.query!(
                 repo,
                 "SELECT scope_key FROM #{prefix}.conversation_learning_batches WHERE id=$1",
                 [batch]
               )

      assert environment(repo, prefix, "episode_case_records", known_case) == "product-a"
      assert environment(repo, prefix, "episode_case_records", bare_case) == nil
      assert environment(repo, prefix, "episode_case_records", unknown_case) == nil

      writable =
        ConversationKnowledge.Query.all()
        |> ConversationKnowledge.Query.by_environment(nil)
        |> ConversationKnowledge.Query.select_ids()

      assert repo.all(writable, prefix: prefix) == [Ecto.UUID.load!(unscoped)]
      local_cases = CaseRecord.Query.all() |> CaseRecord.Query.by_environment(nil)

      assert Enum.map(repo.all(local_cases, prefix: prefix), & &1.id) == [
               Ecto.UUID.load!(bare_case)
             ]

      assert %{rows: [[4]]} =
               SQL.query!(repo, "SELECT count(*) FROM #{prefix}.conversation_knowledge", [])

      assert environment(repo, prefix, "conversation_knowledge", mixed) == nil
      assert environment(repo, prefix, "conversation_knowledge", missing) == nil
      assert rollback!(repo, prefix) == [@version]
    end)
  end

  test "a replaced observation cannot relabel its old knowledge receipt with the edit's environment" do
    in_scratch_schema("edited_provenance", fn repo, prefix ->
      migrate!(repo, prefix, @previous)
      a = message!(repo, prefix, "product-a")
      b = message!(repo, prefix, "product-b")
      topic = topic!(repo, prefix, "edited", [a])

      SQL.query!(
        repo,
        "UPDATE #{prefix}.ingress_inbox_entries SET revision=2,event_fingerprint=$1 WHERE id=$2",
        [String.duplicate("b", 64), b]
      )

      SQL.query!(
        repo,
        "UPDATE #{prefix}.conversation_observations SET revision=2,source_input_id=$1,source_fingerprint=$2 WHERE id=$3",
        [b, String.duplicate("b", 64), a]
      )

      migrate!(repo, prefix, @version)
      assert environment(repo, prefix, "conversation_knowledge", topic) == nil
    end)
  end

  test "migration refuses active mixed custody without changing its membership" do
    in_scratch_schema("mixed_custody", fn repo, prefix ->
      migrate!(repo, prefix, @previous)
      a = message!(repo, prefix, "product-a")
      b = message!(repo, prefix, "product-b")
      batch!(repo, prefix, "queued", [a, b])

      assert_raise Postgrex.Error, ~r/active learning batch contains mixed environments/, fn ->
        migrate!(repo, prefix, @version)
      end

      assert %{rows: [[2]]} =
               SQL.query!(repo, "SELECT count(*) FROM #{prefix}.conversation_learning_inputs", [])
    end)
  end

  test "rollback refuses to merge unknown history with an explicitly unscoped topic" do
    in_scratch_schema("topic_identity", fn repo, prefix ->
      migrate!(repo, prefix, @previous)
      topic = topic!(repo, prefix, "same", [])
      migrate!(repo, prefix, @version)

      SQL.query!(
        repo,
        "INSERT INTO #{prefix}.conversation_knowledge SELECT gen_random_uuid(),scope_key,topic_key,transport,workspace_ref,conversation_ref,repository_ref,visibility,state,version,source_generation,source_dependencies,source_input_id,source_episode_id,latest_source_at,inserted_at,updated_at,anchor_keys,forgotten_at,NULL,true FROM #{prefix}.conversation_knowledge WHERE id=$1",
        [topic]
      )

      assert_raise Postgrex.Error, ~r/environment-specific topics exist/, fn ->
        rollback!(repo, prefix)
      end
    end)
  end

  test "rollback cannot merge deferred remote custody with an active foreign environment" do
    in_scratch_schema("deferred_custody", fn repo, prefix ->
      migrate!(repo, prefix, @previous)
      a = message!(repo, prefix, "product-a")
      b = message!(repo, prefix, "product-b")
      deferred = batch!(repo, prefix, "deferred", [a])
      batch!(repo, prefix, "queued", [b])

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.conversation_learning_runs
          (id,batch_key,batch_id,generation,status,inputs,source_dependencies,knowledge,omissions,policy,policy_digest,prompt_sha256,output_schema,inserted_at,updated_at,started_at)
        VALUES ($1,$2,$1,1,'prepared','[]','[]','[]','[]','read',$3,$3,'{}',now(),now(),now())
        """,
        [deferred, Ecto.UUID.load!(deferred), @digest]
      )

      migrate!(repo, prefix, @version)

      assert_raise Postgrex.Error, ~r/environment-specific active batches exist/, fn ->
        rollback!(repo, prefix)
      end
    end)
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

  defp topic!(repo, prefix, key, sources) do
    id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.conversation_knowledge
        (id,scope_key,topic_key,transport,workspace_ref,conversation_ref,repository_ref,visibility,state,version,source_generation,source_dependencies,source_input_id,latest_source_at,inserted_at,updated_at)
      VALUES ($1,'scope',$2,'slack','slack:T0ENV','slack:T0ENV:C0ENV','shared-infra','conversation','{}',1,1,'[]',$1,now(),now(),now())
      """,
      [id, key]
    )

    for source <- sources do
      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.conversation_knowledge_sources
          (knowledge_id,observation_id,generation,source_revision,source_fingerprint,retained_at,introduced_version,receipt_fingerprint,receipt,direct_support_version)
        VALUES ($1,$2,1,1,$3,now(),1,$4,'{}',1)
        """,
        [id, source, @digest, Ecto.UUID.load!(source)]
      )
    end

    id
  end

  defp batch!(repo, prefix, status, sources) do
    id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.conversation_learning_batches
        (id,scope_key,transport,conversation_ref,repository_ref,execution_mode,policy,policy_digest,status,input_count,inserted_at,updated_at)
      VALUES ($1,$2,'slack','slack:T0ENV:C0ENV','shared-infra','shadow','read',$3,$4,$5,now(),now())
      """,
      [id, Ecto.UUID.load!(id), @digest, status, length(sources)]
    )

    for source <- sources do
      SQL.query!(
        repo,
        "INSERT INTO #{prefix}.conversation_learning_inputs (batch_id,input_id,inserted_at,updated_at) VALUES ($1,$2,now(),now())",
        [id, source]
      )
    end

    id
  end

  defp case!(repo, prefix, environment) do
    id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    if environment != :missing do
      SQL.query!(
        repo,
        "INSERT INTO #{prefix}.episode_kernel_episodes (id,key,state,destination_transport,destination_conversation_ref,inserted_at,updated_at) VALUES ($1,$2,'complete','slack','slack:T0ENV:C0ENV',now(),now())",
        [id, Ecto.UUID.load!(id)]
      )

      SQL.query!(
        repo,
        "INSERT INTO #{prefix}.episode_work_sessions (id,episode_id,policy,policy_digest,external_ref,inserted_at,updated_at,environment_ref) VALUES ($1,$1,'read',$2,$3,now(),now(),$4)",
        [id, @digest, Ecto.UUID.load!(id), environment]
      )
    end

    SQL.query!(
      repo,
      "INSERT INTO #{prefix}.episode_case_records (id,case_ref,episode_id,episode_key,execution_mode,transport,conversation_ref,workspace_ref,problem,search_text,content_fingerprint,closed_at,inserted_at,updated_at) VALUES ($1,$2,$1,$2,'shadow','slack','slack:T0ENV:C0ENV','slack:T0ENV','Host OOM kills','haproxy',$3,now(),now(),now())",
      [id, "case:" <> Ecto.UUID.load!(id), @digest]
    )

    id
  end

  defp environment(repo, prefix, table, id) do
    %{rows: [[ref]]} =
      SQL.query!(repo, "SELECT environment_ref FROM #{prefix}.#{table} WHERE id=$1", [id])

    ref
  end
end
