defmodule Ryker.WeeklyReport.Report.Changeset do
  @moduledoc """
  How a weekly report is queued and posted (`Ryker.WeeklyReport.Report`),
  through the lease custody of `Ryker.Delivery.Lease.Changeset`.
  """
  use Ryker, :changeset
  alias Ryker.Delivery
  alias Ryker.WeeklyReport.Report

  @fields [
    :conversation_ref,
    :delivery_ref,
    :document,
    :due_at,
    :id,
    :period_start,
    :preview,
    :timezone,
    :transport,
    :week
  ]

  @doc "A week's report, or a preview a person sent, waiting to be posted."
  def insert(attributes) do
    %Report{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> report_constraints()
  end

  @doc "See `Ryker.Delivery.Lease.Changeset.claim/5`."
  def claim(%Report{} = report, at, lease_seconds, owner, lease_ref) do
    report
    |> Delivery.Lease.Changeset.claim(at, lease_seconds, owner, lease_ref)
    |> report_constraints()
  end

  @doc "See `Ryker.Delivery.Lease.Changeset.renew/2`."
  def renew(%Report{} = report, expires_at),
    do: report |> Delivery.Lease.Changeset.renew(expires_at) |> report_constraints()

  @doc "See `Ryker.Delivery.Lease.Changeset.defer/4`."
  def defer(%Report{} = report, next_attempt_at, error_code, error_detail) do
    report
    |> Delivery.Lease.Changeset.defer(next_attempt_at, error_code, error_detail)
    |> report_constraints()
  end

  @doc "See `Ryker.Delivery.Lease.Changeset.block/3`."
  def block(%Report{} = report, error_code, error_detail),
    do: report |> Delivery.Lease.Changeset.block(error_code, error_detail) |> report_constraints()

  @doc "See `Ryker.Delivery.Lease.Changeset.retry/1`."
  def retry(%Report{} = report),
    do: report |> Delivery.Lease.Changeset.retry() |> report_constraints()

  @doc "See `Ryker.Delivery.Lease.Changeset.confirm/4`."
  def confirm(%Report{} = report, at, receipt, fingerprint) do
    report |> Delivery.Lease.Changeset.confirm(at, receipt, fingerprint) |> report_constraints()
  end

  defp report_constraints(changeset) do
    changeset
    |> unique_constraint(:week)
    |> unique_constraint(:delivery_ref)
    |> check_constraint(:week, name: :weekly_report_identity_valid)
    |> check_constraint(:document, name: :weekly_report_document_valid)
    |> check_constraint(:status, name: :weekly_report_custody_valid)
  end
end
