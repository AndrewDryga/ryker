defmodule Ryker.Delivery.RoutingResponseCustody do
  @moduledoc """
  Durable single-owner custody for what routing sends by itself: reactions on
  the message, or a quick reply's messages beside it and its reactions on it.

  Admission freezes the exact emoji and words and the host-owned destination
  in the same transaction as the model decision: one response per message or
  emoji, the messages first in the order written, then the reactions. A
  response is sent only once every earlier one of its input is delivered, so
  a retry or a second worker never reorders them. Platform workers can retry
  delivery, but cannot change the target, what is sent or its order.

  Each response queued, claimed, retried, blocked or delivered is announced
  after the outermost commit (`subscribe_routing_responses/0`), on its message's
  topics too (`Ryker.Ingress.Inbox`).
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.{Request, RoutingResponse, RoutingResponseChangeset}
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Work.DeliveryReceipt

  @type claim :: %{lease_ref: String.t(), response: RoutingResponse.t()}

  @doc false
  @spec enqueue_in_transaction(Entry.t()) :: {:ok, [RoutingResponse.t()]} | {:error, term()}
  def enqueue_in_transaction(%Entry{status: :decided, decision_action: action} = entry)
      when action in [:react, :quick_reply] do
    with :ok <- transaction_open(),
         {:ok, responses} <- decided_responses(entry.decision_document) do
      responses
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, &insert_response(entry, &1, &2))
      |> then(fn
        {:ok, inserted} -> {:ok, Enum.reverse(inserted)}
        {:error, _reason} = error -> error
      end)
    end
  end

  def enqueue_in_transaction(%Entry{status: :decided}), do: {:ok, []}
  def enqueue_in_transaction(_entry), do: {:error, {:invalid_routing_response, :entry}}

  defp insert_response(entry, {{kind, document}, position}, {:ok, inserted}) do
    entry
    |> RoutingResponseChangeset.insert(
      Ecto.UUID.generate(),
      position,
      kind,
      document,
      CanonicalJSON.digest(document)
    )
    |> Repo.insert()
    |> persistence_result(:routing_response)
    |> case do
      {:ok, response} -> {:cont, {:ok, [response | inserted]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  # The words first, as written, then the emoji on the person's message: a
  # reaction that cannot be added never holds back the answer.
  defp decided_responses(%{"action" => "react", "reactions" => [_first | _rest] = reactions}),
    do: {:ok, Enum.map(reactions, &reaction/1)}

  defp decided_responses(%{
         "action" => "quick_reply",
         "messages" => [_first | _rest] = messages,
         "reactions" => reactions
       }) do
    {:ok,
     Enum.map(messages, &{:message, %{"message" => &1}}) ++
       Enum.map(reactions || [], &reaction/1)}
  end

  defp decided_responses(_decision), do: {:error, {:invalid_routing_response, :decision}}

  defp reaction(emoji_name), do: {:reaction, %{"emoji_name" => emoji_name}}

  @doc """
  The responses a worker may send now: pending ones whose every earlier
  response for the same input is delivered. The claim and the queue gauges
  read this one query, so a response waiting its turn is never counted as
  stalled work.
  """
  @spec in_order(Ecto.Queryable.t()) :: Ecto.Query.t()
  def in_order(query) do
    from(response in query,
      as: :response,
      where:
        not exists(
          from(earlier in RoutingResponse,
            where:
              earlier.input_id == parent_as(:response).input_id and
                earlier.position < parent_as(:response).position and
                earlier.status != :delivered,
            select: 1
          )
        )
    )
  end

  @spec claim_next(String.t(), pos_integer()) :: {:ok, claim() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- positive_integer(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> claim_locked(worker_ref, lease_seconds) end)
    end
  end

  # A reaction lands on the message it answers; a quick reply is a message of
  # its own in the same place, so it names no source item.
  @spec request(RoutingResponse.t()) :: {:ok, Request.t()} | {:error, term()}
  def request(%RoutingResponse{kind: kind} = response) when kind in [:reaction, :message] do
    Request.new(%{
      conversation_ref: response.conversation_ref,
      document: response.document,
      kind: kind,
      ref: response.delivery_ref,
      source_item_ref: if(kind == :reaction, do: response.source_item_ref),
      thread_ref: response.thread_ref,
      transport: response.transport
    })
  end

  def request(_response), do: {:error, {:invalid_routing_response, :request}}

  @doc """
  Extends the current fenced routing response lease without spending another attempt.
  """
  @spec renew(String.t(), String.t(), pos_integer()) ::
          {:ok, RoutingResponse.t()} | {:error, term()}
  def renew(delivery_ref, lease_ref, lease_seconds) do
    with :ok <- reference(delivery_ref, :delivery_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(lease_seconds, :lease_seconds) do
      mutate_claim(delivery_ref, lease_ref, fn response, now ->
        requested_expiry = DateTime.add(now, lease_seconds, :second)
        lease_expires_at = later_datetime(response.lease_expires_at, requested_expiry)

        response
        |> RoutingResponseChangeset.renew(lease_expires_at)
        |> Repo.update()
        |> unwrap_or_rollback(:delivery_renewal)
      end)
    end
  end

  @spec block(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, RoutingResponse.t()} | {:error, term()}
  def block(delivery_ref, lease_ref, error_code, error_detail) do
    with :ok <- reference(delivery_ref, :delivery_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail) do
      mutate_claim(delivery_ref, lease_ref, fn response, _now ->
        response
        |> RoutingResponseChangeset.block(%{
          last_error_code: error_code,
          last_error_detail: error_detail,
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: nil,
          status: :blocked
        })
        |> Repo.update()
        |> unwrap_or_rollback(:delivery_block)
      end)
    end
  end

  @doc """
  Rearms one operator-inspected blocked routing response without changing its intent.
  """
  @spec retry(String.t()) :: {:ok, RoutingResponse.t()} | {:error, term()}
  def retry(delivery_ref) do
    with :ok <- reference(delivery_ref, :delivery_ref) do
      Repo.transaction(fn -> retry_locked(delivery_ref) end)
    end
  end

  @spec defer(String.t(), String.t(), pos_integer(), String.t(), String.t()) ::
          {:ok, RoutingResponse.t()} | {:error, term()}
  def defer(delivery_ref, lease_ref, retry_seconds, error_code, error_detail) do
    with :ok <- reference(delivery_ref, :delivery_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(retry_seconds, :retry_seconds),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail) do
      mutate_claim(delivery_ref, lease_ref, fn response, now ->
        response
        |> RoutingResponseChangeset.defer(%{
          last_error_code: error_code,
          last_error_detail: error_detail,
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: DateTime.add(now, retry_seconds, :second)
        })
        |> Repo.update()
        |> unwrap_or_rollback(:delivery_defer)
      end)
    end
  end

  @spec confirm_delivery(String.t(), String.t(), map()) ::
          {:ok, RoutingResponse.t()} | {:error, term()}
  def confirm_delivery(delivery_ref, lease_ref, receipt) do
    with :ok <- reference(delivery_ref, :delivery_ref),
         :ok <- reference(lease_ref, :lease_ref),
         {:ok, receipt} <- DeliveryReceipt.prepare(receipt) do
      fingerprint = DeliveryReceipt.fingerprint(receipt)

      Repo.transaction(fn ->
        confirm_locked(delivery_ref, lease_ref, receipt, fingerprint)
      end)
    end
  end

  defp claim_locked(worker_ref, lease_seconds) do
    now = Repo.now!()

    case Repo.one(
           from(response in in_order(RoutingResponse),
             where:
               response.status == :pending and
                 (is_nil(response.next_attempt_at) or response.next_attempt_at <= ^now) and
                 (is_nil(response.lease_ref) or response.lease_expires_at <= ^now),
             order_by: [asc: response.inserted_at, asc: response.position, asc: response.id],
             limit: 1,
             lock: "FOR UPDATE SKIP LOCKED"
           )
         ) do
      nil ->
        nil

      %RoutingResponse{} = response ->
        lease_ref = "routing-response-lease:#{Ecto.UUID.generate()}"

        claimed =
          response
          |> RoutingResponseChangeset.claim(%{
            attempt_count: response.attempt_count + 1,
            last_error_code: nil,
            last_error_detail: nil,
            lease_expires_at: DateTime.add(now, lease_seconds, :second),
            lease_owner: worker_ref,
            lease_ref: lease_ref,
            next_attempt_at: nil
          })
          |> Repo.update()
          |> unwrap_or_rollback(:delivery_claim)

        %{lease_ref: lease_ref, response: claimed}
    end
  end

  # Every change to a claimed routing response happens under its row lock and only
  # while the caller still holds the lease it was given.
  defp mutate_claim(delivery_ref, lease_ref, callback) do
    Repo.transaction(fn ->
      now = Repo.now!()

      case leased_response(delivery_ref, lease_ref, now) do
        {:ok, response} -> callback.(response, now)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp retry_locked(delivery_ref) do
    case lock_response(delivery_ref) do
      %RoutingResponse{status: :blocked} = response ->
        response
        |> RoutingResponseChangeset.retry()
        |> Repo.update()
        |> unwrap_or_rollback(:delivery_retry)

      %RoutingResponse{status: :pending} = response ->
        response

      %RoutingResponse{} ->
        Repo.rollback(:routing_response_not_retryable)

      nil ->
        Repo.rollback(:routing_response_not_found)
    end
  end

  defp confirm_locked(delivery_ref, lease_ref, receipt, fingerprint) do
    now = Repo.now!()

    case lock_response(delivery_ref) do
      %RoutingResponse{status: :delivered, external_receipt_fingerprint: ^fingerprint} = response ->
        response

      %RoutingResponse{status: :delivered} ->
        Repo.rollback(:routing_response_receipt_conflict)

      %RoutingResponse{} = response ->
        with :ok <- current_lease(response, lease_ref, now),
             :ok <- exact_receipt(response, receipt) do
          response
          |> RoutingResponseChangeset.deliver(receipt, fingerprint, now)
          |> Repo.update()
          |> unwrap_or_rollback(:delivery_confirmation)
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      nil ->
        Repo.rollback(:routing_response_not_found)
    end
  end

  defp leased_response(delivery_ref, lease_ref, now) do
    case lock_response(delivery_ref) do
      %RoutingResponse{status: :pending} = response ->
        case current_lease(response, lease_ref, now) do
          :ok -> {:ok, response}
          {:error, _reason} = error -> error
        end

      %RoutingResponse{} ->
        {:error, :routing_response_not_pending}

      nil ->
        {:error, :routing_response_not_found}
    end
  end

  defp lock_response(delivery_ref) do
    Repo.one(
      from(response in RoutingResponse,
        where: response.delivery_ref == ^delivery_ref,
        lock: "FOR UPDATE"
      )
    )
  end

  defp current_lease(response, lease_ref, now) do
    if response.lease_ref == lease_ref and is_binary(response.lease_owner) and
         match?(%DateTime{}, response.lease_expires_at) and
         DateTime.compare(response.lease_expires_at, now) == :gt,
       do: :ok,
       else: {:error, :routing_response_lease_lost}
  end

  # A reaction's receipt names the message it landed on; a quick reply's
  # names the new message it became.
  defp exact_receipt(response, receipt) do
    if receipt["delivery_ref"] == response.delivery_ref and
         receipt["transport"] == response.transport and
         receipt["conversation_ref"] == response.conversation_ref and
         receipt["thread_ref"] == response.thread_ref and
         receipt_message?(response, receipt["message_ref"]),
       do: :ok,
       else: {:error, :routing_response_receipt_mismatch}
  end

  defp receipt_message?(%RoutingResponse{kind: :reaction} = response, message_ref),
    do: message_ref == response.source_item_ref

  defp receipt_message?(%RoutingResponse{kind: :message}, message_ref),
    do: is_binary(message_ref) and message_ref != ""

  defp later_datetime(nil, requested), do: requested

  defp later_datetime(current, requested) do
    if DateTime.compare(current, requested) == :lt, do: requested, else: current
  end

  defp persistence_result({:ok, value}, _operation) do
    broadcast_routing_response_updated(value)
    {:ok, value}
  end

  defp persistence_result({:error, changeset}, operation),
    do: {:error, {:persistence_failed, operation, changeset.errors}}

  # A renewal only moves the lease's expiry, which no page shows.
  defp unwrap_or_rollback({:ok, value}, :delivery_renewal), do: value

  defp unwrap_or_rollback({:ok, value}, _operation) do
    broadcast_routing_response_updated(value)
    value
  end

  defp unwrap_or_rollback({:error, changeset}, operation),
    do: Repo.rollback({:persistence_failed, operation, changeset.errors})

  defp transaction_open do
    if Repo.in_transaction?(),
      do: :ok,
      else: {:error, :delivery_transaction_required}
  end

  defp reference(value, field), do: bounded_text(value, 1_024, field)

  defp bounded_text(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= maximum,
       do: :ok,
       else: {:error, {:invalid_routing_response, field}}
  end

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, field), do: {:error, {:invalid_routing_response, field}}

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to routing response changes:
  `{:routing_response_updated, response_id}` once a reaction or quick reply
  routing chose is queued, claimed, retried, blocked or delivered, and that
  change has committed.
  """
  def subscribe_routing_responses, do: Ryker.PubSub.subscribe(routing_responses_topic())

  def unsubscribe_routing_responses, do: Ryker.PubSub.unsubscribe(routing_responses_topic())

  defp routing_responses_topic, do: "delivery:routing_responses"

  defp broadcast_routing_response_updated(%RoutingResponse{id: id} = response) do
    Inbox.broadcast_input_updated(response.input_id)

    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(routing_responses_topic(), {:routing_response_updated, id})
    end)
  end
end
