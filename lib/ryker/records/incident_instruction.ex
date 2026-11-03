defmodule Ryker.Records.IncidentInstruction do
  @moduledoc "A current host-admitted investigation input, authenticated by its confirmed incident."
  alias Ryker.ConversationRef
  alias Ryker.Episodes
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Slack

  defstruct [
    :event_id,
    :record_ref,
    :room_ref,
    :episode_id,
    :source_conversation_ref,
    :destination_conversation_ref,
    :destination_thread_ref,
    :source_item_ref,
    destination_transport: "slack"
  ]

  @type t :: %__MODULE__{}

  @doc "Resolve a host incident introduction against its current incident relationship."
  def fetch(
        binding,
        %Episodes.Event{payload: %{"payload" => %{"incident_room" => %{"record_ref" => ref}}}} =
          event
      ) do
    with {:ok, room} <- Repo.fetch(Slack.IncidentRoom.Query.by_ref(ref)),
         true <- event.payload["native_input_id"] == "incident-room-request:#{room.id}",
         true <- room.episode_id == binding.episode.id,
         true <- room.source_episode_id == binding.episode.linked_episode_id,
         true <-
           room.status == :ready and room.channel_state == :active and
             is_nil(room.close_requested_at),
         true <-
           binding.episode.destination_conversation_ref ==
             ConversationRef.slack(room.workspace_ref, room.channel_ref),
         true <- binding.episode.destination_thread_ref == room.root_message_ref,
         {:ok, record} <- Repo.fetch(Record.Query.by_id(room.record_id)),
         {:ok, source} <- confirmed_incident(record, binding),
         true <-
           source.destination_conversation_ref ==
             ConversationRef.slack(room.workspace_ref, room.source_channel_ref) do
      {:ok,
       instruction(
         binding,
         event,
         record,
         room.ref,
         ConversationRef.slack(room.workspace_ref, room.source_channel_ref)
       )}
    else
      _invalid -> {:error, :task_instruction_not_authorized}
    end
  end

  def fetch(
        binding,
        %Episodes.Event{
          payload: %{"payload" => %{"record_ref" => ref, "task" => %{"kind" => "incident"}}}
        } =
          event
      ) do
    with {:ok, record} <- Repo.fetch(Record.Query.by_ref(ref)),
         true <- event.payload["native_input_id"] == "task-confirmation:#{record.ref}",
         {:ok, source} <- confirmed_incident(record, binding),
         true <-
           source.destination_conversation_ref == binding.episode.destination_conversation_ref do
      {:ok,
       instruction(binding, event, record, nil, binding.episode.destination_conversation_ref)}
    else
      _invalid -> {:error, :task_instruction_not_authorized}
    end
  end

  def fetch(_binding, _event), do: {:error, :task_instruction_not_authorized}

  defp confirmed_incident(record, binding) do
    with true <-
           record.kind == "task_offer" and record.payload["kind"] == "incident" and
             record.status == :confirmed and record.confirmed_episode_id == binding.episode.id and
             record.episode_id == binding.episode.linked_episode_id and
             binding.episode.execution_mode == :live and
             binding.episode.destination_transport == "slack",
         {:ok, source} <- Repo.fetch(Episodes.Episode.Query.by_id(record.episode_id)),
         true <- source.destination_transport == "slack" and source.execution_mode == :live do
      {:ok, source}
    else
      _invalid -> {:error, :task_instruction_not_authorized}
    end
  end

  defp instruction(binding, event, record, room_ref, source) do
    %__MODULE__{
      event_id: event.id,
      record_ref: record.ref,
      room_ref: room_ref,
      episode_id: binding.episode.id,
      source_conversation_ref: source,
      destination_conversation_ref: binding.episode.destination_conversation_ref,
      destination_thread_ref: binding.episode.destination_thread_ref,
      source_item_ref: binding.episode.destination_thread_ref
    }
  end

  @doc "Fence the incident and both channels before taking its episode's lock."
  def lock_in_transaction(%__MODULE__{} = instruction) do
    with :ok <-
           lock_channels([
             instruction.source_conversation_ref,
             instruction.destination_conversation_ref
           ]),
         {:ok, workspace, _channel} <-
           ConversationRef.parse_slack(instruction.source_conversation_ref),
         :ok <- Slack.IncidentRooms.synchronize_in_transaction(workspace),
         :ok <- lock_room(instruction.room_ref) do
      instruction.record_ref
      |> Record.Query.by_ref()
      |> Record.Query.lock_for_update()
      |> Repo.all()

      :ok
    end
  end

  def lock_in_transaction(_source), do: {:error, :task_instruction_not_authorized}

  @doc "Fence an incoming room message against its source channel and room lifecycle."
  def lock_room_in_transaction(conversation) do
    with {:ok, workspace, channel} <- ConversationRef.parse_slack(conversation),
         {:ok, room} <- Slack.IncidentRooms.fetch_channel_room(workspace, channel) do
      with :ok <-
             lock_channels([
               conversation,
               ConversationRef.slack(workspace, room.source_channel_ref)
             ]),
           :ok <- Slack.IncidentRooms.synchronize_in_transaction(workspace),
           do: lock_room(room.ref)
    else
      _not_room -> :ok
    end
  end

  defp lock_channels(conversations) do
    conversations
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn conversation, :ok ->
      case Slack.ChannelFence.authorize_in_transaction("slack", conversation) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp lock_room(nil), do: :ok

  defp lock_room(ref) do
    query = ref |> Slack.IncidentRoom.Query.by_ref() |> Slack.IncidentRoom.Query.lock_for_update()

    case Repo.fetch(query) do
      {:ok, room} ->
        room.record_id |> Record.Query.by_id() |> Record.Query.lock_for_update() |> Repo.all()

      {:error, :not_found} ->
        :ok
    end

    :ok
  end
end
