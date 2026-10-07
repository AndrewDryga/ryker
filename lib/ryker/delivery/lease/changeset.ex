defmodule Ryker.Delivery.Lease.Changeset do
  @moduledoc """
  The lease custody a delivery row moves through, shared by platform actions
  (`Ryker.Delivery.PlatformAction.Changeset`) and weekly reports
  (`Ryker.WeeklyReport.Report.Changeset`). A worker claims a pending row
  under a lease and renews it while it works. The attempt then confirms the
  delivery, defers it to a later attempt, or blocks it until a person retries
  it. Each caller adds its own table's constraints.
  """
  use Ryker, :changeset

  @released [lease_expires_at: nil, lease_owner: nil, lease_ref: nil]

  @doc "A worker takes the row for `lease_seconds` from `at`, under `lease_ref`."
  @spec claim(struct(), DateTime.t(), pos_integer(), String.t(), Ecto.UUID.t()) ::
          Ecto.Changeset.t()
  def claim(row, at, lease_seconds, owner, lease_ref) do
    change(row,
      attempt_count: row.attempt_count + 1,
      last_error_code: nil,
      last_error_detail: nil,
      lease_expires_at: DateTime.add(at, lease_seconds, :second),
      lease_owner: owner,
      lease_ref: lease_ref,
      next_attempt_at: nil
    )
  end

  @doc "The worker keeps the row until `expires_at`."
  @spec renew(struct(), DateTime.t()) :: Ecto.Changeset.t()
  def renew(row, expires_at), do: change(row, lease_expires_at: expires_at)

  @doc "The attempt failed with `error_code`; the row waits for `next_attempt_at`."
  @spec defer(struct(), DateTime.t(), String.t(), String.t()) :: Ecto.Changeset.t()
  def defer(row, next_attempt_at, error_code, error_detail) do
    change(
      row,
      [
        last_error_code: error_code,
        last_error_detail: error_detail,
        next_attempt_at: next_attempt_at
      ] ++ @released
    )
  end

  @doc "The row cannot be delivered until a person retries it."
  @spec block(struct(), String.t(), String.t()) :: Ecto.Changeset.t()
  def block(row, error_code, error_detail) do
    change(
      row,
      [
        last_error_code: error_code,
        last_error_detail: error_detail,
        next_attempt_at: nil,
        status: :blocked
      ] ++ @released
    )
  end

  @doc "A person retries a blocked row, which starts a fresh round of attempts."
  @spec retry(struct()) :: Ecto.Changeset.t()
  def retry(row) do
    change(row,
      attempt_count: 0,
      last_error_code: nil,
      last_error_detail: nil,
      next_attempt_at: nil,
      retry_generation: row.retry_generation + 1,
      status: :pending
    )
  end

  @doc "The delivery happened at `at`, and `receipt` proves it."
  @spec confirm(struct(), DateTime.t(), map(), String.t()) :: Ecto.Changeset.t()
  def confirm(row, at, receipt, fingerprint) do
    change(
      row,
      [
        delivered_at: at,
        external_receipt: receipt,
        external_receipt_fingerprint: fingerprint,
        last_error_code: nil,
        last_error_detail: nil,
        next_attempt_at: nil,
        status: :delivered
      ] ++ @released
    )
  end
end
