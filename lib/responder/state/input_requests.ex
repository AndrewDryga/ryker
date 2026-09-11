defmodule Responder.State.InputRequests do
  @moduledoc """
  Records authenticated answers and their exact question association.

  The button carries only an opaque record reference and choice index. This
  boundary re-reads the delivered question, exact choice, current wait owner,
  actor, and destination before creating the ingress input. Platform-specific
  envelopes stop here; the resulting inbox entry follows ordinary admission.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Episodes.Episode
  alias Responder.Ingress.{Inbox, Input}
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.Slack.InteractionAudits

  alias Responder.State.{
    CardDelivery,
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

  @doc """
  Associate a typed reply while admission holds the input and episode locks.

  This records provenance, not a semantic decision that the reply supplies the
  requested fact. The original body and revision stay in the immutable inbox;
  no choice is invented and nothing is automatically trusted as global memory.
  """
  def associate_in_transaction(
        %Episode{state: :waiting_for_input, owner_kind: :input, owner_ref: ref},
        %Entry{actor_kind: :user, event_kind: :message, content: %{"text" => text}} = entry
      )
      when is_binary(text) and text != "" do
    with true <- Repo.in_transaction?(),
         {:ok, record, episode, turn} <- lock_request(ref),
         :ok <- current_wait?(episode, ref) do
      if typed_answer_source?(entry, episode, turn) and
           is_nil(Repo.get_by(Response, record_id: record.id)) do
        persist_typed_response(record, entry, turn)
      else
        :ok
      end
    else
      false -> {:error, :state_record_transaction_required}
      {:error, _reason} = error -> error
    end
  end

  def associate_in_transaction(_episode, _entry), do: :ok

  defp persist_typed_response(record, entry, turn) do
    attributes = %{
      actor_ref: entry.actor_ref,
      choice_index: nil,
      occurred_at: entry.occurred_at,
      response_ref: entry.event_ref
    }

    case persist_response(record, entry, nil, attributes) do
      {:ok, _response} ->
        InteractionAudits.record_answer_in_transaction(entry, record, turn, :typed)

      {:error, _reason} = error ->
        error
    end
  end

  defp typed_answer_source?(entry, episode, %Turn{external_receipt: receipt} = turn)
       when is_map(receipt) do
    target = %{
      transport: entry.destination_transport,
      conversation_ref: entry.destination_conversation_ref,
      thread_ref: entry.destination_thread_ref,
      message_ref: receipt["message_ref"]
    }

    delivered_from?(episode, turn, target) == :ok and
      DateTime.compare(entry.occurred_at, turn.delivered_at) == :gt
  end

  defp typed_answer_source?(_entry, _episode, _turn), do: false

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
        nil -> record_answer(record, episode, turn, attributes)
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

  defp record_answer(%Record{status: :open} = record, episode, turn, attributes) do
    with :ok <- current_wait?(episode, record.ref),
         {:ok, choice} <- choice(record, attributes.choice_index),
         {:ok, input} <- input(record, choice, attributes),
         {:ok, inbox_receipt} <- Inbox.record(input),
         {:ok, response} <- persist_response(record, inbox_receipt.entry, choice, attributes),
         {:ok, record} <- record |> RecordChangeset.answer() |> Repo.update(),
         :ok <-
           InteractionAudits.record_answer_in_transaction(
             inbox_receipt.entry,
             record,
             turn,
             :choice
           ) do
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

  defp record_answer(%Record{}, _episode, _turn, _attributes),
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

  defp input(record, choice, %{target: %{transport: "slack"}} = attributes) do
    with {:ok, workspace_ref, channel_ref} <- slack_destination(attributes.target) do
      SlackInput.new(%{
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

  defp input(
         record,
         choice,
         %{target: %{transport: "control_plane"} = target} = attributes
       ) do
    if String.starts_with?(target.conversation_ref, "control-plane:lab:") and
         target.thread_ref == target.conversation_ref do
      Input.new(%{
        actor: %{kind: :user, ref: attributes.actor_ref},
        content: %{
          "choice" => choice,
          "choice_index" => attributes.choice_index,
          "input_request_ref" => record.ref,
          "interaction_kind" => "button"
        },
        destination: %{
          transport: "control_plane",
          conversation_ref: target.conversation_ref,
          thread_ref: target.thread_ref
        },
        event_kind: :event,
        event_ref: attributes.response_ref,
        native_input_id:
          "control-plane-response:" <>
            CanonicalJSON.digest([record.ref, attributes.response_ref]),
        occurred_at: attributes.occurred_at,
        occurred_at_source: :ingress,
        revision: 1,
        source: %{kind: "control_plane", ref: "local"},
        source_capabilities: %{},
        source_item_ref: attributes.response_ref
      })
    else
      {:error, :input_request_delivery_mismatch}
    end
  end

  defp input(_record, _choice, _attributes),
    do: {:error, :input_request_delivery_mismatch}

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

  defp delivered_from?(episode, turn, target) do
    case CardDelivery.delivered_from?(episode, turn, target) do
      :ok -> :ok
      {:error, :mismatch} -> {:error, :input_request_delivery_mismatch}
      {:error, :not_delivered} -> {:error, :input_request_not_delivered}
    end
  end

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
