defmodule Ryker.Repo.Migrations.DropTaskCardRenderedOfferRef do
  use Ecto.Migration

  # Nothing has written slack_task_cards.rendered_publication_offer_ref since the
  # readiness click it recorded was retired; no live row held a value on
  # 2026-10-06 (0 of 5), and no code reads it (2026-10-04 review). The table's
  # check names the column, so it is rebuilt without that clause; a row with a
  # value would be lost, so the column goes only because none has one.

  @kept """
  char_length(ref) BETWEEN 1 AND 256
    AND char_length(workspace_ref) BETWEEN 1 AND 256
    AND char_length(channel_ref) BETWEEN 1 AND 256
    AND char_length(thread_ref) BETWEEN 1 AND 1024
    AND char_length(message_ref) BETWEEN 1 AND 1024
    AND card_ui_revision >= 0
    AND (card_fingerprint IS NULL OR char_length(card_fingerprint) = 64)
  """

  @leases """
  attempt_count >= 0
    AND ((lease_owner IS NULL AND lease_ref IS NULL AND lease_expires_at IS NULL)
      OR (char_length(lease_owner) > 0 AND lease_ref IS NOT NULL AND lease_expires_at IS NOT NULL))
  """

  @offer_ref """
  (rendered_publication_offer_ref IS NULL
    OR char_length(rendered_publication_offer_ref) BETWEEN 1 AND 256)
  """

  def up do
    execute("ALTER TABLE slack_task_cards DROP CONSTRAINT slack_task_card_valid")

    alter table(:slack_task_cards) do
      remove(:rendered_publication_offer_ref)
    end

    valid("#{@kept} AND #{@leases}")
  end

  def down do
    execute("ALTER TABLE slack_task_cards DROP CONSTRAINT slack_task_card_valid")

    alter table(:slack_task_cards) do
      add(:rendered_publication_offer_ref, :text)
    end

    valid("#{@kept} AND #{@offer_ref} AND #{@leases}")
  end

  defp valid(check),
    do:
      execute(
        "ALTER TABLE slack_task_cards ADD CONSTRAINT slack_task_card_valid CHECK (#{check})"
      )
end
