defmodule Ryker.Records.SlackPostOffers do
  @moduledoc """
  Confirms one delivered, inert post offer into one durable platform action.

  The model can prepare exact bytes and a destination, but it cannot authorize
  the post. Only the original human requester may click the host-rendered
  control on the exact delivered offer; that confirmation enqueues one
  idempotent outbox action.
  """
  alias Ryker.Delivery
  alias Ryker.Maps
  alias Ryker.Records
  alias Ryker.Records.CardDelivery
  alias Ryker.Records.Record
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.UTCDateTime

  @fields [:actor_ref, :confirmation_ref, :occurred_at, :record_ref, :target]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]

  @spec confirm(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def confirm(attributes) do
    with {:ok, attributes} <- attributes(attributes),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- reference(attributes.confirmation_ref, :confirmation_ref),
         :ok <- reference(attributes.record_ref, :record_ref),
         {:ok, occurred_at} <- utc_datetime(attributes.occurred_at),
         {:ok, target} <- target(attributes.target) do
      Repo.transaction(fn ->
        confirm_locked(%{attributes | occurred_at: occurred_at, target: target})
      end)
    end
  end

  defp confirm_locked(attributes) do
    with {:ok, record, episode, turn} <- lock_offer(attributes.record_ref),
         :ok <- requester_authorized(record, attributes.actor_ref),
         :ok <- check_delivery(episode, turn, attributes.target) do
      case record.status do
        :open -> confirm_open(record, attributes)
        :confirmed -> confirmed(record)
        _stale -> Repo.rollback(:slack_post_offer_stale)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp confirm_open(record, attributes) do
    with {:ok, %{action: action}} <-
           Delivery.PlatformActionCustody.enqueue_confirmed_record_in_transaction(
             record,
             platform_action_attributes(record)
           ),
         {:ok, record} <- Records.confirm_offer(record, attributes) do
      %{action: action, record: record, status: :confirmed}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp confirmed(record) do
    case Repo.fetch(Delivery.PlatformAction.Query.by_turn_slot(record.turn_id, host_slot(record))) do
      {:ok, %Delivery.PlatformAction{} = action} ->
        %{action: action, record: record, status: :duplicate}

      {:error, :not_found} ->
        Repo.rollback(:slack_post_offer_confirmation_incomplete)
    end
  end

  defp platform_action_attributes(record) do
    %{
      conversation_ref: record.payload["conversation_ref"],
      document: %{"message" => record.payload["message"]},
      host_slot: host_slot(record),
      kind: :message,
      source_item_ref: nil,
      thread_ref: record.payload["thread_ref"],
      tool: :post_slack_message,
      transport: record.payload["transport"]
    }
  end

  @doc """
  The durable slot a confirmed post's platform action occupies.

  Public so a card can find the delivery its own record produced, which is the
  only way it can show where the message went.
  """
  @spec host_slot(Record.t()) :: String.t()
  def host_slot(%Record{} = record), do: "confirmed-post:#{record.id}"

  defp lock_offer(record_ref) do
    case Records.lock_offer(record_ref, ["slack_post_offer"]) do
      {:error, :not_found} -> {:error, :slack_post_offer_not_found}
      found -> found
    end
  end

  defp requester_authorized(
         %Record{payload: %{"requested_by_actor_ref" => actor_ref}},
         actor_ref
       ),
       do: :ok

  defp requester_authorized(_record, _actor_ref),
    do: {:error, :slack_post_offer_actor_mismatch}

  defp check_delivery(episode, turn, target) do
    case CardDelivery.check(episode, turn, target) do
      :ok -> :ok
      {:error, :mismatch} -> {:error, :slack_post_offer_delivery_mismatch}
      {:error, :not_delivered} -> {:error, :slack_post_offer_not_delivered}
    end
  end

  defp attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> attributes(),
       else: {:error, {:invalid_slack_post_confirmation, :fields}}
  end

  defp attributes(%{} = attributes) do
    if Maps.exact_keys?(attributes, @fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_slack_post_confirmation, :fields}}
  end

  defp attributes(_attributes),
    do: {:error, {:invalid_slack_post_confirmation, :fields}}

  defp target(%{} = target) do
    if Maps.exact_keys?(target, @target_fields) do
      with :ok <- reference(target.transport, :transport),
           :ok <- reference(target.conversation_ref, :conversation_ref),
           :ok <- optional_reference(target.thread_ref, :thread_ref),
           :ok <- reference(target.message_ref, :message_ref) do
        {:ok, target}
      end
    else
      {:error, {:invalid_slack_post_confirmation, :target}}
    end
  end

  defp target(_target), do: {:error, {:invalid_slack_post_confirmation, :target}}

  defp utc_datetime(value) do
    case UTCDateTime.exact(value) do
      {:ok, exact} -> {:ok, exact}
      :error -> {:error, {:invalid_slack_post_confirmation, :occurred_at}}
    end
  end

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field) do
    if Reference.valid?(value), do: :ok, else: {:error, {:invalid_slack_post_confirmation, field}}
  end
end
