defmodule Responder.State.KnowledgeSnapshotCapacityTest do
  use Responder.DataCase, async: false

  alias Responder.CanonicalJSON
  alias Responder.Fixtures.Learning, as: Fixtures

  alias Responder.State.{
    ConversationObservation,
    ConversationSummary,
    KnowledgeSnapshot,
    LearningSources,
    SourceExposure
  }

  alias Responder.Work.Custody

  test "later recall pages cannot overflow the session's cumulative source budget" do
    # Structural cardinality expansion of a harvested source. Per-call limits
    # previously admitted 10,001 roots across pages, breaking later summaries.
    [first | _] = Fixtures.inputs!()

    assert {:ok, _} =
             Custody.pin_episode(
               first.episode_id,
               "read-only",
               String.duplicate("a", 64),
               first.repository_ref
             )

    assert {:ok, claim} = Custody.claim_next("exposure-cumulative", 60)
    original = Repo.get_by!(ConversationObservation, source_input_id: first.id)
    [receipt] = LearningSources.for_entry(first)

    pairs =
      for _ <- 1..10_001 do
        id = Ecto.UUID.generate()
        root = %{receipt | "observation_id" => id, "source_input_id" => id}

        attrs =
          original
          |> Map.from_struct()
          |> Map.take(ConversationObservation.__schema__(:fields))
          |> Map.merge(%{
            id: id,
            identity_key: CanonicalJSON.digest(id),
            source_input_id: id,
            source_dependencies: [root],
            note: nil
          })

        {attrs, root}
      end

    pairs
    |> Enum.map(&elem(&1, 0))
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(ConversationObservation, &1))

    roots = Enum.map(pairs, &elem(&1, 1))

    roots
    |> Enum.take(10_000)
    |> Enum.map(fn root ->
      %{
        session_id: claim.session.id,
        observation_id: root["observation_id"],
        source_input_id: root["source_input_id"],
        receipt: root
      }
    end)
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(SourceExposure, &1))

    id = Ecto.UUID.generate()

    summary =
      Repo.insert!(%ConversationSummary{
        id: id,
        ref: "continuity:#{id}",
        identity_key: CanonicalJSON.digest(id),
        transport: original.transport,
        workspace_ref: original.workspace_ref,
        conversation_ref: original.conversation_ref,
        repository_ref: original.repository_ref,
        visibility: original.visibility,
        state: %{},
        state_fingerprint: CanonicalJSON.digest(%{}),
        source_dependencies: [hd(roots), List.last(roots)],
        source_result_ref: "host-cumulative-fixture"
      })

    document = %{"source_ref" => summary.ref, "state" => summary.state}

    assert {:error, :work_memory_source_capacity_exceeded} =
             KnowledgeSnapshot.expose(claim, [document])

    assert Repo.aggregate(SourceExposure, :count) == 10_000

    Repo.update!(Ecto.Changeset.change(summary, source_dependencies: [hd(roots)]))
    assert :ok = KnowledgeSnapshot.expose(claim, [document])
    assert Repo.aggregate(SourceExposure, :count) == 10_000
  end

  test "source exposure uses bounded batches and repeated reads preserve the earliest lifetime" do
    # Structural cardinality expansion of harvested sources, not a captured model
    # response. Fable found 2 SQL round trips per root under the session lock.
    [first | _] = Fixtures.inputs!()

    assert {:ok, _} =
             Custody.pin_episode(
               first.episode_id,
               "read-only",
               String.duplicate("a", 64),
               first.repository_ref
             )

    assert {:ok, claim} = Custody.claim_next("exposure-scale", 60)
    original = Repo.get_by!(ConversationObservation, source_input_id: first.id)
    [receipt] = LearningSources.for_entry(first)

    pairs =
      for _ <- 1..1000 do
        id = Ecto.UUID.generate()
        root = %{receipt | "observation_id" => id, "source_input_id" => id}

        attrs =
          original
          |> Map.from_struct()
          |> Map.take(ConversationObservation.__schema__(:fields))
          |> Map.merge(%{
            id: id,
            identity_key: CanonicalJSON.digest(id),
            source_input_id: id,
            source_dependencies: [root],
            note: nil
          })

        {attrs, root}
      end

    pairs
    |> Enum.map(&elem(&1, 0))
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(ConversationObservation, &1))

    roots = pairs |> Enum.map(&elem(&1, 1)) |> then(&LearningSources.merge([&1]))
    id = Ecto.UUID.generate()

    summary =
      Repo.insert!(%ConversationSummary{
        id: id,
        ref: "continuity:#{id}",
        identity_key: CanonicalJSON.digest(id),
        transport: original.transport,
        workspace_ref: original.workspace_ref,
        conversation_ref: original.conversation_ref,
        repository_ref: original.repository_ref,
        visibility: original.visibility,
        state: %{},
        state_fingerprint: CanonicalJSON.digest(%{}),
        source_dependencies: roots,
        source_result_ref: "host-exposure-scale-fixture"
      })

    document = %{"source_ref" => summary.ref, "state" => summary.state}

    {result, queries} = exposure_queries(fn -> KnowledgeSnapshot.expose(claim, [document]) end)
    assert result == :ok
    assert length(queries) < 20
    assert Repo.aggregate(SourceExposure, :count) == 1000

    {result, queries} = exposure_queries(fn -> KnowledgeSnapshot.expose(claim, [document]) end)
    assert result == :ok
    refute Enum.any?(queries, &String.starts_with?(&1, "UPDATE"))
    assert length(queries) < 20

    [root | rest] = roots

    older =
      Map.put(
        root,
        "retained_at",
        DateTime.utc_now() |> DateTime.add(-600) |> DateTime.to_iso8601()
      )

    Repo.update!(
      Ecto.Changeset.change(summary, source_dependencies: LearningSources.merge([[older | rest]]))
    )

    assert :ok = KnowledgeSnapshot.expose(claim, [document])

    saved =
      Repo.get_by!(SourceExposure,
        session_id: claim.session.id,
        observation_id: root["observation_id"],
        source_input_id: root["source_input_id"]
      )

    assert saved.receipt == older
    assert Repo.aggregate(SourceExposure, :count) == 1000
    assert :ok = KnowledgeSnapshot.authorize_session(claim.episode, claim.session)
  end

  defp exposure_queries(fun) do
    key = {__MODULE__, make_ref()}
    reference = make_ref()

    :ok =
      :telemetry.attach(
        key,
        [:responder, :repo, :query],
        &__MODULE__.record_query/4,
        {self(), reference}
      )

    try do
      result = fun.()
      {result, drain_queries(reference, [])}
    after
      :telemetry.detach(key)
    end
  end

  def record_query(_event, _measurements, %{query: query}, {owner, reference}) do
    if String.contains?(query, "episode_work_source_exposures"),
      do: send(owner, {reference, query})
  end

  defp drain_queries(reference, found) do
    receive do
      {^reference, query} -> drain_queries(reference, [query | found])
    after
      0 -> found
    end
  end
end
