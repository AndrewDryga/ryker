defmodule Ryker.Repo.Migrations.AddWeeklyReports do
  use Ecto.Migration

  # Andrew, 2026-09-27: make the Weekly report setting actually do something.
  # It saved a day, a time and a channel and nothing posted: the Go report was
  # never ported.
  #
  # weekly_reports: one row per calendar week a report was sent for (`week`,
  # that week's Monday in the report's time zone), written when the report
  # falls due. It is the durable record that the week was sent, so a restart
  # inside the week never posts it twice, and it is the report's delivery
  # custody: the frozen words, the channel, and the same lease, retry and
  # receipt columns every other post Ryker makes keeps, so a report Slack
  # refuses shows on Failures like any other post (`Ryker.WeeklyReport.Custody`).
  #
  # Rolling back drops the table: the previous release posts no report, and
  # what was already posted stays in Slack.

  def up do
    create table(:weekly_reports, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:week, :date, null: false)
      add(:due_at, :utc_datetime_usec, null: false)
      add(:period_start, :utc_datetime_usec, null: false)
      add(:timezone, :text, null: false)
      add(:delivery_ref, :text, null: false)
      add(:transport, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:document, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:attempt_count, :bigint, null: false, default: 0)
      add(:retry_generation, :bigint, null: false, default: 0)
      add(:lease_ref, :uuid)
      add(:lease_owner, :text)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:last_error_code, :text)
      add(:last_error_detail, :text)
      add(:external_receipt, :text)
      add(:external_receipt_fingerprint, :text)
      add(:delivered_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:weekly_reports, :weekly_report_identity_valid,
        check: """
        extract(isodow FROM week) = 1
        AND period_start < due_at
        AND char_length(timezone) BETWEEN 1 AND 64
        AND char_length(delivery_ref) BETWEEN 1 AND 256
        AND char_length(transport) BETWEEN 1 AND 64
        AND char_length(conversation_ref) BETWEEN 1 AND 1024
        AND attempt_count >= 0 AND retry_generation >= 0
        """
      )
    )

    create(
      constraint(:weekly_reports, :weekly_report_document_valid,
        check: """
        jsonb_typeof(document::jsonb) = 'object'
        AND document::jsonb ? 'message'
        AND (document::jsonb - 'message') = '{}'::jsonb
        AND jsonb_typeof(document::jsonb -> 'message') = 'string'
        AND char_length(document::jsonb ->> 'message') BETWEEN 1 AND 20000
        """
      )
    )

    create(
      constraint(:weekly_reports, :weekly_report_custody_valid,
        check: """
        status IN ('pending', 'blocked', 'delivered')
        AND (
          (lease_ref IS NULL AND lease_owner IS NULL AND lease_expires_at IS NULL)
          OR (status = 'pending' AND lease_ref IS NOT NULL
              AND char_length(lease_owner) BETWEEN 1 AND 1024 AND lease_expires_at IS NOT NULL)
        )
        AND (status = 'pending' OR next_attempt_at IS NULL)
        AND (status <> 'blocked' OR (
          char_length(last_error_code) BETWEEN 1 AND 128
          AND char_length(last_error_detail) BETWEEN 1 AND 4096
        ))
        AND (
          (status IN ('pending', 'blocked') AND external_receipt IS NULL
            AND external_receipt_fingerprint IS NULL AND delivered_at IS NULL)
          OR (status = 'delivered' AND external_receipt IS NOT NULL
            AND char_length(external_receipt_fingerprint) = 64 AND delivered_at IS NOT NULL)
        )
        """
      )
    )

    create(unique_index(:weekly_reports, [:week]))
    create(unique_index(:weekly_reports, [:delivery_ref]))
    create(index(:weekly_reports, [:status, :next_attempt_at]))
    create(index(:weekly_reports, [:updated_at, :id]))
  end

  def down do
    drop(table(:weekly_reports))
  end
end
