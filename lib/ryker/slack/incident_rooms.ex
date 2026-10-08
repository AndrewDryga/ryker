defmodule Ryker.Slack.IncidentRooms do
  @moduledoc """
  Durable custody for optional Slack incident-room artifacts.

  A model can only create an inert incident offer. An authenticated operator or
  trusted automatic-alert policy records one request here. Slack provisioning
  is reconciled step by step; only a usable room can create and pin the linked
  episode that owns the actual investigation.

  A room requested, set up, blocked, rearmed, observed or closed is announced
  after the outermost commit (`subscribe_rooms/0`, `subscribe_room/1`), on
  the topics of the request it came from and the one investigating it too.
  """
  alias Ryker.AdvisoryLock
  alias Ryker.CanonicalJSON
  alias Ryker.ConversationRef
  alias Ryker.Crypto
  alias Ryker.Episodes
  alias Ryker.ErrorDetail
  alias Ryker.Records
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelConfiguration, IncidentRoom}
  alias Ryker.Slack.IncidentRoomLifecycleEvent
  alias Ryker.Slack.MembershipTransition
  alias Ryker.Text
  alias Ryker.UTCDateTime
  alias Ryker.Work

  @request_fields [
    :actor_ref,
    :bot_user_ref,
    :channel_prefix,
    :confirmation_ref,
    :invite_user_refs,
    :maximum_open_rooms,
    :occurred_at,
    :policy,
    :private,
    :record_ref,
    :target,
    :workspace_ref
  ]
  @investigation_fields [
    :actor_ref,
    :confirmation_ref,
    :occurred_at,
    :policy,
    :record_ref,
    :target,
    :workspace_ref
  ]
  @policy_fields [:digest, :name]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]
  @maximum_error_detail_bytes 4_096

  @type request_result :: %{room: IncidentRoom.t(), status: :requested | :duplicate}

  @spec request(map() | keyword()) :: {:ok, request_result()} | {:error, term()}
  def request(attributes) do
    with {:ok, attributes} <- exact_map(attributes, @request_fields),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- slack_id(attributes.bot_user_ref, :bot_user_ref),
         :ok <- channel_prefix(attributes.channel_prefix),
         :ok <- reference(attributes.confirmation_ref, :confirmation_ref),
         {:ok, invite_users} <- slack_ids(attributes.invite_user_refs, :invite_user_refs),
         :ok <- maximum(attributes.maximum_open_rooms),
         {:ok, occurred_at} <- utc_datetime(attributes.occurred_at),
         {:ok, policy} <- policy(attributes.policy),
         true <- is_boolean(attributes.private),
         :ok <- reference(attributes.record_ref, :record_ref),
         # The target is read against the workspace, so the workspace comes first.
         :ok <- slack_id(attributes.workspace_ref, :workspace_ref),
         {:ok, target} <- target(attributes.target, attributes.workspace_ref) do
      prepared = %{
        attributes
        | invite_user_refs: invite_users,
          occurred_at: occurred_at,
          policy: policy,
          target: target
      }

      Repo.transaction(fn -> request_locked(prepared) end)
    else
      false -> {:error, {:invalid_incident_room_request, :private}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Starts the in-place path of an incident offer: durable read-only work in the
  offer's own thread, under the incident policy, with no room and no invitations.

  The offer owns both paths. The record lock serializes this with a room
  request, so concurrent opposite clicks start exactly one of them.
  """
  @spec investigate(map() | keyword()) ::
          {:ok, Records.TaskOffers.confirmation()} | {:error, term()}
  def investigate(attributes) do
    with {:ok, attributes} <- exact_map(attributes, @investigation_fields, :investigation),
         :ok <- reference(attributes.record_ref, :record_ref),
         :ok <- slack_id(attributes.workspace_ref, :workspace_ref) do
      Repo.transaction(fn -> investigate_locked(attributes) end)
    end
  end

  @doc """
  Persists one authenticated Slack lifecycle event for a managed incident room.

  Unknown channels are reported without creating setup or incident state. Event
  identity is immutable, and older events remain audit history without rolling
  the room backwards.
  """
  @spec observe_lifecycle(MembershipTransition.t()) ::
          {:ok, %{room: IncidentRoom.t() | nil, status: atom()}} | {:error, term()}
  def observe_lifecycle(%MembershipTransition{kind: kind} = transition)
      when kind in [:joined, :left, :archived, :unarchived, :deleted] do
    Repo.transaction(fn -> observe_lifecycle_locked(transition) end)
  end

  def observe_lifecycle(_transition),
    do: {:error, {:invalid_incident_room_lifecycle, :transition}}

  @spec managed_channel?(String.t(), String.t()) :: boolean()
  def managed_channel?(workspace_ref, channel_ref) do
    Repo.exists?(IncidentRoom.Query.by_channel(workspace_ref, channel_ref))
  end

  @spec channel_profile(String.t(), String.t()) :: {:ok, map()} | :not_found
  def channel_profile(workspace_ref, channel_ref) do
    profile =
      workspace_ref
      |> IncidentRoom.Query.by_channel(channel_ref)
      |> IncidentRoom.Query.select_profile()

    case Repo.one(profile) do
      nil -> :not_found
      profile -> {:ok, profile}
    end
  end

  @spec delivery_allowed(String.t(), String.t()) :: :ok | {:error, term()}
  def delivery_allowed(workspace_ref, channel_ref) do
    case channel_profile(workspace_ref, channel_ref) do
      :not_found -> :ok
      {:ok, %{channel_state: :active, status: :ready}} -> :ok
      {:ok, %{channel_state: state}} -> {:error, {:slack_incident_room_inactive, state}}
    end
  end

  @doc """
  The alert thread a room was opened from, as a delivery target: where the
  note about its deletion goes, and where a reply owed to the room goes once
  Slack has deleted it.
  """
  @spec alert_thread(IncidentRoom.t()) :: map()
  def alert_thread(%IncidentRoom{} = room) do
    %{
      "conversation_ref" => ConversationRef.slack(room.workspace_ref, room.source_channel_ref),
      "thread_ref" => room.source_thread_ref || room.source_message_ref,
      "transport" => "slack"
    }
  end

  @doc """
  Asks for a room for the oldest automatic candidate (`automatic_candidate/2`)
  not among the offers `refused` names, with the room `settings` a person's
  request carries too. A refusal other than a full room limit names its offer,
  so the caller can leave it out after: asked for again, it failed every second
  and hid every newer offer (2026-10-04 review).
  """
  @spec request_automatic(String.t(), map(), [String.t()]) ::
          {:ok, request_result() | nil}
          | {:error, :incident_room_capacity | {:automatic_incident_refused, String.t(), term()}}
          | {:error, term()}
  def request_automatic(workspace_ref, settings, refused) do
    case automatic_candidate(workspace_ref, refused) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, candidate} ->
        attributes = Map.merge(candidate, settings)

        case request(attributes) do
          {:error, :incident_room_capacity} ->
            {:error, :incident_room_capacity}

          {:error, reason} ->
            {:error, {:automatic_incident_refused, candidate.record_ref, reason}}

          requested ->
            requested
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Finds the oldest delivered incident offer that a saved automatic-alert policy
  may open without an operator button press.

  The model's offer is still inert by itself. Automatic authority exists only
  when every current input in the frozen Work submission is an authenticated
  Slack app event and the exact source channel saved `automatic` policy.
  """
  @spec automatic_candidate(String.t(), [String.t()]) :: {:ok, map() | nil} | {:error, term()}
  def automatic_candidate(workspace_ref, refused \\ []) do
    with :ok <- slack_id(workspace_ref, :workspace_ref) do
      candidates = automatic_candidates(workspace_ref, refused)

      {:ok, Enum.find_value(candidates, &automatic_request(&1, workspace_ref))}
    end
  end

  defp automatic_candidates(workspace_ref, refused),
    do: Repo.all(IncidentRoom.Query.automatic_candidates(workspace_ref, refused))

  @doc """
  The earliest moment after `since` at which a room has work by the clock
  alone: a request or lifecycle change retried after a backoff, a health
  check due `health_check_seconds` after the last, a pinned card due its
  check `root_card_check_seconds` after the last, or an unrenewed lease
  running out. Nil when no room waits on the clock.
  """
  @spec next_due_at(DateTime.t(), pos_integer(), pos_integer()) :: DateTime.t() | nil
  def next_due_at(%DateTime{} = since, health_check_seconds, root_card_check_seconds) do
    since
    |> IncidentRoom.Query.select_next_due_after(health_check_seconds, root_card_check_seconds)
    |> Repo.one()
    |> UTCDateTime.earliest()
  end

  @spec claim_next(String.t(), pos_integer()) ::
          {:ok, IncidentRoom.t() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- lease_seconds(lease_seconds) do
      Repo.transaction(fn -> claim_next_locked(worker_ref, lease_seconds) end)
    end
  end

  @spec claim_health_check(String.t(), pos_integer(), pos_integer()) ::
          {:ok, IncidentRoom.t() | nil} | {:error, term()}
  def claim_health_check(worker_ref, lease_seconds, check_interval_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- lease_seconds(lease_seconds),
         :ok <- check_interval_seconds(check_interval_seconds) do
      Repo.transaction(fn ->
        claim_health_check_locked(worker_ref, lease_seconds, check_interval_seconds)
      end)
    end
  end

  @spec bind_channel(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, IncidentRoom.t()} | {:error, term()}
  def bind_channel(room_id, lease_ref, channel_ref) do
    mutate_claim(room_id, lease_ref, fn room, now ->
      cond do
        room.channel_ref == channel_ref ->
          room

        is_nil(room.channel_ref) ->
          update!(
            room,
            %{
              channel_ref: channel_ref,
              channel_state: :active,
              channel_state_changed_at: now,
              reconciled_channel_state: :pending
            },
            now
          )

        true ->
          Repo.rollback(:incident_room_channel_conflict)
      end
    end)
  end

  @spec bind_root(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, IncidentRoom.t()} | {:error, term()}
  def bind_root(room_id, lease_ref, message_ref, fingerprint, ui_revision) do
    with :ok <- reference(message_ref, :message_ref),
         :ok <- sha256(fingerprint, :root_card_fingerprint),
         :ok <- positive(ui_revision, :root_card_ui_revision) do
      mutate_claim(room_id, lease_ref, fn room, now ->
        bind_root_locked(room, message_ref, fingerprint, ui_revision, now)
      end)
    end
  end

  defp bind_root_locked(room, message_ref, fingerprint, ui_revision, now) do
    if room.root_message_ref in [nil, message_ref] do
      update!(
        room,
        %{
          root_card_checked_at: now,
          root_card_fingerprint: fingerprint,
          root_card_ui_revision: ui_revision,
          root_message_ref: message_ref
        },
        now
      )
    else
      Repo.rollback(:incident_room_root_conflict)
    end
  end

  @doc """
  Makes the pinned card of the ready room investigating `episode_id` due at the
  next claim: its investigation was announced as changed. Unannounced itself,
  as no page shows when a card was last checked.
  """
  @spec check_card_soon(Ecto.UUID.t()) :: :ok
  def check_card_soon(episode_id) do
    Repo.update_all(IncidentRoom.Query.card_checked_for(episode_id),
      set: [root_card_checked_at: nil]
    )

    :ok
  end

  @spec claim_root_card(String.t(), pos_integer(), pos_integer()) ::
          {:ok, IncidentRoom.t() | nil} | {:error, term()}
  def claim_root_card(worker_ref, lease_seconds, check_interval_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- lease_seconds(lease_seconds),
         :ok <- check_interval_seconds(check_interval_seconds) do
      Repo.transaction(fn ->
        claim_root_card_locked(worker_ref, lease_seconds, check_interval_seconds)
      end)
    end
  end

  @spec mark_root_card(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          pos_integer()
        ) :: {:ok, IncidentRoom.t()} | {:error, term()}
  def mark_root_card(room_id, lease_ref, fingerprint, ui_revision) do
    with :ok <- sha256(fingerprint, :root_card_fingerprint),
         :ok <- positive(ui_revision, :root_card_ui_revision) do
      mutate_claim(room_id, lease_ref, fn room, now ->
        update!(
          room,
          %{
            attempt_count: 0,
            last_error_code: nil,
            last_error_detail: nil,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: nil,
            root_card_checked_at: now,
            root_card_fingerprint: fingerprint,
            root_card_ui_revision: ui_revision
          },
          now,
          root_card_announcement(room, fingerprint, ui_revision)
        )
      end)
    end
  end

  @spec bind_handoff(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, IncidentRoom.t()} | {:error, term()}
  def bind_handoff(room_id, lease_ref, message_ref) do
    mutate_claim(room_id, lease_ref, fn room, now ->
      cond do
        room.handoff_message_ref == message_ref ->
          room

        is_nil(room.handoff_message_ref) ->
          update!(room, %{handoff_message_ref: message_ref}, now)

        true ->
          Repo.rollback(:incident_room_handoff_conflict)
      end
    end)
  end

  @spec mark_prepared(Ecto.UUID.t(), Ecto.UUID.t(), :audience | :topic | :root_pin) ::
          {:ok, IncidentRoom.t()} | {:error, term()}
  def mark_prepared(room_id, lease_ref, kind) when kind in [:audience, :topic, :root_pin] do
    field =
      case kind do
        :audience -> :audience_prepared_at
        :topic -> :topic_prepared_at
        :root_pin -> :root_pinned_at
      end

    mutate_claim(room_id, lease_ref, fn room, now ->
      if Map.fetch!(room, field), do: room, else: update!(room, %{field => now}, now)
    end)
  end

  @spec renew(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, IncidentRoom.t()} | {:error, term()}
  def renew(room_id, lease_ref, lease_seconds) do
    with :ok <- lease_seconds(lease_seconds) do
      mutate_claim(room_id, lease_ref, fn room, now ->
        update!(room, %{lease_expires_at: DateTime.add(now, lease_seconds, :second)}, now)
      end)
    end
  end

  @spec defer(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), term()) ::
          {:ok, IncidentRoom.t()} | {:error, term()}
  def defer(room_id, lease_ref, retry_seconds, reason)
      when is_integer(retry_seconds) and retry_seconds > 0 do
    mutate_claim(room_id, lease_ref, fn room, now ->
      {code, detail} = describe_error(reason)

      update!(
        room,
        %{
          last_error_code: code,
          last_error_detail: detail,
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: DateTime.add(now, retry_seconds, :second)
        },
        now
      )
    end)
  end

  @spec block(Ecto.UUID.t(), Ecto.UUID.t(), term()) ::
          {:ok, IncidentRoom.t()} | {:error, term()}
  def block(room_id, lease_ref, reason) do
    mutate_claim(room_id, lease_ref, fn room, now ->
      {code, detail} = describe_error(reason)

      update!(
        room,
        %{
          last_error_code: code,
          last_error_detail: detail,
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: nil,
          status: :blocked
        },
        now
      )
    end)
  end

  @doc """
  Rearms one operator-inspected blocked incident-room reconciliation.

  Already-created Slack resources and receipts remain immutable. A room that
  already owns its linked episode resumes lifecycle reconciliation as `ready`;
  an unfinished room resumes provisioning as `requested`.
  """
  @spec rearm(String.t()) :: {:ok, IncidentRoom.t()} | {:error, term()}
  def rearm(room_ref) do
    with :ok <- reference(room_ref, :room_ref) do
      Repo.transaction(fn -> rearm_locked(room_ref) end)
    end
  end

  @doc """
  Asks to close a room on a person's behalf. The room worker carries it out:
  it closes the room's investigation, says so in the room and in the alert
  thread the room came from, then closes the room (`close_on_request/3`).
  The channel stays in Slack, and Ryker no longer answers there.

  A room whose setup stopped goes back to its worker, as a retry would, so
  the worker can close it. Asking again while a close is pending answers with
  the room as it is; a closed room refuses.
  """
  @spec request_close(String.t(), String.t()) :: {:ok, IncidentRoom.t()} | {:error, term()}
  def request_close(room_ref, actor_ref) do
    with :ok <- reference(room_ref, :room_ref),
         :ok <- bounded_text(actor_ref, 256, :actor_ref) do
      Repo.transaction(fn -> request_close_locked(room_ref, actor_ref) end)
    end
  end

  defp request_close_locked(room_ref, actor_ref) do
    case Repo.one(locked_room(room_ref)) do
      nil ->
        Repo.rollback(:incident_room_not_found)

      %IncidentRoom{status: :closed} ->
        Repo.rollback(:incident_room_closed)

      # Pending, unless closing it stopped too and it waits for a person again.
      %IncidentRoom{status: status, close_requested_at: %DateTime{}} = room
      when status != :blocked ->
        room

      %IncidentRoom{} = room ->
        now = Repo.now!()
        update!(room, close_request_attributes(room, actor_ref, now), now)
    end
  end

  defp close_request_attributes(%IncidentRoom{status: :blocked} = room, actor_ref, now) do
    %{
      attempt_count: 0,
      close_requested_at: now,
      close_requested_by: actor_ref,
      last_error_code: nil,
      last_error_detail: nil,
      next_attempt_at: nil,
      status: if(room.episode_id, do: :ready, else: :requested)
    }
  end

  defp close_request_attributes(_room, actor_ref, now),
    do: %{close_requested_at: now, close_requested_by: actor_ref, next_attempt_at: nil}

  @spec mark_lifecycle_reconciled(Ecto.UUID.t(), Ecto.UUID.t(), atom()) ::
          {:ok, IncidentRoom.t()} | {:error, term()}
  def mark_lifecycle_reconciled(room_id, lease_ref, expected_state)
      when expected_state in [:active, :archived, :unavailable] do
    mutate_claim(room_id, lease_ref, fn room, now ->
      with :ok <- current_lifecycle(room, expected_state) do
        update!(room, reconciled_attributes(expected_state), now)
      end
    end)
  end

  @doc """
  Closes a ready room whose channel Slack deleted, once the worker has closed
  its investigation, or found the reply it still owes refused in the alert
  thread, and told that thread the room came from, or found it cannot.
  `detail` records which, for whoever opens the room later.
  """
  @spec close_deleted(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, IncidentRoom.t()} | {:error, term()}
  def close_deleted(room_id, lease_ref, detail) do
    with :ok <- bounded_text(detail, @maximum_error_detail_bytes, :detail) do
      mutate_claim(room_id, lease_ref, &close_deleted_locked(&1, &2, detail))
    end
  end

  @doc """
  Closes a room a person asked to close (`request_close/2`), once the worker
  has closed its investigation and said so in the room and the alert thread,
  or found it cannot. `detail` records which, for whoever opens the room
  later.
  """
  @spec close_on_request(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, IncidentRoom.t()} | {:error, term()}
  def close_on_request(room_id, lease_ref, detail) do
    with :ok <- bounded_text(detail, @maximum_error_detail_bytes, :detail) do
      mutate_claim(room_id, lease_ref, &close_requested_locked(&1, &2, detail))
    end
  end

  defp close_requested_locked(%IncidentRoom{close_requested_at: nil}, _now, _detail),
    do: Repo.rollback(:incident_room_close_not_requested)

  defp close_requested_locked(room, now, detail) do
    attributes =
      room.channel_state
      |> reconciled_attributes()
      |> Map.merge(%{
        last_error_code: "incident_room_closed",
        last_error_detail: detail,
        status: :closed
      })

    update!(room, attributes, now)
  end

  @doc """
  The oldest investigation still open whose room closed because Slack deleted
  its channel, with that room.

  A room closes while a reply it owed stays refused in the alert thread. Once
  a person posts that reply from the Failures page, the investigation goes on
  to wait for an answer, or to run again for messages queued behind the
  reply, in a room that is gone; nothing else looks at a closed room again.
  One still owing a reply waits for it to settle, and one already being
  stopped is left to its worker's answer, so a pass never repeats itself.
  """
  @spec fetch_next_orphaned_investigation() ::
          {:ok, {IncidentRoom.t(), Episodes.Episode.t()}} | {:error, :not_found}
  def fetch_next_orphaned_investigation,
    do: Repo.fetch(IncidentRoom.Query.next_orphaned_investigation())

  defp close_deleted_locked(room, now, detail) do
    with :ok <- current_lifecycle(room, :deleted) do
      attributes =
        :deleted
        |> reconciled_attributes()
        |> Map.merge(channel_deleted_attributes())
        |> Map.put(:last_error_detail, detail)

      update!(room, attributes, now)
    end
  end

  defp current_lifecycle(%IncidentRoom{status: :ready, channel_state: state}, state), do: :ok

  defp current_lifecycle(%IncidentRoom{status: :ready}, _state),
    do: Repo.rollback(:incident_room_lifecycle_stale)

  defp current_lifecycle(%IncidentRoom{}, _state), do: Repo.rollback(:incident_room_not_ready)

  defp reconciled_attributes(expected_state) do
    %{
      last_error_code: nil,
      last_error_detail: nil,
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      next_attempt_at: nil,
      reconciled_channel_state: expected_state
    }
  end

  @spec record_channel_observation(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          :active | :archived | :unavailable
        ) :: {:ok, map()} | {:error, term()}
  def record_channel_observation(room_id, lease_ref, state)
      when state in [:active, :archived, :unavailable] do
    mutate_claim(room_id, lease_ref, fn room, now ->
      cond do
        room.status != :ready ->
          Repo.rollback(:incident_room_not_ready)

        room.channel_state == :deleted ->
          room = release_health_check(room, now)
          %{room: room, status: :unchanged}

        room.channel_state == state ->
          room = release_health_check(room, now)
          %{room: room, status: :unchanged}

        true ->
          event_ref = observation_ref(room, state, now)
          insert_observation_event!(room, state, event_ref, now)

          room =
            update!(
              room,
              %{
                channel_checked_at: now,
                channel_state: state,
                channel_state_changed_at: now,
                channel_state_event_ref: event_ref,
                next_attempt_at: nil
              },
              now
            )

          %{room: room, status: :changed}
      end
    end)
  end

  @spec finalize(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, IncidentRoom.t()} | {:error, term()}
  def finalize(room_id, lease_ref) do
    Repo.transaction(fn -> finalize_locked(room_id, lease_ref) end)
  end

  defp observe_lifecycle_locked(transition) do
    lock_workspace!(transition.workspace_ref)

    room =
      transition.workspace_ref
      |> IncidentRoom.Query.by_channel(transition.channel_ref)
      |> IncidentRoom.Query.lock_for_update()
      |> Repo.one()

    case room do
      nil ->
        %{room: nil, status: :not_incident_room}

      %IncidentRoom{} = room ->
        persist_lifecycle_event(room, transition)
    end
  end

  defp persist_lifecycle_event(room, transition) do
    fingerprint =
      CanonicalJSON.digest(%{
        "actor_ref" => transition.actor_ref,
        "channel_ref" => transition.channel_ref,
        "event_ref" => transition.event_ref,
        "kind" => Atom.to_string(transition.kind),
        "occurred_at" => DateTime.to_iso8601(transition.occurred_at),
        "workspace_ref" => transition.workspace_ref
      })

    stored =
      transition.workspace_ref
      |> IncidentRoomLifecycleEvent.Query.by_event(transition.event_ref)
      |> IncidentRoomLifecycleEvent.Query.lock_for_update()

    case Repo.one(stored) do
      %IncidentRoomLifecycleEvent{event_fingerprint: ^fingerprint} ->
        %{room: room, status: :duplicate}

      %IncidentRoomLifecycleEvent{} ->
        Repo.rollback(:incident_room_lifecycle_event_conflict)

      nil ->
        insert_lifecycle_event!(room, transition, fingerprint)
        apply_lifecycle_event(room, transition)
    end
  end

  defp insert_lifecycle_event!(room, transition, fingerprint) do
    %{
      channel_ref: transition.channel_ref,
      event_fingerprint: fingerprint,
      event_ref: transition.event_ref,
      id: Repo.generate_id(),
      kind: transition.kind,
      occurred_at: transition.occurred_at,
      room_id: room.id,
      workspace_ref: transition.workspace_ref
    }
    |> IncidentRoomLifecycleEvent.Changeset.insert()
    |> Repo.insert!()
    |> tap(fn _event -> broadcast_room_updated(room) end)
  end

  defp apply_lifecycle_event(%IncidentRoom{channel_state: :deleted} = room, _transition),
    do: %{room: room, status: :stale}

  defp apply_lifecycle_event(room, transition) do
    if newer_lifecycle?(room, transition) do
      state = lifecycle_state(transition.kind)

      attributes = %{
        channel_state: state,
        channel_state_changed_at: transition.occurred_at,
        channel_state_event_ref: transition.event_ref,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil
      }

      attributes = deleted_attributes(room, state, attributes)
      room = update!(room, attributes, Repo.now!())
      %{room: room, status: :applied}
    else
      %{room: room, status: :stale}
    end
  end

  # A room without its investigation yet has nothing to close, so it closes on
  # the event: its channel deleted, archived or left while Ryker set it up.
  # Deleted, it used to be blocked for good; archived or left, it was never
  # taken up again. Either way it held a place in the open-room limit
  # forever. A room that owns an investigation closes once the worker has
  # closed that and told the alert thread the room came from
  # (`close_deleted/3`); archived or left, it is paused until its channel
  # comes back.
  defp deleted_attributes(%IncidentRoom{episode_id: nil}, state, attributes)
       when state in [:deleted, :archived, :unavailable],
       do: Map.merge(attributes, channel_gone_attributes(state))

  defp deleted_attributes(_room, _state, attributes), do: attributes

  # Slack deletes a channel for good, so a room whose channel is gone can never
  # be set up or resumed. Closing it releases its place in the open-room limit;
  # its lifecycle events and the investigation's history stay.
  defp channel_deleted_attributes, do: channel_gone_attributes(:deleted)

  defp channel_gone_attributes(:deleted) do
    %{
      last_error_code: "incident_room_deleted",
      last_error_detail: "Slack deleted the room's channel, so Ryker closed the room.",
      reconciled_channel_state: :deleted,
      status: :closed
    }
  end

  defp channel_gone_attributes(:archived) do
    %{
      last_error_code: "incident_room_archived",
      last_error_detail:
        "Someone archived the room's channel before Ryker finished setting it up, " <>
          "so Ryker closed the room.",
      reconciled_channel_state: :archived,
      status: :closed
    }
  end

  defp channel_gone_attributes(:unavailable) do
    %{
      last_error_code: "incident_room_left",
      last_error_detail:
        "Ryker was removed from the room's channel before it finished setting it up, " <>
          "so Ryker closed the room.",
      reconciled_channel_state: :unavailable,
      status: :closed
    }
  end

  defp lifecycle_state(:joined), do: :active
  defp lifecycle_state(:unarchived), do: :active
  defp lifecycle_state(:left), do: :unavailable
  defp lifecycle_state(:archived), do: :archived
  defp lifecycle_state(:deleted), do: :deleted

  defp newer_lifecycle?(%IncidentRoom{channel_state_changed_at: nil}, _transition), do: true

  defp newer_lifecycle?(room, transition) do
    case DateTime.compare(transition.occurred_at, room.channel_state_changed_at) do
      :gt ->
        true

      :lt ->
        false

      :eq ->
        is_nil(room.channel_state_event_ref) or
          transition.event_ref > room.channel_state_event_ref
    end
  end

  defp investigate_locked(attributes) do
    lock_workspace!(attributes.workspace_ref)

    with {:ok, record, source_episode, _turn, session} <- lock_offer(attributes.record_ref),
         :ok <- workspace_source?(source_episode, attributes.workspace_ref),
         :ok <- no_room_for(record),
         offer = attributes |> Map.delete(:workspace_ref) |> inherit_placement(session),
         {:ok, confirmation} <- Records.TaskOffers.confirm(offer) do
      confirmation
    else
      {:error, :task_offer_stale} -> Repo.rollback(:incident_offer_stale)
      {:error, :task_offer_not_found} -> Repo.rollback(:incident_offer_not_found)
      {:error, :task_offer_delivery_mismatch} -> Repo.rollback(:incident_offer_delivery_mismatch)
      {:error, :task_offer_not_delivered} -> Repo.rollback(:incident_offer_not_delivered)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # An investigation in the thread works where its conversation works, like a
  # room does: the same environment (so the same Emisar account) and the same
  # mounted repositories the offer's session had. It ran outside any
  # environment before 2026-09-25, so it could record no approvals.
  defp inherit_placement(attributes, session) do
    Map.update!(attributes, :policy, fn policy ->
      policy
      |> Map.put_new(:environment_ref, session.environment_ref)
      |> Map.put_new(:repository_context, session.repository_context)
      |> Map.put_new(:repository_ref, session.repository_ref)
    end)
  end

  defp no_room_for(record) do
    case Repo.one(locked_room_of(record)) do
      nil -> :ok
      %IncidentRoom{} -> {:error, :incident_offer_stale}
    end
  end

  defp request_locked(attributes) do
    lock_workspace!(attributes.workspace_ref)

    case lock_offer(attributes.record_ref) do
      {:ok, record, source_episode, source_turn, source_session} ->
        request_from_offer(record, source_episode, source_turn, source_session, attributes)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp request_from_offer(record, source_episode, source_turn, source_session, attributes) do
    with :ok <- check_delivery(source_episode, source_turn, attributes.target),
         :ok <- workspace_source?(source_episode, attributes.workspace_ref) do
      request_unique_room(record, source_episode, source_session, attributes)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp request_unique_room(record, source_episode, source_session, attributes) do
    case Repo.one(locked_room_of(record)) do
      %IncidentRoom{} = room ->
        %{room: room, status: :duplicate}

      nil when record.status == :open ->
        enforce_capacity!(attributes.workspace_ref, attributes.maximum_open_rooms)
        room = insert_room!(record, source_episode, source_session, attributes)
        %{room: room, status: :requested}

      nil ->
        Repo.rollback(:incident_offer_stale)
    end
  end

  # The offer's row serializes its requests and investigations. The episode,
  # turn and session are read, not locked: locking them made every write to
  # that conversation's work wait for the request (2026-10-04 review).
  defp lock_offer(record_ref) do
    query = Records.Record.Query.incident_offer(record_ref)

    case Repo.one(query) do
      nil -> {:error, :incident_offer_not_found}
      {record, episode, turn, session} -> {:ok, record, episode, turn, session}
    end
  end

  defp check_delivery(episode, turn, target) do
    case Records.CardDelivery.check(episode, turn, target) do
      :ok -> :ok
      {:error, :mismatch} -> {:error, :incident_offer_delivery_mismatch}
      {:error, :not_delivered} -> {:error, :incident_offer_not_delivered}
    end
  end

  defp workspace_source?(episode, workspace_ref) do
    case ConversationRef.parse_slack(episode.destination_conversation_ref) do
      {:ok, ^workspace_ref, _channel_ref} -> :ok
      _other -> {:error, :incident_offer_workspace_mismatch}
    end
  end

  # The room works where the conversation it was opened from worked: that
  # session's environment, repository and mounted companions, whatever the
  # channel has chosen since. The channel supplies only who to invite.
  defp insert_room!(record, source_episode, source_session, attributes) do
    room_id = Repo.generate_id()
    room_ref = "incident-room:#{room_id}"
    source_channel_ref = ConversationRef.slack_channel(attributes.target.conversation_ref)
    configuration = configuration(attributes.workspace_ref, source_channel_ref)
    title = record.payload["title"]
    prompt = record.payload["prompt"]
    channel_name = channel_name(attributes.channel_prefix, attributes.occurred_at, title, room_id)
    topic = topic(title)

    invite_users =
      (attributes.invite_user_refs ++ configuration.invite_user_refs)
      |> Enum.uniq()
      |> Enum.sort()

    attributes = %{
      attempt_count: 0,
      bot_user_ref: attributes.bot_user_ref,
      channel_name: channel_name,
      channel_state: :pending,
      confirmation_ref: attributes.confirmation_ref,
      environment_ref: source_session.environment_ref,
      id: room_id,
      invite_user_group_refs: configuration.invite_user_group_refs,
      invite_user_refs: invite_users,
      policy: attributes.policy.name,
      policy_digest: attributes.policy.digest,
      private: attributes.private,
      prompt: prompt,
      record_id: record.id,
      ref: room_ref,
      repository_context: source_session.repository_context,
      repository_ref: source_session.repository_ref,
      requested_at: attributes.occurred_at,
      requested_by_actor_ref: attributes.actor_ref,
      source_channel_ref: source_channel_ref,
      source_episode_id: source_episode.id,
      source_message_ref: attributes.target.message_ref,
      source_thread_ref: attributes.target.thread_ref,
      status: :requested,
      title: title,
      topic: topic,
      workspace_ref: attributes.workspace_ref
    }

    case Repo.insert(IncidentRoom.Changeset.insert(attributes)) do
      {:ok, room} -> tap(room, &broadcast_room_updated/1)
      {:error, changeset} -> Repo.rollback({:incident_room_persistence_failed, changeset.errors})
    end
  end

  defp configuration(workspace_ref, channel_ref) do
    case Repo.one(ChannelConfiguration.Query.by_channel(workspace_ref, channel_ref)) do
      %ChannelConfiguration{} = configuration -> configuration
      nil -> %ChannelConfiguration{invite_user_group_refs: [], invite_user_refs: []}
    end
  end

  defp automatic_request({record, turn, episode}, workspace_ref) do
    with {:ok, actor_ref} <- automatic_alert_actor(turn.submission, workspace_ref),
         %{} = receipt <- turn.external_receipt,
         message_ref when is_binary(message_ref) <- receipt["message_ref"],
         true <-
           receipt["transport"] == "slack" and
             receipt["conversation_ref"] == episode.destination_conversation_ref and
             receipt["thread_ref"] == episode.destination_thread_ref do
      %{
        actor_ref: actor_ref,
        confirmation_ref: "automatic-alert:#{record.ref}",
        occurred_at: turn.delivered_at || record.inserted_at,
        record_ref: record.ref,
        target: %{
          conversation_ref: episode.destination_conversation_ref,
          message_ref: message_ref,
          thread_ref: episode.destination_thread_ref,
          transport: "slack"
        },
        workspace_ref: workspace_ref
      }
    else
      _not_automatic -> nil
    end
  end

  defp automatic_alert_actor(%{"context" => context}, workspace_ref) when is_map(context) do
    items =
      case context do
        %{"mode" => "full", "inputs" => %{"items" => items}} when is_list(items) ->
          Enum.filter(items, &(&1["current"] == true))

        %{"mode" => "continuation", "current_inputs" => %{"items" => items}}
        when is_list(items) ->
          items

        _invalid ->
          []
      end

    if items != [] and Enum.all?(items, &automatic_alert_item?(&1, workspace_ref)) do
      {:ok, items |> List.last() |> Map.fetch!("actor_ref")}
    else
      {:error, :not_automatic_alert}
    end
  end

  defp automatic_alert_actor(_submission, _workspace_ref),
    do: {:error, :not_automatic_alert}

  defp automatic_alert_item?(
         %{
           "actor_ref" => "slack:app:" <> app_ref,
           "content" => %{
             "actor" => %{"kind" => "app", "ref" => app_ref},
             "source" => %{"kind" => "slack", "ref" => workspace_ref}
           }
         },
         workspace_ref
       ),
       do: true

  defp automatic_alert_item?(_item, _workspace_ref), do: false

  defp enforce_capacity!(workspace_ref, maximum) do
    count = Repo.aggregate(IncidentRoom.Query.open_in_workspace(workspace_ref), :count)

    if count < maximum, do: :ok, else: Repo.rollback(:incident_room_capacity)
  end

  defp claim_next_locked(worker_ref, lease_seconds) do
    now = Repo.now!()
    now |> next_claimable_room() |> lease_room(worker_ref, lease_seconds, now)
  end

  defp rearm_locked(room_ref) do
    now = Repo.now!()

    case Repo.one(locked_room(room_ref)) do
      nil ->
        Repo.rollback(:incident_room_not_found)

      %IncidentRoom{status: :blocked} = room ->
        status = if room.episode_id, do: :ready, else: :requested

        update!(
          room,
          %{
            attempt_count: 0,
            last_error_code: nil,
            last_error_detail: nil,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: nil,
            status: status
          },
          now
        )

      %IncidentRoom{} ->
        Repo.rollback(:incident_room_not_blocked)
    end
  end

  defp next_claimable_room(now), do: Repo.one(IncidentRoom.Query.next_claimable(now))

  defp claim_health_check_locked(worker_ref, lease_seconds, check_interval_seconds) do
    now = Repo.now!()
    due_at = DateTime.add(now, -check_interval_seconds, :second)

    room = Repo.one(IncidentRoom.Query.next_health_check(due_at, now))

    case room do
      nil ->
        nil

      %IncidentRoom{} = room ->
        update!(
          room,
          %{
            attempt_count: room.attempt_count + 1,
            lease_expires_at: DateTime.add(now, lease_seconds, :second),
            lease_owner: worker_ref,
            lease_ref: Ecto.UUID.generate(),
            next_attempt_at: nil
          },
          now,
          :quiet
        )
    end
  end

  defp claim_root_card_locked(worker_ref, lease_seconds, check_interval_seconds) do
    now = Repo.now!()

    now
    |> root_card_claimable_room(check_interval_seconds)
    |> lease_room(worker_ref, lease_seconds, now)
  end

  defp root_card_claimable_room(now, check_interval_seconds),
    do: Repo.one(IncidentRoom.Query.next_root_card(now, check_interval_seconds))

  defp lease_room(nil, _worker_ref, _lease_seconds, _now), do: nil

  # A claim only takes the lease, which no page shows. A ready room is claimed
  # for its card every few seconds; announcing each claim woke every worker
  # that listens to requests as often.
  defp lease_room(%IncidentRoom{} = room, worker_ref, lease_seconds, now) do
    update!(
      room,
      %{
        attempt_count: room.attempt_count + 1,
        lease_expires_at: DateTime.add(now, lease_seconds, :second),
        lease_owner: worker_ref,
        lease_ref: Ecto.UUID.generate(),
        next_attempt_at: nil
      },
      now,
      :quiet
    )
  end

  # A health check that found the channel as it was, with nothing to clear,
  # changed nothing anyone sees. Like a checked card, it gives the claim's
  # attempt back: routine checks spent them, so a room open an hour waited
  # the longest backoff after its first refusal (2026-10-04 review).
  defp release_health_check(room, now) do
    update!(
      room,
      %{
        attempt_count: 0,
        channel_checked_at: now,
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil
      },
      now,
      if(is_nil(room.last_error_code), do: :quiet, else: :announce)
    )
  end

  # A card check that found the pinned card as it was, with nothing to clear,
  # changed nothing anyone sees.
  defp root_card_announcement(
         %IncidentRoom{
           last_error_code: nil,
           root_card_fingerprint: fingerprint,
           root_card_ui_revision: revision
         },
         fingerprint,
         revision
       ),
       do: :quiet

  defp root_card_announcement(_room, _fingerprint, _revision), do: :announce

  defp insert_observation_event!(room, state, event_ref, occurred_at) do
    kind = observation_kind(state)

    fingerprint =
      CanonicalJSON.digest(%{
        "channel_ref" => room.channel_ref,
        "event_ref" => event_ref,
        "kind" => Atom.to_string(kind),
        "occurred_at" => DateTime.to_iso8601(occurred_at),
        "workspace_ref" => room.workspace_ref
      })

    %{
      channel_ref: room.channel_ref,
      event_fingerprint: fingerprint,
      event_ref: event_ref,
      id: Repo.generate_id(),
      kind: kind,
      occurred_at: occurred_at,
      room_id: room.id,
      workspace_ref: room.workspace_ref
    }
    |> IncidentRoomLifecycleEvent.Changeset.insert()
    |> Repo.insert!()
    |> tap(fn _event -> broadcast_room_updated(room) end)
  end

  defp observation_kind(:active), do: :observed_active
  defp observation_kind(:archived), do: :observed_archived
  defp observation_kind(:unavailable), do: :observed_unavailable

  defp observation_ref(room, state, now) do
    timestamp = DateTime.to_unix(now, :microsecond)
    "incident-room-observation:#{room.id}:#{state}:#{timestamp}"
  end

  defp mutate_claim(room_id, lease_ref, callback) do
    with {:ok, _room_id} <- uuid(room_id, :room_id),
         {:ok, _lease_ref} <- uuid(lease_ref, :lease_ref) do
      Repo.transaction(fn -> mutate_claim_locked(room_id, lease_ref, callback) end)
    end
  end

  defp mutate_claim_locked(room_id, lease_ref, callback) do
    now = Repo.now!()

    room =
      room_id |> IncidentRoom.Query.by_id() |> IncidentRoom.Query.lock_for_update() |> Repo.one()

    cond do
      is_nil(room) ->
        Repo.rollback(:incident_room_not_found)

      room.status not in [:requested, :ready] ->
        Repo.rollback(:incident_room_not_claimable)

      room.lease_ref != lease_ref ->
        Repo.rollback(:incident_room_lease_lost)

      DateTime.compare(room.lease_expires_at, now) != :gt ->
        Repo.rollback(:incident_room_lease_lost)

      true ->
        callback.(room, now)
    end
  end

  defp finalize_locked(room_id, lease_ref) do
    now = Repo.now!()

    room =
      room_id |> IncidentRoom.Query.by_id() |> IncidentRoom.Query.lock_for_update() |> Repo.one()

    cond do
      is_nil(room) ->
        Repo.rollback(:incident_room_not_found)

      room.status == :ready ->
        room

      room.status != :requested or room.lease_ref != lease_ref or
          DateTime.compare(room.lease_expires_at, now) != :gt ->
        Repo.rollback(:incident_room_lease_lost)

      not ready_for_episode?(room) ->
        Repo.rollback(:incident_room_not_prepared)

      true ->
        create_linked_episode!(room)
    end
  end

  defp ready_for_episode?(room) do
    Enum.all?(
      [
        room.channel_ref,
        room.root_message_ref,
        room.handoff_message_ref,
        room.audience_prepared_at,
        room.topic_prepared_at,
        room.root_pinned_at
      ],
      &(not is_nil(&1))
    )
  end

  defp create_linked_episode!(room) do
    episode_id = Repo.generate_id()
    episode_key = "incident-room:#{room.id}"

    command = %Episodes.Command.AdmitInput{
      actor_ref: room.requested_by_actor_ref,
      destination: %{
        conversation_ref: ConversationRef.slack(room.workspace_ref, room.channel_ref),
        thread_ref: room.root_message_ref,
        transport: "slack"
      },
      episode_id: episode_id,
      episode_key: episode_key,
      linked_episode_id: room.source_episode_id,
      native_input_id: "incident-room-request:#{room.id}",
      occurred_at: room.requested_at,
      payload: %{
        "incident_room" => %{
          "channel_ref" => room.channel_ref,
          "prompt" => room.prompt,
          "record_ref" => room.ref,
          "repository" => room.repository_ref,
          "source_channel_ref" => room.source_channel_ref,
          "source_message_ref" => room.source_message_ref,
          "source_thread_ref" => room.source_thread_ref,
          "title" => room.title
        }
      },
      revision: 1,
      turn_ref: "turn:incident-room:#{room.id}"
    }

    with {:ok, [transition]} <- Episodes.apply_batch_in_transaction([command]),
         {:ok, _session} <-
           Work.Custody.pin_episode_in_transaction(
             transition.episode.id,
             room.policy,
             room.policy_digest,
             environment_ref: room.environment_ref,
             repository_context: room.repository_context,
             repository_ref: room.repository_ref
           ),
         %Records.Record{} = record <- Repo.one(locked_record(room.record_id)),
         :ok <- confirmable_record(record),
         {:ok, _record} <- confirm_record(record, transition.episode.id, room),
         changeset =
           IncidentRoom.Changeset.update(room, %{
             channel_checked_at: Repo.now!(),
             episode_id: transition.episode.id,
             last_error_code: nil,
             last_error_detail: nil,
             lease_expires_at: nil,
             lease_owner: nil,
             lease_ref: nil,
             next_attempt_at: nil,
             reconciled_channel_state: room.channel_state,
             root_card_checked_at: nil,
             status: :ready
           }),
         {:ok, room} <- Repo.update(changeset) do
      broadcast_room_updated(room)
      room
    else
      nil ->
        Repo.rollback(:incident_offer_not_found)

      {:error, %Ecto.Changeset{} = changeset} ->
        Repo.rollback({:incident_room_persistence_failed, changeset.errors})

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp confirmable_record(%Records.Record{status: :open}), do: :ok

  defp confirmable_record(%Records.Record{status: :confirmed}),
    do: {:error, :incident_offer_already_confirmed}

  defp confirmable_record(_record), do: {:error, :incident_offer_stale}

  defp confirm_record(record, episode_id, room) do
    record
    |> Records.Record.Changeset.confirm(%{
      confirmed_at: room.requested_at,
      confirmed_by_actor_ref: room.requested_by_actor_ref,
      confirmed_episode_id: episode_id,
      confirmation_ref: room.confirmation_ref,
      status: :confirmed
    })
    |> Repo.update()
    |> tap(fn
      {:ok, confirmed} -> Records.broadcast_record_updated(confirmed)
      {:error, _changeset} -> :ok
    end)
  end

  # A renewal only moves the lease's expiry, which no page shows.
  defp update!(room, %{lease_expires_at: _expiry} = attributes, now)
       when map_size(attributes) == 1,
       do: update!(room, attributes, now, :quiet)

  defp update!(room, attributes, now), do: update!(room, attributes, now, :announce)

  defp update!(room, attributes, now, announce) do
    attributes = Map.put(attributes, :updated_at, now)

    changeset = IncidentRoom.Changeset.update(room, attributes)

    case Repo.update(changeset) do
      {:ok, room} when announce == :quiet -> room
      {:ok, room} -> tap(room, &broadcast_room_updated/1)
      {:error, changeset} -> Repo.rollback({:incident_room_persistence_failed, changeset.errors})
    end
  end

  defp exact_map(attributes, fields, boundary \\ :request)

  defp exact_map(attributes, fields, boundary) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> exact_map(fields, boundary),
       else: {:error, {invalid_boundary(boundary), :fields}}
  end

  defp exact_map(%{} = attributes, fields, boundary) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(fields),
      do: {:ok, attributes},
      else: {:error, {invalid_boundary(boundary), :fields}}
  end

  defp exact_map(_attributes, _fields, boundary),
    do: {:error, {invalid_boundary(boundary), :fields}}

  defp invalid_boundary(:request), do: :invalid_incident_room_request
  defp invalid_boundary(:investigation), do: :invalid_incident_investigation

  defp policy(%{} = policy) do
    if Map.keys(policy) |> Enum.sort() == Enum.sort(@policy_fields) do
      with :ok <- reference(policy.name, :policy),
           true <- Crypto.sha256_hex?(policy.digest) do
        {:ok, policy}
      else
        {:error, reason} -> {:error, reason}
        false -> {:error, {:invalid_incident_room_request, :policy_digest}}
      end
    else
      {:error, {:invalid_incident_room_request, :policy}}
    end
  end

  defp policy(_policy), do: {:error, {:invalid_incident_room_request, :policy}}

  defp target(%{} = target, workspace_ref) do
    if Map.keys(target) |> Enum.sort() == Enum.sort(@target_fields) do
      with true <- target.transport == "slack",
           :ok <- reference(target.message_ref, :message_ref),
           :ok <- optional_reference(target.thread_ref, :thread_ref),
           {:ok, _channel_ref} <- slack_conversation(target.conversation_ref, workspace_ref) do
        {:ok, target}
      else
        false -> {:error, {:invalid_incident_room_request, :transport}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:invalid_incident_room_request, :target}}
    end
  end

  defp target(_target, _workspace_ref), do: {:error, {:invalid_incident_room_request, :target}}

  defp slack_conversation(value, workspace_ref) when is_binary(value) do
    case ConversationRef.parse_slack(value) do
      {:ok, ^workspace_ref, channel_ref} ->
        case slack_id(channel_ref, :channel_ref) do
          :ok -> {:ok, channel_ref}
          {:error, reason} -> {:error, reason}
        end

      _invalid ->
        {:error, {:invalid_incident_room_request, :conversation_ref}}
    end
  end

  defp slack_conversation(_value, _workspace_ref),
    do: {:error, {:invalid_incident_room_request, :conversation_ref}}

  defp channel_name(prefix, occurred_at, title, room_id) do
    date = Calendar.strftime(occurred_at, "%m%d")

    slug =
      title
      |> String.downcase()
      |> String.normalize(:nfd)
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> case do
        "" -> "incident"
        value -> value
      end

    # The id's last eight hex digits, random in every UUID Ryker makes; its
    # first eight are a UUIDv7's timestamp, the same for every room opened
    # within the same minute.
    suffix = room_id |> String.replace("-", "") |> String.slice(-8, 8)
    fixed = "#{prefix}-#{date}-#{suffix}"
    title_bytes = max(80 - byte_size(fixed) - 1, 1)
    slug = Text.bytes(slug, title_bytes) |> String.trim("-")
    "#{prefix}-#{date}-#{slug}-#{suffix}"
  end

  # The incident and who keeps the room, in words: the topic once led with
  # Ryker's own id and named Emisar (2026-10-04 review).
  defp topic(title), do: Text.bytes("#{title} · incident room opened by Ryker", 250)

  defp locked_room(room_ref),
    do: room_ref |> IncidentRoom.Query.by_ref() |> IncidentRoom.Query.lock_for_update()

  defp locked_room_of(record),
    do: record.id |> IncidentRoom.Query.by_record_id() |> IncidentRoom.Query.lock_for_update()

  defp locked_record(id),
    do: id |> Records.Record.Query.by_id() |> Records.Record.Query.lock_for_update()

  defp lock_workspace!(workspace_ref),
    do: AdvisoryLock.hold!("slack-incident-room:#{workspace_ref}")

  defp describe_error(reason) do
    code =
      reason
      |> case do
        value when is_atom(value) -> Atom.to_string(value)
        {value, _detail} when is_atom(value) -> Atom.to_string(value)
        _other -> "incident_room_error"
      end
      |> Text.bytes(120)

    {code, ErrorDetail.detail(reason)}
  end

  defp slack_ids(values, field) when is_list(values) and length(values) <= 200 do
    if Enum.uniq(values) == values and Enum.all?(values, &(slack_id(&1, field) == :ok)),
      do: {:ok, Enum.sort(values)},
      else: {:error, {:invalid_incident_room_request, field}}
  end

  defp slack_ids(_values, field), do: {:error, {:invalid_incident_room_request, field}}

  defp slack_id(value, field) do
    if is_binary(value) and Regex.match?(~r/\A[A-Z0-9_-]+\z/, value) and byte_size(value) <= 256,
      do: :ok,
      else: {:error, {:invalid_incident_room_request, field}}
  end

  defp channel_prefix(value) do
    if is_binary(value) and Regex.match?(~r/\A[a-z0-9_-]{1,20}\z/, value),
      do: :ok,
      else: {:error, {:invalid_incident_room_request, :channel_prefix}}
  end

  defp maximum(value) do
    if is_integer(value) and value in 1..1_000,
      do: :ok,
      else: {:error, {:invalid_incident_room_request, :maximum_open_rooms}}
  end

  defp sha256(value, field) do
    if Crypto.sha256_hex?(value),
      do: :ok,
      else: {:error, {:invalid_incident_room_request, field}}
  end

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_incident_room_request, field}}

  defp lease_seconds(value) do
    if is_integer(value) and value in 5..3_600,
      do: :ok,
      else: {:error, {:invalid_incident_room_request, :lease_seconds}}
  end

  defp check_interval_seconds(value) do
    if is_integer(value) and value in 1..86_400,
      do: :ok,
      else: {:error, {:invalid_incident_room_request, :check_interval_seconds}}
  end

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field),
    do: Reference.check(value, field, :invalid_incident_room_request)

  defp bounded_text(value, maximum, field),
    do: Reference.check(value, field, :invalid_incident_room_request, maximum)

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_incident_room_request, field}}
    end
  end

  defp utc_datetime(%DateTime{} = value) do
    case UTCDateTime.exact(value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_incident_room_request, :occurred_at}}
    end
  end

  defp utc_datetime(_value), do: {:error, {:invalid_incident_room_request, :occurred_at}}

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to every incident room's changes:
  `{:incident_room_updated, room_id}` once a room is requested, set up in
  Slack, blocked, rearmed, observed archived or deleted, or closed, and that
  change has committed.
  """
  def subscribe_rooms, do: Ryker.PubSub.subscribe(rooms_topic())

  def unsubscribe_rooms, do: Ryker.PubSub.unsubscribe(rooms_topic())

  @doc """
  Subscribes the caller to one room's changes (`{:incident_room_updated,
  room_id}`), by the room's ref, for the page that shows it.
  """
  def subscribe_room(room_ref), do: Ryker.PubSub.subscribe(room_topic(room_ref))

  def unsubscribe_room(room_ref), do: Ryker.PubSub.unsubscribe(room_topic(room_ref))

  defp rooms_topic, do: "incident_rooms"
  defp room_topic(room_ref), do: "incident_room:#{room_ref}"

  defp broadcast_room_updated(%IncidentRoom{id: id, ref: ref} = room) do
    Episodes.broadcast_episode_updated(room.source_episode_id)
    Episodes.broadcast_episode_updated(room.episode_id)

    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(room_topic(ref), {:incident_room_updated, id})
      Ryker.PubSub.broadcast(rooms_topic(), {:incident_room_updated, id})
    end)
  end
end
