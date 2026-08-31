defmodule Responder.ControlPlane.Projection do
  @moduledoc """
  Bounded, payload-minimizing read models for the local control plane.

  Raw ingress bodies, model prompts, credentials, and arbitrary state payloads
  never cross this boundary. Detail pages expose durable lifecycle metadata and
  typed record summaries only.
  """

  import Ecto.Query

  alias Responder.Delivery.Operator, as: DeliveryOperator
  alias Responder.Emisar.Operator, as: EmisarOperator
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.Retention.OperatorAction
  alias Responder.Slack.{IncidentRoom, InteractionAudit}
  alias Responder.State.{Behavior, MemoryEntry, Record, Schedule}
  alias Responder.Work.{Measurement, Session, Turn}

  @page_size 50
  @maximum_page 10_000
  @active_states [:working, :waiting_for_input, :waiting_for_event]
  @lab_prefix "control-plane:lab:"
  @lab_message_limit 200

  @spec callbacks() :: map()
  def callbacks do
    %{
      admission: &admission/1,
      audit: &audit/1,
      configuration: &configuration/0,
      decisions: &decisions/1,
      delivery: &delivery/1,
      emisar: &emisar/1,
      episode: &episode/1,
      episodes: &episodes/1,
      failures: &failures/1,
      findings: &findings/1,
      lab_conversation: &lab_conversation/1,
      lab_index: &lab_index/0,
      memory: &memory/0,
      overview: &overview/0,
      usage: &usage/1,
      slack_incident: &slack_incident/1,
      slack_interaction: &slack_interaction/1,
      work: &work/1,
      workspace: &workspace/1,
      workspaces: &workspaces/1
    }
  end

  @doc """
  Lists recent loopback conversations without loading their message bodies.
  """
  def lab_index do
    Repo.all(
      from(entry in Entry,
        where:
          entry.source_kind == "control_plane" and entry.source_ref == "local" and
            entry.destination_transport == "control_plane" and
            like(entry.destination_conversation_ref, ^"#{@lab_prefix}%") and
            entry.destination_thread_ref == entry.destination_conversation_ref,
        group_by: entry.destination_conversation_ref,
        order_by: [desc: max(entry.inserted_at), desc: entry.destination_conversation_ref],
        limit: 100,
        select: %{
          message_count: count(entry.id),
          ref: entry.destination_conversation_ref,
          updated_at: max(entry.inserted_at)
        }
      )
    )
    |> Enum.flat_map(fn item ->
      case lab_id(item.ref) do
        {:ok, id} -> [Map.put(item, :id, id)]
        :error -> []
      end
    end)
  end

  @doc """
  Projects one local conversation from its durable ingress and accepted Work rows.

  Only exact local operator text and accepted visible replies cross this read
  boundary. Prompts, candidates, arbitrary external payloads, credentials, and
  unreleased model output remain private.
  """
  def lab_conversation(conversation_id) do
    case normalized_uuid(conversation_id) do
      {:ok, conversation_id} -> project_lab_conversation(conversation_id)
      :error -> :not_found
    end
  end

  defp project_lab_conversation(conversation_id) do
    ref = @lab_prefix <> conversation_id
    inputs = lab_inputs(ref)
    episodes = lab_episodes(ref)

    if inputs == [] and episodes == [] do
      :not_found
    else
      replies = lab_replies(ref)

      {:ok,
       %{
         blocked: Enum.any?(inputs, &(&1.status == :blocked)),
         conversation_id: conversation_id,
         conversation_ref: ref,
         episodes: episodes,
         live: lab_live?(inputs, episodes, replies),
         messages: lab_messages(inputs, replies),
         pending: Enum.count(inputs, &(&1.status == :pending))
       }}
    end
  end

  def overview do
    active_query = from(episode in Episode, where: episode.state in ^@active_states)

    waiting_query =
      from(episode in Episode, where: episode.state in [:waiting_for_input, :waiting_for_event])

    blocked_query =
      from(turn in Turn,
        join: episode in Episode,
        on:
          episode.id == turn.episode_id and episode.owner_kind == :turn and
            episode.owner_ref == turn.turn_ref,
        where: turn.status == :blocked and episode.state == :working
      )

    delivery_query = from(turn in Turn, where: turn.status == :delivery_pending)

    %{
      counts: %{
        active: count(active_query),
        blocked: count(blocked_query),
        delivery_pending: count(delivery_query),
        waiting: count(waiting_query)
      },
      needs_attention: needs_attention()
    }
  end

  def episodes(params) when is_map(params) do
    page = page(params["page"])
    query = episode_query(params)

    total = count(query)
    items = episode_page(query, page)

    %{items: items, page: page, pages: max(div(total + @page_size - 1, @page_size), 1)}
  end

  def episodes(_params), do: episodes(%{})

  defp episode_query(params) do
    from(episode in Episode)
    |> filter_episode_state(state(params["state"]))
    |> filter_episode_target(target(params["target"]))
    |> filter_episode_repository(repository(params["repository"]))
    |> filter_episode_search(search(params["q"]))
  end

  defp filter_episode_state(query, nil), do: query

  defp filter_episode_state(query, state),
    do: from(episode in query, where: episode.state == ^state)

  defp filter_episode_target(query, nil), do: query

  defp filter_episode_target(query, target) do
    episode_ids =
      from(turn in Turn, where: turn.execution_target == ^target, select: turn.episode_id)

    from(episode in query, where: episode.id in subquery(episode_ids))
  end

  defp filter_episode_repository(query, nil), do: query

  defp filter_episode_repository(query, repository_ref) do
    episode_ids =
      from(session in Session,
        where: session.repository_ref == ^repository_ref,
        select: session.episode_id
      )

    from(episode in query, where: episode.id in subquery(episode_ids))
  end

  defp filter_episode_search(query, nil), do: query

  defp filter_episode_search(query, search) do
    pattern = "%#{escape_like(search)}%"

    from(episode in query,
      where: ilike(episode.key, ^pattern) or ilike(episode.destination_conversation_ref, ^pattern)
    )
  end

  defp episode_page(query, page) do
    Repo.all(
      from(episode in query,
        left_join: turn in Turn,
        on:
          turn.episode_id == episode.id and episode.owner_kind == :turn and
            turn.turn_ref == episode.owner_ref,
        order_by: [desc: episode.updated_at, desc: episode.id],
        offset: ^((page - 1) * @page_size),
        limit: @page_size,
        select: {episode, turn.status, turn.coop_turn_id}
      )
    )
    |> Enum.map(fn {episode, turn_status, coop_turn_id} ->
      %{
        destination: destination(episode),
        next_action: next_action(episode, turn_status, coop_turn_id),
        ref: episode.key,
        state: episode.state,
        updated_at: episode.updated_at
      }
    end)
  end

  def episode(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(from(episode in Episode, where: episode.key == ^ref)) do
      nil ->
        :not_found

      episode ->
        events =
          Repo.all(
            from(event in Event,
              where: event.episode_id == ^episode.id,
              order_by: [asc: event.sequence],
              limit: 500
            )
          )
          |> Enum.map(fn event ->
            %{
              kind: event.kind,
              occurred_at: event.occurred_at,
              summary: event_summary(event.kind)
            }
          end)

        records =
          Repo.all(
            from(record in Record,
              where: record.episode_id == ^episode.id,
              order_by: [asc: record.sequence, asc: record.id],
              limit: 500
            )
          )
          |> Enum.map(fn record ->
            %{
              kind: record.kind,
              status: record.status,
              summary: record_summary(record)
            }
          end)

        {:ok,
         %{
           episode: %{
             destination: destination(episode),
             ref: episode.key,
             state: episode.state,
             updated_at: episode.updated_at
           },
           events: events,
           records: records
         }}
    end
  end

  def episode(_ref), do: :not_found

  def failures(_params) do
    work =
      Repo.all(
        from(turn in Turn,
          join: episode in Episode,
          on:
            episode.id == turn.episode_id and episode.state == :working and
              episode.owner_kind == :turn and episode.owner_ref == turn.turn_ref,
          where: turn.status == :blocked and is_nil(turn.delivery_ref),
          order_by: [desc: turn.updated_at, desc: turn.id],
          limit: 100,
          select: {turn, episode}
        )
      )
      |> Enum.map(&work_item/1)

    admission =
      Repo.all(
        from(entry in Entry,
          where: entry.status == :blocked,
          order_by: [desc: entry.updated_at, desc: entry.id],
          limit: 100
        )
      )
      |> Enum.map(&admission_item/1)

    deliveries =
      case DeliveryOperator.list_blocked(100) do
        {:ok, items} -> Enum.map(items, &delivery_item/1)
        {:error, _reason} -> []
      end

    retention =
      Repo.all(
        from(session in Session,
          join: episode in Episode,
          on: episode.id == session.episode_id,
          where: session.cleanup_status == :blocked,
          order_by: [desc: session.updated_at, desc: session.id],
          limit: 100,
          select: {session, episode}
        )
      )
      |> Enum.map(&retention_item/1)

    interaction_feedback =
      Repo.all(
        from(audit in InteractionAudit,
          where: audit.repaint_status == :blocked,
          order_by: [desc: audit.updated_at, desc: audit.id],
          limit: 100,
          select: audit
        )
      )
      |> Enum.map(&interaction_item/1)

    incident_rooms =
      Repo.all(
        from(room in IncidentRoom,
          where: room.status == :blocked,
          order_by: [desc: room.updated_at, desc: room.id],
          limit: 100
        )
      )
      |> Enum.map(&incident_item/1)

    emisar =
      case EmisarOperator.list_blocked(100) do
        {:ok, items} -> Enum.map(items, &emisar_item/1)
        {:error, _reason} -> []
      end

    (work ++
       admission ++
       deliveries ++
       retention ++
       interaction_feedback ++
       incident_rooms ++
       emisar)
    |> decorate_failures()
    |> Enum.sort_by(&DateTime.to_unix(&1.updated_at, :microsecond), :desc)
    |> Enum.take(100)
  end

  def delivery(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case DeliveryOperator.fetch(ref) do
      {:ok, %{status: :blocked} = item} -> {:ok, delivery_item(item)}
      {:ok, _item} -> :not_found
      {:error, _reason} -> :not_found
    end
  end

  def delivery(_ref), do: :not_found

  def admission(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Inbox.fetch(ref) do
      {:ok, %Entry{status: :blocked} = entry} -> {:ok, admission_item(entry)}
      _unavailable -> :not_found
    end
  end

  def admission(_ref), do: :not_found

  def work(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case blocked_work(ref) do
      nil -> :not_found
      row -> {:ok, work_item(row)}
    end
  end

  def work(_ref), do: :not_found

  def emisar(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case EmisarOperator.fetch(ref) do
      {:ok, %{status: :blocked} = item} -> {:ok, emisar_item(item)}
      _unavailable -> :not_found
    end
  end

  def emisar(_ref), do: :not_found

  def slack_interaction(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.get_by(InteractionAudit, event_ref: ref) do
      %InteractionAudit{repaint_status: :blocked} = audit -> {:ok, interaction_item(audit)}
      _unavailable -> :not_found
    end
  end

  def slack_interaction(_ref), do: :not_found

  def slack_incident(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.get_by(IncidentRoom, ref: ref) do
      %IncidentRoom{status: :blocked} = room -> {:ok, incident_item(room)}
      _unavailable -> :not_found
    end
  end

  def slack_incident(_ref), do: :not_found

  def workspaces(_params) do
    Repo.all(
      from(session in Session,
        join: episode in Episode,
        on: episode.id == session.episode_id,
        order_by: [desc: session.updated_at, desc: session.id],
        limit: 100,
        select: {session, episode.state}
      )
    )
    |> Enum.map(&workspace_item/1)
  end

  def workspace(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(
           from(session in Session,
             join: episode in Episode,
             on: episode.id == session.episode_id,
             where: session.external_ref == ^ref,
             select: {session, episode.state}
           )
         ) do
      nil -> :not_found
      row -> {:ok, workspace_item(row)}
    end
  end

  def workspace(_ref), do: :not_found

  def decisions(_params) do
    Repo.all(
      from(entry in Entry,
        where: entry.status in [:decided, :superseded],
        order_by: [desc: entry.updated_at, desc: entry.id],
        limit: 100,
        select: %{
          kind: "admission",
          ref: entry.decision_ref,
          state: entry.decision_action,
          status: entry.status,
          summary: entry.source_kind,
          updated_at: entry.updated_at
        }
      )
    )
  end

  def findings(_params) do
    Repo.all(
      from(record in Record,
        where: record.kind == "finding",
        order_by: [desc: record.inserted_at, desc: record.id],
        limit: 100,
        select: %{
          kind: record.kind,
          ref: record.ref,
          status: record.status,
          summary: record.payload_fingerprint,
          updated_at: record.inserted_at
        }
      )
    )
  end

  def audit(_params) do
    episode_events =
      Repo.all(
        from(event in Event,
          join: episode in Episode,
          on: episode.id == event.episode_id,
          order_by: [desc: event.inserted_at, desc: event.id],
          limit: 100,
          select: %{
            kind: event.kind,
            ref: episode.key,
            summary: event.dedupe_key,
            updated_at: event.occurred_at
          }
        )
      )

    interaction_events =
      Repo.all(
        from(audit in InteractionAudit,
          order_by: [desc: audit.occurred_at, desc: audit.id],
          limit: 100,
          select: %{
            kind: audit.outcome,
            ref: audit.event_ref,
            summary: audit.action_id,
            updated_at: audit.occurred_at
          }
        )
      )

    retention_events =
      Repo.all(
        from(action in OperatorAction,
          join: session in Session,
          on: session.id == action.session_id,
          order_by: [desc: action.occurred_at, desc: action.id],
          limit: 100,
          select: %{
            kind: action.action,
            ref: session.external_ref,
            summary: action.actor_ref,
            updated_at: action.occurred_at
          }
        )
      )

    (episode_events ++ interaction_events ++ retention_events)
    |> Enum.sort_by(
      &{DateTime.to_unix(&1.updated_at, :microsecond), &1.ref},
      :desc
    )
    |> Enum.take(100)
  end

  def memory do
    now = database_now!()

    %{
      behaviors:
        Repo.all(
          from(behavior in Behavior,
            where: behavior.status in [:active, :disabled] and behavior.expires_at > ^now,
            order_by: [desc: behavior.updated_at, desc: behavior.id],
            limit: 100,
            select: %{
              kind: behavior.kind,
              ref: behavior.ref,
              status: behavior.status,
              subject: behavior.identity_key
            }
          )
        ),
      memories:
        Repo.all(
          from(memory in MemoryEntry,
            where: memory.status == :active and memory.expires_at > ^now,
            order_by: [desc: memory.updated_at, desc: memory.id],
            limit: 100,
            select: %{
              kind: memory.kind,
              ref: memory.ref,
              status: memory.status,
              subject: memory.subject
            }
          )
        ),
      schedules:
        Repo.all(
          from(schedule in Schedule,
            where:
              schedule.status in [:active, :paused] and
                (is_nil(schedule.expires_at) or schedule.expires_at > ^now),
            order_by: [asc: schedule.next_occurrence_at, asc: schedule.id],
            limit: 100,
            select: %{
              next_occurrence_at: schedule.next_occurrence_at,
              ref: schedule.ref,
              status: schedule.status,
              title: schedule.title
            }
          )
        )
    }
  end

  def configuration do
    ~w(admission work control_plane coop_worker_gateway delivery publication retention state_tools event_waits schedules emisar slack github webhooks)a
    |> Enum.map(fn key ->
      %{
        key: Atom.to_string(key),
        value: if(Application.get_env(:responder, key), do: "enabled", else: "disabled")
      }
    end)
  end

  def usage(params) when is_map(params) do
    {window, since} = usage_window(params["window"])
    query = usage_query(since)

    %{
      channels: usage_channels(query),
      days: usage_days(query),
      repositories: usage_repositories(query),
      targets: usage_targets(query),
      totals: usage_totals(query),
      window: window
    }
  end

  def usage(_params), do: usage(%{})

  defp lab_inputs(ref) do
    Repo.all(
      from(entry in Entry,
        where:
          entry.source_kind == "control_plane" and entry.source_ref == "local" and
            entry.actor_kind == :user and entry.destination_transport == "control_plane" and
            entry.destination_conversation_ref == ^ref and
            entry.destination_thread_ref == ^ref,
        order_by: [asc: entry.inserted_at, asc: entry.id],
        limit: @lab_message_limit,
        select: %{
          content: entry.content,
          occurred_at: entry.inserted_at,
          ref: entry.event_ref,
          status: entry.status
        }
      )
    )
  end

  defp lab_episodes(ref) do
    Repo.all(
      from(episode in Episode,
        left_join: turn in Turn,
        on:
          turn.episode_id == episode.id and episode.owner_kind == :turn and
            episode.owner_ref == turn.turn_ref,
        where:
          episode.destination_transport == "control_plane" and
            episode.destination_conversation_ref == ^ref and
            episode.destination_thread_ref == ^ref,
        order_by: [desc: episode.updated_at, desc: episode.id],
        limit: 20,
        select: {episode, turn.status, turn.coop_turn_id}
      )
    )
    |> Enum.map(fn {episode, turn_status, coop_turn_id} ->
      %{
        next_action: next_action(episode, turn_status, coop_turn_id),
        ref: episode.key,
        state: episode.state,
        updated_at: episode.updated_at,
        work_status: turn_status
      }
    end)
  end

  defp lab_replies(ref) do
    Repo.all(
      from(turn in Turn,
        join: episode in Episode,
        on: episode.id == turn.episode_id,
        where:
          episode.destination_transport == "control_plane" and
            episode.destination_conversation_ref == ^ref and
            episode.destination_thread_ref == ^ref and
            not is_nil(turn.delivery_document) and not is_nil(turn.accepted_at),
        order_by: [asc: turn.accepted_at, asc: turn.id],
        limit: @lab_message_limit,
        select: %{
          document: turn.delivery_document,
          occurred_at: turn.accepted_at,
          ref: turn.delivery_ref,
          status: turn.status
        }
      )
    )
  end

  defp lab_messages(inputs, replies) do
    input_messages =
      Enum.flat_map(inputs, fn input ->
        case input.content do
          %{"text" => text} when is_binary(text) ->
            [
              %{
                actor: :operator,
                artifact_refs: [],
                occurred_at: input.occurred_at,
                record_refs: [],
                ref: input.ref,
                state: nil,
                status: input.status,
                text: text
              }
            ]

          _not_local_text ->
            []
        end
      end)

    reply_messages = Enum.flat_map(replies, &lab_reply_message/1)

    (input_messages ++ reply_messages)
    |> Enum.sort_by(fn message ->
      actor_order = if message.actor == :operator, do: 0, else: 1
      {DateTime.to_unix(message.occurred_at, :microsecond), actor_order, message.ref || ""}
    end)
  end

  defp lab_reply_message(%{document: %{"message" => text} = document} = reply)
       when is_binary(text) do
    outcome = lab_reply_outcome(document)

    [
      %{
        actor: :responder,
        artifact_refs: bounded_refs(outcome["artifact_refs"]),
        occurred_at: reply.occurred_at,
        record_refs: bounded_refs(outcome["record_refs"]),
        ref: reply.ref,
        state: outcome["state"],
        status: reply.status,
        text: text
      }
    ]
  end

  defp lab_reply_message(_not_visible_reply), do: []

  defp lab_reply_outcome(%{"outcome" => %{} = outcome}), do: outcome
  defp lab_reply_outcome(_document), do: %{}

  defp bounded_refs(values) when is_list(values) do
    values
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) <= 1_024))
    |> Enum.take(64)
  end

  defp bounded_refs(_values), do: []

  defp lab_live?(inputs, episodes, replies) do
    Enum.any?(inputs, &(&1.status == :pending)) or
      Enum.any?(episodes, &(&1.state == :working or &1.next_action == "deliver_result")) or
      Enum.any?(replies, &(&1.status == :delivery_pending))
  end

  defp normalized_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp normalized_uuid(_value), do: :error

  defp lab_id(@lab_prefix <> id) do
    case normalized_uuid(id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> :error
    end
  end

  defp lab_id(_ref), do: :error

  defp needs_attention do
    waits =
      Repo.all(
        from(episode in Episode,
          where: episode.state == :waiting_for_input,
          order_by: [desc: episode.updated_at, desc: episode.id],
          limit: 10,
          select: %{
            kind: :operator_input,
            ref: episode.key,
            title: episode.key,
            updated_at: episode.updated_at
          }
        )
      )

    blocks =
      Repo.all(
        from(turn in Turn,
          join: episode in Episode,
          on:
            episode.id == turn.episode_id and episode.owner_kind == :turn and
              episode.owner_ref == turn.turn_ref,
          where: turn.status == :blocked and episode.state == :working,
          order_by: [desc: turn.updated_at, desc: turn.id],
          limit: 10,
          select: %{
            kind: :blocked_work,
            ref: episode.key,
            title: episode.key,
            updated_at: turn.updated_at
          }
        )
      )

    incident_blocks =
      Repo.all(
        from(room in IncidentRoom,
          where: room.status == :blocked,
          order_by: [desc: room.updated_at, desc: room.id],
          limit: 10,
          select: %{
            kind: :blocked_incident,
            ref: room.ref,
            title: room.title,
            updated_at: room.updated_at
          }
        )
      )

    (waits ++ blocks ++ incident_blocks)
    |> Enum.sort_by(&{DateTime.to_unix(&1.updated_at, :microsecond), &1.ref}, :desc)
    |> Enum.take(20)
    |> Enum.map(&Map.delete(&1, :updated_at))
  end

  defp next_action(%Episode{state: :waiting_for_input}, _turn_status, _coop_turn_id),
    do: "operator_input"

  defp next_action(%Episode{state: :waiting_for_event}, _turn_status, _coop_turn_id),
    do: "external_event"

  defp next_action(%Episode{owner_kind: :delivery}, _turn_status, _coop_turn_id),
    do: "deliver_result"

  defp next_action(_episode, :blocked, _coop_turn_id), do: "operator_recovery"
  defp next_action(_episode, :cancel_pending, _coop_turn_id), do: "reconcile_stop"
  defp next_action(%Episode{state: :complete}, _turn_status, _coop_turn_id), do: "complete"
  defp next_action(%Episode{state: :cancelled}, _turn_status, _coop_turn_id), do: "cancelled"
  defp next_action(_episode, _turn_status, nil), do: "start_work"
  defp next_action(_episode, _turn_status, _coop_turn_id), do: "continue_work"

  defp destination(episode) do
    case episode.destination_thread_ref do
      nil ->
        "#{episode.destination_transport}:#{episode.destination_conversation_ref}"

      thread ->
        "#{episode.destination_transport}:#{episode.destination_conversation_ref}:#{thread}"
    end
  end

  defp event_summary(kind) do
    kind |> Atom.to_string() |> String.replace("_", " ")
  end

  defp record_summary(%Record{subject_ref: subject}) when is_binary(subject), do: subject
  defp record_summary(%Record{operation_id: operation}), do: operation

  defp delivery_item(item) do
    %{
      action: :rearm,
      attempt_count: item.attempt_count,
      episode_id: Map.get(item, :episode_id),
      kind: "delivery",
      ref: item.delivery_ref,
      source: "#{item.kind} delivery",
      status: item.status,
      summary: item.error_code || "delivery blocked",
      updated_at: item.updated_at
    }
  end

  defp admission_item(%Entry{} = entry) do
    %{
      action: :rearm,
      attempt_count: entry.attempt_count,
      destination: failure_destination(entry),
      episode_id: entry.episode_id,
      kind: "admission",
      ref: Inbox.ref(entry),
      source: "#{entry.source_kind}:#{entry.source_ref} · #{entry.event_ref}",
      status: entry.status,
      summary: entry.last_error_code || "admission blocked",
      updated_at: entry.updated_at
    }
  end

  defp blocked_work(ref) do
    Repo.one(
      from(turn in Turn,
        join: episode in Episode,
        on:
          episode.id == turn.episode_id and episode.state == :working and
            episode.owner_kind == :turn and episode.owner_ref == turn.turn_ref,
        where: episode.key == ^ref and turn.status == :blocked and is_nil(turn.delivery_ref),
        select: {turn, episode}
      )
    )
  end

  defp work_item({%Turn{} = turn, %Episode{} = episode}) do
    %{
      action: :retry,
      attempt_count: max(turn.work_attempt_count, turn.cancel_attempt_count),
      destination: failure_destination(episode),
      episode_id: episode.id,
      episode_ref: episode.key,
      kind: "work",
      ref: episode.key,
      source: turn.execution_target,
      status: turn.status,
      summary: turn.last_error_code || "work blocked",
      updated_at: turn.updated_at
    }
  end

  defp interaction_item(%InteractionAudit{} = audit) do
    %{
      action: :rearm,
      attempt_count: audit.attempt_count,
      destination:
        join_target("slack:#{audit.workspace_ref}:#{audit.channel_ref}", audit.thread_ref),
      kind: "slack_interaction",
      ref: audit.event_ref,
      source: "#{audit.actor_ref} · #{audit.action_id}",
      status: audit.repaint_status,
      summary: audit.last_error_code || "Slack repaint blocked",
      updated_at: audit.updated_at
    }
  end

  defp incident_item(%IncidentRoom{} = room) do
    %{
      action: :rearm,
      attempt_count: room.attempt_count || 0,
      destination:
        join_target(
          "slack:#{room.workspace_ref}:#{room.source_channel_ref}",
          room.source_thread_ref
        ),
      episode_id: room.episode_id || room.source_episode_id,
      kind: "slack_incident",
      ref: room.ref,
      source: room.source_message_ref,
      status: room.status,
      summary: room.last_error_code || "Slack incident-room reconciliation blocked",
      updated_at: room.updated_at
    }
  end

  defp emisar_item(item) do
    %{
      action: :rearm,
      attempt_count: item.failure_count,
      episode_id: item.episode_id,
      kind: "emisar",
      ref: item.request_id,
      source: "#{item.runner_ref} · #{item.action_id}",
      status: item.status,
      summary: item.last_error || "Emisar approval monitoring blocked",
      updated_at: item.updated_at
    }
  end

  defp retention_item({%Session{} = session, %Episode{} = episode}) do
    %{
      action: :rearm,
      attempt_count: session.cleanup_attempt_count,
      destination: failure_destination(episode),
      episode_id: episode.id,
      episode_ref: episode.key,
      kind: "retention",
      ref: session.external_ref,
      source: session.repository_ref || "no repository",
      status: session.cleanup_status,
      summary: session.cleanup_last_error_code || "retention blocked",
      updated_at: session.updated_at
    }
  end

  defp decorate_failures(items) do
    items
    |> attach_input_contexts()
    |> attach_episode_contexts()
    |> Enum.map(&failure_defaults/1)
  end

  defp attach_input_contexts(items) do
    input_ids =
      items
      |> Enum.map(&Map.get(&1, :input_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    contexts =
      Repo.all(
        from(entry in Entry,
          where: entry.id in ^input_ids,
          select: {entry.id, entry}
        )
      )
      |> Map.new()

    Enum.map(items, fn item ->
      case Map.get(contexts, Map.get(item, :input_id)) do
        %Entry{} = entry ->
          item
          |> Map.put(:episode_id, entry.episode_id)
          |> Map.put(:destination, failure_destination(entry))
          |> Map.put(:source, "#{entry.source_kind}:#{entry.source_ref} · #{entry.event_ref}")

        nil ->
          item
      end
    end)
  end

  defp attach_episode_contexts(items) do
    episode_ids =
      items
      |> Enum.map(&Map.get(&1, :episode_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    contexts =
      Repo.all(
        from(episode in Episode,
          where: episode.id in ^episode_ids,
          select: {episode.id, episode}
        )
      )
      |> Map.new()

    Enum.map(items, fn item ->
      case Map.get(contexts, Map.get(item, :episode_id)) do
        %Episode{} = episode ->
          item
          |> Map.put_new(:episode_ref, episode.key)
          |> put_if_nil(:episode_ref, episode.key)
          |> Map.put_new(:destination, failure_destination(episode))
          |> put_if_nil(:destination, failure_destination(episode))

        nil ->
          item
      end
    end)
  end

  defp failure_defaults(item) do
    Map.merge(
      %{
        attempt_count: 0,
        destination: nil,
        episode_ref: nil,
        source: nil
      },
      item
    )
  end

  defp put_if_nil(map, key, value) do
    if is_nil(Map.get(map, key)), do: Map.put(map, key, value), else: map
  end

  defp failure_destination(%{destination_transport: transport} = owner) do
    conversation = owner.destination_conversation_ref

    target =
      if String.starts_with?(conversation, "#{transport}:"),
        do: conversation,
        else: "#{transport}:#{conversation}"

    join_target(target, owner.destination_thread_ref)
  end

  defp join_target(target, nil), do: target
  defp join_target(target, thread), do: "#{target} / #{thread}"

  defp workspace_item({%Session{} = session, episode_state}) do
    %{
      action: workspace_action(session),
      kind: "coop_session",
      ref: session.external_ref,
      state: episode_state,
      status: session.cleanup_status,
      summary:
        session.cleanup_last_error_code || session.retained_reason || session.repository_ref ||
          "no repository",
      updated_at: session.updated_at
    }
  end

  defp workspace_action(%Session{
         cleanup_status: :blocked,
         cleanup_blocked_from: blocked_from
       })
       when blocked_from in [:close_pending, :plan_pending, :discard_pending],
       do: :rearm

  defp workspace_action(%Session{
         cleanup_status: :retained,
         discard_plan: %{"workspace" => %{"dirty" => false, "unmerged" => true}},
         discard_plan_fingerprint: fingerprint,
         retained_reason: "unpublished_unmerged"
       })
       when is_binary(fingerprint),
       do: :discard_unmerged

  defp workspace_action(%Session{}), do: nil

  defp usage_query(nil),
    do: from(turn in Turn, where: not is_nil(turn.accepted_at))

  defp usage_query(%DateTime{} = since),
    do: from(turn in Turn, where: not is_nil(turn.accepted_at) and turn.accepted_at >= ^since)

  defp usage_totals(query) do
    totals =
      Repo.one(
        from(turn in query,
          select: %{
            attempts: count(turn.id),
            cached_input_tokens:
              type(
                fragment("COALESCE(SUM(?), 0)::bigint", turn.usage_cached_input_tokens),
                :integer
              ),
            cost_usd: fragment("COALESCE(SUM(?), 0)", turn.usage_cost_usd),
            costed:
              fragment(
                "COUNT(*) FILTER (WHERE ? = TRUE)",
                turn.usage_cost_recorded
              ),
            host_ms: type(fragment("COALESCE(SUM(?), 0)::bigint", turn.usage_host_ms), :integer),
            input_tokens:
              type(fragment("COALESCE(SUM(?), 0)::bigint", turn.usage_input_tokens), :integer),
            measurement_errors:
              fragment(
                "COUNT(*) FILTER (WHERE ? IS NOT NULL)",
                turn.measurement_error_code
              ),
            output_tokens:
              type(fragment("COALESCE(SUM(?), 0)::bigint", turn.usage_output_tokens), :integer),
            provider_ms:
              type(fragment("COALESCE(SUM(?), 0)::bigint", turn.usage_provider_ms), :integer),
            queued_ms:
              type(fragment("COALESCE(SUM(?), 0)::bigint", turn.usage_queued_ms), :integer),
            reasoning_tokens:
              type(
                fragment("COALESCE(SUM(?), 0)::bigint", turn.usage_reasoning_tokens),
                :integer
              ),
            timed: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.timing_recorded),
            usage_measured: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.usage_recorded)
          }
        )
      )

    total_input = totals.input_tokens + totals.cached_input_tokens

    totals
    |> Map.put(
      :cache_hit_rate,
      if(total_input > 0, do: Float.round(totals.cached_input_tokens / total_input, 4))
    )
    |> Map.put(:average_queued_ms, average(totals.queued_ms, totals.timed))
    |> Map.put(:average_provider_ms, average(totals.provider_ms, totals.timed))
    |> Map.put(:average_host_ms, average(totals.host_ms, totals.timed))
    |> Map.drop([:host_ms, :provider_ms, :queued_ms])
  end

  defp usage_targets(query) do
    Repo.all(
      from(turn in query,
        group_by: turn.execution_target,
        order_by: [desc: count(turn.id), asc: turn.execution_target],
        limit: 100,
        select: %{
          attempts: count(turn.id),
          cost_usd: fragment("COALESCE(SUM(?), 0)", turn.usage_cost_usd),
          costed: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.usage_cost_recorded),
          measured: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.usage_recorded),
          target: turn.execution_target,
          tokens:
            type(
              fragment(
                "(COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0))::bigint",
                turn.usage_input_tokens,
                turn.usage_cached_input_tokens,
                turn.usage_output_tokens,
                turn.usage_reasoning_tokens
              ),
              :integer
            )
        }
      )
    )
    |> Enum.map(fn row -> Map.merge(row, Measurement.target_parts(row.target)) end)
  end

  defp usage_channels(query) do
    Repo.all(
      from(turn in query,
        join: episode in Episode,
        on: episode.id == turn.episode_id,
        group_by: [episode.destination_transport, episode.destination_conversation_ref],
        order_by: [desc: count(turn.id), asc: episode.destination_transport],
        limit: 100,
        select: %{
          attempts: count(turn.id),
          conversation_ref: episode.destination_conversation_ref,
          cost_usd: fragment("COALESCE(SUM(?), 0)", turn.usage_cost_usd),
          costed: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.usage_cost_recorded),
          measured: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.usage_recorded),
          tokens:
            type(
              fragment(
                "(COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0))::bigint",
                turn.usage_input_tokens,
                turn.usage_cached_input_tokens,
                turn.usage_output_tokens,
                turn.usage_reasoning_tokens
              ),
              :integer
            ),
          transport: episode.destination_transport
        }
      )
    )
  end

  defp usage_repositories(query) do
    Repo.all(
      from(turn in query,
        join: session in Session,
        on: session.id == turn.session_id,
        group_by: session.repository_ref,
        order_by: [desc: count(turn.id), asc: session.repository_ref],
        limit: 100,
        select: %{
          attempts: count(turn.id),
          cost_usd: fragment("COALESCE(SUM(?), 0)", turn.usage_cost_usd),
          costed: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.usage_cost_recorded),
          measured: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.usage_recorded),
          repository_ref: session.repository_ref,
          tokens:
            type(
              fragment(
                "(COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0))::bigint",
                turn.usage_input_tokens,
                turn.usage_cached_input_tokens,
                turn.usage_output_tokens,
                turn.usage_reasoning_tokens
              ),
              :integer
            )
        }
      )
    )
  end

  defp usage_days(query) do
    Repo.all(
      from(turn in query,
        group_by: fragment("date(?)", turn.accepted_at),
        order_by: [asc: fragment("date(?)", turn.accepted_at)],
        limit: 366,
        select: %{
          attempts: count(turn.id),
          cost_usd: fragment("COALESCE(SUM(?), 0)", turn.usage_cost_usd),
          date: type(fragment("date(?)", turn.accepted_at), :date),
          measured: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.usage_recorded),
          tokens:
            type(
              fragment(
                "(COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0))::bigint",
                turn.usage_input_tokens,
                turn.usage_cached_input_tokens,
                turn.usage_output_tokens,
                turn.usage_reasoning_tokens
              ),
              :integer
            )
        }
      )
    )
  end

  defp average(_sum, 0), do: nil
  defp average(sum, count), do: div(sum, count)

  defp usage_window("24h"), do: {"24h", DateTime.add(database_now!(), -24, :hour)}
  defp usage_window("30d"), do: {"30d", DateTime.add(database_now!(), -30, :day)}
  defp usage_window("all"), do: {"all", nil}
  defp usage_window(_window), do: {"7d", DateTime.add(database_now!(), -7, :day)}

  defp page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page in 1..@maximum_page -> page
      _invalid -> 1
    end
  end

  defp page(_value), do: 1

  defp state("working"), do: :working
  defp state("waiting_for_input"), do: :waiting_for_input
  defp state("waiting_for_event"), do: :waiting_for_event
  defp state("complete"), do: :complete
  defp state("cancelled"), do: :cancelled
  defp state(_state), do: nil

  defp search(value) when is_binary(value) do
    value = String.trim(value)
    if value != "" and String.valid?(value) and byte_size(value) <= 120, do: value
  end

  defp search(_value), do: nil

  defp target(value) when is_binary(value) do
    value = String.trim(value)
    if value != "" and String.valid?(value) and byte_size(value) <= 512, do: value
  end

  defp target(_value), do: nil

  defp repository(value) when is_binary(value) do
    value = String.trim(value)
    if value != "" and String.valid?(value) and byte_size(value) <= 1_024, do: value
  end

  defp repository(_value), do: nil

  defp escape_like(value), do: String.replace(value, ["%", "_", "\\"], &"\\#{&1}")

  defp count(query), do: Repo.aggregate(query, :count, :id)

  defp database_now! do
    {:ok, %{rows: [[%DateTime{} = now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end
end
