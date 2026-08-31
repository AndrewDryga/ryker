defmodule Responder.Slack.IncidentRooms do
  @moduledoc """
  Durable custody for optional Slack incident-room artifacts.

  A model can only create an inert incident offer. An authenticated operator or
  trusted automatic-alert policy records one request here. Slack provisioning
  is reconciled step by step; only a usable room can create and pin the linked
  episode that owns the actual investigation.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode}
  alias Responder.Repo

  alias Responder.Slack.{
    ChannelConfiguration,
    IncidentRoom,
    IncidentRoomChangeset,
    IncidentRoomLifecycleEvent,
    IncidentRoomLifecycleEventChangeset,
    MembershipTransition
  }

  alias Responder.State.{Record, RecordChangeset}
  alias Responder.Work.{Custody, Session, Turn}

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
         {:ok, target} <- target(attributes.target, attributes.workspace_ref),
         :ok <- slack_id(attributes.workspace_ref, :workspace_ref) do
      prepared = %{
        attributes
        | invite_user_refs: invite_users,
          occurred_at: occurred_at,
          policy: policy,
          target: target
      }

      Repo.transaction(fn -> request_locked(prepared) end)
      |> transaction_result()
    else
      false -> {:error, {:invalid_incident_room_request, :private}}
      {:error, _reason} = error -> error
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
    |> transaction_result()
  end

  def observe_lifecycle(_transition),
    do: {:error, {:invalid_incident_room_lifecycle, :transition}}

  @spec managed_channel?(String.t(), String.t()) :: boolean()
  def managed_channel?(workspace_ref, channel_ref) do
    Repo.exists?(
      from(room in IncidentRoom,
        where: room.workspace_ref == ^workspace_ref and room.channel_ref == ^channel_ref
      )
    )
  end

  @spec channel_profile(String.t(), String.t()) :: {:ok, map()} | :not_found
  def channel_profile(workspace_ref, channel_ref) do
    case Repo.one(
           from(room in IncidentRoom,
             where: room.workspace_ref == ^workspace_ref and room.channel_ref == ^channel_ref,
             select: %{
               channel_state: room.channel_state,
               episode_id: room.episode_id,
               policy: room.policy,
               policy_digest: room.policy_digest,
               repository_ref: room.repository_ref,
               room_ref: room.ref,
               status: room.status
             }
           )
         ) do
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
  Finds the oldest delivered incident offer that a saved automatic-alert policy
  may open without an operator button press.

  The model's offer is still inert by itself. Automatic authority exists only
  when every current input in the frozen Work submission is an authenticated
  Slack app event and the exact source channel saved `automatic` policy.
  """
  @spec automatic_candidate(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def automatic_candidate(workspace_ref) do
    with :ok <- slack_id(workspace_ref, :workspace_ref) do
      candidates = automatic_candidates(workspace_ref)

      {:ok, Enum.find_value(candidates, &automatic_request(&1, workspace_ref))}
    end
  end

  defp automatic_candidates(workspace_ref) do
    workspace_ref
    |> automatic_candidate_base()
    |> automatic_offer_filter()
    |> automatic_delivery_filter()
    |> automatic_authority_filter(workspace_ref)
    |> automatic_candidate_order()
    |> Repo.all()
  end

  defp automatic_candidate_base(workspace_ref) do
    from(record in Record,
      join: turn in Turn,
      on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
      join: episode in Episode,
      on: episode.id == record.episode_id,
      join: configuration in ChannelConfiguration,
      on:
        configuration.workspace_ref == ^workspace_ref and
          configuration.channel_ref ==
            fragment("split_part(?, ':', 3)", episode.destination_conversation_ref),
      left_join: room in IncidentRoom,
      on: room.record_id == record.id
    )
  end

  defp automatic_offer_filter(query) do
    from([record, _turn, _episode, _configuration, _room] in query,
      where:
        record.kind == "task_offer" and record.status == :open and
          fragment("(?::jsonb ->> 'kind') = 'incident'", record.payload)
    )
  end

  defp automatic_delivery_filter(query) do
    from([_record, turn, episode, _configuration, _room] in query,
      where:
        turn.status == :settled and not is_nil(turn.external_receipt) and
          episode.destination_transport == "slack"
    )
  end

  defp automatic_authority_filter(query, workspace_ref) do
    from([_record, _turn, episode, configuration, room] in query,
      where:
        fragment("split_part(?, ':', 2)", episode.destination_conversation_ref) ==
          ^workspace_ref and configuration.alert_policy == :automatic and is_nil(room.id)
    )
  end

  defp automatic_candidate_order(query) do
    from([record, turn, episode, _configuration, _room] in query,
      order_by: [asc: turn.delivered_at, asc: record.inserted_at, asc: record.id],
      limit: 25,
      select: {record, turn, episode}
    )
  end

  @spec claim_next(String.t(), pos_integer()) ::
          {:ok, IncidentRoom.t() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- lease_seconds(lease_seconds) do
      Repo.transaction(fn -> claim_next_locked(worker_ref, lease_seconds) end)
      |> transaction_result()
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
      |> transaction_result()
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

  @spec claim_root_card(String.t(), pos_integer(), pos_integer()) ::
          {:ok, IncidentRoom.t() | nil} | {:error, term()}
  def claim_root_card(worker_ref, lease_seconds, check_interval_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- lease_seconds(lease_seconds),
         :ok <- check_interval_seconds(check_interval_seconds) do
      Repo.transaction(fn ->
        claim_root_card_locked(worker_ref, lease_seconds, check_interval_seconds)
      end)
      |> transaction_result()
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
          now
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
      |> transaction_result()
    end
  end

  @spec mark_lifecycle_reconciled(Ecto.UUID.t(), Ecto.UUID.t(), atom()) ::
          {:ok, IncidentRoom.t()} | {:error, term()}
  def mark_lifecycle_reconciled(room_id, lease_ref, expected_state)
      when expected_state in [:active, :archived, :deleted, :unavailable] do
    mutate_claim(room_id, lease_ref, fn room, now ->
      cond do
        room.status != :ready ->
          Repo.rollback(:incident_room_not_ready)

        room.channel_state != expected_state ->
          Repo.rollback(:incident_room_lifecycle_stale)

        true ->
          update!(
            room,
            %{
              last_error_code: nil,
              last_error_detail: nil,
              lease_expires_at: nil,
              lease_owner: nil,
              lease_ref: nil,
              next_attempt_at: nil,
              reconciled_channel_state: expected_state
            },
            now
          )
      end
    end)
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
    |> transaction_result()
  end

  defp observe_lifecycle_locked(transition) do
    lock_workspace!(transition.workspace_ref)

    room =
      Repo.one(
        from(room in IncidentRoom,
          where:
            room.workspace_ref == ^transition.workspace_ref and
              room.channel_ref == ^transition.channel_ref,
          lock: "FOR UPDATE"
        )
      )

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

    case Repo.one(
           from(event in IncidentRoomLifecycleEvent,
             where:
               event.workspace_ref == ^transition.workspace_ref and
                 event.event_ref == ^transition.event_ref,
             lock: "FOR UPDATE"
           )
         ) do
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
      id: Ecto.UUID.generate(),
      kind: transition.kind,
      occurred_at: transition.occurred_at,
      room_id: room.id,
      workspace_ref: transition.workspace_ref
    }
    |> IncidentRoomLifecycleEventChangeset.insert()
    |> Repo.insert!()
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

      attributes = requested_deleted_attributes(room, state, attributes)
      room = update!(room, attributes, database_now!())
      %{room: room, status: :applied}
    else
      %{room: room, status: :stale}
    end
  end

  defp requested_deleted_attributes(%IncidentRoom{status: :requested}, :deleted, attributes) do
    Map.merge(attributes, %{
      last_error_code: "incident_room_deleted",
      last_error_detail: "Slack deleted the incident room before provisioning completed.",
      reconciled_channel_state: :deleted,
      status: :blocked
    })
  end

  defp requested_deleted_attributes(_room, _state, attributes), do: attributes

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
    with :ok <- delivered_from?(source_episode, source_turn, attributes.target),
         :ok <- workspace_source?(source_episode, attributes.workspace_ref) do
      request_unique_room(record, source_episode, source_session, attributes)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp request_unique_room(record, source_episode, source_session, attributes) do
    query = from(room in IncidentRoom, where: room.record_id == ^record.id, lock: "FOR UPDATE")

    case Repo.one(query) do
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

  defp lock_offer(record_ref) do
    query =
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        join: session in Session,
        on: session.id == turn.session_id and session.episode_id == turn.episode_id,
        where:
          record.ref == ^record_ref and record.kind == "task_offer" and
            fragment("(?::jsonb ->> 'kind') = 'incident'", record.payload),
        select: {record, episode, turn, session},
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :incident_offer_not_found}
      {record, episode, turn, session} -> {:ok, record, episode, turn, session}
    end
  end

  defp delivered_from?(episode, %Turn{status: :settled, external_receipt: receipt}, target)
       when is_map(receipt) do
    matches =
      receipt["conversation_ref"] == episode.destination_conversation_ref and
        receipt["thread_ref"] == episode.destination_thread_ref and
        receipt["transport"] == episode.destination_transport and
        target == %{
          conversation_ref: episode.destination_conversation_ref,
          message_ref: receipt["message_ref"],
          thread_ref: episode.destination_thread_ref,
          transport: episode.destination_transport
        }

    if matches, do: :ok, else: {:error, :incident_offer_delivery_mismatch}
  end

  defp delivered_from?(_episode, _turn, _target), do: {:error, :incident_offer_not_delivered}

  defp workspace_source?(episode, workspace_ref) do
    case String.split(episode.destination_conversation_ref, ":", parts: 3) do
      ["slack", ^workspace_ref, _channel_ref] -> :ok
      _other -> {:error, :incident_offer_workspace_mismatch}
    end
  end

  defp insert_room!(record, source_episode, source_session, attributes) do
    room_id = Ecto.UUID.generate()
    room_ref = "incident-room:#{room_id}"
    source_channel_ref = source_channel_ref!(attributes.target.conversation_ref)
    configuration = configuration(attributes.workspace_ref, source_channel_ref)
    repository_ref = source_session.repository_ref || configuration.repository_ref
    title = record.payload["title"]
    prompt = record.payload["prompt"]
    channel_name = channel_name(attributes.channel_prefix, attributes.occurred_at, title, room_id)
    topic = topic(room_ref, title)

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
      id: room_id,
      invite_user_group_refs: configuration.invite_user_group_refs,
      invite_user_refs: invite_users,
      policy: attributes.policy.name,
      policy_digest: attributes.policy.digest,
      private: attributes.private,
      prompt: prompt,
      record_id: record.id,
      ref: room_ref,
      repository_ref: repository_ref,
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

    case Repo.insert(IncidentRoomChangeset.insert(attributes)) do
      {:ok, room} -> room
      {:error, changeset} -> Repo.rollback({:incident_room_persistence_failed, changeset.errors})
    end
  end

  defp configuration(workspace_ref, channel_ref) do
    case Repo.get_by(ChannelConfiguration, workspace_ref: workspace_ref, channel_ref: channel_ref) do
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
    count =
      Repo.aggregate(
        from(room in IncidentRoom,
          where: room.workspace_ref == ^workspace_ref and room.status != :closed
        ),
        :count
      )

    if count < maximum, do: :ok, else: Repo.rollback(:incident_room_capacity)
  end

  defp claim_next_locked(worker_ref, lease_seconds) do
    now = database_now!()
    now |> next_claimable_room() |> lease_room(worker_ref, lease_seconds, now)
  end

  defp rearm_locked(room_ref) do
    now = database_now!()

    case Repo.one(
           from(room in IncidentRoom,
             where: room.ref == ^room_ref,
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        Repo.rollback(:incident_room_not_found)

      %IncidentRoom{status: :blocked, channel_state: :deleted} ->
        Repo.rollback(:incident_room_deleted)

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

  defp next_claimable_room(now) do
    Repo.one(
      from(room in IncidentRoom,
        where:
          ((room.status == :requested and room.channel_state in [:pending, :active]) or
             (room.status == :ready and room.channel_state != room.reconciled_channel_state)) and
            (is_nil(room.next_attempt_at) or room.next_attempt_at <= ^now) and
            (is_nil(room.lease_expires_at) or room.lease_expires_at <= ^now),
        order_by: [
          asc: fragment("CASE WHEN ? = 'ready' THEN 0 ELSE 1 END", room.status),
          asc: room.updated_at,
          asc: room.id
        ],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  defp claim_health_check_locked(worker_ref, lease_seconds, check_interval_seconds) do
    now = database_now!()
    due_at = DateTime.add(now, -check_interval_seconds, :second)

    room =
      Repo.one(
        from(room in IncidentRoom,
          where:
            room.status == :ready and room.channel_state != :deleted and
              room.channel_state == room.reconciled_channel_state and
              (is_nil(room.channel_checked_at) or room.channel_checked_at <= ^due_at) and
              (is_nil(room.lease_expires_at) or room.lease_expires_at <= ^now),
          order_by: [asc_nulls_first: room.channel_checked_at, asc: room.id],
          limit: 1,
          lock: "FOR UPDATE SKIP LOCKED"
        )
      )

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
          now
        )
    end
  end

  defp claim_root_card_locked(worker_ref, lease_seconds, check_interval_seconds) do
    now = database_now!()
    due_at = DateTime.add(now, -check_interval_seconds, :second)
    due_at |> root_card_claimable_room(now) |> lease_room(worker_ref, lease_seconds, now)
  end

  defp root_card_claimable_room(due_at, now) do
    Repo.one(
      from(room in IncidentRoom,
        where:
          room.status == :ready and room.channel_state == :active and
            room.reconciled_channel_state == :active and not is_nil(room.root_message_ref) and
            (is_nil(room.root_card_checked_at) or room.root_card_checked_at <= ^due_at) and
            (is_nil(room.lease_expires_at) or room.lease_expires_at <= ^now),
        order_by: [
          asc_nulls_first: room.root_card_checked_at,
          asc: room.updated_at,
          asc: room.id
        ],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  defp lease_room(nil, _worker_ref, _lease_seconds, _now), do: nil

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
      now
    )
  end

  defp release_health_check(room, now) do
    update!(
      room,
      %{
        channel_checked_at: now,
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil
      },
      now
    )
  end

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
      id: Ecto.UUID.generate(),
      kind: kind,
      occurred_at: occurred_at,
      room_id: room.id,
      workspace_ref: room.workspace_ref
    }
    |> IncidentRoomLifecycleEventChangeset.insert()
    |> Repo.insert!()
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
      |> transaction_result()
    end
  end

  defp mutate_claim_locked(room_id, lease_ref, callback) do
    now = database_now!()
    room = Repo.one(from(room in IncidentRoom, where: room.id == ^room_id, lock: "FOR UPDATE"))

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
    now = database_now!()

    room = Repo.one(from(room in IncidentRoom, where: room.id == ^room_id, lock: "FOR UPDATE"))

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
    episode_id = Ecto.UUID.generate()
    episode_key = "incident-room:#{room.id}"

    command = %Command.AdmitInput{
      actor_ref: room.requested_by_actor_ref,
      destination: %{
        conversation_ref: "slack:#{room.workspace_ref}:#{room.channel_ref}",
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
           Custody.pin_episode_in_transaction(
             transition.episode.id,
             room.policy,
             room.policy_digest,
             room.repository_ref
           ),
         %Record{} = record <-
           Repo.one(
             from(record in Record, where: record.id == ^room.record_id, lock: "FOR UPDATE")
           ),
         :ok <- confirmable_record(record),
         {:ok, _record} <- confirm_record(record, transition.episode.id, room),
         {:ok, room} <-
           room
           |> IncidentRoomChangeset.update(%{
             channel_checked_at: database_now!(),
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
           })
           |> Repo.update() do
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

  defp confirmable_record(%Record{status: :open}), do: :ok

  defp confirmable_record(%Record{status: :confirmed}),
    do: {:error, :incident_offer_already_confirmed}

  defp confirmable_record(_record), do: {:error, :incident_offer_stale}

  defp confirm_record(record, episode_id, room) do
    record
    |> RecordChangeset.confirm(%{
      confirmed_at: room.requested_at,
      confirmed_by_actor_ref: room.requested_by_actor_ref,
      confirmed_episode_id: episode_id,
      confirmation_ref: room.confirmation_ref,
      status: :confirmed
    })
    |> Repo.update()
  end

  defp update!(room, attributes, now) do
    attributes = Map.put(attributes, :updated_at, now)

    case room |> IncidentRoomChangeset.update(attributes) |> Repo.update() do
      {:ok, room} -> room
      {:error, changeset} -> Repo.rollback({:incident_room_persistence_failed, changeset.errors})
    end
  end

  defp exact_map(attributes, fields) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> exact_map(fields),
       else: {:error, {:invalid_incident_room_request, :fields}}
  end

  defp exact_map(%{} = attributes, fields) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_incident_room_request, :fields}}
  end

  defp exact_map(_attributes, _fields), do: {:error, {:invalid_incident_room_request, :fields}}

  defp policy(%{} = policy) do
    if Map.keys(policy) |> Enum.sort() == Enum.sort(@policy_fields) do
      with :ok <- reference(policy.name, :policy),
           true <- is_binary(policy.digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, policy.digest) do
        {:ok, policy}
      else
        {:error, _reason} = error -> error
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
        {:error, _reason} = error -> error
      end
    else
      {:error, {:invalid_incident_room_request, :target}}
    end
  end

  defp target(_target, _workspace_ref), do: {:error, {:invalid_incident_room_request, :target}}

  defp slack_conversation(value, workspace_ref) when is_binary(value) do
    case String.split(value, ":", parts: 3) do
      ["slack", ^workspace_ref, channel_ref] ->
        case slack_id(channel_ref, :channel_ref) do
          :ok -> {:ok, channel_ref}
          {:error, _reason} = error -> error
        end

      _invalid ->
        {:error, {:invalid_incident_room_request, :conversation_ref}}
    end
  end

  defp slack_conversation(_value, _workspace_ref),
    do: {:error, {:invalid_incident_room_request, :conversation_ref}}

  defp source_channel_ref!(conversation_ref) do
    ["slack", _workspace_ref, channel_ref] = String.split(conversation_ref, ":", parts: 3)
    channel_ref
  end

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

    suffix = room_id |> String.replace("-", "") |> String.slice(0, 8)
    fixed = "#{prefix}-#{date}-#{suffix}"
    title_bytes = max(80 - byte_size(fixed) - 1, 1)
    slug = byte_slice(slug, title_bytes) |> String.trim("-")
    "#{prefix}-#{date}-#{slug}-#{suffix}"
  end

  defp topic(room_ref, title) do
    short = room_ref |> String.replace_prefix("incident-room:", "") |> String.slice(0, 8)
    byte_slice("Incident #{short} | #{title} | managed by Emisar", 250)
  end

  defp lock_workspace!(workspace_ref) do
    key = "slack-incident-room:#{workspace_ref}"
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    :ok
  end

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp describe_error(reason) do
    code =
      reason
      |> case do
        value when is_atom(value) -> Atom.to_string(value)
        {value, _detail} when is_atom(value) -> Atom.to_string(value)
        _other -> "incident_room_error"
      end
      |> byte_slice(120)

    {code,
     reason
     |> inspect(limit: 30, printable_limit: 3_000)
     |> byte_slice(@maximum_error_detail_bytes)}
  end

  defp byte_slice(value, maximum) do
    if byte_size(value) <= maximum do
      value
    else
      value
      |> String.graphemes()
      |> Enum.reduce_while("", fn grapheme, output ->
        append_grapheme(output, grapheme, maximum)
      end)
    end
  end

  defp append_grapheme(output, grapheme, maximum) do
    if byte_size(output) + byte_size(grapheme) <= maximum,
      do: {:cont, output <> grapheme},
      else: {:halt, output}
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
    if is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
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

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: {:error, {:invalid_incident_room_request, field}}
  end

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_incident_room_request, field}}
    end
  end

  defp utc_datetime(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0 do
      {microsecond, _precision} = value.microsecond
      {:ok, %{value | microsecond: {microsecond, 6}}}
    else
      {:error, {:invalid_incident_room_request, :occurred_at}}
    end
  end

  defp utc_datetime(_value), do: {:error, {:invalid_incident_room_request, :occurred_at}}

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
