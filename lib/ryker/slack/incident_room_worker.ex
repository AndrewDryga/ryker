defmodule Ryker.Slack.IncidentRoomWorker do
  @moduledoc """
  Reconciles one durable Slack incident-room request at a time.

  Every provider operation is idempotent or searched by a deterministic
  receipt before mutation. A room does not become episode authority: it merely
  supplies a usable destination for the linked episode created at settlement.
  """

  use GenServer

  require Logger

  alias Ryker.Observability.Progress
  alias Ryker.Polling

  alias Ryker.Delivery.Dispatcher, as: DeliveryDispatcher
  alias Ryker.Delivery.HostNote
  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Episode}
  alias Ryker.Repo
  alias Ryker.Slack.{IncidentRoomCard, IncidentRooms}
  alias Ryker.Work.{Custody, Turn}

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
           | {:requested | :ready | :deferred | :blocked | :closed | :closing, String.t()}
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
      {:ok, nil} -> close_orphaned_investigation(options)
      {:ok, room} -> refresh_root_card(room, options)
      {:error, _reason} = error -> error
    end
  end

  # An investigation that outlived its deleted room closes the way the room's
  # deletion closes one: a waiting one at once, a running one through its
  # worker's confirmed stop. The room closed already and says why.
  defp close_orphaned_investigation(options) do
    case IncidentRooms.next_orphaned_investigation() do
      nil ->
        request_automatic(options)

      {room, episode} ->
        case close_investigation(room, episode) do
          {:ok, %{status: :settled}} -> {:ok, {:closed, room.ref}}
          {:ok, %{status: :pending}} -> {:ok, {:closing, room.ref}}
          {:error, _reason} = error -> error
        end
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
         {:ok, outcome} <- settle_lifecycle_reconciliation(room, episode, result, options) do
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

  # Slack deletes a channel for good, so an investigation paused for its room
  # would wait forever for a room that cannot come back: it closes instead.
  defp reconcile_episode_destination(%{channel_state: :deleted} = room, episode),
    do: close_investigation(room, episode)

  defp reconcile_episode_destination(%{channel_state: state} = room, episode)
       when state in [:archived, :unavailable] do
    Custody.pause_destination(episode.id, episode.key, destination_pause_ref(room))
  end

  # A person's Close request, made for them because Slack deleted the room. A
  # run still working stops through cancellation custody and the request
  # closes on its worker's answer; one waiting for a reply or an event closes
  # now. The kernel closes no request under a reply it accepted, and a reply
  # owed to the room can never be posted there: it goes to the alert thread
  # the room was opened from, and the request closes after it.
  defp close_investigation(_room, %Episode{state: state}) when state in [:complete, :cancelled],
    do: {:ok, %{status: :settled}}

  defp close_investigation(room, %Episode{state: :working, owner_kind: :turn} = episode) do
    Custody.request_cancel(
      episode.id,
      episode.key,
      episode.owner_ref,
      deletion_ref(room),
      deletion_reason(room)
    )
  end

  defp close_investigation(room, %Episode{state: state, owner_kind: owner_kind} = episode)
       when state in [:waiting_for_input, :waiting_for_event] and owner_kind in [:input, :event] do
    command = %Command.CancelEpisode{
      cancel_ref: deletion_ref(room),
      episode_key: episode.key,
      expected_owner: %{kind: owner_kind, ref: episode.owner_ref},
      occurred_at: Repo.now!(),
      reason: deletion_reason(room)
    }

    case Episodes.apply(command) do
      {:ok, _transition} -> {:ok, %{status: :settled}}
      {:error, _reason} = error -> error
    end
  end

  defp close_investigation(room, %Episode{state: :working, owner_kind: :delivery} = episode) do
    case Custody.redirect_delivery(
           episode.id,
           episode.key,
           "slack:#{room.workspace_ref}:#{room.channel_ref}",
           IncidentRooms.alert_thread(room)
         ) do
      # The reply was posted since the request was read: the next pass closes
      # whatever the request went on to do.
      {:ok, %{status: :settled}} -> {:ok, %{status: :pending}}
      result -> result
    end
  end

  defp close_investigation(room, episode),
    do: Custody.pause_destination(episode.id, episode.key, destination_pause_ref(room))

  defp settle_lifecycle_reconciliation(room, _episode, %{status: :pending}, options) do
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

  # The alert thread the room came from is told before the room closes, so a
  # note Slack cannot take right now is retried, never lost, and never posted
  # twice. A refusal no retry can change does not hold the room open, and
  # neither does a reply the alert thread refused for good: that reply stays
  # owed, for a person to post from the Failures page, and the room says so.
  defp settle_lifecycle_reconciliation(
         %{channel_state: :deleted} = room,
         episode,
         %{status: status} = result,
         options
       )
       when status in [:settled, :refused] do
    refused_reply = if status == :refused, do: result.turn

    case HostNote.deliver(deletion_note(room, episode)) do
      {:ok, note} ->
        close_deleted(room, note, refused_reply)

      {:error, reason} ->
        if DeliveryDispatcher.retryable?(reason),
          do: handle_error(room, {:incident_room_note_failed, reason}, options),
          else: close_deleted(room, {:refused, reason}, refused_reply)
    end
  end

  defp settle_lifecycle_reconciliation(room, _episode, %{status: :settled}, _options) do
    case IncidentRooms.mark_lifecycle_reconciled(
           room.id,
           room.lease_ref,
           room.channel_state
         ) do
      {:ok, reconciled} -> {:ok, {:ready, reconciled.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp close_deleted(room, note, refused_reply) do
    detail = deletion_detail(note) <> reply_detail(refused_reply)

    case IncidentRooms.close_deleted(room.id, room.lease_ref, detail) do
      {:ok, closed} -> {:ok, {:closed, closed.ref}}
      {:error, _reason} = error -> error
    end
  end

  # Fixed words, no model. Slack's channel_deleted event names nobody, so the
  # note names the room rather than who deleted it. It goes to the same thread
  # as a reply the room still owed.
  defp deletion_note(room, episode) do
    alert_thread = IncidentRooms.alert_thread(room)

    %HostNote{
      conversation_ref: alert_thread["conversation_ref"],
      execution_mode: episode.execution_mode,
      message: "The incident room ##{room.channel_name} was deleted. Reply here to pick it up.",
      ref: "incident-room:#{room.ref}:deleted",
      thread_ref: alert_thread["thread_ref"],
      transport: alert_thread["transport"]
    }
  end

  defp deletion_ref(room), do: "#{room.ref}:deleted"

  defp deletion_reason(room),
    do: "Closed because its incident room ##{room.channel_name} was deleted in Slack."

  @deletion_detail "Slack deleted the room's channel, so Ryker closed the room"

  defp deletion_detail({:posted, _receipt}),
    do: @deletion_detail <> " and said so in the alert thread it was opened from."

  defp deletion_detail({:not_posted, :shadow}),
    do: @deletion_detail <> ". It was a shadow room, so nothing was posted."

  defp deletion_detail({:not_posted, _reason}),
    do:
      @deletion_detail <>
        ". Ryker has no way to post in the alert thread, so it said nothing there."

  defp deletion_detail({:refused, reason}),
    do:
      @deletion_detail <>
        ". Its note in the alert thread was refused (#{refusal(reason)}), so it said nothing there."

  defp reply_detail(nil), do: ""

  defp reply_detail(%Turn{} = reply),
    do:
      " The investigation's finished reply could not be posted (#{reply_refusal(reply)}), " <>
        "so it waits on the Failures page."

  # Slack's own word for the refusal when the error text the delivery lane
  # saved carries one, and the saved error code otherwise.
  defp reply_refusal(%Turn{last_error_code: code, last_error_detail: detail}) do
    case Regex.run(~r/\{:slack_api_error, "([a-z_]{1,60})"\}/, detail || "") do
      [_error, slack_code] -> slack_code
      nil -> code || "an error"
    end
  end

  defp refusal({:delivery_reconciliation_failed, reason}), do: refusal(reason)

  defp refusal({:slack_api_error, code}) when is_binary(code) do
    if Regex.match?(~r/\A[a-z_]{1,60}\z/, code), do: code, else: "slack_api_error"
  end

  defp refusal({:slack_http_error, status, _body}) when is_integer(status), do: "HTTP #{status}"

  defp refusal(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  defp refusal(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp refusal(_reason), do: "an error"

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
