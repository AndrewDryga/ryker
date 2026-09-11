defmodule Responder.Repo.Migrations.RetainSourceEnvelopes do
  use Ecto.Migration

  def change do
    alter table(:ingress_inbox_entries) do
      # The source's own event payload, exactly as the adapter received it,
      # kept beside the normalized content it was turned into. Null means the
      # adapter did not hand one over, including every input that predates
      # this column; the normalized document is never relabelled as raw.
      # Canonical JSON text, bounded, and pruned with the other input bodies.
      add(:source_envelope, :text)
    end

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_source_envelope_valid,
        check: "source_envelope IS NULL OR octet_length(source_envelope) BETWEEN 2 AND 65536"
      )
    )
  end
end
