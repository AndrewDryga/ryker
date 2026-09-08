defmodule Responder.State.KnowledgeRetentionShapeTest do
  use Responder.DataCase, async: true

  alias Responder.CanonicalJSON
  alias Responder.Fixtures.Learning, as: LearningFixtures

  alias Responder.State.{
    ConversationObservation,
    ConversationRollup,
    ConversationSummary,
    KnowledgeRetention,
    LearningSources
  }

  @retention_seconds 3_600

  test "retention fixtures isolate shared lock identities while retaining both source messages" do
    # The outer sandbox holds conversation/configuration locks until test exit;
    # replay tests legitimately acquire those same production locks in other
    # transactions. Shared captured fixture identities created an artificial cycle.
    originals =
      "testdata/learning/retained-haproxy-lifecycle.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")

    entries = retained_inputs!()
    assert length(entries) == length(originals)
    assert length(Enum.uniq_by(entries, & &1.destination_conversation_ref)) == 1

    for {entry, raw} <- Enum.zip(entries, originals) do
      refute entry.id == raw["id"]
      refute entry.source_ref == raw["source_ref"]
      refute entry.destination_conversation_ref == raw["destination_conversation_ref"]
      assert entry.content == raw["content"]

      assert DateTime.to_naive(entry.occurred_at) ==
               NaiveDateTime.from_iso8601!(raw["occurred_at"])
    end
  end

  for schema <- [ConversationSummary, ConversationRollup],
      history <- [[], nil, %{}, "unavailable"] do
    test "#{inspect(schema)} history #{inspect(history)} cannot abort expiry of a sourced neighbor" do
      # Receiptless retained history must not crash the maintenance transaction
      # and prevent genuinely expired source prose from being withdrawn.
      [expired_entry, current_entry] = retained_inputs!()
      old = DateTime.add(DateTime.utc_now(), -2 * @retention_seconds, :second)
      source = Repo.get_by!(ConversationObservation, source_input_id: expired_entry.id)
      Repo.update!(Ecto.Changeset.change(source, updated_at: old))
      assert [_] = expired_sources = LearningSources.for_entry(expired_entry)
      assert [_] = current_sources = LearningSources.for_entry(current_entry)

      schema = unquote(schema)
      history = retained!(schema, unquote(Macro.escape(history)), source)
      expired = retained!(schema, expired_sources, source)
      current = retained!(schema, current_sources, source)

      assert {:ok, 1} =
               Repo.transaction(fn ->
                 KnowledgeRetention.prune_in_transaction(@retention_seconds)
               end)

      assert Repo.get!(schema, expired.id).state == %{"retention" => "pruned"}
      # Keep the audit identity, not up to 8 MiB of now-unused copied receipts.
      # Consumers of a handover already inherit terminal roots of their own.
      assert Repo.get!(schema, expired.id).source_dependencies == []

      assert Repo.get!(schema, expired.id).state_fingerprint ==
               CanonicalJSON.digest(%{"retention" => "pruned"})

      assert Repo.get!(schema, history.id) == history
      assert Repo.get!(schema, current.id) == current
    end
  end

  for schema <- [ConversationSummary, ConversationRollup],
      retained_at <- [
        nil,
        "not-a-timestamp",
        "-infinity",
        "infinity",
        "now",
        "2000-01-01T00:00:00+01:00",
        "2000-01-01"
      ] do
    test "#{inspect(schema)} receipt time #{inspect(retained_at)} cannot abort expiry of a sourced neighbor" do
      # One malformed retained source time must neither destroy that record nor
      # roll back expiry of unrelated, genuinely expired source prose.
      # PostgreSQL accepts special values and non-UTC formats that are not
      # valid receipt clocks; parsing them is not authority to expire a row.
      [expired_entry, current_entry] = retained_inputs!()
      old = DateTime.add(DateTime.utc_now(), -2 * @retention_seconds, :second)
      source = Repo.get_by!(ConversationObservation, source_input_id: expired_entry.id)
      Repo.update!(Ecto.Changeset.change(source, updated_at: old))
      assert [receipt] = expired_sources = LearningSources.for_entry(expired_entry)
      assert [_] = current_sources = LearningSources.for_entry(current_entry)

      schema = unquote(schema)
      malformed_receipt = Map.put(receipt, "retained_at", unquote(retained_at))
      malformed = retained!(schema, [malformed_receipt], source)
      original_text = retained_text(schema, malformed.id)
      expired = retained!(schema, expired_sources, source)
      current = retained!(schema, current_sources, source)

      assert {:ok, 1} =
               Repo.transaction(fn ->
                 KnowledgeRetention.prune_in_transaction(@retention_seconds)
               end)

      assert Repo.get!(schema, expired.id).state == %{"retention" => "pruned"}

      assert Repo.get!(schema, expired.id).state_fingerprint ==
               CanonicalJSON.digest(%{"retention" => "pruned"})

      assert Repo.get!(schema, malformed.id) == malformed
      assert retained_text(schema, malformed.id) == original_text
      assert Repo.get!(schema, current.id) == current
    end
  end

  for schema <- [ConversationSummary, ConversationRollup],
      variant <- [:decimal_comma, :negative_zero_offset] do
    test "#{inspect(schema)} expired UTC receipt using #{variant} still expires normally" do
      # Rejecting PostgreSQL-only clocks must not silently disable expiry for
      # equivalent UTC spellings already accepted by the receipt validator.
      [expired_entry, current_entry] = retained_inputs!()
      old = DateTime.add(DateTime.utc_now(), -2 * @retention_seconds, :second)
      source = Repo.get_by!(ConversationObservation, source_input_id: expired_entry.id)
      Repo.update!(Ecto.Changeset.change(source, updated_at: old))
      assert [receipt] = LearningSources.for_entry(expired_entry)
      assert [_] = current_sources = LearningSources.for_entry(current_entry)

      clock =
        case unquote(variant) do
          :decimal_comma -> String.replace(receipt["retained_at"], ".", ",")
          :negative_zero_offset -> String.replace_suffix(receipt["retained_at"], "Z", "-0000")
        end

      assert {:ok, instant, 0} = DateTime.from_iso8601(clock)
      assert DateTime.to_iso8601(instant) == receipt["retained_at"]
      schema = unquote(schema)
      expired = retained!(schema, [Map.put(receipt, "retained_at", clock)], source)
      current = retained!(schema, current_sources, source)

      assert {:ok, 1} =
               Repo.transaction(fn ->
                 KnowledgeRetention.prune_in_transaction(@retention_seconds)
               end)

      assert Repo.get!(schema, expired.id).state == %{"retention" => "pruned"}

      assert Repo.get!(schema, expired.id).state_fingerprint ==
               CanonicalJSON.digest(%{"retention" => "pruned"})

      assert Repo.get!(schema, current.id) == current
    end
  end

  defp retained_inputs!, do: LearningFixtures.inputs!(isolate: true)

  defp retained_text(schema, id) do
    Repo.query!(
      "SELECT state, source_dependencies FROM #{schema.__schema__(:source)} WHERE id::text = $1",
      [id]
    ).rows
  end

  defp retained!(schema, dependencies, source) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()
    state = %{"situation" => "Retained structural fixture for source-history expiry."}

    attributes = %{
      id: id,
      workspace_ref: source.workspace_ref,
      visibility: source.visibility,
      repository_ref: source.repository_ref,
      state: state,
      state_fingerprint: CanonicalJSON.digest(state),
      source_dependencies: dependencies || []
    }

    specific =
      case schema do
        ConversationSummary ->
          %{
            ref: "continuity:#{id}",
            identity_key: CanonicalJSON.digest(id),
            transport: source.transport,
            conversation_ref: source.conversation_ref,
            source_result_ref: "result:#{id}"
          }

        ConversationRollup ->
          %{
            ref: "continuity-rollup:#{id}",
            scope_kind: :conversation,
            scope_ref: source.conversation_ref,
            period_start: DateTime.add(now, -86_400, :second),
            period_end: now,
            expires_at: DateTime.add(now, 86_400, :second),
            source_refs: ["continuity:#{id}"],
            source_scopes: [],
            source_count: 1
          }
      end

    saved = schema |> struct!(Map.merge(attributes, specific)) |> Repo.insert!()

    # The schema defaults to []; retain actual SQL NULL when that is the case
    # under test rather than accidentally testing an empty array twice.
    if is_nil(dependencies),
      do: Repo.update!(Ecto.Changeset.change(saved, source_dependencies: nil)),
      else: saved
  end
end
