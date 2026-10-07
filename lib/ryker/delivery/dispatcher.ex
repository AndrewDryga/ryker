defmodule Ryker.Delivery.Dispatcher do
  @moduledoc """
  Delivers one host-routed message, routing response, model-requested action,
  or weekly report under durable custody.

  Platform publishers receive immutable requests without credentials or
  routing authority. Any ambiguous provider result releases the exact intent
  for a bounded retry; a typed receipt is the only way to settle custody.
  """
  alias Ryker.Artifacts.Outputs
  alias Ryker.Defaults
  alias Ryker.Delivery.{Adapters, PlatformActionCustody, Request, Retry, RoutingResponseCustody}
  alias Ryker.Episodes
  alias Ryker.ErrorDetail
  alias Ryker.LeasedCall
  alias Ryker.Reference
  alias Ryker.Slack.ReplyRecords
  alias Ryker.WeeklyReport.Custody, as: ReportCustody
  alias Ryker.Work.Custody

  @options ~w(adapters kind lease_seconds max_attempts retry_base_seconds retry_max_seconds worker_ref)a

  @type kind :: :message | :routing | :action | :report
  @type result ::
          {:ok,
           :idle
           | {:delivered, kind(), String.t()}
           | {:deferred, kind(), String.t(), term()}
           | {:blocked, kind(), String.t(), term()}}
          | {:error, term()}

  @spec run_once(keyword()) :: result()
  def run_once(options) do
    with {:ok, settings} <- settings(options),
         {:ok, claim} <- claim_next(settings) do
      execute(claim, settings)
    end
  end

  @doc """
  The announcements that can make delivery of `kind` claimable: a Work reply
  is a turn, announced on its request's topics; a routing response, a
  model-requested action and a weekly report each have a topic of their own.
  """
  @spec subscriptions(atom()) :: [(-> :ok | {:error, term()})]
  def subscriptions(:message), do: [&Episodes.subscribe_episodes/0]
  def subscriptions(:routing), do: [&RoutingResponseCustody.subscribe_routing_responses/0]
  def subscriptions(:action), do: [&PlatformActionCustody.subscribe_platform_actions/0]
  def subscriptions(:report), do: [&ReportCustody.subscribe_reports/0]
  def subscriptions(_kind), do: []

  @doc """
  The earliest moment after `since` at which delivery of `kind` becomes
  claimable by the clock alone, or nil.
  """
  @spec next_due_at(atom(), DateTime.t()) :: DateTime.t() | nil
  def next_due_at(:message, since), do: Custody.next_due_at(since, :delivery)
  def next_due_at(:routing, since), do: RoutingResponseCustody.next_due_at(since)
  def next_due_at(:action, since), do: PlatformActionCustody.next_due_at(since)
  def next_due_at(:report, since), do: ReportCustody.next_due_at(since)
  def next_due_at(_kind, _since), do: nil

  defp claim_next(%{kind: :message} = settings) do
    Custody.claim_next(settings.worker_ref, settings.lease_seconds, :delivery)
  end

  defp claim_next(%{kind: :routing} = settings) do
    RoutingResponseCustody.claim_next(settings.worker_ref, settings.lease_seconds)
  end

  defp claim_next(%{kind: :action} = settings) do
    PlatformActionCustody.claim_next(settings.worker_ref, settings.lease_seconds)
  end

  defp claim_next(%{kind: :report} = settings) do
    ReportCustody.claim_next(settings.worker_ref, settings.lease_seconds)
  end

  defp execute(nil, _settings), do: {:ok, :idle}

  defp execute(claim, settings) do
    custody = custody(claim, settings)

    with {:ok, request} <- request(claim, settings.kind),
         {:ok, receipt} <- publish_with_lease(request, custody, settings),
         {:ok, _settled} <- confirm(claim, request, receipt, settings.kind) do
      {:ok, {:delivered, custody.kind, request.ref}}
    else
      {:error, reason} -> handle_error(custody, reason, settings)
    end
  end

  # The four custodies hold the same lease shape under different names; the
  # dispatcher talks to them through this one, so the retry policy, the lease
  # renewal cadence and the give-up rule exist once rather than four times.
  # Only a Work reply carries images, so only its custody keeps the files an
  # attempt uploaded; the others never upload one.
  defp custody(claim, %{kind: :message} = settings) do
    %{episode: episode, turn: turn, lease_ref: lease_ref} = claim

    %{
      attempt_count: turn.delivery_attempt_count,
      kind: :message,
      ref: turn.delivery_ref,
      renew: fn ->
        Custody.renew(episode.id, turn.turn_ref, lease_ref, settings.lease_seconds)
      end,
      defer: fn retry_seconds, code, detail, upload_refs ->
        Custody.defer(
          episode.id,
          turn.turn_ref,
          lease_ref,
          retry_seconds,
          code,
          detail,
          upload_refs
        )
      end,
      block: fn code, detail ->
        Custody.block_delivery(episode.id, turn.turn_ref, lease_ref, code, detail)
      end
    }
  end

  defp custody(%{response: response, lease_ref: lease_ref}, %{kind: :routing} = settings) do
    %{
      attempt_count: response.attempt_count,
      kind: :routing,
      ref: response.delivery_ref,
      renew: fn ->
        RoutingResponseCustody.renew(response.delivery_ref, lease_ref, settings.lease_seconds)
      end,
      defer: fn retry_seconds, code, detail, [] ->
        RoutingResponseCustody.defer(
          response.delivery_ref,
          lease_ref,
          retry_seconds,
          code,
          detail
        )
      end,
      block: fn code, detail ->
        RoutingResponseCustody.block(response.delivery_ref, lease_ref, code, detail)
      end
    }
  end

  defp custody(%{action: action, lease_ref: lease_ref}, %{kind: :action} = settings) do
    %{
      attempt_count: action.attempt_count,
      kind: :action,
      ref: action.action_ref,
      renew: fn ->
        PlatformActionCustody.renew(action.action_ref, lease_ref, settings.lease_seconds)
      end,
      defer: fn retry_seconds, code, detail, [] ->
        PlatformActionCustody.defer(action.action_ref, lease_ref, retry_seconds, code, detail)
      end,
      block: fn code, detail ->
        PlatformActionCustody.block(action.action_ref, lease_ref, code, detail)
      end
    }
  end

  defp custody(%{report: report, lease_ref: lease_ref}, %{kind: :report} = settings) do
    %{
      attempt_count: report.attempt_count,
      kind: :report,
      ref: report.delivery_ref,
      renew: fn ->
        ReportCustody.renew(report.delivery_ref, lease_ref, settings.lease_seconds)
      end,
      defer: fn retry_seconds, code, detail, [] ->
        ReportCustody.defer(report.delivery_ref, lease_ref, retry_seconds, code, detail)
      end,
      block: fn code, detail ->
        ReportCustody.block(report.delivery_ref, lease_ref, code, detail)
      end
    }
  end

  defp request(claim, :message), do: message_request(claim)
  defp request(claim, :routing), do: RoutingResponseCustody.request(claim.response)
  defp request(claim, :action), do: PlatformActionCustody.request(claim.action)
  defp request(claim, :report), do: ReportCustody.request(claim.report)

  defp confirm(claim, _request, receipt, :message) do
    Custody.confirm_delivery(
      claim.episode.id,
      claim.episode.key,
      claim.turn.turn_ref,
      claim.lease_ref,
      receipt
    )
  end

  defp confirm(claim, request, receipt, :routing),
    do: RoutingResponseCustody.confirm_delivery(request.ref, claim.lease_ref, receipt)

  defp confirm(claim, request, receipt, :action),
    do: PlatformActionCustody.confirm_delivery(request.ref, claim.lease_ref, receipt)

  defp confirm(claim, request, receipt, :report),
    do: ReportCustody.confirm_delivery(request.ref, claim.lease_ref, receipt)

  defp message_request(claim) do
    with {:ok, message, record_refs, artifact_refs} <-
           delivery_message(claim.turn.delivery_document),
         {:ok, records} <- delivery_records(claim.episode.id, record_refs),
         {:ok, artifacts} <- Outputs.fetch_many(claim.turn.id, artifact_refs) do
      document =
        if records == [],
          do: %{"message" => message},
          else: %{
            "message" => message,
            "records" =>
              ReplyRecords.documents(
                claim.episode.destination_transport,
                claim.episode.id,
                records
              )
          }

      target = Custody.delivery_target(claim.episode, claim.turn)

      Request.new(%{
        artifacts: Enum.map(artifacts, &artifact_document/1),
        conversation_ref: target["conversation_ref"],
        document: document,
        kind: :message,
        ref: claim.turn.delivery_ref,
        source_item_ref: nil,
        thread_ref: target["thread_ref"],
        transport: target["transport"],
        upload_refs: claim.turn.delivery_upload_refs
      })
    end
  end

  defp delivery_message(%{"message" => message} = document)
       when map_size(document) == 1 and is_binary(message),
       do: {:ok, message, [], []}

  defp delivery_message(
         %{
           "decision_reason" => nil,
           "delivery" => "reply",
           "message" => message,
           "outcome" =>
             %{
               "artifact_refs" => artifact_refs,
               "record_refs" => record_refs,
               "state" => state
             } = outcome
         } = document
       )
       when map_size(document) == 4 and map_size(outcome) == 3 and is_binary(message) and
              is_list(artifact_refs) and is_list(record_refs) and is_binary(state),
       do: {:ok, message, record_refs, artifact_refs}

  defp delivery_message(_document), do: {:error, {:invalid_delivery_message, :document}}

  defp delivery_records(_episode_id, []), do: {:ok, []}

  defp delivery_records(episode_id, refs) do
    case ReplyRecords.fetch(episode_id, refs) do
      {:ok, records} -> {:ok, records}
      {:error, _reason} -> {:error, {:invalid_delivery_message, :record_refs}}
    end
  end

  defp artifact_document(artifact) do
    %{
      "bytes" => artifact.byte_size,
      "data" => artifact.data,
      "media_type" => artifact.media_type,
      "name" => artifact.name,
      "ref" => artifact.ref,
      "sha256" => artifact.sha256
    }
  end

  defp publish_with_lease(request, custody, settings) do
    LeasedCall.run(
      fn -> publish(request, settings.adapters) end,
      custody.renew,
      settings.lease_seconds,
      :delivery_publisher_exit
    )
  end

  defp publish(request, adapters) do
    Adapters.publish(request, adapters)
  catch
    kind, reason -> {:error, {:delivery_publisher_crashed, kind, reason}}
  end

  defp handle_error(custody, reason, settings) do
    cond do
      lease_error?(reason) ->
        {:error, reason}

      Retry.retryable?(reason) and custody.attempt_count < settings.max_attempts ->
        defer(custody, reason, settings)

      true ->
        block(custody, reason)
    end
  end

  defp defer(custody, reason, settings) do
    retry_seconds = retry_delay(reason, custody.attempt_count, settings)
    {error_code, error_detail} = describe_error(reason)

    case custody.defer.(retry_seconds, error_code, error_detail, Retry.uploaded(reason)) do
      {:ok, _deferred} -> {:ok, {:deferred, custody.kind, custody.ref, reason}}
      {:error, defer_reason} -> delivery_error(reason, defer_reason)
    end
  end

  defp block(custody, reason) do
    {error_code, error_detail} = describe_error(reason)

    case custody.block.(error_code, error_detail) do
      {:ok, _blocked} -> {:ok, {:blocked, custody.kind, custody.ref, reason}}
      {:error, block_reason} -> delivery_error(reason, block_reason)
    end
  end

  defp delivery_error(reason, custody_reason),
    do: {:error, {:delivery_dispatch_failed, reason, custody_reason}}

  defp lease_error?(:work_lease_lost), do: true
  defp lease_error?(:routing_response_lease_lost), do: true
  defp lease_error?(:platform_action_lease_lost), do: true
  defp lease_error?(:weekly_report_lease_lost), do: true
  defp lease_error?(_reason), do: false

  defp retry_delay(reason, attempt_count, settings) do
    backoff = backoff_delay(attempt_count, settings)

    case Retry.rate_limited(reason) do
      {:ok, delay} when is_integer(delay) -> max(delay, backoff)
      _none -> backoff
    end
  end

  defp backoff_delay(attempt_count, settings) do
    exponent = min(max(attempt_count - 1, 0), 20)
    min(settings.retry_base_seconds * Integer.pow(2, exponent), settings.retry_max_seconds)
  end

  defp describe_error(reason), do: ErrorDetail.describe(reason, :delivery_failed)

  # What the options leave out is the shipped default.
  defp settings(options) do
    with true <- Keyword.keyword?(options) and known_unique_keys?(options),
         true <- Enum.all?([:adapters, :kind, :worker_ref], &Keyword.has_key?(options, &1)) do
      :delivery
      |> Defaults.fetch!()
      |> Map.take([:lease_seconds, :max_attempts, :retry_base_seconds, :retry_max_seconds])
      |> Map.merge(Map.new(options))
      |> validate_settings()
    else
      _invalid -> {:error, {:invalid_delivery_dispatcher, :options}}
    end
  end

  defp known_unique_keys?(options) do
    keys = Keyword.keys(options)
    keys == Enum.uniq(keys) and keys -- @options == []
  end

  defp validate_settings(settings) do
    with :ok <- setting(is_map(settings.adapters) and map_size(settings.adapters) > 0, :adapters),
         :ok <- setting(settings.kind in [:message, :routing, :action, :report], :kind),
         :ok <- setting(positive?(settings.lease_seconds), :lease_seconds),
         :ok <- setting(positive?(settings.max_attempts), :max_attempts),
         :ok <- setting(positive?(settings.retry_base_seconds), :retry_base_seconds),
         :ok <- setting(valid_retry_max?(settings), :retry_max_seconds),
         :ok <- setting(reference?(settings.worker_ref), :worker_ref) do
      {:ok, settings}
    end
  end

  defp valid_retry_max?(settings) do
    positive?(settings.retry_max_seconds) and
      settings.retry_max_seconds >= settings.retry_base_seconds
  end

  defp positive?(value), do: is_integer(value) and value > 0

  defp reference?(value), do: Reference.valid?(value)

  defp setting(true, _field), do: :ok
  defp setting(false, field), do: {:error, {:invalid_delivery_dispatcher, field}}
end
