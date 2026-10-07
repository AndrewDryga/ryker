defmodule Ryker.WeeklyReport.ReportChangeset do
  @moduledoc """
  How a weekly report is queued and posted (`Ryker.WeeklyReport.Report`),
  through the lease custody of `Ryker.Delivery.LeaseChangeset`.
  """
  import Ecto.Changeset
  alias Ryker.Delivery.LeaseChangeset
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

  @doc "See `Ryker.Delivery.LeaseChangeset.claim/5`."
  def claim(%Report{} = report, at, lease_seconds, owner, lease_ref) do
    report
    |> LeaseChangeset.claim(at, lease_seconds, owner, lease_ref)
    |> report_constraints()
  end

  @doc "See `Ryker.Delivery.LeaseChangeset.renew/2`."
  def renew(%Report{} = report, expires_at),
    do: report |> LeaseChangeset.renew(expires_at) |> report_constraints()

  @doc "See `Ryker.Delivery.LeaseChangeset.defer/4`."
  def defer(%Report{} = report, next_attempt_at, error_code, error_detail) do
    report
    |> LeaseChangeset.defer(next_attempt_at, error_code, error_detail)
    |> report_constraints()
  end

  @doc "See `Ryker.Delivery.LeaseChangeset.block/3`."
  def block(%Report{} = report, error_code, error_detail),
    do: report |> LeaseChangeset.block(error_code, error_detail) |> report_constraints()

  @doc "See `Ryker.Delivery.LeaseChangeset.retry/1`."
  def retry(%Report{} = report), do: report |> LeaseChangeset.retry() |> report_constraints()

  @doc "See `Ryker.Delivery.LeaseChangeset.confirm/4`."
  def confirm(%Report{} = report, at, receipt, fingerprint),
    do: report |> LeaseChangeset.confirm(at, receipt, fingerprint) |> report_constraints()

  defp report_constraints(changeset) do
    changeset
    |> unique_constraint(:week)
    |> unique_constraint(:delivery_ref)
    |> check_constraint(:week, name: :weekly_report_identity_valid)
    |> check_constraint(:document, name: :weekly_report_document_valid)
    |> check_constraint(:status, name: :weekly_report_custody_valid)
  end
end
