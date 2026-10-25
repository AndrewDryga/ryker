defmodule Ryker.Emisar.ApprovalMessages do
  @moduledoc "Independent delivery custody for the regular Emisar review message, one per asking turn."
  alias Ryker.CanonicalJSON
  alias Ryker.Delivery
  alias Ryker.Emisar.{Approval, ApprovalMessage, ApprovalStatus}
  alias Ryker.Episodes
  alias Ryker.ErrorDetail
  alias Ryker.Records
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Work

  @neutral %{
    "message" =>
      "Emisar review details are unavailable until their source context can be checked."
  }

  @doc "Internal — approval registration freezes its separate Slack message route. Returns :ok or an error."
  @spec ensure_in_transaction(Records.Record.t()) :: :ok | {:error, term()}
  def ensure_in_transaction(%Records.Record{kind: "emisar_approval"} = record) do
    with true <- Repo.in_transaction?(),
         {:ok, turn} <- Repo.fetch(Work.Turn.Query.by_id(record.turn_id)),
         {:ok, episode} <- Repo.fetch(Episodes.Episode.Query.by_id(record.episode_id)),
         true <- turn.episode_id == episode.id do
      target = turn.delivery_target || Work.Custody.Delivery.answer_target(episode, turn)
      ensure_target(record, turn, episode, target)
    else
      _ -> {:error, :emisar_approval_message_source_missing}
    end
  end

  def ensure_in_transaction(_record), do: {:error, :emisar_approval_message_source_missing}

  defp ensure_target(record, turn, episode, %{"transport" => "slack"} = target) do
    attributes = %{
      episode_id: episode.id,
      turn_id: turn.id,
      connection_ref: record.payload["connection_ref"],
      ref: "emisar-review:#{turn.id}",
      transport: "slack",
      conversation_ref: target["conversation_ref"],
      thread_ref: target["thread_ref"]
    }

    with {:ok, _} <-
           Repo.insert(ApprovalMessage.Changeset.insert(attributes),
             on_conflict: :nothing,
             conflict_target: [:turn_id]
           ),
         {:ok, message} <- Repo.fetch(ApprovalMessage.Query.by_turn_id(turn.id)),
         true <- Map.take(message, Map.keys(attributes)) == attributes do
      check_soon(record.id)
    else
      _ -> {:error, :emisar_approval_message_identity_changed}
    end
  end

  defp ensure_target(_record, _turn, _episode, _target), do: :ok

  @doc "Internal — the approval dispatcher repairs separate custody and marks it due. Returns whether it owns Slack presentation."
  @spec schedule(Approval.t()) :: {:ok, boolean()} | {:error, term()}
  def schedule(%Approval{} = approval) do
    Repo.transaction(fn ->
      with {:ok, record} <- Repo.fetch(Records.Record.Query.by_id(approval.record_id)),
           :ok <- ensure_in_transaction(record) do
        owns_turn?(record.turn_id)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def schedule(_approval), do: {:error, :emisar_approval_message_source_missing}

  @doc "Internal — ReplyRecords leaves reviews to their separate message. Returns a boolean."
  @spec owns_turn?(Ecto.UUID.t()) :: boolean()
  def owns_turn?(turn_id) when is_binary(turn_id),
    do: turn_id |> ApprovalMessage.Query.by_turn_id() |> Repo.exists?()

  def owns_turn?(_turn_id), do: false

  @doc "Internal — approval/record changes dirty their message without losing a concurrent refresh. Returns :ok."
  @spec check_soon(Ecto.UUID.t()) :: :ok
  def check_soon(record_id) do
    Repo.update_all(ApprovalMessage.Query.changed_for_record(record_id),
      set: [checked_at: nil],
      inc: [generation: 1]
    )

    :ok
  end

  @doc "Internal — the message worker repairs one retained open watch created before this custody existed. Returns :ok or an error."
  @spec repair_one(String.t()) :: :ok | {:error, term()}
  def repair_one(connection_ref) do
    connection_ref
    |> ApprovalMessage.Query.missing_records()
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn record, :ok ->
      case schedule_record(record) do
        {:ok, true} -> {:halt, :ok}
        {:ok, false} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp schedule_record(record) do
    Repo.transaction(fn ->
      case ensure_in_transaction(record) do
        :ok -> owns_turn?(record.turn_id)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Internal — one message worker leases a due review card. Returns the row or nil."
  @spec claim_next(String.t(), String.t(), pos_integer()) ::
          {:ok, ApprovalMessage.t() | nil} | {:error, term()}
  def claim_next(connection_ref, worker_ref, seconds) do
    if Reference.valid?(connection_ref, 64) and Reference.valid?(worker_ref) and
         is_integer(seconds) and seconds > 0 do
      Repo.transaction(fn -> claim_locked(connection_ref, worker_ref, seconds) end)
    else
      {:error, :invalid_emisar_approval_message_claim}
    end
  end

  defp claim_locked(connection_ref, worker_ref, seconds) do
    now = Repo.now!()

    case Repo.peek(ApprovalMessage.Query.next_claimable(connection_ref, now)) do
      nil ->
        nil

      message ->
        update!(message, %{
          attempt_count: message.attempt_count + 1,
          lease_ref: Ecto.UUID.generate(),
          lease_owner: worker_ref,
          lease_expires_at: DateTime.add(now, seconds, :second),
          next_attempt_at: nil
        })
    end
  end

  @doc "Internal — the message worker projects all reviews of the exact asking turn and reauthorizes their sources. Returns a delivery request."
  @spec request(ApprovalMessage.t()) :: {:ok, Delivery.Request.t()} | {:error, term()}
  def request(%ApprovalMessage{} = message) do
    with :ok <- stored_receipt(message),
         {:ok, result} <- Repo.transaction(fn -> request_in_transaction(message) end),
         do: result
  end

  def request(_message), do: {:error, :emisar_approval_message_source_missing}

  defp request_in_transaction(message) do
    with {:ok, episode} <- Repo.fetch(Episodes.Episode.Query.by_id(message.episode_id)),
         {:ok, turn} <- Repo.fetch(Work.Turn.Query.by_id(message.turn_id)),
         {:ok, session} <- Repo.fetch(Work.Session.Query.by_id(turn.session_id)),
         true <- turn.episode_id == episode.id and session.episode_id == episode.id do
      approvals = Repo.all(Approval.Query.asked_by_turn(message.turn_id, []))
      records = Repo.all(Records.Record.Query.by_ids(Enum.map(approvals, & &1.record_id)))
      documents = Enum.map(records, &Records.DerivedContext.record(Records.Record.document(&1)))

      destination = %{
        episode
        | destination_transport: message.transport,
          destination_conversation_ref: message.conversation_ref,
          destination_thread_ref: message.thread_ref
      }

      document = review_document(approvals, records, documents, destination, session)

      Delivery.Request.new(%{
        ref: message.ref,
        kind: :message,
        source_item_ref: nil,
        transport: message.transport,
        conversation_ref: message.conversation_ref,
        thread_ref: message.thread_ref,
        document: document,
        frozen_at: message.inserted_at
      })
    else
      _ -> {:error, :emisar_approval_message_source_missing}
    end
  end

  defp review_document(approvals, records, documents, destination, session) do
    if approvals != [] and length(records) == length(approvals) do
      case Records.DerivedContext.resolve(documents, destination, session.repository_ref, session) do
        {:ok, _} -> statuses_document(approvals)
        {:error, :work_derived_context_busy} -> Repo.rollback(:work_derived_context_busy)
        _ -> @neutral
      end
    else
      @neutral
    end
  end

  defp statuses_document(approvals) do
    statuses =
      Enum.map(approvals, fn approval ->
        {:ok, status} = ApprovalStatus.last(approval)
        status
      end)

    %{"emisar_approval_statuses" => statuses}
  end

  @doc "Internal — delivery custody and its worker compare the actual rendered card. Returns its digest."
  @spec fingerprint(Delivery.Request.t()) :: String.t()
  def fingerprint(%Delivery.Request{} = request) do
    {:ok, payload} = Ryker.Slack.Renderer.render(request.document)
    CanonicalJSON.digest(payload)
  end

  @doc "Internal — the message worker records a typed receipt and rendered revision under its lease. Returns the updated row."
  @spec mark(ApprovalMessage.t(), Delivery.Request.t(), map()) ::
          {:ok, ApprovalMessage.t()} | {:error, term()}
  def mark(%ApprovalMessage{} = claimed, %Delivery.Request{} = request, receipt) do
    case validate_receipt(claimed, receipt) do
      :ok ->
        mutate(claimed, fn current ->
          update!(
            current,
            released(%{
              external_receipt: receipt,
              card_fingerprint: fingerprint(request),
              checked_at:
                if(current.generation == claimed.generation, do: Repo.now!(), else: nil),
              attempt_count: 0,
              next_attempt_at: nil,
              last_error_code: nil,
              last_error_detail: nil
            })
          )
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def mark(_claimed, _request, _receipt), do: {:error, :emisar_approval_message_receipt_mismatch}

  @doc "Internal — a failed independent delivery waits or blocks without blocking run observation. Returns the updated row."
  @spec failed(ApprovalMessage.t(), term(), pos_integer(), boolean()) ::
          {:ok, ApprovalMessage.t()} | {:error, term()}
  def failed(%ApprovalMessage{} = claimed, reason, seconds, permanent?)
      when is_integer(seconds) and seconds > 0 and is_boolean(permanent?) do
    mutate(claimed, fn current ->
      update!(
        current,
        released(%{
          status: if(permanent?, do: :blocked, else: :active),
          next_attempt_at:
            if(permanent?, do: nil, else: DateTime.add(Repo.now!(), seconds, :second)),
          last_error_code: "emisar_review_delivery_failed",
          last_error_detail: ErrorDetail.detail(reason)
        })
      )
    end)
  end

  def failed(_claimed, _reason, _seconds, _permanent?),
    do: {:error, :invalid_emisar_approval_message_failure}

  defp stored_receipt(%ApprovalMessage{external_receipt: nil}), do: :ok
  defp stored_receipt(message), do: validate_receipt(message, message.external_receipt)

  @doc "Internal — the message worker validates the exact typed route before an update. Returns :ok or an error."
  @spec validate_receipt(ApprovalMessage.t(), term()) :: :ok | {:error, term()}
  def validate_receipt(%ApprovalMessage{} = message, receipt) do
    with {:ok, prepared} <- Work.DeliveryReceipt.prepare(receipt),
         true <-
           prepared == receipt and
             receipt["delivery_ref"] == message.ref and receipt["transport"] == message.transport and
             receipt["conversation_ref"] == message.conversation_ref and
             receipt["thread_ref"] == message.thread_ref do
      :ok
    else
      _ -> {:error, :emisar_approval_message_receipt_mismatch}
    end
  end

  def validate_receipt(_message, _receipt),
    do: {:error, :emisar_approval_message_receipt_mismatch}

  defp mutate(claimed, fun) do
    Repo.transaction(fn ->
      current =
        claimed.id
        |> ApprovalMessage.Query.by_id()
        |> ApprovalMessage.Query.lock_for_update()
        |> Repo.peek()

      if not is_nil(current) and current.lease_ref == claimed.lease_ref and
           DateTime.compare(current.lease_expires_at, Repo.now!()) == :gt,
         do: fun.(current),
         else: Repo.rollback(:emisar_approval_message_lease_lost)
    end)
  end

  defp released(attributes),
    do: Map.merge(attributes, %{lease_ref: nil, lease_owner: nil, lease_expires_at: nil})

  defp update!(message, attributes),
    do: message |> ApprovalMessage.Changeset.update(attributes) |> Repo.update!()
end
