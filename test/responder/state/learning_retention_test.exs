defmodule Responder.State.LearningRetentionTest do
  use Responder.DataCase, async: false

  alias Responder.CanonicalJSON
  alias Responder.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.State.{Learning, LearningRun}

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}
  @retention_seconds 3_600

  test "pruning a topic cannot hide expiry of its copies in a frozen learning request" do
    # Compact references must keep their lifetime after the referenced prose
    # is pruned, otherwise copied prompts outlive their expired original source.
    [first, second] = Fixtures.inputs!()
    {_source, document} = KnowledgeFixtures.learn!(first, first.repository_ref)
    "knowledge:" <> id = document["source_ref"]
    head = Repo.get!(Responder.State.ConversationKnowledge, id)
    assert {:ok, run} = Learning.prepare([first.id], @policy)
    assert {:ok, current} = Learning.prepare([second.id], @policy)

    saved =
      Repo.update!(
        Ecto.Changeset.change(run,
          source_dependencies: head.source_dependencies,
          knowledge: [document],
          prompt: Jason.encode!(%{"knowledge" => [document]})
        )
      )

    Repo.query!(
      """
      UPDATE conversation_knowledge_sources
      SET receipt = jsonb_set(receipt::jsonb, '{retained_at}', to_jsonb($2::text))::text,
        retained_at = $2::timestamptz
      WHERE knowledge_id = $1::uuid
      """,
      [Ecto.UUID.dump!(id), expired_clock()]
    )

    Repo.query!(
      """
      UPDATE conversation_knowledge_revisions SET state = '{"retention":"pruned"}'
      WHERE knowledge_id = $1::uuid
      """,
      [Ecto.UUID.dump!(id)]
    )

    assert_prunes_only!(saved, current)
  end

  for clock <- [
        nil,
        3,
        %{},
        "",
        "not-a-timestamp",
        "-infinity",
        "infinity",
        "now",
        "2000-01-01",
        "2000-01-01T00:00:00+01:00",
        "2000-02-30T00:00:00Z",
        "2000-01-01T24:00:00Z",
        "2000-01-01T00:00:00-00:00",
        "2000-01-01T00:00:00Z\nextra"
      ] do
    test "unknown source clock #{inspect(clock)} preserves its learning record without blocking due cleanup" do
      # One bad retained clock used to abort the entire retention transaction,
      # preventing unrelated expired copies from being removed. Unknown age is
      # not evidence of expiry: retain that prompt and its audit identity.
      {malformed, expired, current} = retained_runs!()

      dependencies =
        Enum.map(
          malformed.source_dependencies,
          &Map.put(&1, "retained_at", unquote(Macro.escape(clock)))
        )

      replace_json!(malformed, "source_dependencies", CanonicalJSON.encode!(dependencies))
      before = retained_text(malformed)
      assert_prunes_only!(expired, current)
      assert retained_text(malformed) == before
    end
  end

  for field <- ~w(source_dependencies inputs),
      raw <- ["[]", "null", "{}", "\"unavailable\"", "3", "not-json"] do
    test "#{field} shape #{raw} cannot poison another learning record's cleanup" do
      # These columns are NOT NULL text, but have no database JSON-shape
      # constraint. JSON null/scalars and even invalid JSON must fail closed,
      # without authorizing removal of a record with otherwise current sources.
      {malformed, expired, current} = retained_runs!()
      replace_json!(malformed, unquote(field), unquote(raw))
      before = retained_text(malformed)
      assert_prunes_only!(expired, current)
      assert retained_text(malformed) == before
    end
  end

  for raw <- ["[null]", "[3]", "[{}]", "[null,42,{}]"] do
    test "source receipt element #{raw} does not invent an expiry clock" do
      {malformed, expired, current} = retained_runs!()
      replace_json!(malformed, "source_dependencies", unquote(raw))
      before = retained_text(malformed)
      assert_prunes_only!(expired, current)
      assert retained_text(malformed) == before
    end
  end

  for value <- [nil, 42, 12_345_678_901_234_567_890_123_456_789_012, true, %{}, [], "not-a-uuid"] do
    test "input reference #{inspect(value)} is unknown rather than a missing source" do
      {malformed, expired, current} = retained_runs!()
      inputs = [%{"source_input_id" => unquote(Macro.escape(value))}]
      replace_json!(malformed, "inputs", CanonicalJSON.encode!(inputs))
      before = retained_text(malformed)
      assert_prunes_only!(expired, current)
      assert retained_text(malformed) == before
    end
  end

  test "input elements with no identity do not mean a known source was deleted" do
    {malformed, expired, current} = retained_runs!()
    replace_json!(malformed, "inputs", "[null,42,{}]")
    before = retained_text(malformed)
    assert_prunes_only!(expired, current)
    assert retained_text(malformed) == before
  end

  test "an existing input UUID's uppercase spelling is not mistaken for a missing source" do
    {malformed, expired, current} = retained_runs!()

    inputs =
      Enum.map(
        malformed.inputs,
        &Map.update!(&1, "source_input_id", fn id -> String.upcase(id) end)
      )

    replace_json!(malformed, "inputs", CanonicalJSON.encode!(inputs))
    before = retained_text(malformed)
    assert_prunes_only!(expired, current)
    assert retained_text(malformed) == before
  end

  test "a well-formed missing input UUID still expires its copies alongside unknown elements" do
    [first, second] = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare([first.id], @policy)
    assert {:ok, current} = Learning.prepare([second.id], @policy)
    input = hd(run.inputs) |> Map.put("source_input_id", Ecto.UUID.generate())
    replace_json!(run, "inputs", CanonicalJSON.encode!([nil, 42, %{}, input]))
    assert_prunes_only!(Repo.get!(LearningRun, run.id), current)
  end

  for offset <- ~w(Z +00 +0000 +00:00 -00 -0000), separator <- [".", ","] do
    test "expired UTC clock with #{offset} offset and #{separator} fraction still prunes normally" do
      {untouched, expired, current} = retained_runs!()

      dependencies =
        Enum.map(expired.source_dependencies, fn receipt ->
          clock =
            receipt["retained_at"]
            |> String.replace(".", unquote(separator))
            |> String.replace_suffix("Z", unquote(offset))

          assert {:ok, _, 0} = DateTime.from_iso8601(clock)
          Map.put(receipt, "retained_at", clock)
        end)

      expired = Repo.update!(Ecto.Changeset.change(expired, source_dependencies: dependencies))
      before = retained_text(untouched)
      assert_prunes_only!(expired, current)
      assert retained_text(untouched) == before
    end
  end

  test "one valid expired dependency still authorizes cleanup alongside a malformed clock" do
    entries = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    [first, second] = run.source_dependencies

    dependencies = [
      Map.put(first, "retained_at", "not-a-timestamp"),
      Map.put(second, "retained_at", expired_clock())
    ]

    saved = Repo.update!(Ecto.Changeset.change(run, source_dependencies: dependencies))

    assert {:ok, 1} =
             Repo.transaction(fn -> Learning.prune_in_transaction(@retention_seconds) end)

    assert_pruned_receipt!(saved)
  end

  test "a null dependency cannot hide another genuinely expired source" do
    [first, second] = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare([first.id], @policy)
    assert {:ok, current} = Learning.prepare([second.id], @policy)
    expired = hd(run.source_dependencies) |> Map.put("retained_at", expired_clock())
    saved = Repo.update!(Ecto.Changeset.change(run, source_dependencies: [nil, expired]))
    assert_prunes_only!(saved, current)
  end

  test "fresh UTC receipt clocks with decimal commas keep the entire learning record" do
    {untouched, expired, current} = retained_runs!()

    dependencies =
      Enum.map(current.source_dependencies, fn receipt ->
        clock = String.replace(receipt["retained_at"], ".", ",")
        assert clock =~ ","
        assert {:ok, instant, 0} = DateTime.from_iso8601(clock)
        assert DateTime.to_iso8601(instant) == receipt["retained_at"]
        Map.put(receipt, "retained_at", clock)
      end)

    current = Repo.update!(Ecto.Changeset.change(current, source_dependencies: dependencies))
    before = retained_text(untouched)
    assert_prunes_only!(expired, current)
    assert retained_text(untouched) == before
  end

  test "a known operationally pruned input still expires copies with unknown dependency history" do
    [first, second] = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare([first.id], @policy)
    assert {:ok, current} = Learning.prepare([second.id], @policy)
    replace_json!(run, "source_dependencies", "null")
    saved = Repo.get!(LearningRun, run.id)

    Repo.update!(Ecto.Changeset.change(first, operational_pruned_at: DateTime.utc_now()))

    assert_prunes_only!(saved, current)
  end

  defp retained_runs! do
    # Exact harvested inputs produce genuine host-owned, persisted source
    # receipts through Learning.prepare. Only the tested stored field is fault
    # injected; no model output or historical Slack receipt is fabricated.
    [first, second] = entries = Fixtures.inputs!()
    assert {:ok, expired} = Learning.prepare([first.id], @policy)
    assert {:ok, current} = Learning.prepare([second.id], @policy)
    assert {:ok, malformed} = Learning.prepare(Enum.map(entries, & &1.id), @policy)

    dependencies =
      Enum.map(expired.source_dependencies, &Map.put(&1, "retained_at", expired_clock()))

    expired = Repo.update!(Ecto.Changeset.change(expired, source_dependencies: dependencies))
    {malformed, expired, current}
  end

  defp expired_clock do
    DateTime.utc_now()
    |> DateTime.add(-2 * @retention_seconds, :second)
    |> DateTime.to_iso8601()
  end

  defp replace_json!(run, field, raw) when field in ~w(source_dependencies inputs) do
    Repo.query!("UPDATE conversation_learning_runs SET #{field} = $1 WHERE id::text = $2", [
      raw,
      run.id
    ])
  end

  defp retained_text(run) do
    Repo.query!(
      "SELECT row_to_json(l)::text FROM conversation_learning_runs l WHERE id::text = $1",
      [run.id]
    ).rows
  end

  defp assert_prunes_only!(expired, current) do
    assert {:ok, 1} =
             Repo.transaction(fn -> Learning.prune_in_transaction(@retention_seconds) end)

    assert_pruned_receipt!(expired)
    assert Repo.get!(LearningRun, current.id) == current
  end

  defp assert_pruned_receipt!(original) do
    saved = Repo.get!(LearningRun, original.id)
    assert saved.prompt == nil
    assert saved.result == nil
    assert saved.knowledge == []
    assert saved.producer == %{}
    assert saved.pruned_at != nil

    assert Map.drop(saved, [:prompt, :result, :knowledge, :producer, :pruned_at, :updated_at]) ==
             Map.drop(original, [:prompt, :result, :knowledge, :producer, :pruned_at, :updated_at])
  end
end
