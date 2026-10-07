defmodule Ryker.Repo.Migrations.ApprovalErrorCodes do
  use Ecto.Migration

  # An approval watch kept what stopped it only as the printed term, and the
  # queries and the Failures page matched that text (`{:emisar_http_error,
  # 401,%`); a change to how a reason prints would have stopped them matching
  # (2026-10-04 review). The watch keeps a code beside the term now
  # (`Ryker.Emisar.Approvals.error_code/1`), set and cleared with it, and the
  # rows that have a term get the code it reads as.

  @code """
  CASE
    WHEN last_error = '{:delivery_credentials_unavailable, :credential_missing}'
      THEN 'credential_missing'
    WHEN last_error = '{:delivery_credentials_unavailable, :credential_decryption_failed}'
      THEN 'credential_decryption_failed'
    WHEN last_error ~ '^\\{:emisar_http_error, [1-5][0-9]{2},'
      THEN 'emisar_http_' || substring(last_error FROM '^\\{:emisar_http_error, ([1-5][0-9]{2}),')
    WHEN last_error LIKE '{:emisar_protocol_error, :review}%' THEN 'emisar_review_unreadable'
    WHEN last_error LIKE '{:emisar_protocol_error,%' THEN 'emisar_protocol_error'
    WHEN last_error LIKE '{:invalid_emisar_client,%' THEN 'invalid_emisar_client'
    WHEN last_error LIKE ':emisar_approval_identity_mismatch%'
      THEN 'emisar_approval_identity_mismatch'
    WHEN last_error LIKE '{:emisar_approval_presentation_permanent,%'
      THEN 'emisar_approval_presentation_failed'
    ELSE 'emisar_approval_monitoring_blocked'
  END
  """

  @doc "The code a saved `last_error` reads as, as SQL over that column."
  def code_sql, do: @code

  def up do
    alter table(:episode_emisar_approvals) do
      add(:last_error_code, :text)
    end

    execute(
      "UPDATE episode_emisar_approvals SET last_error_code = #{@code} WHERE last_error IS NOT NULL"
    )

    execute("""
    ALTER TABLE episode_emisar_approvals ADD CONSTRAINT episode_emisar_approval_error_valid
      CHECK ((last_error IS NULL) = (last_error_code IS NULL)
        AND (last_error_code IS NULL OR char_length(last_error_code) BETWEEN 1 AND 128))
    """)
  end

  def down do
    execute(
      "ALTER TABLE episode_emisar_approvals DROP CONSTRAINT episode_emisar_approval_error_valid"
    )

    alter table(:episode_emisar_approvals) do
      remove(:last_error_code)
    end
  end
end
