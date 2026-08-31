defmodule Responder.State.InputRequests do
  @moduledoc """
  Records one authenticated Slack choice as generic durable input.

  The button carries only an opaque record reference and choice index. This
  boundary re-reads the delivered question, exact choice, current wait owner,
  actor, and Slack destination before creating the ingress input.
  """

  import Ecto.Query

  alias Responder.Episodes.Episode
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.Slack.Input

  alias Responder.State.{
    Record,
    RecordChangeset,
    Response,
    ResponseChangeset
  }

  alias Responder.Work.Turn

  @fields [
    :actor_ref,
    :choice_index,
    :occurred_at,
    :record_ref,
    :response_ref,
    :target
  ]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]

  @spec answer(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def answer(attributes) do
    with {:ok, attributes} <- attributes(attributes),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- choice_index(attributes.choice_index),
         {:ok, occurred_at} <- utc_datetime(attributes.occurred_at),
         :ok <- reference(attributes.record_ref, :record_ref),
         :ok <- reference(attributes.response_ref, :response_ref),
         {:ok, target} <- target(attributes.target) do
      Repo.transaction(fn ->
        answer_locked(%{attributes | occurred_at: occurred_at, target: target})
      end)
      |> transaction_result()
    end
  end

  defp answer_locked(attributes) do
    with {:ok, record, episode, turn} <- lock_request(attributes.record_ref),
         :ok <- delivered_from?(episode, turn, attributes.target) do
      case Repo.get_by(Response, record_id: record.id) do
        nil -> record_answer(record, episode, attributes)
        response -> duplicate(response, record, attributes)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_request(record_ref) do
    query =
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        where: record.ref == ^record_ref and record.kind == "input_request",
        select: {record, episode, turn},
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :input_request_not_found}
      {record, episode, turn} -> {:ok, record, episode, turn}
    end
  end

  defp record_answer(%Record{status: :open} = record, episode, attributes) do
    with :ok <- current_wait?(episode, record.ref),
         {:ok, choice} <- choice(record, attributes.choice_index),
         {:ok, input} <- input(record, choice, attributes),
         {:ok, inbox_receipt} <- Inbox.record(input),
         {:ok, response} <- persist_response(record, inbox_receipt.entry, choice, attributes),
         {:ok, record} <- record |> RecordChangeset.answer() |> Repo.update() do
      %{
        input_ref: Inbox.ref(inbox_receipt.entry),
        record: record,
        response: response,
        status: inbox_receipt.status
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp record_answer(%Record{}, _episode, _attributes),
    do: Repo.rollback(:input_request_stale)

  defp duplicate(response, record, attributes) do
    if response.response_ref == attributes.response_ref and
         response.actor_ref == attributes.actor_ref and
         response.choice_index == attributes.choice_index do
      case Repo.get(Entry, response.inbox_entry_id) do
        %Entry{} = entry ->
          %{
            input_ref: Inbox.ref(entry),
            record: record,
            response: response,
            status: :duplicate
          }

        nil ->
          Repo.rollback(:input_request_response_incomplete)
      end
    else
      Repo.rollback(:input_request_already_answered)
    end
  end

  defp current_wait?(
         %Episode{state: :waiting_for_input, owner_kind: :input, owner_ref: ref},
         ref
       ),
       do: :ok

  defp current_wait?(_episode, _record_ref), do: {:error, :input_request_stale}

  defp choice(%Record{payload: %{"choices" => choices}}, index) when is_list(choices) do
    case Enum.fetch(choices, index) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _missing -> {:error, :input_request_choice_invalid}
    end
  end

  defp choice(_record, _index), do: {:error, :input_request_choice_invalid}

  defp input(record, choice, attributes) do
    with {:ok, workspace_ref, channel_ref} <- slack_destination(attributes.target) do
      Input.new(%{
        actor: %{kind: :user, ref: attributes.actor_ref},
        channel_ref: channel_ref,
        content: %{
          "choice" => choice,
          "choice_index" => attributes.choice_index,
          "input_request_ref" => record.ref,
          "interaction_kind" => "button"
        },
        event_kind: :event,
        event_ref: attributes.response_ref,
        message_ref: attributes.response_ref,
        occurred_at: attributes.occurred_at,
        revision: 1,
        thread_ref: attributes.target.thread_ref,
        workspace_ref: workspace_ref
      })
    end
  end

  defp persist_response(record, entry, choice, attributes) do
    %{
      actor_ref: attributes.actor_ref,
      choice: choice,
      choice_index: attributes.choice_index,
      id: Ecto.UUID.generate(),
      inbox_entry_id: entry.id,
      occurred_at: attributes.occurred_at,
      record_id: record.id,
      response_ref: attributes.response_ref
    }
    |> ResponseChangeset.insert()
    |> Repo.insert()
    |> case do
      {:ok, response} -> {:ok, response}
      {:error, changeset} -> {:error, {:input_request_persistence_failed, changeset.errors}}
    end
  end

  defp delivered_from?(episode, %Turn{status: :settled, external_receipt: receipt}, target)
       when is_map(receipt) do
    exact =
      receipt["transport"] == episode.destination_transport and
        receipt["conversation_ref"] == episode.destination_conversation_ref and
        receipt["thread_ref"] == episode.destination_thread_ref and
        receipt["message_ref"] == target.message_ref and
        target.transport == episode.destination_transport and
        target.conversation_ref == episode.destination_conversation_ref and
        target.thread_ref == episode.destination_thread_ref

    if exact, do: :ok, else: {:error, :input_request_delivery_mismatch}
  end

  defp delivered_from?(_episode, _turn, _target), do: {:error, :input_request_not_delivered}

  defp slack_destination(%{conversation_ref: conversation_ref, transport: "slack"}) do
    case String.split(conversation_ref, ":", parts: 3) do
      ["slack", workspace_ref, channel_ref] -> {:ok, workspace_ref, channel_ref}
      _invalid -> {:error, :input_request_delivery_mismatch}
    end
  end

  defp slack_destination(_target), do: {:error, :input_request_delivery_mismatch}

  defp attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes) do
      attributes |> Map.new() |> attributes()
    else
      {:error, {:invalid_input_request_answer, :fields}}
    end
  end

  defp attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_input_request_answer, :fields}}
  end

  defp attributes(_attributes), do: {:error, {:invalid_input_request_answer, :fields}}

  defp target(%{} = target) do
    if Map.keys(target) |> Enum.sort() == Enum.sort(@target_fields) do
      with :ok <- reference(target.transport, :transport),
           :ok <- reference(target.conversation_ref, :conversation_ref),
           :ok <- reference(target.thread_ref, :thread_ref),
           :ok <- reference(target.message_ref, :message_ref) do
        {:ok, target}
      end
    else
      {:error, {:invalid_input_request_answer, :target}}
    end
  end

  defp target(_target), do: {:error, {:invalid_input_request_answer, :target}}

  defp choice_index(value) when is_integer(value) and value in 0..9, do: :ok
  defp choice_index(_value), do: {:error, {:invalid_input_request_answer, :choice_index}}

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: {:error, {:invalid_input_request_answer, field}}
  end

  defp utc_datetime(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0 do
      {microsecond, _precision} = value.microsecond
      {:ok, %{value | microsecond: {microsecond, 6}}}
    else
      {:error, {:invalid_input_request_answer, :occurred_at}}
    end
  end

  defp utc_datetime(_value), do: {:error, {:invalid_input_request_answer, :occurred_at}}

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
