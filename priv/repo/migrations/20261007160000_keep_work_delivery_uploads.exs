defmodule Ryker.Repo.Migrations.KeepWorkDeliveryUploads do
  use Ecto.Migration

  # Slack shares an uploaded image a moment after the upload completes. An
  # attempt that saw the upload finish but not yet the share was retried, found
  # no share, and uploaded the images again (2026-10-04 review). A turn keeps
  # the ids of the files an attempt uploaded, so the next attempt waits for
  # their share instead. A reply holds at most five images.

  def change do
    alter table(:episode_work_turns) do
      add(:delivery_upload_refs, {:array, :text}, null: false, default: [])
    end

    create(
      constraint(:episode_work_turns, :episode_work_turn_delivery_uploads_valid,
        check: """
        cardinality(delivery_upload_refs) <= 5
          AND array_position(delivery_upload_refs, NULL) IS NULL
          AND (cardinality(delivery_upload_refs) = 0 OR delivery_ref IS NOT NULL)
        """
      )
    )
  end
end
