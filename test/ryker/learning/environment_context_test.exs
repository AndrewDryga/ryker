defmodule Ryker.Learning.EnvironmentContextTest do
  use Ryker.DataCase, async: false
  alias Ryker.Fixtures.Learning, as: Fixtures
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Learning
  alias Ryker.Learning.Batches
  alias Ryker.Repo

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}

  # A product health request twice followed another product's shared inventory.
  # The same missing environment also reached learning, where it could persist.
  test "learning refuses a batch whose shared repository hides different source environments" do
    scoped = scoped_inputs!()

    assert Learning.prepare(Enum.map(scoped, & &1.id), @policy) ==
             {:error, :learning_source_stale}
  end

  test "each learning input retains the environment selected before routing" do
    [input | _] = scoped_inputs!()
    assert {:ok, run} = Learning.prepare([input.id], @policy)
    [document] = Jason.decode!(run.prompt)["inputs"]
    assert document["environment"] == %{"ref" => "product-a", "name" => "product-a"}
  end

  test "the learning queue assigns different environments to separate batches" do
    scoped_inputs!()

    settings =
      Map.merge(@policy, %{
        quiet_seconds: 0,
        maximum_delay_seconds: 60,
        lease_seconds: 300,
        batch_size: 16
      })

    assert {:ok, %{batch: _, inputs: [_]} = first} = Batches.claim("environment-first", settings)
    assert length(first.inputs) == 1

    assert {:ok, %{batch: _, inputs: [_]} = second} =
             Batches.claim("environment-second", settings)

    assert length(second.inputs) == 1
    refute first.batch.scope_key == second.batch.scope_key

    assert Enum.sort([first.batch.environment_ref, second.batch.environment_ref]) == [
             "product-a",
             "product-b"
           ]
  end

  test "shared conversation topics keep separate heads for each producing environment" do
    [first, second] = scoped_inputs!()
    # Store-contract proposal from the retained haproxy lifecycle observations.
    proposal = proposal()

    assert Repo.transaction(fn ->
             Ryker.Fixtures.Knowledge.record_topic(first, proposal, [])
           end) == {:ok, :ok}

    assert Ryker.Knowledge.context(second, second.repository_ref, "", 16, "writable") == []
    assert Ryker.Knowledge.context(second, second.repository_ref) == []

    page = Ryker.Memories.MemorySearchPage.first("haproxy", "workspace")

    assert {:ok, {:ok, foreign, _}} =
             Repo.transaction(fn ->
               Ryker.Knowledge.search_page(second, second.repository_ref, page)
             end)

    assert foreign["environment_ref"] == "product-a"
    refute foreign["can_update"]

    assert Ryker.Knowledge.KnowledgeSnapshot.still_valid(second, second.repository_ref, [foreign]) ==
             :ok

    mislabeled = Map.put(foreign, "environment_ref", "product-b")

    assert Ryker.Knowledge.KnowledgeSnapshot.still_valid(second, second.repository_ref, [
             mislabeled
           ]) ==
             {:error, :work_knowledge_context_stale}

    assert Repo.transaction(fn ->
             Ryker.Fixtures.Knowledge.record_topic(second, proposal, [])
           end) == {:ok, :ok}

    for entry <- [first, second] do
      [own] = Ryker.Knowledge.context(entry, entry.repository_ref, "", 16, "writable")
      assert own["can_update"]
      assert own["environment_ref"] == entry.work_profile["environment_ref"]
      assert own["version"] == 1
      "knowledge:" <> topic_id = own["source_ref"]
      assert {:ok, preview} = Ryker.Learning.Rebuilds.preview(topic_id, %{page: 1, q: ""})
      assert Enum.map(preview.entries, & &1.input_id) == [entry.id]
    end
  end

  test "another environment's batch cannot hold a local topic rebuild" do
    [entry | _] = scoped_inputs!()

    Ryker.Config.put_override(:learning, %{
      api: __MODULE__,
      client: %{},
      worker_ref: "environment-rebuild",
      policy: @policy.policy,
      policy_digest: @policy.policy_digest
    })

    assert Repo.transaction(fn ->
             Ryker.Fixtures.Knowledge.record_topic(entry, proposal(), [])
           end) == {:ok, :ok}

    topic = Repo.one!(Ryker.Knowledge.ConversationKnowledge)
    topic |> Ecto.Changeset.change(source_generation: 2) |> Repo.update!()

    Repo.insert!(%Ryker.Learning.Batch{
      scope_key: "foreign-environment",
      transport: entry.destination_transport,
      conversation_ref: entry.destination_conversation_ref,
      repository_ref: entry.repository_ref,
      environment_ref: "product-b",
      execution_mode: entry.execution_mode,
      policy: @policy.policy,
      policy_digest: @policy.policy_digest,
      status: :queued,
      input_count: 1
    })

    assert {:ok, preview} = Ryker.Learning.Rebuilds.preview(topic.id, %{page: 1, q: ""})
    assert preview.eligible?
    assert preview.reason == nil
  end

  test "a scoped topic stays authorized after the worker retains its exposure" do
    [entry | _] = scoped_inputs!()

    assert Repo.transaction(fn ->
             Ryker.Fixtures.Knowledge.record_topic(entry, proposal(), [])
           end) == {:ok, :ok}

    [topic] = Ryker.Knowledge.context(entry, entry.repository_ref)

    assert {:ok, _} =
             Ryker.Fixtures.WorkSessions.pin_episode(
               entry.episode_id,
               "exposure-read",
               String.duplicate("a", 64),
               environment_ref: "product-a",
               repository_ref: entry.repository_ref
             )

    assert {:ok, claim} = Ryker.Work.Custody.claim_next("environment-exposure", 60)
    assert Ryker.Knowledge.KnowledgeSnapshot.expose(claim, [topic]) == :ok

    assert Ryker.Knowledge.KnowledgeSnapshot.authorize_session(claim.episode, claim.session) ==
             :ok

    assert Ryker.Knowledge.KnowledgeSnapshot.expose(claim, [topic]) == :ok
  end

  defp proposal do
    %{
      "topic_key" => "haproxy",
      "title" => "Host OOM kills",
      "summary" =>
        "Grafana bot B0TENANTBT3 reported a historical VA1 warning starting 2026-09-05 at 17:18:50 UTC: the kernel OOM-killed website/haproxy-edge process haproxy on nomad-hst01. CONSTRAINT_MEMCG indicates the workload cgroup reached its limit; it does not establish host RAM exhaustion.",
      "topics" => ["haproxy"],
      "anchors" => ["haproxy"],
      "target_ref" => nil,
      "expected_version" => 0
    }
  end

  defp scoped_inputs! do
    entries = Fixtures.inputs!(isolate: true)
    environments = ["product-a", "product-b"]
    assert {:ok, _} = Ryker.Settings.initialize("control-plane:local")

    assert {:ok, _} =
             Ryker.Settings.put_repository(
               %{ref: hd(entries).repository_ref},
               :current,
               "control-plane:local"
             )

    for environment <- environments do
      assert {:ok, _} =
               Ryker.Settings.put_environment(
                 %{
                   ref: environment,
                   display_name: environment,
                   repositories: [hd(entries).repository_ref]
                 },
                 :current,
                 "control-plane:local"
               )
    end

    scoped =
      Enum.zip(entries, environments)
      |> Enum.map(fn {entry, environment} ->
        classes =
          Map.new([:conversational, :standard, :deep], fn kind ->
            {kind,
             %{
               policy: "shared-infra-#{kind}",
               policy_digest: String.duplicate("b", 64),
               authority_digest: String.duplicate("c", 64)
             }}
          end)

        assert {:ok, profile} =
                 WorkProfile.new(%{
                   environment_ref: environment,
                   parallel_goal_limit: 2,
                   policies: %{entry.repository_ref => classes},
                   repositories: [entry.repository_ref]
                 })

        entry =
          entry
          |> Ecto.Changeset.change(
            work_profile: WorkProfile.document(profile),
            work_policy: profile.policy,
            work_policy_digest: profile.policy_digest
          )
          |> Repo.update!()

        # The corpus was received before these environment overrides. Retain
        # the excerpt with the same provenance real ingress receives up front.
        assert Repo.transaction(fn ->
                 Learning.Observations.record_excerpt_in_transaction(entry)
               end) == {:ok, :ok}

        entry
      end)

    Fixtures.normalize_queue_timestamps!(scoped)
  end
end
