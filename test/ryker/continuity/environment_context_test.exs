defmodule Ryker.Continuity.EnvironmentContextTest do
  use Ryker.DataCase, async: false
  alias Ryker.Admission.ConversationSummaries
  alias Ryker.{CanonicalJSON, Continuity, Repo}
  alias Ryker.Continuity.{Compaction, ConversationRollup, ConversationSummary}
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.{Learning, WorkSessions}
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Learning.{LearningSources, Observations}
  alias Ryker.Memories.MemorySearchPage

  # Host-contract variants built from the retained haproxy input corpus.
  # No invented model response or external operation is involved.
  for kind <- [:observations, :summary, :rollup] do
    test "automatic #{kind} cannot silently inject another environment" do
      {source, target} = sources!()
      {:ok, :ok} = Repo.transaction(fn -> Observations.record_excerpt_in_transaction(source) end)
      assert source.work_profile["environment_ref"] == "product-a"
      assert target.work_profile["environment_ref"] == "product-b"

      actual =
        case unquote(kind) do
          :observations ->
            Observations.context(target, target.repository_ref, "", 10)

          :summary ->
            summary!(source)
            episode = Repo.get!(Ryker.Episodes.Episode, target.episode_id)

            Continuity.model_context(episode, target.repository_ref, [
              Ryker.Ingress.RecallText.prose(source.content)
            ])["related"]

          :rollup ->
            rollup!(source)
            episode = Repo.get!(Ryker.Episodes.Episode, target.episode_id)

            Continuity.model_context(episode, target.repository_ref, [
              Ryker.Ingress.RecallText.prose(source.content)
            ])["rollups"]
        end

      assert actual == []
    end
  end

  # Routing has its own summary selector. A newer foreign row used to win its
  # thread-only LIMIT even after Work recall had been isolated by environment.
  for provenance <- [:foreign, :unknown] do
    test "routing selects local history before a newer #{provenance} thread summary" do
      {source, target} = sources!()
      target = %{target | destination_thread_ref: "host-contract-thread"}

      for entry <- [source, target] do
        {:ok, :ok} = Repo.transaction(fn -> Observations.record_excerpt_in_transaction(entry) end)
      end

      {:ok, scope} = Continuity.destination_context(target, target.repository_ref)
      local = summary!(target)
      candidate = summary!(source)

      local
      |> Ecto.Changeset.change(
        identity_key: scope.identity_key,
        source_message_ref: local.id,
        updated_at: DateTime.add(target.occurred_at, -120)
      )
      |> Repo.update!()

      attributes =
        case unquote(provenance) do
          :foreign -> [environment_ref: "product-a"]
          :unknown -> [environment_ref: nil, environment_known: false]
        end

      attributes =
        attributes ++
          [identity_key: scope.identity_key, updated_at: DateTime.add(target.occurred_at, -60)]

      candidate
      |> Ecto.Changeset.change(attributes)
      |> Repo.update!()

      selected = ConversationSummaries.thread(target, target.occurred_at)
      assert selected["status"] == "available"
      assert selected["covered_source"] == local.id
      assert selected["document"]["environment_ref"] == "product-b"
      assert selected["document"]["environment_known"] == true
    end
  end

  test "routing refuses a local thread summary whose retained roots belong elsewhere" do
    {source, target} = sources!()
    target = %{target | destination_thread_ref: "host-contract-thread"}
    {:ok, :ok} = Repo.transaction(fn -> Observations.record_excerpt_in_transaction(source) end)
    {:ok, scope} = Continuity.destination_context(target, target.repository_ref)

    source
    |> summary!()
    |> Ecto.Changeset.change(
      identity_key: scope.identity_key,
      environment_ref: "product-b",
      updated_at: DateTime.add(target.occurred_at, -60)
    )
    |> Repo.update!()

    assert ConversationSummaries.thread(target, target.occurred_at)["status"] == "unavailable"
  end

  test "a frozen local routing summary is valid only while its exact source remains readable" do
    {_source, target} = sources!()
    target = %{target | destination_thread_ref: "host-contract-thread"}
    {:ok, :ok} = Repo.transaction(fn -> Observations.record_excerpt_in_transaction(target) end)
    {:ok, scope} = Continuity.destination_context(target, target.repository_ref)
    summary = summary!(target)

    summary
    |> Ecto.Changeset.change(
      identity_key: scope.identity_key,
      updated_at: DateTime.add(target.occurred_at, -60)
    )
    |> Repo.update!()

    selected = ConversationSummaries.thread(target, target.occurred_at)
    assert selected["status"] == "available"
    assert selected["document"]["source_ref"] == summary.ref
    bundle = %{"thread_summary" => selected["document"]}
    assert ConversationSummaries.reauthorize(target, bundle, target.occurred_at) == :ok

    target.id
    |> Ryker.Learning.ConversationObservation.Query.by_id()
    |> Repo.fetch!()
    |> Ecto.Changeset.change(forgotten_at: Repo.now!())
    |> Repo.update!()

    assert ConversationSummaries.reauthorize(target, bundle, target.occurred_at) ==
             {:error, {:admission_rejected, :context_stale}}
  end

  test "original excerpts retain the producing environment in routing and explicit search" do
    {source, target} = sources!()
    {:ok, :ok} = Repo.transaction(fn -> Observations.record_excerpt_in_transaction(source) end)
    [document] = Observations.context(source, source.repository_ref)
    assert document["environment_ref"] == "product-a"
    assert document["environment_known"] == true

    assert Observations.reauthorize(target, target.repository_ref, [document]) ==
             {:error, {:admission_rejected, :context_stale}}
  end

  test "explicit foreign history carries source labels that frozen custody cannot forge" do
    {source, target} = sources!()
    {:ok, :ok} = Repo.transaction(fn -> Observations.record_excerpt_in_transaction(source) end)
    episode = Repo.get!(Ryker.Episodes.Episode, target.episode_id)
    query = "haproxy"
    page = MemorySearchPage.first(query, "workspace")

    assert {:ok, {:ok, note, _}} =
             Repo.transaction(fn ->
               Observations.search_page(target, target.repository_ref, page)
             end)

    assert note["environment_ref"] == "product-a"
    assert note["environment_known"] == true
    assert LearningSources.document_sources(note) != nil
    assert LearningSources.document_sources(Map.put(note, "environment_ref", "product-b")) == nil

    for kind <- [:summary, :rollup] do
      case kind do
        :summary -> summary!(source)
        :rollup -> rollup!(source)
      end

      assert {:ok, {:ok, document, _}} =
               Repo.transaction(fn ->
                 Ryker.Continuity.Recall.search_page(kind, episode, target.repository_ref, page)
               end)

      assert document["environment_ref"] == "product-a"
      assert document["environment_known"] == true
      assert LearningSources.document_sources(document) != nil

      assert LearningSources.document_sources(Map.put(document, "environment_ref", "product-b")) ==
               nil

      assert LearningSources.document_sources(Map.put(document, "environment_known", false)) ==
               nil
    end
  end

  test "same-environment context remains available while mixed roots and unknown history stay out" do
    {source, target} = sources!()

    for entry <- [source, target] do
      {:ok, :ok} = Repo.transaction(fn -> Observations.record_excerpt_in_transaction(entry) end)
    end

    episode = Repo.get!(Ryker.Episodes.Episode, target.episode_id)
    local = summary!(target)
    rollup = rollup!(target)

    assert [%{"source_ref" => ref}] =
             Continuity.model_context(episode, target.repository_ref)["related"]

    assert ref == local.ref

    assert [%{"source_ref" => ref}] =
             Continuity.model_context(episode, target.repository_ref)["rollups"]

    assert ref == rollup.ref

    mixed =
      LearningSources.merge([
        LearningSources.for_entry(source),
        LearningSources.for_entry(target)
      ])

    for record <- [local, rollup] do
      record |> Ecto.Changeset.change(source_dependencies: mixed) |> Repo.update!()
    end

    context = Continuity.model_context(episode, target.repository_ref)
    assert context["related"] == []
    assert context["rollups"] == []

    for record <- [local, rollup] do
      record |> Ecto.Changeset.change(environment_known: false) |> Repo.update!()
    end

    assert Continuity.model_context(episode, target.repository_ref)["related"] == []
  end

  test "compaction keeps shared conversation histories in separate environment identities" do
    {source, target} = sources!()

    for entry <- [source, target] do
      {:ok, :ok} = Repo.transaction(fn -> Observations.record_excerpt_in_transaction(entry) end)
      summary = summary!(entry)

      summary
      |> Ecto.Changeset.change(updated_at: DateTime.add(Repo.now!(), -120))
      |> Repo.update!()
    end

    assert Repo.transaction(fn -> Compaction.compact_in_transaction(60, 7200) end) ==
             {:ok, {:ok, 2}}

    rollups = Repo.all(ConversationRollup)
    assert length(rollups) == 2
    assert Enum.sort(Enum.map(rollups, & &1.environment_ref)) == ["product-a", "product-b"]

    for entry <- [source, target] do
      episode = Repo.get!(Ryker.Episodes.Episode, entry.episode_id)
      assert [document] = Continuity.model_context(episode, entry.repository_ref)["rollups"]
      assert document["environment_ref"] == entry.work_profile["environment_ref"]
    end
  end

  # Forget cleared fresh recall but left the current handover and raw native
  # exposures authorized, so the same forgotten prose reached later turns.
  test "forgotten original roots cannot remain automatic current-summary context" do
    {source, _target} = sources!()
    {:ok, :ok} = Repo.transaction(fn -> Observations.record_excerpt_in_transaction(source) end)
    {:ok, scope} = Continuity.destination_context(source, source.repository_ref)

    source
    |> summary!()
    |> Ecto.Changeset.change(identity_key: scope.identity_key)
    |> Repo.update!()

    episode = Repo.get!(Ryker.Episodes.Episode, source.episode_id)
    assert Continuity.model_context(episode, source.repository_ref)["current"] != nil
    assert KnowledgeFixtures.forget!(source) == :ok
    assert Continuity.model_context(episode, source.repository_ref)["current"] == nil
  end

  test "forgetting a recalled original invalidates the retained native transcript" do
    {source, _target} = sources!()
    {:ok, :ok} = Repo.transaction(fn -> Observations.record_excerpt_in_transaction(source) end)
    assert {:ok, claim} = Ryker.Work.Custody.claim_next("forgotten-source", 60, :work)
    assert claim.episode.id == source.episode_id
    note = Repo.get!(Ryker.Learning.ConversationObservation, source.id)
    assert Ryker.Knowledge.KnowledgeSnapshot.expose(claim, [Observations.document(note)]) == :ok
    assert KnowledgeFixtures.forget!(source) == :ok

    assert Ryker.Knowledge.KnowledgeSnapshot.authorize_session(claim.episode, claim.session) ==
             {:error, :work_knowledge_context_stale}
  end

  defp sources! do
    [first, second] = Learning.inputs!(isolate: true)

    entries =
      Enum.zip([first, second], ["product-a", "product-b"])
      |> Enum.map(fn {entry, ref} ->
        classes =
          Map.new([:conversational, :standard, :deep], fn kind ->
            {kind,
             %{
               policy: "shared-infra-#{kind}",
               policy_digest: String.duplicate("b", 64),
               authority_digest: String.duplicate("c", 64)
             }}
          end)

        {:ok, profile} =
          WorkProfile.new(%{
            environment_ref: ref,
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

        {:ok, _} =
          WorkSessions.pin_episode(entry.episode_id, profile.policy, profile.policy_digest,
            environment_ref: ref,
            repository_ref: entry.repository_ref
          )

        entry
      end)

    [first, second] = Learning.normalize_queue_timestamps!(entries)
    {first, second}
  end

  defp summary!(source) do
    {:ok, scope} = Continuity.destination_context(source, source.repository_ref)
    text = Ryker.Ingress.RecallText.prose(source.content)
    assert String.trim(text) != ""

    state =
      Map.new(Ryker.Continuity.ConversationSummaryState.fields(), fn field ->
        {field,
         if(field in Ryker.Continuity.ConversationSummaryState.list_fields(), do: [], else: nil)}
      end)
      |> Map.put("situation", text)

    id = Ecto.UUID.generate()

    Repo.insert!(%ConversationSummary{
      id: id,
      ref: "continuity:#{id}",
      identity_key: CanonicalJSON.digest(id),
      transport: scope.transport,
      workspace_ref: scope.workspace_ref,
      conversation_ref: scope.conversation_ref,
      thread_ref: source.destination_thread_ref,
      repository_ref: source.repository_ref,
      visibility: scope.visibility,
      environment_ref: scope.environment_ref,
      environment_known: true,
      source_episode_id: source.episode_id,
      source_dependencies: LearningSources.for_entry(source),
      state: state,
      state_fingerprint: CanonicalJSON.digest(state),
      source_result_ref: "result:#{id}"
    })
  end

  defp rollup!(source) do
    {:ok, scope} = Continuity.destination_context(source, source.repository_ref)
    text = Ryker.Ingress.RecallText.prose(source.content)
    assert String.trim(text) != ""

    state =
      Map.new(Ryker.Continuity.ConversationSummaryState.fields(), fn field ->
        {field,
         if(field in Ryker.Continuity.ConversationSummaryState.list_fields(), do: [], else: nil)}
      end)
      |> Map.put("situation", text)

    id = Ecto.UUID.generate()
    now = Repo.now!()

    Repo.insert!(%ConversationRollup{
      id: id,
      ref: "continuity-rollup:#{id}",
      workspace_ref: scope.workspace_ref,
      scope_kind: :conversation,
      scope_ref: scope.conversation_ref,
      repository_ref: source.repository_ref,
      visibility: scope.visibility,
      environment_ref: scope.environment_ref,
      environment_known: true,
      period_start: DateTime.add(now, -120),
      period_end: DateTime.add(now, -60),
      state: state,
      state_fingerprint: CanonicalJSON.digest(state),
      source_dependencies: LearningSources.for_entry(source),
      source_refs: ["input:#{source.id}"],
      source_scopes: [],
      source_count: 1,
      expires_at: DateTime.add(now, 3600)
    })
  end
end
