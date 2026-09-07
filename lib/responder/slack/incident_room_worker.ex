defmodule Responder.Slack.IncidentRoomWorker do
  @moduledoc """
  Reconciles one durable Slack incident-room request at a time.

  Every provider operation is idempotent or searched by a deterministic
  receipt before mutation. A room does not become episode authority: it merely
  supplies a usable destination for the linked episode created at settlement.
  """

  use GenServer

  require Logger

  alias Responder.Observability.Progress
  alias Responder.Polling

  alias Responder.Episodes.Episode
  alias Responder.Repo
  alias Responder.Slack.{IncidentRoomCard, IncidentRooms}
  alias Responder.Work.Custody

  @default_interval_ms 1_000

  @spec start_link(map() | keyword()) :: GenServer.on_start()
  def start_link(options) do
    options = options!(options)

    case options.name do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @impl GenServer
  def init(options) do
    send(self(), :work)
    {:ok, options}
  end

  @impl GenServer
  def handle_info(:work, options) do
    delay =
      Polling.run(:slack_incidents, options.interval_ms, fn ->
        delay =
          case run_once(options) do
            {:ok, :idle} ->
              options.interval_ms

            {:ok, _result} ->
              0

            {:error, reason} ->
              Logger.warning("Slack incident-room worker failed: #{inspect(reason)}")
              options.interval_ms
          end

        _ = Progress.beat(:slack_incidents)
        delay
      end)

    Process.send_after(self(), :work, delay)
    {:noreply, options}
  end

  @spec run_once(map() | keyword()) ::
          {:ok,
           :idle
           | {:requested | :ready | :deferred | :blocked, String.t()}
           | {:blocked, String.t(), term()}}
          | {:error, term()}
  def run_once(options) do
    options = options!(options)

    case IncidentRooms.claim_next(options.worker_ref, options.lease_seconds) do
      {:ok, nil} -> claim_health_check(options)
      {:ok, room} -> execute(room, options)
      {:error, _reason} = error -> error
    end
  end

  defp claim_health_check(options) do
    case IncidentRooms.claim_health_check(
           options.worker_ref,
           options.lease_seconds,
           options.health_check_seconds
         ) do
      {:ok, nil} -> claim_root_card(options)
      {:ok, room} -> execute(room, options)
      {:error, _reason} = error -> error
    end
  end

  defp claim_root_card(options) do
    case IncidentRooms.claim_root_card(
           options.worker_ref,
           options.lease_seconds,
           options.root_card_check_seconds
         ) do
      {:ok, nil} -> request_automatic(options)
      {:ok, room} -> refresh_root_card(room, options)
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec options!(map() | keyword()) :: map()
  def options!(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> options!(),
      else: raise(ArgumentError, "incident-room worker requires unique options")
  end

  def options!(%{} = options) do
    required = [
      :api,
      :bot_user_ref,
      :client,
      :directory,
      :lease_seconds,
      :max_attempts,
      :retry_base_seconds,
      :worker_ref
    ]

    optional = [
      :automatic_request,
      :health_check_seconds,
      :interval_ms,
      :name,
      :root_card_check_seconds,
      :reserve_channel
    ]

    prepared =
      options
      |> Map.put_new(:health_check_seconds, 300)
      |> Map.put_new(:interval_ms, @default_interval_ms)
      |> Map.put_new(:name, nil)
      |> Map.put_new(:root_card_check_seconds, 2)

    if valid_options?(prepared, required, optional) do
      prepared
    else
      raise ArgumentError, "invalid incident-room worker options"
    end
  end

  def options!(_options), do: raise(ArgumentError, "invalid incident-room worker options")

  defp valid_options?(options, required, optional) do
    keys = Map.keys(options)
    automatic_request = Map.get(options, :automatic_request)
    reserve_channel = Map.get(options, :reserve_channel)

    Enum.all?([
      keys -- (required ++ optional) == [],
      Enum.all?(required, &(&1 in keys)),
      Map.get(options, :lease_seconds) in 5..3_600,
      Map.get(options, :max_attempts) in 1..100,
      Map.get(options, :retry_base_seconds) in 1..3_600,
      Map.get(options, :health_check_seconds) in 1..86_400,
      Map.get(options, :root_card_check_seconds) in 1..86_400,
      Map.get(options, :interval_ms) in 50..3_600_000,
      is_nil(automatic_request) or is_function(automatic_request, 0),
      is_nil(reserve_channel) or is_function(reserve_channel, 2),
      is_binary(Map.get(options, :worker_ref)),
      Map.get(options, :worker_ref) != ""
    ])
  end

  defp request_automatic(%{automatic_request: callback}) when is_function(callback, 0) do
    case callback.() do
      {:ok, nil} -> {:ok, :idle}
      {:ok, %{room: room}} -> {:ok, {:requested, room.ref}}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_automatic_incident_request}
    end
  end

  defp request_automatic(_options), do: {:ok, :idle}

  defp execute(%{status: :ready} = room, options) do
    if room.channel_state == room.reconciled_channel_state,
      do: check_channel(room, options),
      else: reconcile_lifecycle(room, options)
  end

  defp execute(room, options) do
    with {:ok, users} <- audience(room, options),
         {:ok, room} <- ensure_channel(room, options),
         :ok <- reserve_channel(room, options),
         {:ok, room} <- ensure_root(room, options),
         {:ok, room} <- ensure_audience(room, users, options),
         {:ok, room} <- ensure_topic(room, options),
         {:ok, room} <- ensure_pin(room, options),
         {:ok, room} <- ensure_handoff(room, options),
         {:ok, room} <- IncidentRooms.finalize(room.id, room.lease_ref) do
      {:ok, {:ready, room.ref}}
    else
      {:error, reason} -> handle_error(room, reason, options)
    end
  end

  defp reconcile_lifecycle(room, options) do
    with %Episode{} = episode <- Repo.get(Episode, room.episode_id),
         {:ok, result} <- reconcile_episode_destination(room, episode),
         {:ok, outcome} <- settle_lifecycle_reconciliation(room, result, options) do
      {:ok, outcome}
    else
      nil -> handle_error(room, :incident_room_episode_not_found, options)
      {:error, reason} -> handle_error(room, reason, options)
    end
  end

  defp check_channel(room, options) do
    case options.api.conversation_state(options.client, room.channel_ref) do
      {:ok, state} -> record_channel_observation(room, state, options)
      :not_found -> record_channel_observation(room, :unavailable, options)
      {:error, reason} -> handle_error(room, reason, options)
    end
  end

  defp record_channel_observation(room, state, options) do
    case IncidentRooms.record_channel_observation(room.id, room.lease_ref, state) do
      {:ok, %{status: :unchanged, room: observed}} -> {:ok, {:ready, observed.ref}}
      {:ok, %{status: :changed, room: observed}} -> reconcile_lifecycle(observed, options)
      {:error, reason} -> handle_error(room, reason, options)
    end
  end

  defp reconcile_episode_destination(%{channel_state: :active} = room, episode) do
    Custody.resume_destination(episode.id, episode.key, destination_pause_ref(room))
  end

  defp reconcile_episode_destination(
         %{channel_state: state} = room,
         episode
       )
       when state in [:archived, :deleted, :unavailable] do
    Custody.pause_destination(episode.id, episode.key, destination_pause_ref(room))
  end

  defp settle_lifecycle_reconciliation(room, %{status: :pending}, options) do
    retry_seconds = retry_delay(room.attempt_count, options.retry_base_seconds)

    case IncidentRooms.defer(
           room.id,
           room.lease_ref,
           retry_seconds,
           :incident_room_lifecycle_pending
         ) do
      {:ok, deferred} -> {:ok, {:deferred, deferred.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp settle_lifecycle_reconciliation(room, %{status: :settled}, _options) do
    case IncidentRooms.mark_lifecycle_reconciled(
           room.id,
           room.lease_ref,
           room.channel_state
         ) do
      {:ok, reconciled} -> {:ok, {:ready, reconciled.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp destination_pause_ref(room), do: "#{room.ref}:channel"

  defp audience(room, options) do
    with {:ok, group_users} <- expand_groups(room, options),
         users <- (room.invite_user_refs ++ group_users) |> Enum.uniq() |> Enum.sort(),
         :ok <- validate_users(users, room, options) do
      {:ok, Enum.reject(users, &(&1 == room.bot_user_ref))}
    end
  end

  defp expand_groups(room, options) do
    Enum.reduce_while(room.invite_user_group_refs, {:ok, []}, fn group_ref, {:ok, users} ->
      case options.directory.user_group_members(options.client, group_ref, room.workspace_ref) do
        {:ok, members} when is_list(members) and members != [] ->
          {:cont, {:ok, users ++ members}}

        {:ok, _empty_or_invalid} ->
          {:halt, {:error, :incident_audience_group_empty}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp validate_users(users, room, options) do
    Enum.reduce_while(users, :ok, fn user_ref, :ok ->
      case options.directory.user_allowed(options.client, user_ref, room.workspace_ref) do
        {:ok, true} -> {:cont, :ok}
        {:ok, false} -> {:halt, {:error, :incident_audience_member_invalid}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_channel(%{channel_ref: channel_ref} = room, _options) when is_binary(channel_ref),
    do: {:ok, room}

  defp ensure_channel(room, options) do
    with {:ok, channel_ref} <-
           options.api.ensure_conversation(
             options.client,
             room.workspace_ref,
             room.channel_name,
             room.private,
             room.bot_user_ref,
             room.requested_at
           ) do
      IncidentRooms.bind_channel(room.id, room.lease_ref, channel_ref)
    end
  end

  defp reserve_channel(room, %{reserve_channel: callback}) when is_function(callback, 2),
    do: callback.(room.workspace_ref, room.channel_ref)

  defp reserve_channel(_room, _options), do: :ok

  defp ensure_root(%{root_message_ref: message_ref} = room, _options) when is_binary(message_ref),
    do: {:ok, room}

  defp ensure_root(room, options) do
    delivery_ref = "#{room.ref}:root"

    with {:ok, card} <- IncidentRoomCard.build(room),
         {:ok, message_ref} <- root_message(room, card, delivery_ref, options) do
      IncidentRooms.bind_root(
        room.id,
        room.lease_ref,
        message_ref,
        card.fingerprint,
        card.ui_revision
      )
    end
  end

  defp root_message(room, card, delivery_ref, options) do
    case options.api.find_message(options.client, room.channel_ref, nil, delivery_ref) do
      {:ok, message_ref} ->
        {:ok, message_ref}

      :not_found ->
        options.api.post_message(
          options.client,
          room.channel_ref,
          nil,
          card.document,
          delivery_ref
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp refresh_root_card(room, options) do
    with {:ok, card} <- IncidentRoomCard.build(room),
         :ok <- maybe_update_root_card(room, card, options),
         {:ok, marked} <-
           IncidentRooms.mark_root_card(
             room.id,
             room.lease_ref,
             card.fingerprint,
             card.ui_revision
           ) do
      {:ok, {:ready, marked.ref}}
    else
      {:error, reason} -> handle_card_error(room, reason, options)
    end
  end

  defp maybe_update_root_card(
         %{root_card_fingerprint: fingerprint, root_card_ui_revision: revision},
         %{fingerprint: fingerprint, ui_revision: revision},
         _options
       ),
       do: :ok

  defp maybe_update_root_card(room, card, options) do
    options.api.update_message(
      options.client,
      room.channel_ref,
      room.root_message_ref,
      card.document,
      "#{room.ref}:root"
    )
  end

  defp ensure_audience(%{audience_prepared_at: %DateTime{}} = room, _users, _options),
    do: {:ok, room}

  defp ensure_audience(room, users, options) do
    with :ok <- options.api.invite_users(options.client, room.channel_ref, users) do
      IncidentRooms.mark_prepared(room.id, room.lease_ref, :audience)
    end
  end

  defp ensure_topic(%{topic_prepared_at: %DateTime{}} = room, _options), do: {:ok, room}

  defp ensure_topic(room, options) do
    with :ok <- options.api.set_topic(options.client, room.channel_ref, room.topic) do
      IncidentRooms.mark_prepared(room.id, room.lease_ref, :topic)
    end
  end

  defp ensure_pin(%{root_pinned_at: %DateTime{}} = room, _options), do: {:ok, room}

  defp ensure_pin(room, options) do
    with :ok <- options.api.pin_message(options.client, room.channel_ref, room.root_message_ref) do
      IncidentRooms.mark_prepared(room.id, room.lease_ref, :root_pin)
    end
  end

  defp ensure_handoff(%{handoff_message_ref: message_ref} = room, _options)
       when is_binary(message_ref),
       do: {:ok, room}

  defp ensure_handoff(room, options) do
    delivery_ref = "incident-room:#{room.ref}:handoff"

    result =
      case options.api.find_message(
             options.client,
             room.source_channel_ref,
             room.source_thread_ref,
             delivery_ref
           ) do
        {:ok, message_ref} ->
          {:ok, message_ref}

        :not_found ->
          options.api.post_message(
            options.client,
            room.source_channel_ref,
            room.source_thread_ref,
            %{
              "message" =>
                "Incident room ready: <##{room.channel_ref}>. The investigation and its pinned status card are now in that room."
            },
            delivery_ref
          )

        {:error, _reason} = error ->
          error
      end

    with {:ok, message_ref} <- result do
      IncidentRooms.bind_handoff(room.id, room.lease_ref, message_ref)
    end
  end

  defp handle_error(room, reason, options) do
    if room.status == :requested and
         (permanent?(reason) or room.attempt_count >= options.max_attempts) do
      case IncidentRooms.block(room.id, room.lease_ref, reason) do
        {:ok, blocked} -> {:ok, {:blocked, blocked.ref, reason}}
        {:error, _reason} = error -> error
      end
    else
      retry_seconds = retry_delay(room.attempt_count, options.retry_base_seconds)

      case IncidentRooms.defer(room.id, room.lease_ref, retry_seconds, reason) do
        {:ok, deferred} -> {:ok, {:deferred, deferred.ref}}
        {:error, _reason} = error -> error
      end
    end
  end

  defp handle_card_error(room, reason, options) do
    retry_seconds = retry_delay(room.attempt_count, options.retry_base_seconds)

    case IncidentRooms.defer(room.id, room.lease_ref, retry_seconds, reason) do
      {:ok, deferred} -> {:ok, {:deferred, deferred.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp permanent?(reason),
    do:
      reason in [
        :incident_audience_group_empty,
        :incident_audience_member_invalid,
        :incident_offer_delivery_mismatch,
        :incident_offer_not_delivered,
        :incident_offer_not_found,
        :incident_offer_stale,
        :incident_offer_workspace_mismatch,
        :incident_room_capacity
      ]

  defp retry_delay(attempt_count, base) do
    exponent = max(attempt_count - 1, 0) |> min(8)
    min(base * Integer.pow(2, exponent), 3_600)
  end
end
