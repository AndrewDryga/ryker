defmodule Ryker.State.SlackPostOffers do
  @moduledoc """
  Confirms one delivered, inert post offer into one durable platform action.

  The model can prepare exact bytes and a destination, but it cannot authorize
  the post. Only the original human requester may click the host-rendered
  control on the exact delivered offer; that confirmation enqueues one
  idempotent outbox action.
  """

  import Ecto.Query

  alias Ryker.Delivery.{PlatformAction, PlatformActionCustody}
  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.State.{CardDelivery, Record, RecordChangeset}
  alias Ryker.Work.Turn

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
      |> transaction_result()
    end
  end

  defp confirm_locked(attributes) do
    with {:ok, record, episode, turn} <- lock_offer(attributes.record_ref),
         :ok <- requester_authorized(record, attributes.actor_ref),
         :ok <- delivered_from?(episode, turn, attributes.target) do
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
           PlatformActionCustody.enqueue_confirmed_record_in_transaction(
             record,
             platform_action_attributes(record)
           ),
         {:ok, record} <-
           record
           |> RecordChangeset.confirm_resource(%{
             confirmed_at: attributes.occurred_at,
             confirmed_by_actor_ref: attributes.actor_ref,
             confirmation_ref: attributes.confirmation_ref,
             status: :confirmed
           })
           |> Repo.update() do
      %{action: action, record: record, status: :confirmed}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp confirmed(record) do
    case Repo.get_by(PlatformAction,
           turn_id: record.turn_id,
           host_slot: host_slot(record)
         ) do
      %PlatformAction{} = action ->
        %{action: action, record: record, status: :duplicate}

      nil ->
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
  def host_slot(record), do: "confirmed-post:#{record.id}"

  defp lock_offer(record_ref) do
    query =
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        where: record.ref == ^record_ref and record.kind == "slack_post_offer",
        select: {record, episode, turn},
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :slack_post_offer_not_found}
      {record, episode, turn} -> {:ok, record, episode, turn}
    end
  end

  defp requester_authorized(
         %Record{payload: %{"requested_by_actor_ref" => actor_ref}},
         actor_ref
       ),
       do: :ok

  defp requester_authorized(_record, _actor_ref),
    do: {:error, :slack_post_offer_actor_mismatch}

  defp delivered_from?(episode, turn, target) do
    case CardDelivery.delivered_from?(episode, turn, target) do
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
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_slack_post_confirmation, :fields}}
  end

  defp attributes(_attributes),
    do: {:error, {:invalid_slack_post_confirmation, :fields}}

  defp target(%{} = target) do
    if Map.keys(target) |> Enum.sort() == Enum.sort(@target_fields) do
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

  defp utc_datetime(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0 do
      {microsecond, _precision} = value.microsecond
      {:ok, %{value | microsecond: {microsecond, 6}}}
    else
      {:error, {:invalid_slack_post_confirmation, :occurred_at}}
    end
  end

  defp utc_datetime(_value),
    do: {:error, {:invalid_slack_post_confirmation, :occurred_at}}

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_slack_post_confirmation, field}}
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
