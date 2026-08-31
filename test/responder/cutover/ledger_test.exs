defmodule Responder.Cutover.LedgerTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.{CanonicalJSON, Repo}
  alias Responder.Cutover.{Item, Ledger, LegacySchema, Run}

  test "a sealed inventory and complete human review become one idempotent cutover plan" do
    envelope = envelope()

    review =
      review(envelope, %{"episode:legacy-episode" => "import", "wait:legacy-wait" => "import"})

    assert {:ok, %{status: :prepared, run: %Run{} = run}} = Ledger.prepare(envelope, review)
    assert run.status == :prepared
    assert run.manifest_sha256 == envelope["sha256"]
    assert run.review_sha256 == CanonicalJSON.digest(review)
    assert run.item_count == 3

    items =
      Repo.all(
        from(item in Item,
          where: item.run_id == ^run.id,
          order_by: [asc: item.ref]
        )
      )

    assert Enum.map(items, &{&1.ref, &1.decision, &1.status}) == [
             {"episode:legacy-episode", :import, :pending},
             {"memory:legacy-memory", :import, :pending},
             {"wait:legacy-wait", :import, :pending}
           ]

    assert {:ok, %{status: :duplicate, run: %Run{id: duplicate_id}}} =
             Ledger.prepare(envelope, review)

    assert duplicate_id == run.id
    assert Repo.aggregate(from(item in Item, where: item.run_id == ^run.id), :count) == 3
  end

  test "tampering, incomplete review, and orphaned imported waits fail before persistence" do
    envelope = envelope()

    tampered = put_in(envelope, ["manifest", "workspace_ref"], "slack:T999")
    assert Ledger.prepare(tampered, review(envelope, %{})) == {:error, :cutover_manifest_invalid}

    wrong_schema_version =
      reseal(envelope, &put_in(&1, ["source", "schema_version"], 91))

    assert Ledger.prepare(wrong_schema_version, review(wrong_schema_version, %{})) ==
             {:error, :cutover_manifest_invalid}

    wrong_schema_digest =
      reseal(envelope, &put_in(&1, ["source", "schema_sha256"], String.duplicate("f", 64)))

    assert Ledger.prepare(wrong_schema_digest, review(wrong_schema_digest, %{})) ==
             {:error, :cutover_manifest_invalid}

    assert Ledger.prepare(envelope, review(envelope, %{})) ==
             {:error, {:cutover_review_missing, "episode:legacy-episode"}}

    orphaned =
      review(envelope, %{
        "episode:legacy-episode" => "skip",
        "wait:legacy-wait" => "import"
      })

    assert Ledger.prepare(envelope, orphaned) ==
             {:error, {:cutover_wait_episode_not_imported, "wait:legacy-wait"}}

    assert Repo.aggregate(Run, :count) == 0
    assert Repo.aggregate(Item, :count) == 0
  end

  test "one inventory cannot be rebound to a different reviewed decision" do
    envelope = envelope()

    imported =
      review(envelope, %{
        "episode:legacy-episode" => "import",
        "wait:legacy-wait" => "import"
      })

    skipped =
      review(envelope, %{
        "episode:legacy-episode" => "skip",
        "wait:legacy-wait" => "skip"
      })

    assert {:ok, %{status: :prepared}} = Ledger.prepare(envelope, imported)
    assert Ledger.prepare(envelope, skipped) == {:error, :cutover_manifest_review_conflict}
  end

  test "malformed operator artifacts fail before any ledger row is written" do
    valid = envelope()

    assert Ledger.prepare("not-an-envelope", %{}) == {:error, :cutover_manifest_invalid}
    assert Ledger.prepare(valid, "not-a-review") == {:error, :cutover_review_invalid}

    non_list_items = reseal(valid, &Map.put(&1, "items", %{}))

    assert Ledger.prepare(non_list_items, review(non_list_items, %{})) ==
             {:error, :cutover_items_invalid}

    malformed_item = reseal(valid, &Map.put(&1, "items", [%{}]))

    assert Ledger.prepare(malformed_item, review(malformed_item, %{})) ==
             {:error, :cutover_item_invalid}

    wrong_table =
      reseal(valid, fn manifest ->
        items =
          Enum.map(manifest["items"], fn
            %{"kind" => "memory"} = item -> put_in(item, ["source", "table"], "scheduled_tasks")
            item -> item
          end)

        Map.put(manifest, "items", items)
      end)

    decisions = %{"episode:legacy-episode" => "import", "wait:legacy-wait" => "import"}

    assert Ledger.prepare(wrong_table, review(wrong_table, decisions)) ==
             {:error, :cutover_item_invalid}

    unsupported_decision =
      reseal(valid, fn manifest ->
        items =
          Enum.map(manifest["items"], fn
            %{"kind" => "memory"} = item -> Map.put(item, "decision", "merge")
            item -> item
          end)

        Map.put(manifest, "items", items)
      end)

    assert Ledger.prepare(unsupported_decision, review(unsupported_decision, decisions)) ==
             {:error, :cutover_item_invalid}

    non_text_cutover = reseal(valid, &Map.put(&1, "cutover_at", 1_788_000_000))

    assert Ledger.prepare(non_text_cutover, review(non_text_cutover, decisions)) ==
             {:error, {:cutover_datetime_invalid, :cutover_at}}

    invalid_cutover = reseal(valid, &Map.put(&1, "cutover_at", "tomorrow"))

    assert Ledger.prepare(invalid_cutover, review(invalid_cutover, decisions)) ==
             {:error, {:cutover_datetime_invalid, :cutover_at}}

    assert Repo.aggregate(Run, :count) == 0
    assert Repo.aggregate(Item, :count) == 0
  end

  defp envelope do
    items = [
      item("episode", "legacy-episode", "work_episodes", "review", %{
        "lifecycle_state" => "working"
      }),
      item("memory", "legacy-memory", "memory_entries", "import", %{
        "predicate" => "alias_of",
        "value_json" => %{"value" => "payments"}
      }),
      item("wait", "legacy-wait", "episode_wakeups", "review", %{
        "episode_id" => "legacy-episode",
        "kind" => "event",
        "state" => "pending"
      })
    ]

    manifest = %{
      "cutover_at" => "2026-08-30T12:00:00.000000Z",
      "items" => items,
      "source" => %{
        "kind" => "responder_sqlite",
        "schema_sha256" => LegacySchema.sha256(),
        "schema_version" => LegacySchema.version(),
        "sha256" => String.duplicate("a", 64)
      },
      "summary" => %{"episode" => 1, "memory" => 1, "wait" => 1},
      "version" => 1,
      "workspace_ref" => "slack:T123"
    }

    %{"manifest" => manifest, "sha256" => CanonicalJSON.digest(manifest)}
  end

  defp item(kind, source_ref, table, decision, data) do
    %{
      "data" => data,
      "decision" => decision,
      "id" => "#{kind}:#{source_ref}",
      "kind" => kind,
      "source" => %{
        "ref" => source_ref,
        "sha256" => CanonicalJSON.digest(data),
        "table" => table
      }
    }
  end

  defp review(envelope, decisions) do
    %{
      "decisions" => decisions,
      "manifest_sha256" => envelope["sha256"],
      "operator_ref" => "operator:andrew",
      "reviewed_at" => "2026-08-30T12:05:00.000000Z",
      "version" => 1
    }
  end

  defp reseal(envelope, update) do
    manifest = update.(envelope["manifest"])
    %{"manifest" => manifest, "sha256" => CanonicalJSON.digest(manifest)}
  end
end
