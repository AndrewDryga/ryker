defmodule Ryker.Slack.IncidentRoomWorker do
  @moduledoc """
  Reconciles one durable Slack incident-room request at a time.

  Every provider operation is idempotent or searched by a deterministic
  receipt before mutation. A room does not become episode authority: it merely
  supplies a usable destination for the linked episode created at settlement.

  A room, a request (an incident offer delivered, an investigation that
  outlived its room) and a channel's alert policy that change are announced,
  and each wakes the worker at once. Otherwise it sleeps until a retry, a
  health check or a pinned card's check falls due, or for its safety-net
  interval.
  """
  use Ryker.PollingWorker, lane: :slack_incidents, interval: :interval_ms
  alias Ryker.Backoff
  alias Ryker.ConversationRef
  alias Ryker.Delivery
  alias Ryker.Episodes
  alias Ryker.ErrorDetail
  alias Ryker.Observability
  alias Ryker.Options
  alias Ryker.PollingWorker
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelConfigurations, IncidentRoomCard, IncidentRooms}
  alias Ryker.Work
  require Logger

  @default_interval_ms 1_000
  @refused_offers {__MODULE__, :refused_offers}

  @spec start_link(map() | keyword()) :: GenServer.on_start()
  def start_link(options) do
    options = options!(options)
    GenServer.start_link(__MODULE__, options, name: options.name)
  end

  @impl PollingWorker
  def wake_on(_options),
    do: [
      &IncidentRooms.subscribe_rooms/0,
      &Episodes.subscribe_episodes/0,
      &ChannelConfigurations.subscribe_channels/0
    ]

  # A room's card is due by the clock, so an investigation announced as changed
  # waited for the card's next check: one that finished showed as working until
  # then (2026-10-04 review).
  @impl PollingWorker
  def woken({:episode_updated, episode_id}, _options),
    do: IncidentRooms.check_card_soon(episode_id)

  def woken(_message, _options), do: :ok

  @impl PollingWorker
  def poll(options) do
    delay =
      case run_once(options) do
        {:ok, :idle} ->
          PollingWorker.idle_delay(
            &IncidentRooms.next_due_at(
              &1,
              options.health_check_seconds,
              options.root_card_check_seconds
            ),
            Map.get(options, :idle_interval_ms, PollingWorker.idle_interval_ms())
          )

        {:ok, _result} ->
          0

        {:error, reason} ->
          Logger.warning("Slack incident-room worker failed: #{inspect(reason)}")
          options.interval_ms
      end

    _ = Observability.Progress.beat(:slack_incidents)
    delay
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
      {:error, reason} -> {:error, reason}
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
      {:error, reason} -> {:error, reason}
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
      {:error, reason} -> {:error, reason}
    end
  end

  # An investigation that outlived its deleted room closes the way the room's
  # deletion closes one: a waiting one at once, a running one through its
  # worker's confirmed stop. The room closed already and says why.
  defp close_orphaned_investigation(options) do
    case IncidentRooms.fetch_next_orphaned_investigation() do
      {:error, :not_found} ->
        request_automatic(options)

      {:ok, {room, episode}} ->
        case close_investigation(room, episode, deletion(room)) do
          {:ok, %{status: :settled}} -> {:ok, {:closed, room.ref}}
          {:ok, %{status: :pending}} -> {:ok, {:closing, room.ref}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc false
  @spec options!(map() | keyword()) :: map()
  def options!(options) do
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
      :idle_interval_ms,
      :interval_ms,
      :name,
      :root_card_check_seconds,
      :reserve_channel
    ]

    options =
      Options.normalize!(options, required ++ optional, required,
        list: "incident-room worker requires unique options",
        map: "invalid incident-room worker options",
        other: "invalid incident-room worker options"
      )

    prepared =
      options
      |> Map.put_new(:health_check_seconds, 300)
      |> Map.put_new(:interval_ms, @default_interval_ms)
      |> Map.put_new(:name, nil)
      |> Map.put_new(:root_card_check_seconds, 2)

    if valid_options?(prepared) do
      prepared
    else
      raise ArgumentError, "invalid incident-room worker options"
    end
  end

  defp valid_options?(options) do
    automatic_request = Map.get(options, :automatic_request)
    reserve_channel = Map.get(options, :reserve_channel)

    Enum.all?([
      Map.get(options, :lease_seconds) in 5..3_600,
      Map.get(options, :max_attempts) in 1..100,
      Map.get(options, :retry_base_seconds) in 1..3_600,
      Map.get(options, :health_check_seconds) in 1..86_400,
      Map.get(options, :root_card_check_seconds) in 1..86_400,
      Map.get(options, :interval_ms) in 50..3_600_000,
      Map.get(options, :idle_interval_ms, 50) in 50..3_600_000,
      is_nil(automatic_request) or is_function(automatic_request, 1),
      is_nil(reserve_channel) or is_function(reserve_channel, 2),
      is_binary(Map.get(options, :worker_ref)),
      Map.get(options, :worker_ref) != ""
    ])
  end

  # A full open-room limit is nothing to do until a room closes; as a failure
  # it was retried and logged every second. An offer refused a room for itself
  # is logged once and left out while this worker runs: asked for again, it
  # failed every second and hid every newer offer (2026-10-04 review). After a
  # restart it is asked for, and logged, once more.
  defp request_automatic(%{automatic_request: callback}) when is_function(callback, 1) do
    refused = Process.get(@refused_offers, MapSet.new())

    case callback.(MapSet.to_list(refused)) do
      {:ok, nil} ->
        {:ok, :idle}

      {:ok, %{room: room}} ->
        {:ok, {:requested, room.ref}}

      {:error, :incident_room_capacity} ->
        {:ok, :idle}

      {:error, {:automatic_incident_refused, record_ref, reason}} ->
        Logger.warning(
          "Ryker could not open an incident room for #{record_ref} automatically: " <>
            ErrorDetail.detail(reason)
        )

        # The offers this worker has already logged as refused, so each is logged once.
        refused = MapSet.put(refused, record_ref)
        # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
        Process.put(@refused_offers, refused)
        {:ok, {:refused, record_ref}}

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :invalid_automatic_incident_request}
    end
  end

  defp request_automatic(_options), do: {:ok, :idle}

  # A person asked to close the room: that comes before any other step.
  defp execute(%{close_requested_at: %DateTime{}} = room, options),
    do: close_on_request(room, options)

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
    with {:ok, episode} <- room_episode(room),
         {:ok, result} <- reconcile_episode_destination(room, episode),
         {:ok, outcome} <- settle_lifecycle_reconciliation(room, episode, result, options) do
      {:ok, outcome}
    else
      {:error, reason} -> handle_error(room, reason, options)
    end
  end

  defp room_episode(room) do
    with {:error, :not_found} <- Repo.fetch(Episodes.Episode.Query.by_id(room.episode_id)),
         do: {:error, :incident_room_episode_not_found}
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
    Work.Custody.resume_destination(episode.id, episode.key, destination_pause_ref(room))
  end

  # Slack deletes a channel for good, so an investigation paused for its room
  # would wait forever for a room that cannot come back: it closes instead.
  defp reconcile_episode_destination(%{channel_state: :deleted} = room, episode),
    do: close_investigation(room, episode, deletion(room))

  defp reconcile_episode_destination(%{channel_state: state} = room, episode)
       when state in [:archived, :unavailable] do
    Work.Custody.pause_destination(episode.id, episode.key, destination_pause_ref(room))
  end

  # A person's Close request, made for them because they closed the room or
  # because Slack deleted it (`cause` says which, in the request's history). A
  # run still working stops through cancellation custody and the request
  # closes on its worker's answer; one waiting for a reply or an event closes
  # now. The kernel closes no request under a reply it accepted. A reply owed
  # to a room someone is closing is posted there first, while people can read
  # it; one owed to a room Ryker cannot post in goes to the alert thread the
  # room was opened from, and the request closes after it.
  defp close_investigation(_room, %Episodes.Episode{state: state}, _cause)
       when state in [:complete, :cancelled],
       do: {:ok, %{status: :settled}}

  defp close_investigation(
         _room,
         %Episodes.Episode{state: :working, owner_kind: :turn} = episode,
         cause
       ) do
    Work.Custody.request_cancel(
      episode.id,
      episode.key,
      episode.owner_ref,
      cause.ref,
      cause.reason
    )
  end

  defp close_investigation(
         _room,
         %Episodes.Episode{state: state, owner_kind: owner_kind} = episode,
         cause
       )
       when state in [:waiting_for_input, :waiting_for_event] and owner_kind in [:input, :event] do
    command = %Episodes.Command.CancelEpisode{
      cancel_ref: cause.ref,
      episode_key: episode.key,
      expected_owner: %{kind: owner_kind, ref: episode.owner_ref},
      occurred_at: Repo.now!(),
      reason: cause.reason
    }

    case Episodes.apply(command) do
      {:ok, _transition} -> {:ok, %{status: :settled}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_investigation(
         %{channel_state: :active, close_requested_at: %DateTime{}},
         %Episodes.Episode{state: :working, owner_kind: :delivery},
         _cause
       ),
       do: {:ok, %{status: :pending}}

  defp close_investigation(
         room,
         %Episodes.Episode{state: :working, owner_kind: :delivery} = episode,
         _cause
       ) do
    case Work.Custody.redirect_delivery(
           episode.id,
           episode.key,
           ConversationRef.slack(room.workspace_ref, room.channel_ref),
           IncidentRooms.alert_thread(room)
         ) do
      # The reply was posted since the request was read: the next pass closes
      # whatever the request went on to do.
      {:ok, %{status: :settled}} -> {:ok, %{status: :pending}}
      result -> result
    end
  end

  defp close_investigation(room, episode, _cause),
    do: Work.Custody.pause_destination(episode.id, episode.key, destination_pause_ref(room))

  # A person asked to close the room (`IncidentRooms.request_close/2`). Its
  # investigation closes the way a deleted room's does. Then Ryker says so in
  # the room, while it can still post there, and in the alert thread the room
  # came from, and the room closes. A note Slack refuses for good does not
  # hold the room open, and neither does a reply the alert thread refused: it
  # stays owed, for a person to post from the Failures page.
  defp close_on_request(room, options) do
    episode = room.episode_id && Repo.peek(Episodes.Episode.Query.by_id(room.episode_id))

    with {:ok, result} <- close_requested_investigation(room, episode),
         {:ok, outcome} <- settle_close(room, episode, result, options) do
      {:ok, outcome}
    else
      {:error, reason} -> handle_error(room, reason, options)
    end
  end

  defp close_requested_investigation(_room, nil), do: {:ok, %{status: :settled}}

  defp close_requested_investigation(room, episode),
    do: close_investigation(room, episode, closing(room))

  defp settle_close(room, _episode, %{status: :pending}, options) do
    retry_seconds = Backoff.delay(room.attempt_count, options.retry_base_seconds, 3_600, 8)

    case IncidentRooms.defer(room.id, room.lease_ref, retry_seconds, :incident_room_close_pending) do
      {:ok, deferred} -> {:ok, {:deferred, deferred.ref}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle_close(room, episode, %{status: status} = result, _options)
       when status in [:settled, :refused] do
    refused_reply = if status == :refused, do: result.turn
    mode = execution_mode(room, episode)

    with {:ok, in_room} <- note(room_note(room, mode)),
         {:ok, in_thread} <- note(closed_note(room, mode)),
         detail = close_detail(in_room, in_thread) <> reply_detail(refused_reply),
         {:ok, closed} <- IncidentRooms.close_on_request(room.id, room.lease_ref, detail) do
      {:ok, {:closed, closed.ref}}
    end
  end

  # A note Slack refuses for good is not worth a retry; one it could not take
  # right now is.
  defp note(nil), do: {:ok, :not_needed}

  defp note(%Delivery.HostNote{} = note) do
    case Delivery.HostNote.deliver(note) do
      {:ok, outcome} ->
        {:ok, outcome}

      {:error, reason} ->
        if Delivery.Retry.retryable?(reason),
          do: {:error, {:incident_room_note_failed, reason}},
          else: {:ok, {:refused, reason}}
    end
  end

  # A room without its investigation yet is as live as the request it was
  # opened from.
  defp execution_mode(_room, %Episodes.Episode{execution_mode: mode}), do: mode

  defp execution_mode(room, nil) do
    room.source_episode_id
    |> Episodes.Episode.Query.by_id()
    |> Episodes.Episode.Query.select_execution_modes()
    |> Repo.one() || :live
  end

  # Fixed words, no model, in the room while Ryker can still post there.
  defp room_note(%{status: :ready, channel_state: :active} = room, mode) do
    %Delivery.HostNote{
      conversation_ref: ConversationRef.slack(room.workspace_ref, room.channel_ref),
      execution_mode: mode,
      message:
        "This incident room is closed. Ryker won't answer here anymore. " <>
          "Archive the channel in Slack when you no longer need it.",
      ref: "incident-room:#{room.ref}:closed-room",
      thread_ref: nil,
      transport: "slack"
    }
  end

  defp room_note(_room, _mode), do: nil

  # And in the alert thread the room came from, where someone asked for it.
  defp closed_note(room, mode) do
    alert_thread = IncidentRooms.alert_thread(room)

    %Delivery.HostNote{
      conversation_ref: alert_thread["conversation_ref"],
      execution_mode: mode,
      message: closed_message(room),
      ref: "incident-room:#{room.ref}:closed",
      thread_ref: alert_thread["thread_ref"],
      transport: alert_thread["transport"]
    }
  end

  defp closed_message(%{channel_ref: nil}),
    do: "The incident room for this alert was closed before Ryker set it up."

  defp closed_message(room), do: "The incident room ##{room.channel_name} is closed."

  @close_detail "Closed on request from Ryker's console."

  defp close_detail(in_room, in_thread) do
    places =
      for {place, {:posted, _receipt}} <- [
            {"the room", in_room},
            {"the alert thread it was opened from", in_thread}
          ],
          do: place

    cond do
      {:not_posted, :shadow} in [in_room, in_thread] ->
        @close_detail <> " It was a shadow room, so nothing was posted."

      places == [] ->
        @close_detail <> " Ryker could not post in Slack about it."

      true ->
        @close_detail <> " Ryker said so in " <> Enum.join(places, " and in ") <> "."
    end
  end

  defp settle_lifecycle_reconciliation(room, _episode, %{status: :pending}, options) do
    retry_seconds = Backoff.delay(room.attempt_count, options.retry_base_seconds, 3_600, 8)

    case IncidentRooms.defer(
           room.id,
           room.lease_ref,
           retry_seconds,
           :incident_room_lifecycle_pending
         ) do
      {:ok, deferred} -> {:ok, {:deferred, deferred.ref}}
      {:error, reason} -> {:error, reason}
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

    case Delivery.HostNote.deliver(deletion_note(room, episode)) do
      {:ok, note} ->
        close_deleted(room, note, refused_reply)

      {:error, reason} ->
        if Delivery.Retry.retryable?(reason),
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
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_deleted(room, note, refused_reply) do
    detail = deletion_detail(note) <> reply_detail(refused_reply)

    case IncidentRooms.close_deleted(room.id, room.lease_ref, detail) do
      {:ok, closed} -> {:ok, {:closed, closed.ref}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Fixed words, no model. Slack's channel_deleted event names nobody, so the
  # note names the room rather than who deleted it. It goes to the same thread
  # as a reply the room still owed.
  defp deletion_note(room, episode) do
    alert_thread = IncidentRooms.alert_thread(room)

    %Delivery.HostNote{
      conversation_ref: alert_thread["conversation_ref"],
      execution_mode: episode.execution_mode,
      message: "The incident room ##{room.channel_name} was deleted. Reply here to pick it up.",
      ref: "incident-room:#{room.ref}:deleted",
      thread_ref: alert_thread["thread_ref"],
      transport: alert_thread["transport"]
    }
  end

  defp deletion(room),
    do: %{
      ref: "#{room.ref}:deleted",
      reason: "Closed because its incident room ##{room.channel_name} was deleted in Slack."
    }

  defp closing(room),
    do: %{
      ref: "#{room.ref}:closed",
      reason: "Closed with its incident room ##{room.channel_name}."
    }

  @deletion_detail "Slack deleted the room's channel, so Ryker closed the room"

  defp deletion_detail({:posted, _receipt}),
    do: @deletion_detail <> " and said so in the alert thread it was opened from."

  defp deletion_detail({:not_posted, :shadow}),
    do: @deletion_detail <> ". It was a shadow room, so nothing was posted."

  defp deletion_detail({:not_posted, _reason}) do
    @deletion_detail <>
      ". Ryker has no way to post in the alert thread, so it said nothing there."
  end

  defp deletion_detail({:refused, reason}) do
    @deletion_detail <>
      ". Its note in the alert thread was refused (#{refusal(reason)}), so it said nothing there."
  end

  defp reply_detail(nil), do: ""

  defp reply_detail(%Work.Turn{} = reply) do
    " The investigation's finished reply could not be posted (#{reply_refusal(reply)}), " <>
      "so it waits on the Failures page."
  end

  # Slack's own word for the refusal when the error text the delivery lane
  # saved carries one, and the saved error code otherwise.
  defp reply_refusal(%Work.Turn{last_error_code: code, last_error_detail: detail}) do
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

  # Who the room invites: its people and its groups' members, less Ryker. A
  # person who cannot join (deactivated, a guest, from another workspace) and
  # a group with nobody in it are left out, with a line in the log: one such
  # name on a channel's list blocked every room from that channel. The
  # audience is read until its invitations go out, and not again.
  defp audience(%{audience_prepared_at: %DateTime{}}, _options), do: {:ok, []}

  defp audience(room, options) do
    with {:ok, group_users} <- expand_groups(room, options) do
      (room.invite_user_refs ++ group_users)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reject(&(&1 == room.bot_user_ref))
      |> joinable(room, options)
    end
  end

  defp expand_groups(room, options) do
    Enum.reduce_while(room.invite_user_group_refs, {:ok, []}, fn group_ref, {:ok, users} ->
      case options.directory.user_group_members(options.client, group_ref, room.workspace_ref) do
        {:ok, [_member | _more] = members} ->
          {:cont, {:ok, users ++ members}}

        {:ok, _empty} ->
          Logger.warning(
            "incident room #{room.ref} left out user group #{group_ref}: it is empty"
          )

          {:cont, {:ok, users}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp joinable(users, room, options) do
    Enum.reduce_while(users, {:ok, []}, fn user_ref, {:ok, joinable} ->
      case options.directory.user_allowed(options.client, user_ref, room.workspace_ref) do
        {:ok, true} ->
          {:cont, {:ok, joinable ++ [user_ref]}}

        {:ok, false} ->
          Logger.warning("incident room #{room.ref} left out #{user_ref}: they cannot join it")
          {:cont, {:ok, joinable}}

        {:error, reason} ->
          {:halt, {:error, reason}}
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

      {:error, reason} ->
        {:error, reason}
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
            handoff_message(room),
            delivery_ref
          )

        {:error, reason} ->
          {:error, reason}
      end

    with {:ok, message_ref} <- result do
      IncidentRooms.bind_handoff(room.id, room.lease_ref, message_ref)
    end
  end

  # The room's channel as a link: the message's text is escaped, so the link
  # is a typed one this message alone may name. Written into the text, it
  # showed as "<#C…>" (2026-10-04 review).
  defp handoff_message(room) do
    conversation = ConversationRef.slack(room.workspace_ref, room.channel_ref)

    %{
      "message" =>
        "Incident room ready: [##{room.channel_name}](slack-channel:#{conversation}). The investigation and its pinned status card are now in that room.",
      "slack_mentions" => %{
        "broadcasts" => [],
        "channels" => [conversation],
        "user_groups" => [],
        "users" => [],
        "workspace_ref" => room.workspace_ref
      }
    }
  end

  defp handle_error(room, reason, options) do
    if room.status == :requested and
         (permanent?(reason) or room.attempt_count >= options.max_attempts) do
      case IncidentRooms.block(room.id, room.lease_ref, reason) do
        {:ok, blocked} -> {:ok, {:blocked, blocked.ref, reason}}
        {:error, reason} -> {:error, reason}
      end
    else
      retry_seconds = Backoff.delay(room.attempt_count, options.retry_base_seconds, 3_600, 8)

      case IncidentRooms.defer(room.id, room.lease_ref, retry_seconds, reason) do
        {:ok, deferred} -> {:ok, {:deferred, deferred.ref}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp handle_card_error(room, reason, options) do
    retry_seconds = Backoff.delay(room.attempt_count, options.retry_base_seconds, 3_600, 8)

    case IncidentRooms.defer(room.id, room.lease_ref, retry_seconds, reason) do
      {:ok, deferred} -> {:ok, {:deferred, deferred.ref}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp permanent?(reason) do
    reason in [
      :incident_offer_delivery_mismatch,
      :incident_offer_not_delivered,
      :incident_offer_not_found,
      :incident_offer_stale,
      :incident_offer_workspace_mismatch,
      :incident_room_capacity
    ]
  end
end
