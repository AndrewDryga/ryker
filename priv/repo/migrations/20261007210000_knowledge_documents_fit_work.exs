defmodule Ryker.Repo.Migrations.KnowledgeDocumentsFitWork do
  use Ecto.Migration

  # A repository's RYKER.md was kept up to 128,000 bytes, and every Work turn's
  # briefing carried at most 48 KiB of it, cut in the middle (2026-10-04
  # review). What Ryker keeps is now what Work reads whole; the largest live
  # document was 16,473 bytes on 2026-10-07.

  @tables [
    repository_knowledge: :repository_knowledge_document_fits_work,
    repository_knowledge_runs: :repository_knowledge_run_document_fits_work
  ]

  def change do
    for {table, name} <- @tables do
      create(
        constraint(table, name, check: "document IS NULL OR octet_length(document) <= 49152")
      )
    end
  end
end
