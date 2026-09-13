defmodule Ryker.Repo.Migrations.RecordEngagementReceipts do
  use Ecto.Migration

  def change do
    alter table(:ingress_inbox_entries) do
      # Why this input entered processing: the path it came through, the
      # effective participation settings with the source each value won from,
      # and the outcome of every engagement check including the ones the gate
      # short-circuited past ("not checked" is a recorded fact, not a "no").
      # Null means no receipt was recorded, including every input before this
      # column; the page must not recompute it from today's settings.
      add(:engagement_receipt, :text)
    end

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_engagement_receipt_valid,
        check: "engagement_receipt IS NULL OR octet_length(engagement_receipt) BETWEEN 2 AND 8192"
      )
    )
  end
end
