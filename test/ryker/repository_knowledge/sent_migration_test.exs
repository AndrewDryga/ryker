defmodule Ryker.RepositoryKnowledge.SentMigrationTest do
  @moduledoc """
  A knowledge entry records the sha256 of each document Ryker was about to
  write on its pull request's branch since it last recorded a proposal
  there (`Ryker.RepositoryKnowledge.Custody.sending/1`). The column is added
  to entries every installation already has: each keeps what it had and
  starts with nothing sent, and nothing but a sha256 is kept as sent.
  """
  # The migrator runs inside this test's sandbox transaction.
  use Ryker.DataCase, async: false

  alias Ryker.RepositoryKnowledge.Entry

  @version 20_260_928_110_000
  @migration Ryker.Repo.Migrations.RecordRepositoryKnowledgeSent
  @file_name "20260928110000_record_repository_knowledge_sent.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]
  @document "# RYKER.md\n\nWritten by Ryker from `aaaaaaa` on 2026-09-27.\n\n## Purpose\n\nIt works.\n"

  test "every entry keeps what it had and starts with nothing sent, and only a sha256 is kept" do
    now = Repo.now!()
    digest = sha256(@document)

    Repo.insert!(%Entry{
      repository_ref: "api",
      document: @document,
      document_sha256: digest,
      document_commit: String.duplicate("a", 40),
      document_by: :model,
      document_at: now,
      published_at: now,
      publication: :opened,
      pull_request_url: "https://github.com/acme/api/pull/7",
      pull_request_number: 7,
      pull_request_state: :open
    })

    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)
    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)

    entry = Repo.get!(Entry, "api")

    assert {entry.document, entry.document_sha256, entry.publication, entry.pull_request_number} ==
             {@document, digest, :opened, 7}

    assert entry.sent_sha256s == []

    assert %Entry{sent_sha256s: [^digest]} =
             entry |> Ecto.Changeset.change(sent_sha256s: [digest]) |> Repo.update!()

    for invalid <- [["not a sha256"], [digest, ""]] do
      assert_raise Ecto.ConstraintError, ~r/repository_knowledge_sent_valid/, fn ->
        Repo.transaction(fn ->
          entry |> Ecto.Changeset.change(sent_sha256s: invalid) |> Repo.update!()
        end)
      end
    end
  end

  # `ecto.migrate` loads a migration only while it is pending, so a database
  # migrated by an earlier run leaves it for this test to load.
  defp migration do
    unless Code.ensure_loaded?(@migration) do
      :ryker
      |> Application.app_dir(Path.join("priv/repo/migrations", @file_name))
      |> Code.compile_file()
    end

    @migration
  end

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
