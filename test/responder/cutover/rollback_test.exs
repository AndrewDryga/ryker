defmodule Responder.Cutover.RollbackTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Cutover.{Importer, Item, Ledger, LegacySchema, Rollback, Run}
  alias Responder.Repo
  alias Responder.State.{Memories, MemoryEntry}

  test "an untouched applied cutover rolls back once and retains its audit ledger" do
    envelope = envelope()
    {:ok, %{run: run}} = Ledger.prepare(envelope, review(envelope))
    assert {:ok, %{status: :applied}} = Importer.apply(run.id)
    assert Repo.aggregate(MemoryEntry, :count) == 1

    assert {:ok, %{status: :rolled_back, run: %Run{} = rolled_back}} =
             Rollback.rollback(run.id, "operator:andrew")

    assert rolled_back.rolled_back_by == "operator:andrew"
    assert %DateTime{} = rolled_back.rolled_back_at
    assert Repo.aggregate(MemoryEntry, :count) == 0

    item = Repo.one!(from(value in Item, where: value.run_id == ^run.id))
    assert item.status == :rolled_back
    assert is_list(item.target_refs)
    assert is_binary(item.target_fingerprint)

    assert {:ok, %{status: :duplicate}} = Rollback.rollback(run.id, "operator:andrew")

    assert Rollback.rollback(run.id, "operator:different") ==
             {:error, :cutover_rollback_operator_conflict}
  end

  test "rollback refuses state that the replacement runtime has already used" do
    envelope = envelope()
    {:ok, %{run: run}} = Ledger.prepare(envelope, review(envelope))
    assert {:ok, %{status: :applied}} = Importer.apply(run.id)

    assert [_memory] =
             Memories.recall(%{
               conversation_ref: "slack:T123:C456",
               repository: nil,
               workspace_ref: "slack:T123"
             })

    assert Rollback.rollback(run.id, "operator:andrew") ==
             {:error, {:cutover_target_changed, "memory:legacy-memory"}}

    assert Repo.get!(Run, run.id).status == :applied
    assert Repo.aggregate(MemoryEntry, :count) == 1
    assert Repo.one!(Item).status == :applied
  end

  test "rollback rejects invalid, missing, and unapplied runs without changing the ledger" do
    assert Rollback.rollback("not-a-uuid", "operator:andrew") ==
             {:error, {:invalid_cutover_rollback, :run_id}}

    assert Rollback.rollback(Ecto.UUID.generate(), "operator:andrew") ==
             {:error, :cutover_run_not_found}

    envelope = envelope()
    {:ok, %{run: run}} = Ledger.prepare(envelope, review(envelope))

    assert Rollback.rollback(run.id, "operator:andrew") ==
             {:error, {:cutover_run_not_rollbackable, :prepared}}

    assert Rollback.rollback(run.id, " ") ==
             {:error, {:invalid_cutover_rollback, :operator_ref}}

    assert Repo.get!(Run, run.id).status == :prepared
    assert Repo.one!(Item).status == :pending
  end

  defp envelope do
    data = %{
      "actor_id" => "U123",
      "created_at" => "2026-08-01T00:00:00.000000Z",
      "expires_at" => "2099-08-30T12:00:00.000000Z",
      "id" => "legacy-memory",
      "last_recalled_at" => nil,
      "last_reviewed_at" => nil,
      "predicate" => "alias_of",
      "recall_count" => 3,
      "scope_key" => "C456",
      "scope_kind" => "channel",
      "source_ref" => "message:memory",
      "source_revision" => "1",
      "subject_key" => "checkout",
      "updated_at" => "2026-08-29T00:00:00.000000Z",
      "value_hash" => String.duplicate("a", 64),
      "value_json" => %{"value" => "payments"},
      "visibility_id" => "C456",
      "visibility_kind" => "channel"
    }

    item = %{
      "data" => data,
      "decision" => "import",
      "id" => "memory:legacy-memory",
      "kind" => "memory",
      "source" => %{
        "ref" => "legacy-memory",
        "sha256" => CanonicalJSON.digest(data),
        "table" => "memory_entries"
      }
    }

    manifest = %{
      "cutover_at" => "2026-08-30T12:00:00.000000Z",
      "items" => [item],
      "source" => %{
        "kind" => "responder_sqlite",
        "schema_sha256" => LegacySchema.sha256(),
        "schema_version" => LegacySchema.version(),
        "sha256" => String.duplicate("a", 64)
      },
      "summary" => %{"memory" => 1},
      "version" => 1,
      "workspace_ref" => "slack:T123"
    }

    %{"manifest" => manifest, "sha256" => CanonicalJSON.digest(manifest)}
  end

  defp review(envelope) do
    %{
      "decisions" => %{},
      "manifest_sha256" => envelope["sha256"],
      "operator_ref" => "operator:andrew",
      "reviewed_at" => "2026-08-30T12:05:00.000000Z",
      "version" => 1
    }
  end
end
