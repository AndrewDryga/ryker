defmodule Ryker.WeeklyReport.Custody do
  @moduledoc """
  Durable single-owner custody for the weekly report's post.

  The scheduler freezes a week's words and channel once, when the week's
  report falls due (`enqueue/1`); the delivery pool (`Ryker.Delivery.Dispatcher`,
  kind `:report`) claims it under a lease, posts it through the same Slack
  publisher every reply goes through, and settles it with the receipt. Slack
  or network trouble is retried with the delivery lanes' backoff; a refusal a
  retry cannot change blocks it for a person, and the Failures page lists it
  beside every other post (`Ryker.Operator.Delivery`) with the same Post it
  again. A retry posts the same words to the same channel, and the publisher
  looks for a copy already there first, so a report never appears twice.

  Each report queued, claimed, retried, blocked or delivered is announced
  after the outermost commit (`subscribe_reports/0`).
  """

  alias Ryker.Delivery.Request
  alias Ryker.Repo
  alias Ryker.UTCDateTime
  alias Ryker.WeeklyReport.{Report, ReportChangeset, ReportQuery}
  alias Ryker.Work.DeliveryReceipt

  @type claim :: %{report: Report.t(), lease_ref: Ecto.UUID.t()}

  @doc """
  Freezes one week's report: `week` (that week's Monday), `due_at`,
  `period_start`, `timezone`, `conversation_ref` and `message`, posted to
  Slack. A week already on record keeps what it has: the call returns
  `{:ok, :already_queued}` and writes nothing. With `preview: true` it is a
  preview a person sent, its own post every time and never the week's.
  """
  @spec enqueue(map()) :: {:ok, Report.t() | :already_queued} | {:error, term()}
  def enqueue(%{week: %Date{} = week} = attributes) do
    id = Ecto.UUID.generate()
    preview = Map.get(attributes, :preview, false) == true

    values = %{
      conversation_ref: attributes.conversation_ref,
      delivery_ref: if(preview, do: "weekly-report-preview:" <> id, else: delivery_ref(week)),
      document: %{"message" => attributes.message},
      due_at: attributes.due_at,
      id: id,
      period_start: attributes.period_start,
      preview: preview,
      timezone: attributes.timezone,
      transport: "slack",
      week: week
    }

    with {:ok, _request} <- request_for(values) do
      values
      |> ReportChangeset.insert()
      |> Repo.insert()
      |> queued()
    end
  end

  def enqueue(_attributes), do: {:error, {:invalid_weekly_report, :week}}

  defp queued({:ok, report}) do
    broadcast_report_updated(report)
    {:ok, report}
  end

  defp queued({:error, %Ecto.Changeset{errors: errors}}) do
    if Keyword.has_key?(errors, :week),
      do: {:ok, :already_queued},
      else: {:error, {:weekly_report_persistence_failed, :enqueue, errors}}
  end

  @doc "The delivery reference of one week's report: the week it was for."
  @spec delivery_ref(Date.t()) :: String.t()
  def delivery_ref(%Date{} = week), do: "weekly-report:" <> Date.to_iso8601(week)

  @doc "Whether the week that starts on `week` (a Monday) has its report on record; a preview is not it."
  @spec recorded?(Date.t()) :: boolean()
  def recorded?(%Date{} = week), do: Repo.exists?(ReportQuery.for_week(week))

  @doc """
  The earliest moment after `since` at which a pending report becomes
  claimable by the clock alone: its retry's backoff ends, or the lease of a
  claim nobody renewed runs out. Nil when none waits on the clock.
  """
  @spec next_due_at(DateTime.t()) :: DateTime.t() | nil
  def next_due_at(%DateTime{} = since) do
    since
    |> ReportQuery.next_due_after()
    |> Repo.one()
    |> UTCDateTime.earliest()
  end

  @spec claim_next(String.t(), pos_integer()) :: {:ok, claim() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> claim_locked(worker_ref, lease_seconds) end)
    end
  end

  @doc "The report's post as the one immutable message the publishers take."
  @spec request(Report.t()) :: {:ok, Request.t()} | {:error, term()}
  def request(%Report{} = report), do: request_for(report)

  def request(_report), do: {:error, {:invalid_weekly_report, :request}}

  # The report was frozen when its row was written: no copy of it can be in
  # the channel from before then, so the publisher's search for one starts
  # there rather than at the channel's first message.
  defp request_for(report) do
    Request.new(%{
      conversation_ref: report.conversation_ref,
      document: report.document,
      frozen_at: Map.get(report, :inserted_at),
      kind: :message,
      ref: report.delivery_ref,
      source_item_ref: nil,
      thread_ref: nil,
      transport: report.transport
    })
  end

  @spec renew(String.t(), Ecto.UUID.t(), pos_integer()) :: {:ok, Report.t()} | {:error, term()}
  def renew(delivery_ref, lease_ref, lease_seconds) do
    with :ok <- reference(delivery_ref, :delivery_ref),
         {:ok, lease_ref} <- uuid(lease_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      mutate_claim(delivery_ref, lease_ref, fn report, now ->
        requested = DateTime.add(now, lease_seconds, :second)
        expiry = later(report.lease_expires_at, requested)
        report |> ReportChangeset.renew(expiry) |> write!(:renew)
      end)
    end
  end

  @spec defer(String.t(), Ecto.UUID.t(), pos_integer(), String.t(), String.t()) ::
          {:ok, Report.t()} | {:error, term()}
  def defer(delivery_ref, lease_ref, retry_seconds, error_code, error_detail) do
    with :ok <- reference(delivery_ref, :delivery_ref),
         {:ok, lease_ref} <- uuid(lease_ref),
         :ok <- positive(retry_seconds, :retry_seconds),
         :ok <- bounded(error_code, 128, :error_code),
         :ok <- bounded(error_detail, 4_096, :error_detail) do
      mutate_claim(delivery_ref, lease_ref, fn report, now ->
        report
        |> ReportChangeset.defer(
          DateTime.add(now, retry_seconds, :second),
          error_code,
          error_detail
        )
        |> write!(:defer)
      end)
    end
  end

  @spec block(String.t(), Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, Report.t()} | {:error, term()}
  def block(delivery_ref, lease_ref, error_code, error_detail) do
    with :ok <- reference(delivery_ref, :delivery_ref),
         {:ok, lease_ref} <- uuid(lease_ref),
         :ok <- bounded(error_code, 128, :error_code),
         :ok <- bounded(error_detail, 4_096, :error_detail) do
      mutate_claim(delivery_ref, lease_ref, fn report, _now ->
        report |> ReportChangeset.block(error_code, error_detail) |> write!(:block)
      end)
    end
  end

  @doc "Rearms one blocked report a person asked to post again, without changing its words."
  @spec retry(String.t()) :: {:ok, Report.t()} | {:error, term()}
  def retry(delivery_ref) do
    with :ok <- reference(delivery_ref, :delivery_ref) do
      Repo.transaction(fn -> retry_locked(delivery_ref) end)
    end
  end

  @spec confirm_delivery(String.t(), Ecto.UUID.t(), map()) :: {:ok, Report.t()} | {:error, term()}
  def confirm_delivery(delivery_ref, lease_ref, receipt) do
    with :ok <- reference(delivery_ref, :delivery_ref),
         {:ok, lease_ref} <- uuid(lease_ref),
         {:ok, receipt} <- DeliveryReceipt.prepare(receipt) do
      fingerprint = DeliveryReceipt.fingerprint(receipt)
      Repo.transaction(fn -> confirm_locked(delivery_ref, lease_ref, receipt, fingerprint) end)
    end
  end

  @doc "Blocked reports, newest first, at most `limit`, for Failures."
  @spec blocked(pos_integer()) :: [Report.t()]
  def blocked(limit) do
    ReportQuery.with_status(:blocked)
    |> ReportQuery.recently_updated_first()
    |> ReportQuery.limit_to(limit)
    |> Repo.all()
  end

  @doc "One report by its delivery reference, or nil."
  @spec fetch(String.t()) :: Report.t() | nil
  def fetch(delivery_ref) when is_binary(delivery_ref),
    do: Repo.one(ReportQuery.by_delivery_ref(delivery_ref))

  defp claim_locked(worker_ref, lease_seconds) do
    now = Repo.now!()

    next =
      now
      |> ReportQuery.claimable_at()
      |> ReportQuery.soonest_due_first()
      |> ReportQuery.limit_to(1)
      |> ReportQuery.lock_next_free()
      |> Repo.one()

    case next do
      nil ->
        nil

      %Report{} = report ->
        lease_ref = Ecto.UUID.generate()

        report =
          report
          |> ReportChangeset.claim(now, lease_seconds, worker_ref, lease_ref)
          |> write!(:claim)

        %{report: report, lease_ref: lease_ref}
    end
  end

  defp retry_locked(delivery_ref) do
    case lock(delivery_ref) do
      %Report{status: :blocked} = report ->
        report |> ReportChangeset.retry() |> write!(:retry)

      %Report{status: :pending} = report ->
        report

      %Report{} ->
        Repo.rollback(:weekly_report_not_retryable)

      nil ->
        Repo.rollback(:weekly_report_not_found)
    end
  end

  defp confirm_locked(delivery_ref, lease_ref, receipt, fingerprint) do
    now = Repo.now!()

    case lock(delivery_ref) do
      %Report{status: :delivered, external_receipt_fingerprint: ^fingerprint} = report ->
        report

      %Report{status: :delivered} ->
        Repo.rollback(:weekly_report_receipt_conflict)

      %Report{} = report ->
        with :ok <- current_lease(report, lease_ref, now),
             :ok <- exact_receipt(report, receipt) do
          report
          |> ReportChangeset.confirm(now, receipt, fingerprint)
          |> write!(:confirm)
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      nil ->
        Repo.rollback(:weekly_report_not_found)
    end
  end

  # Every change to a claimed report happens under its row lock, and only
  # while the caller still holds the lease it was given.
  defp mutate_claim(delivery_ref, lease_ref, callback) do
    Repo.transaction(fn ->
      now = Repo.now!()

      case leased(delivery_ref, lease_ref, now) do
        {:ok, report} -> callback.(report, now)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp leased(delivery_ref, lease_ref, now) do
    case lock(delivery_ref) do
      %Report{status: :pending} = report ->
        with :ok <- current_lease(report, lease_ref, now), do: {:ok, report}

      %Report{} ->
        {:error, :weekly_report_not_pending}

      nil ->
        {:error, :weekly_report_not_found}
    end
  end

  defp lock(delivery_ref) do
    delivery_ref
    |> ReportQuery.by_delivery_ref()
    |> ReportQuery.lock_for_update()
    |> Repo.one()
  end

  defp current_lease(report, lease_ref, now) do
    if report.lease_ref == lease_ref and is_binary(report.lease_owner) and
         match?(%DateTime{}, report.lease_expires_at) and
         DateTime.compare(report.lease_expires_at, now) == :gt,
       do: :ok,
       else: {:error, :weekly_report_lease_lost}
  end

  # The receipt names the new message the report became, in the channel it
  # was frozen for, outside any thread.
  defp exact_receipt(report, receipt) do
    if receipt["delivery_ref"] == report.delivery_ref and
         receipt["transport"] == report.transport and
         receipt["conversation_ref"] == report.conversation_ref and
         is_nil(receipt["thread_ref"]) and is_binary(receipt["message_ref"]),
       do: :ok,
       else: {:error, :weekly_report_receipt_mismatch}
  end

  defp write!(changeset, operation) do
    case Repo.update(changeset) do
      # A renewal only moves the lease's expiry, which no page shows.
      {:ok, updated} when operation == :renew ->
        updated

      {:ok, updated} ->
        broadcast_report_updated(updated)
        updated

      {:error, changeset} ->
        Repo.rollback({:weekly_report_persistence_failed, operation, changeset.errors})
    end
  end

  defp later(nil, requested), do: requested

  defp later(current, requested),
    do: if(DateTime.compare(current, requested) == :lt, do: requested, else: current)

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_weekly_report, :lease_ref}}
    end
  end

  defp reference(value, field), do: bounded(value, 1_024, field)

  defp bounded(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "" and
         byte_size(value) <= maximum and :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_weekly_report, field}}
  end

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_weekly_report, field}}

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to weekly reports: `{:weekly_report_updated, id}`
  once a report is queued, claimed, retried, blocked or delivered, and that
  change has committed. The delivery pool wakes on it; Failures redraws.
  """
  def subscribe_reports, do: Ryker.PubSub.subscribe(topic())

  def unsubscribe_reports, do: Ryker.PubSub.unsubscribe(topic())

  defp topic, do: "weekly_reports"

  defp broadcast_report_updated(%Report{id: id}) do
    Repo.after_commit(fn -> Ryker.PubSub.broadcast(topic(), {:weekly_report_updated, id}) end)
  end
end
