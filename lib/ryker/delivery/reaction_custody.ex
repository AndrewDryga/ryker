defmodule Ryker.Delivery.ReactionCustody do
  @moduledoc """
  Durable single-owner custody for source-item reactions.

  Admission freezes the exact emoji and host-owned destination in the same
  transaction as the model decision. Platform workers can retry delivery, but
  cannot change either the target or reaction.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.{Reaction, ReactionChangeset, Request}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Work.DeliveryReceipt

  @type claim :: %{lease_ref: String.t(), reaction: Reaction.t()}

  @doc false
  @spec enqueue_in_transaction(Entry.t()) :: {:ok, Reaction.t() | nil} | {:error, term()}
  def enqueue_in_transaction(%Entry{status: :decided, decision_action: :react} = entry) do
    with :ok <- transaction_open(),
         %{"reaction" => %{} = document} <- entry.decision_document do
      entry
      |> ReactionChangeset.insert(Ecto.UUID.generate(), document, CanonicalJSON.digest(document))
      |> Repo.insert()
      |> persistence_result(:delivery_reaction)
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_delivery_reaction, :decision}}
    end
  end

  def enqueue_in_transaction(%Entry{status: :decided}), do: {:ok, nil}
  def enqueue_in_transaction(_entry), do: {:error, {:invalid_delivery_reaction, :entry}}

  @spec fetch_by_input(Ecto.UUID.t()) :: {:ok, Reaction.t()} | :error
  def fetch_by_input(input_id) do
    case uuid(input_id) do
      {:ok, input_id} ->
        case Repo.get_by(Reaction, input_id: input_id) do
          %Reaction{} = reaction -> {:ok, reaction}
          nil -> :error
        end

      :error ->
        :error
    end
  end

  @spec claim_next(String.t(), pos_integer()) :: {:ok, claim() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- positive_integer(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> claim_locked(worker_ref, lease_seconds) end)
    end
  end

  @spec request(Reaction.t()) :: {:ok, Request.t()} | {:error, term()}
  def request(%Reaction{} = reaction) do
    Request.new(%{
      conversation_ref: reaction.conversation_ref,
      document: reaction.document,
      kind: :reaction,
      ref: reaction.delivery_ref,
      source_item_ref: reaction.source_item_ref,
      thread_ref: reaction.thread_ref,
      transport: reaction.transport
    })
  end

  def request(_reaction), do: {:error, {:invalid_delivery_reaction, :request}}

  @doc """
  Extends the current fenced reaction lease without spending another attempt.
  """
  @spec renew(String.t(), String.t(), pos_integer()) ::
          {:ok, Reaction.t()} | {:error, term()}
  def renew(delivery_ref, lease_ref, lease_seconds) do
    with :ok <- reference(delivery_ref, :delivery_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> renew_locked(delivery_ref, lease_ref, lease_seconds) end)
    end
  end

  @spec block(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Reaction.t()} | {:error, term()}
  def block(delivery_ref, lease_ref, error_code, error_detail) do
    with :ok <- reference(delivery_ref, :delivery_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail) do
      Repo.transaction(fn -> block_locked(delivery_ref, lease_ref, error_code, error_detail) end)
    end
  end

  @doc """
  Rearms one operator-inspected blocked reaction without changing its intent.
  """
  @spec retry(String.t()) :: {:ok, Reaction.t()} | {:error, term()}
  def retry(delivery_ref) do
    with :ok <- reference(delivery_ref, :delivery_ref) do
      Repo.transaction(fn -> retry_locked(delivery_ref) end)
    end
  end

  @spec defer(String.t(), String.t(), pos_integer(), String.t(), String.t()) ::
          {:ok, Reaction.t()} | {:error, term()}
  def defer(delivery_ref, lease_ref, retry_seconds, error_code, error_detail) do
    with :ok <- reference(delivery_ref, :delivery_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(retry_seconds, :retry_seconds),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail) do
      Repo.transaction(fn ->
        defer_locked(
          delivery_ref,
          lease_ref,
          retry_seconds,
          error_code,
          error_detail
        )
      end)
    end
  end

  @spec confirm_delivery(String.t(), String.t(), map()) ::
          {:ok, Reaction.t()} | {:error, term()}
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
           from(reaction in Reaction,
             where:
               reaction.status == :pending and
                 (is_nil(reaction.next_attempt_at) or reaction.next_attempt_at <= ^now) and
                 (is_nil(reaction.lease_ref) or reaction.lease_expires_at <= ^now),
             order_by: [asc: reaction.inserted_at, asc: reaction.id],
             limit: 1,
             lock: "FOR UPDATE SKIP LOCKED"
           )
         ) do
      nil ->
        nil

      %Reaction{} = reaction ->
        lease_ref = "reaction-lease:#{Ecto.UUID.generate()}"

        reaction
        |> ReactionChangeset.claim(%{
          attempt_count: reaction.attempt_count + 1,
          last_error_code: nil,
          last_error_detail: nil,
          lease_expires_at: DateTime.add(now, lease_seconds, :second),
          lease_owner: worker_ref,
          lease_ref: lease_ref,
          next_attempt_at: nil
        })
        |> Repo.update()
        |> case do
          {:ok, claimed} ->
            %{lease_ref: lease_ref, reaction: claimed}

          {:error, changeset} ->
            Repo.rollback({:persistence_failed, :delivery_claim, changeset.errors})
        end
    end
  end

  defp defer_locked(delivery_ref, lease_ref, retry_seconds, error_code, error_detail) do
    now = Repo.now!()

    case leased_reaction(delivery_ref, lease_ref, now) do
      {:ok, reaction} ->
        reaction
        |> ReactionChangeset.defer(%{
          last_error_code: error_code,
          last_error_detail: error_detail,
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: DateTime.add(now, retry_seconds, :second)
        })
        |> Repo.update()
        |> unwrap_or_rollback(:delivery_defer)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp renew_locked(delivery_ref, lease_ref, lease_seconds) do
    now = Repo.now!()

    case leased_reaction(delivery_ref, lease_ref, now) do
      {:ok, reaction} ->
        requested_expiry = DateTime.add(now, lease_seconds, :second)
        lease_expires_at = later_datetime(reaction.lease_expires_at, requested_expiry)

        reaction
        |> ReactionChangeset.renew(lease_expires_at)
        |> Repo.update()
        |> unwrap_or_rollback(:delivery_renewal)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp block_locked(delivery_ref, lease_ref, error_code, error_detail) do
    now = Repo.now!()

    case leased_reaction(delivery_ref, lease_ref, now) do
      {:ok, reaction} ->
        reaction
        |> ReactionChangeset.block(%{
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

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp retry_locked(delivery_ref) do
    case lock_reaction(delivery_ref) do
      %Reaction{status: :blocked} = reaction ->
        reaction
        |> ReactionChangeset.retry()
        |> Repo.update()
        |> unwrap_or_rollback(:delivery_retry)

      %Reaction{status: :pending} = reaction ->
        reaction

      %Reaction{} ->
        Repo.rollback(:delivery_reaction_not_retryable)

      nil ->
        Repo.rollback(:delivery_reaction_not_found)
    end
  end

  defp confirm_locked(delivery_ref, lease_ref, receipt, fingerprint) do
    now = Repo.now!()

    case lock_reaction(delivery_ref) do
      %Reaction{status: :delivered, external_receipt_fingerprint: ^fingerprint} = reaction ->
        reaction

      %Reaction{status: :delivered} ->
        Repo.rollback(:delivery_reaction_receipt_conflict)

      %Reaction{} = reaction ->
        with :ok <- current_lease(reaction, lease_ref, now),
             :ok <- exact_receipt(reaction, receipt) do
          reaction
          |> ReactionChangeset.deliver(receipt, fingerprint, now)
          |> Repo.update()
          |> unwrap_or_rollback(:delivery_confirmation)
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      nil ->
        Repo.rollback(:delivery_reaction_not_found)
    end
  end

  defp leased_reaction(delivery_ref, lease_ref, now) do
    case lock_reaction(delivery_ref) do
      %Reaction{status: :pending} = reaction ->
        case current_lease(reaction, lease_ref, now) do
          :ok -> {:ok, reaction}
          {:error, _reason} = error -> error
        end

      %Reaction{} ->
        {:error, :delivery_reaction_not_pending}

      nil ->
        {:error, :delivery_reaction_not_found}
    end
  end

  defp lock_reaction(delivery_ref) do
    Repo.one(
      from(reaction in Reaction,
        where: reaction.delivery_ref == ^delivery_ref,
        lock: "FOR UPDATE"
      )
    )
  end

  defp current_lease(reaction, lease_ref, now) do
    if reaction.lease_ref == lease_ref and is_binary(reaction.lease_owner) and
         match?(%DateTime{}, reaction.lease_expires_at) and
         DateTime.compare(reaction.lease_expires_at, now) == :gt,
       do: :ok,
       else: {:error, :delivery_reaction_lease_lost}
  end

  defp exact_receipt(reaction, receipt) do
    if receipt["delivery_ref"] == reaction.delivery_ref and
         receipt["transport"] == reaction.transport and
         receipt["conversation_ref"] == reaction.conversation_ref and
         receipt["thread_ref"] == reaction.thread_ref and
         receipt["message_ref"] == reaction.source_item_ref,
       do: :ok,
       else: {:error, :delivery_reaction_receipt_mismatch}
  end

  defp later_datetime(nil, requested), do: requested

  defp later_datetime(current, requested) do
    if DateTime.compare(current, requested) == :lt, do: requested, else: current
  end

  defp persistence_result({:ok, value}, _operation), do: {:ok, value}

  defp persistence_result({:error, changeset}, operation),
    do: {:error, {:persistence_failed, operation, changeset.errors}}

  defp unwrap_or_rollback({:ok, value}, _operation), do: value

  defp unwrap_or_rollback({:error, changeset}, operation),
    do: Repo.rollback({:persistence_failed, operation, changeset.errors})

  defp uuid(value), do: Ecto.UUID.cast(value)

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
       else: {:error, {:invalid_delivery_reaction, field}}
  end

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, field), do: {:error, {:invalid_delivery_reaction, field}}
end
