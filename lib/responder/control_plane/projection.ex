defmodule Responder.ControlPlane.Projection do
  @moduledoc """
  Bounded, payload-minimizing read models for the local control plane.

  Raw ingress bodies, model prompts, credentials, and arbitrary state payloads
  never cross this boundary. Detail pages expose durable lifecycle metadata and
  typed record summaries only.
  """

  import Ecto.Query

  alias Responder.ControlPlane.{Activity, AdmissionProgress, InspectionRedactor}
  alias Responder.ControlPlane.CurrentInputs
  alias Responder.ControlPlane.ModelRequests

  alias Responder.Artifacts.OutputArtifact
  alias Responder.ControlPlane.{Card, CardLabDelivery, CardLabFeedback, EpisodeTrace}
  alias Responder.Delivery.Operator, as: DeliveryOperator
  alias Responder.Delivery.PlatformAction
  alias Responder.Delivery.Reaction
  alias Responder.Emisar.Operator, as: EmisarOperator
  alias Responder.Episodes.{Episode, Event, Reactions}
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Observability
  alias Responder.Operator.{Action, FailureDetail}
  alias Responder.Publication.Publication
  alias Responder.Repo
  alias Responder.Retention.OperatorAction
  alias Responder.Slack.{IncidentRoom, InteractionAudit, ThreadStatus}
  alias Responder.State.{Behavior, Memories, MemoryEntry, Record, Schedule}
  alias Responder.Work.{Measurement, Session, Turn}

  @page_size 50
  @maximum_page 10_000
  @active_states [:working, :waiting_for_input, :waiting_for_event]
  @lab_prefix "control-plane:lab:"
  @lab_message_limit 200
  @lab_record_limit 64

  @spec callbacks() :: map()
  def callbacks do
    %{
      activity: &Activity.list/1,
      admission: &admission/1,
      audit: &audit/1,
      calibration: &calibration/1,
      card_lab_feedback: &CardLabFeedback.list/2,
      card_lab_slack: &CardLabDelivery.snapshot/1,
      card_lab_post: &CardLabDelivery.fetch/1,
      channel: &channel/2,
      channels: &channels/1,
      configuration: &configuration/0,
      decisions: &decisions/1,
      delivery: &delivery/1,
      emisar: &emisar/1,
      episode: &episode/1,
      model_requests: &ModelRequests.project/2,
      admission_request: &ModelRequests.project_input/2,
      episodes: &episodes/1,
      failures: &failures/1,
      findings: &findings/1,
      incident: &incident/1,
      incidents: &incidents/1,
      lab_artifact: &lab_artifact/3,
      lab_conversation: &lab_conversation/1,
      lab_index: &lab_index/0,
      memory: &memory/0,
      overview: &overview/0,
      operator_configuration: &operator_configuration/0,
      repositories: &repositories/1,
      schedule: &schedule/1,
      schedules: &schedules/1,
      subscriptions: &subscriptions/1,
      usage: &usage/1,
      slack_incident: &slack_incident/1,
      slack_interaction: &slack_interaction/1,
      work: &work/1,
      workspace: &workspace/1,
      workspaces: &workspaces/1
    }
  end

  defdelegate calibration(params), to: Responder.ControlPlane.OperatorProjection
  defdelegate channel(workspace_ref, channel_ref), to: Responder.ControlPlane.OperatorProjection
  defdelegate channels(params), to: Responder.ControlPlane.OperatorProjection
  defdelegate incident(ref), to: Responder.ControlPlane.OperatorProjection
  defdelegate incidents(params), to: Responder.ControlPlane.OperatorProjection
  defdelegate operator_configuration(), to: Responder.ControlPlane.OperatorProjection
  defdelegate repositories(params), to: Responder.ControlPlane.OperatorProjection
  defdelegate schedule(ref), to: Responder.ControlPlane.OperatorProjection
  defdelegate schedules(params), to: Responder.ControlPlane.OperatorProjection
  defdelegate subscriptions(params), to: Responder.ControlPlane.OperatorProjection

  @doc """
  Lists recent loopback conversations without loading their message bodies.
  """
  def lab_index do
    Repo.all(
      from(entry in Entry,
        where:
          entry.destination_transport == "control_plane" and
            like(entry.destination_conversation_ref, ^"#{@lab_prefix}%") and
            entry.destination_thread_ref == entry.destination_conversation_ref,
        group_by: entry.destination_conversation_ref,
        order_by: [desc: max(entry.inserted_at), desc: entry.destination_conversation_ref],
        limit: 100,
        select: %{
          message_count: count(entry.native_input_id, :distinct),
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
    |> lab_directory_titles()
  end

  defp lab_directory_titles([]), do: []

  defp lab_directory_titles(items) do
    refs = Enum.map(items, & &1.ref)

    titles =
      Repo.all(
        from(entry in Entry,
          join: current in subquery(CurrentInputs.latest()),
          on:
            current.native_input_id == entry.native_input_id and
              current.execution_mode == entry.execution_mode,
          where:
            entry.destination_conversation_ref in ^refs and entry.source_kind == "control_plane",
          distinct: entry.destination_conversation_ref,
          order_by: [
            asc: entry.destination_conversation_ref,
            asc: entry.inserted_at,
            asc: entry.id
          ],
          select:
            {entry.destination_conversation_ref,
             fragment(
               "CASE WHEN ? IS NOT NULL THEN NULL WHEN ? = 'delete' THEN 'Message deleted' ELSE left(?::jsonb->>'text', 12000) END",
               current.operational_pruned_at,
               current.event_kind,
               current.content
             )}
        )
      )
      |> Map.new()

    secrets = InspectionRedactor.configured_secrets()

    Enum.map(items, fn item ->
      artifact =
        InspectionRedactor.artifact(titles[item.ref],
          secrets: secrets,
          max_bytes: 600
        )

      Map.put(
        item,
        :title,
        if(artifact.text in [nil, ""],
          do: "Conversation · #{Calendar.strftime(item.updated_at, "%d %b")}",
          else: String.slice(artifact.text, 0, 160)
        )
      )
    end)
  end

  @doc """
  Projects one local conversation from its durable ingress and accepted Work rows.

  Only exact local operator text, bounded integration-source markers, and
  accepted visible replies cross this read boundary. Prompts, candidates,
  arbitrary external payloads, credentials, and unreleased model output remain
  private.
  """
  def lab_conversation(conversation_id) do
    case normalized_uuid(conversation_id) do
      {:ok, conversation_id} -> project_lab_conversation(conversation_id)
      :error -> :not_found
    end
  end

  @doc false
  def lab_artifact(conversation_id, turn_id, artifact_ref)
      when is_binary(turn_id) and is_binary(artifact_ref) do
    with {:ok, conversation_id} <- normalized_uuid(conversation_id),
         {:ok, turn_id} <- normalized_uuid(turn_id),
         true <- Regex.match?(~r/\A[A-Za-z0-9_.:-]{1,256}\z/, artifact_ref),
         {artifact, delivery_document} when not is_nil(artifact) <-
           Repo.one(
             from(artifact in OutputArtifact,
               join: turn in Turn,
               on: turn.id == artifact.turn_id,
               join: episode in Episode,
               on: episode.id == turn.episode_id,
               where:
                 artifact.turn_id == ^turn_id and artifact.ref == ^artifact_ref and
                   episode.destination_transport == "control_plane" and
                   episode.destination_conversation_ref == ^(@lab_prefix <> conversation_id) and
                   episode.destination_thread_ref == ^(@lab_prefix <> conversation_id) and
                   not is_nil(turn.accepted_at) and not is_nil(turn.delivery_document),
               select: {artifact, turn.delivery_document}
             )
           ),
         true <- artifact_ref in lab_reply_outcome(delivery_document)["artifact_refs"] do
      {:ok,
       %{
         byte_size: artifact.byte_size,
         data: artifact.data,
         media_type: artifact.media_type,
         name: artifact.name,
         ref: artifact.ref,
         sha256: artifact.sha256
       }}
    else
      _missing_or_invalid -> :not_found
    end
  end

  def lab_artifact(_conversation_id, _turn_id, _artifact_ref), do: :not_found

  defp project_lab_conversation(conversation_id) do
    ref = @lab_prefix <> conversation_id
    inputs = lab_inputs(ref)
    input_queue = lab_input_queue(ref)
    episodes = lab_episodes(ref)

    if inputs == [] and episodes == [] do
      :not_found
    else
      replies = lab_replies(ref)
      cards = lab_cards(replies)
      artifacts = lab_output_artifacts(replies, conversation_id)
      publications = lab_publications(ref)
      actions = lab_platform_actions(ref)
      reactions = lab_delivery_reactions(ref)
      feedback_reactions = Reactions.current_for_episodes(Enum.map(episodes, & &1.id))

      blocked =
        input_queue.blocked > 0 or input_queue.reaction_blocked > 0 or
          Enum.any?(episodes, &(&1.work_status == :blocked)) or
          Enum.any?(actions, &(&1.status == :blocked))

      {:ok,
       %{
         blocked: blocked,
         admission_progress: AdmissionProgress.conversation(ref),
         conversation_id: conversation_id,
         conversation_ref: ref,
         episodes: episodes,
         live: lab_live?(input_queue, episodes, replies, publications, actions),
         messages:
           (lab_messages(
              inputs,
              replies,
              cards,
              artifacts,
              actions,
              reactions,
              feedback_reactions
            ) ++
              lab_publication_messages(publications))
           |> sort_lab_messages()
           |> Enum.take(-@lab_message_limit),
         pending: input_queue.pending
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
      fleet: fleet_overview(),
      needs_attention: needs_attention(),
      progress: %{
        admission: admission_progress(),
        slack_status: slack_status_progress()
      }
    }
  end

  defp admission_progress do
    Repo.one!(
      from(entry in Entry,
        select: %{
          admitting:
            type(
              fragment(
                "COUNT(*) FILTER (WHERE ? = 'pending' AND ? IS NOT NULL AND ? > clock_timestamp())::bigint",
                entry.status,
                entry.lease_ref,
                entry.lease_expires_at
              ),
              :integer
            ),
          blocked:
            type(
              fragment("COUNT(*) FILTER (WHERE ? = 'blocked')::bigint", entry.status),
              :integer
            ),
          oldest_active_ms:
            type(
              fragment(
                "GREATEST(0, COALESCE(EXTRACT(EPOCH FROM (clock_timestamp() - MIN(?) FILTER (WHERE ? = 'pending'))) * 1000, 0))::bigint",
                entry.inserted_at,
                entry.status
              ),
              :integer
            ),
          queued:
            type(
              fragment(
                "COUNT(*) FILTER (WHERE ? = 'pending' AND (? IS NULL OR ? <= clock_timestamp()) AND (? IS NULL OR ? <= clock_timestamp()))::bigint",
                entry.status,
                entry.lease_expires_at,
                entry.lease_expires_at,
                entry.next_attempt_at,
                entry.next_attempt_at
              ),
              :integer
            ),
          retrying:
            type(
              fragment(
                "COUNT(*) FILTER (WHERE ? = 'pending' AND (? IS NULL OR ? <= clock_timestamp()) AND ? > clock_timestamp())::bigint",
                entry.status,
                entry.lease_expires_at,
                entry.lease_expires_at,
                entry.next_attempt_at
              ),
              :integer
            )
        }
      )
    )
  end

  defp slack_status_progress do
    Repo.one!(
      from(status in ThreadStatus,
        select: %{
          oldest_pending_ms:
            type(
              fragment(
                "COALESCE(EXTRACT(EPOCH FROM (clock_timestamp() - MIN(?) FILTER (WHERE ? = 'pending'))) * 1000, 0)::bigint",
                status.updated_at,
                status.status
              ),
              :integer
            ),
          pending:
            type(
              fragment("COUNT(*) FILTER (WHERE ? = 'pending')::bigint", status.status),
              :integer
            )
        }
      )
    )
  end

  defp fleet_overview do
    case Observability.fleet() do
      {:ok, fleet} -> fleet
      {:error, _reason} -> %{required: true, unavailable: true}
    end
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
        event_records =
          Repo.all(
            from(event in Event,
              where: event.episode_id == ^episode.id,
              order_by: [desc: event.sequence],
              limit: 500
            )
          )
          |> Enum.reverse()

        events =
          Enum.map(event_records, fn event ->
            %{
              kind: event.kind,
              occurred_at: event.occurred_at,
              summary: event_summary(event.kind)
            }
          end)

        record_records =
          Repo.all(
            from(record in Record,
              where: record.episode_id == ^episode.id,
              order_by: [desc: record.sequence, desc: record.id],
              limit: 500
            )
          )
          |> Enum.reverse()

        records =
          Enum.map(record_records, fn record ->
            %{
              kind: record.kind,
              status: record.status,
              summary: record_summary(record)
            }
          end)

        trace = EpisodeTrace.project(episode, event_records, record_records)

        accounting =
          Responder.Accounting.Query.executions(nil, "all")
          |> where([execution], execution.episode_id == ^episode.id)
          |> usage_totals()

        {:ok,
         %{
           episode: %{
             created_at: episode.inserted_at,
             destination: destination(episode),
             next_action: trace.next_action,
             ref: episode.key,
             state: episode.state,
             updated_at: episode.updated_at
           },
           events: events,
           records: records,
           accounting: accounting,
           trace: trace
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

    with {:ok, delivery_items} <- DeliveryOperator.list_blocked(100),
         {:ok, emisar_items} <- EmisarOperator.list_blocked(100) do
      failures =
        work ++
          admission ++
          Enum.map(delivery_items, &delivery_item/1) ++
          retention ++
          interaction_feedback ++
          incident_rooms ++
          Enum.map(emisar_items, &emisar_item/1)

      {:ok,
       failures
       |> decorate_failures()
       |> Enum.sort_by(&DateTime.to_unix(&1.updated_at, :microsecond), :desc)
       |> Enum.take(100)}
    end
  rescue
    _error -> {:error, :failure_projection_unavailable}
  catch
    _kind, _reason -> {:error, :failure_projection_unavailable}
  end

  def failure(kind, ref) do
    failure_exact(kind, ref)
  rescue
    _error -> {:error, :failure_projection_unavailable}
  catch
    _kind, _reason -> {:error, :failure_projection_unavailable}
  end

  defp failure_exact("admission", ref), do: admission(ref)
  defp failure_exact("delivery", ref), do: delivery(ref)
  defp failure_exact("emisar", ref), do: emisar(ref)
  defp failure_exact("slack_incident", ref), do: slack_incident(ref)
  defp failure_exact("slack_interaction", ref), do: slack_interaction(ref)
  defp failure_exact("work", ref), do: work(ref)

  defp failure_exact("retention", ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(
           from(session in Session,
             join: episode in Episode,
             on: episode.id == session.episode_id,
             where: session.external_ref == ^ref and session.cleanup_status == :blocked,
             select: {session, episode}
           )
         ) do
      nil -> :not_found
      row -> {:ok, row |> retention_item() |> decorate_failure()}
    end
  end

  defp failure_exact(_kind, _ref), do: :not_found

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

    operator_events =
      Repo.all(
        from(action in Action,
          order_by: [desc: action.occurred_at, desc: action.id],
          limit: 100,
          select: %{
            kind: fragment("? || ':' || ?", action.action, action.kind),
            ref: action.action_ref,
            summary: fragment("? || ' · ' || ?", action.actor_ref, action.resource_ref),
            updated_at: action.occurred_at
          }
        )
      )

    (episode_events ++ interaction_events ++ retention_events ++ operator_events)
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
      reviews: Memories.pending_reviews(100),
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
    mode = if params["mode"] in ~w(shadow all), do: params["mode"], else: "live"
    query = Responder.Accounting.Query.executions(since, mode)

    %{
      channels: usage_channels(query),
      days: usage_days(query),
      repositories: usage_repositories(query),
      targets: usage_targets(query),
      executions: usage_executions(query, params),
      totals: usage_totals(query),
      mode: mode,
      window: window
    }
  end

  def usage(_params), do: usage(%{})

  defp lab_inputs(ref) do
    latest =
      from(entry in Entry,
        where:
          entry.destination_transport == "control_plane" and
            entry.destination_conversation_ref == ^ref and entry.destination_thread_ref == ^ref,
        distinct: entry.native_input_id,
        order_by: [
          asc: entry.native_input_id,
          desc: entry.revision,
          desc: entry.inserted_at,
          desc: entry.id
        ],
        select: %{
          content: entry.content,
          event_kind: entry.event_kind,
          id: entry.id,
          inserted_at: entry.inserted_at,
          ref: entry.event_ref,
          revision: entry.revision,
          source_kind: entry.source_kind,
          source_ref: entry.source_ref,
          source_item_ref: entry.source_item_ref,
          status: entry.status
        }
      )

    Repo.all(
      from(entry in subquery(latest),
        order_by: [desc: entry.inserted_at, desc: entry.id],
        limit: @lab_message_limit,
        select: %{
          content: entry.content,
          event_kind: entry.event_kind,
          occurred_at: entry.inserted_at,
          ref: entry.ref,
          revision: entry.revision,
          source_kind: entry.source_kind,
          source_ref: entry.source_ref,
          source_item_ref: entry.source_item_ref,
          status: entry.status
        }
      )
    )
  end

  defp lab_input_queue(ref) do
    entries =
      Repo.one(
        from(entry in Entry,
          where:
            entry.destination_transport == "control_plane" and
              entry.destination_conversation_ref == ^ref and
              entry.destination_thread_ref == ^ref,
          select: %{
            blocked: filter(count(entry.id), entry.status == :blocked),
            pending: filter(count(entry.id), entry.status == :pending)
          }
        )
      )

    reactions =
      Repo.one(
        from(reaction in Reaction,
          where:
            reaction.transport == "control_plane" and reaction.conversation_ref == ^ref and
              reaction.thread_ref == ^ref,
          select: %{
            blocked: filter(count(reaction.id), reaction.status == :blocked),
            pending: filter(count(reaction.id), reaction.status == :pending)
          }
        )
      )

    %{
      blocked: entries.blocked,
      pending: entries.pending,
      reaction_blocked: reactions.blocked,
      reaction_pending: reactions.pending
    }
  end

  defp lab_delivery_reactions(ref) do
    Repo.all(
      from(reaction in Reaction,
        where:
          reaction.transport == "control_plane" and reaction.conversation_ref == ^ref and
            reaction.thread_ref == ^ref,
        order_by: [asc: reaction.inserted_at, asc: reaction.id],
        limit: @lab_message_limit,
        select: %{
          delivery_ref: reaction.delivery_ref,
          emoji_name: fragment("(?::jsonb ->> 'emoji_name')", reaction.document),
          source_item_ref: reaction.source_item_ref,
          status: reaction.status
        }
      )
    )
    |> Enum.filter(&(is_binary(&1.emoji_name) and is_binary(&1.source_item_ref)))
    |> Enum.group_by(& &1.source_item_ref, &Map.delete(&1, :source_item_ref))
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
        id: episode.id,
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
        order_by: [desc: turn.accepted_at, desc: turn.id],
        limit: @lab_message_limit,
        select: %{
          document: turn.delivery_document,
          episode_id: turn.episode_id,
          external_receipt: turn.external_receipt,
          occurred_at: turn.accepted_at,
          ref: turn.delivery_ref,
          status: turn.status,
          turn_id: turn.id
        }
      )
    )
  end

  defp lab_publications(ref) do
    Repo.all(
      from(publication in Publication,
        join: record in Record,
        on: record.id == publication.record_id and record.episode_id == publication.episode_id,
        where:
          publication.destination_transport == "control_plane" and
            publication.destination_conversation_ref == ^ref and
            publication.destination_thread_ref == ^ref,
        order_by: [desc: publication.inserted_at, desc: publication.id],
        limit: @lab_message_limit,
        select: {publication, record.ref}
      )
    )
  end

  defp lab_platform_actions(ref) do
    Repo.all(
      from(action in PlatformAction,
        join: episode in Episode,
        on: episode.id == action.episode_id,
        where:
          action.transport == "control_plane" and action.conversation_ref == ^ref and
            episode.destination_transport == "control_plane" and
            episode.destination_conversation_ref == ^ref,
        order_by: [desc: action.inserted_at, desc: action.id],
        limit: @lab_message_limit,
        select: %{
          action_ref: action.action_ref,
          delivered_at: action.delivered_at,
          document: action.document,
          inserted_at: action.inserted_at,
          kind: action.kind,
          source_item_ref: action.source_item_ref,
          status: action.status,
          tool: action.tool
        }
      )
    )
  end

  defp lab_cards(replies) do
    pairs = lab_card_pairs(replies)

    refs = Enum.map(pairs, &elem(&1, 1))
    allowed = MapSet.new(pairs)

    refs
    |> lab_card_records()
    |> Enum.reduce(%{}, &put_lab_card(&1, &2, allowed))
  end

  defp lab_card_pairs(replies) do
    replies
    |> Enum.reverse()
    |> Enum.flat_map(fn reply ->
      reply.document
      |> lab_reply_outcome()
      |> Map.get("record_refs", [])
      |> bounded_refs()
      |> Enum.map(&{reply.turn_id, &1})
    end)
    |> Enum.uniq()
    |> Enum.take(@lab_record_limit)
  end

  defp lab_card_records([]), do: []

  defp lab_card_records(refs) do
    Repo.all(
      from(record in Record,
        where: record.ref in ^refs,
        limit: @lab_record_limit
      )
    )
  end

  defp put_lab_card(record, cards, allowed) do
    key = {record.turn_id, record.ref}

    if MapSet.member?(allowed, key),
      do: put_projected_lab_card(record, key, cards),
      else: cards
  end

  defp put_projected_lab_card(record, key, cards) do
    case Card.project(record) do
      {:ok, card} -> Map.put(cards, key, card)
      :ignore -> cards
    end
  end

  defp lab_output_artifacts(replies, conversation_id) do
    pairs =
      replies
      |> Enum.flat_map(fn reply ->
        reply.document
        |> lab_reply_outcome()
        |> Map.get("artifact_refs", [])
        |> bounded_refs()
        |> Enum.map(&{reply.turn_id, &1})
      end)
      |> Enum.uniq()
      |> Enum.take(@lab_message_limit * 5)

    turn_ids = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    allowed = MapSet.new(pairs)

    project_lab_output_artifacts(turn_ids, allowed, conversation_id)
  end

  defp project_lab_output_artifacts([], _allowed, _conversation_id), do: %{}

  defp project_lab_output_artifacts(turn_ids, allowed, conversation_id) do
    Repo.all(
      from(artifact in OutputArtifact,
        where: artifact.turn_id in ^turn_ids,
        limit: ^(@lab_message_limit * 5)
      )
    )
    |> Enum.reduce(%{}, &put_lab_output_artifact(&1, &2, allowed, conversation_id))
  end

  defp put_lab_output_artifact(artifact, projected, allowed, conversation_id) do
    key = {artifact.turn_id, artifact.ref}

    if MapSet.member?(allowed, key),
      do: Map.put(projected, key, lab_output_artifact(artifact, conversation_id)),
      else: projected
  end

  defp lab_output_artifact(artifact, conversation_id) do
    %{
      bytes: artifact.byte_size,
      media_type: artifact.media_type,
      name: artifact.name,
      path:
        "/lab/#{conversation_id}/turns/#{artifact.turn_id}/artifacts/#{URI.encode(artifact.ref, &URI.char_unreserved?/1)}",
      ref: artifact.ref,
      status: "available"
    }
  end

  defp lab_messages(
         inputs,
         replies,
         cards,
         artifacts,
         actions,
         delivery_reactions,
         feedback_reactions
       ) do
    action_reactions = lab_action_reactions(actions)

    input_messages =
      Enum.flat_map(inputs, fn input ->
        case input do
          %{
            content: %{"text" => text},
            source_kind: "control_plane",
            source_ref: "local"
          }
          when is_binary(text) ->
            deleted = input.event_kind == :delete

            [
              %{
                actor: :operator,
                artifact_refs: if(deleted, do: [], else: lab_input_artifact_refs(input.content)),
                attachments: if(deleted, do: [], else: lab_input_attachments(input.content)),
                cards: [],
                editable: not deleted,
                event_kind: input.event_kind,
                item_id: lab_item_id(input.source_item_ref),
                occurred_at: input.occurred_at,
                reactions:
                  Map.get(delivery_reactions, input.source_item_ref, []) ++
                    Map.get(action_reactions, input.source_item_ref, []),
                record_refs: [],
                ref: input.ref,
                revision: input.revision,
                state: nil,
                status: input.status,
                text: if(deleted, do: "Message deleted", else: text)
              }
            ]

          %{source_kind: source_kind, source_ref: source_ref}
          when is_binary(source_kind) and is_binary(source_ref) ->
            [lab_integration_message(input)]

          _invalid_source ->
            []
        end
      end)

    reply_messages =
      Enum.flat_map(replies, &lab_reply_message(&1, cards, artifacts, feedback_reactions))

    action_messages = Enum.flat_map(actions, &lab_action_message/1)

    sort_lab_messages(input_messages ++ reply_messages ++ action_messages)
  end

  defp lab_integration_message(input) do
    event_type =
      case input.content do
        %{"event_type" => value} when is_binary(value) -> lab_marker_component(value, "event")
        _other -> input.event_kind |> Atom.to_string() |> lab_marker_component("event")
      end

    %{
      actor: :integration,
      artifact_refs: [],
      attachments: [],
      cards: [],
      editable: false,
      event_kind: input.event_kind,
      item_id: nil,
      occurred_at: input.occurred_at,
      reactions: [],
      record_refs: [],
      ref: input.ref,
      revision: input.revision,
      state: nil,
      status: input.status,
      text:
        "#{lab_source_label(input.source_kind)} #{lab_marker_component(input.source_ref, "integration")} · #{event_type} · revision #{input.revision}"
    }
  end

  defp lab_source_label("webhook"), do: "Webhook"

  defp lab_source_label(source_kind) do
    source_kind
    |> lab_marker_component("Integration")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp lab_marker_component(value, fallback) when is_binary(value) do
    case value |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 160) do
      "" -> fallback
      component -> component
    end
  end

  defp lab_marker_component(_value, fallback), do: fallback

  defp lab_action_reactions(actions) do
    actions
    |> Enum.filter(fn action ->
      action.kind == :reaction and is_binary(action.source_item_ref) and
        is_map(action.document) and is_binary(action.document["emoji_name"])
    end)
    |> Enum.group_by(
      & &1.source_item_ref,
      fn action ->
        %{
          delivery_ref: action.action_ref,
          emoji_name: action.document["emoji_name"],
          status: action.status
        }
      end
    )
  end

  defp lab_action_message(%{
         action_ref: action_ref,
         delivered_at: %DateTime{} = delivered_at,
         document: %{"message" => message},
         kind: :message,
         status: :delivered,
         tool: :post_slack_message
       })
       when is_binary(action_ref) and is_binary(message) do
    [
      %{
        actor: :responder,
        artifact_refs: [],
        attachments: [],
        cards: [],
        occurred_at: delivered_at,
        reactions: [],
        record_refs: [],
        ref: action_ref,
        state: nil,
        status: :delivered,
        text: message
      }
    ]
  end

  defp lab_action_message(_action), do: []

  defp lab_publication_messages(publications) do
    Enum.flat_map(publications, &lab_publication_message/1)
  end

  defp lab_publication_message(
         {%Publication{status: status, review_delivery_receipt: receipt} = publication,
          record_ref}
       )
       when status in [:reviewed, :blocked] and is_map(receipt) do
    project_lab_publication_message(
      publication,
      record_ref,
      receipt,
      publication_review_message(status)
    )
  end

  defp lab_publication_message(
         {%Publication{status: :published, published_delivery_receipt: receipt} = publication,
          record_ref}
       )
       when is_map(receipt) do
    project_lab_publication_message(
      publication,
      record_ref,
      receipt,
      "Published the exact reviewed candidate as a draft pull request."
    )
  end

  defp lab_publication_message(_not_delivered), do: []

  defp project_lab_publication_message(publication, record_ref, receipt, message) do
    case Card.project_publication(publication, record_ref) do
      {:ok, card} -> [publication_message(publication, receipt, card, message)]
      :ignore -> []
    end
  end

  defp publication_review_message(:reviewed) do
    "The committed change passed trusted review. Publish this exact candidate only after reviewing the host-owned details."
  end

  defp publication_review_message(:blocked) do
    "The committed change is not publishable. Review the trusted findings below."
  end

  defp publication_message(publication, receipt, card, message) do
    occurred_at =
      if publication.status == :published,
        do: publication.published_at || publication.updated_at || publication.inserted_at,
        else: publication.reviewed_at || publication.updated_at || publication.inserted_at

    %{
      actor: :responder,
      artifact_refs: [],
      attachments: [],
      cards: [card],
      occurred_at: occurred_at,
      record_refs: [],
      ref: receipt["delivery_ref"],
      state: nil,
      status: publication.status,
      text: message
    }
  end

  defp sort_lab_messages(messages) do
    Enum.sort_by(messages, fn message ->
      actor_order = if message.actor == :operator, do: 0, else: 1
      {DateTime.to_unix(message.occurred_at, :microsecond), actor_order, message.ref || ""}
    end)
  end

  defp lab_reply_message(
         %{document: %{"message" => text} = document} = reply,
         cards,
         artifacts,
         feedback_reactions
       )
       when is_binary(text) do
    outcome = lab_reply_outcome(document)
    record_refs = bounded_refs(outcome["record_refs"])
    artifact_refs = bounded_refs(outcome["artifact_refs"])

    [
      %{
        actor: :responder,
        artifact_refs: artifact_refs,
        attachments:
          Enum.flat_map(artifact_refs, fn ref ->
            case Map.get(artifacts, {reply.turn_id, ref}) do
              %{} = artifact -> [artifact]
              _missing -> []
            end
          end),
        cards:
          Enum.flat_map(record_refs, fn ref ->
            case Map.get(cards, {reply.turn_id, ref}) do
              %{} = card -> [card]
              _missing -> []
            end
          end),
        feedback_reactions: Map.get(feedback_reactions, reply.ref, []),
        message_ref: lab_reply_message_ref(reply),
        occurred_at: reply.occurred_at,
        record_refs: record_refs,
        ref: reply.ref,
        state: outcome["state"],
        status: reply.status,
        text: text
      }
    ]
  end

  defp lab_reply_message(_not_visible_reply, _cards, _artifacts, _feedback_reactions), do: []

  defp lab_reply_message_ref(%{
         status: :settled,
         external_receipt: %{
           "conversation_ref" => conversation_ref,
           "message_ref" => message_ref,
           "transport" => "control_plane"
         }
       })
       when is_binary(conversation_ref) and is_binary(message_ref),
       do: message_ref

  defp lab_reply_message_ref(_reply), do: nil

  defp lab_item_id("control-plane-item:" <> item_id) do
    case Ecto.UUID.cast(item_id) do
      {:ok, normalized} -> normalized
      :error -> nil
    end
  end

  defp lab_item_id(_source_item_ref), do: nil

  defp lab_input_artifact_refs(content) do
    content
    |> lab_input_attachments()
    |> Enum.flat_map(fn
      %{ref: ref, status: "available"} when is_binary(ref) -> [ref]
      _unavailable -> []
    end)
  end

  defp lab_input_attachments(%{"files" => files}) when is_list(files) do
    files
    |> Enum.take(2)
    |> Enum.flat_map(fn
      %{
        "artifact_ref" => ref,
        "bytes" => bytes,
        "media_type" => media_type,
        "name" => name,
        "status" => "available"
      }
      when is_binary(ref) and is_integer(bytes) and bytes > 0 and is_binary(media_type) and
             is_binary(name) ->
        [
          %{
            bytes: bytes,
            media_type: media_type,
            name: name,
            ref: ref,
            status: "available"
          }
        ]

      %{"reason" => reason, "status" => "unavailable"} when is_binary(reason) ->
        [%{bytes: nil, media_type: nil, name: "Attachment", ref: nil, status: reason}]

      _invalid ->
        []
    end)
  end

  defp lab_input_attachments(_content), do: []

  defp lab_reply_outcome(%{"outcome" => %{} = outcome}), do: outcome
  defp lab_reply_outcome(_document), do: %{}

  defp bounded_refs(values) when is_list(values) do
    values
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) <= 1_024))
    |> Enum.take(64)
  end

  defp bounded_refs(_values), do: []

  defp lab_live?(input_queue, episodes, replies, publications, actions) do
    input_queue.pending > 0 or input_queue.reaction_pending > 0 or
      Enum.any?(
        episodes,
        &(&1.next_action in [
            "start_work",
            "continue_work",
            "reconcile_stop",
            "deliver_result",
            "external_event"
          ])
      ) or
      Enum.any?(replies, &(&1.status == :delivery_pending)) or
      Enum.any?(actions, &(&1.status == :pending)) or
      Enum.any?(publications, fn {publication, _record_ref} ->
        publication.status in [:review_pending, :review_ready, :publish_pending, :published_ready]
      end)
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
      detail: FailureDetail.project(item.error_detail),
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
      detail: FailureDetail.project(entry.last_error_detail),
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
      detail: FailureDetail.project(turn.last_error_detail),
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
      detail: FailureDetail.project(audit.last_error_detail),
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
      detail: FailureDetail.project(room.last_error_detail),
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
      detail: FailureDetail.project(item.last_error),
      episode_id: item.episode_id,
      kind: "emisar",
      ref: item.request_id,
      source: "#{item.runner_ref} · #{item.action_id}",
      status: item.status,
      summary: "Emisar approval monitoring blocked",
      updated_at: item.updated_at
    }
  end

  defp retention_item({%Session{} = session, %Episode{} = episode}) do
    %{
      action: :rearm,
      attempt_count: session.cleanup_attempt_count,
      detail: FailureDetail.project(session.cleanup_last_error_detail),
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

  defp decorate_failure(item), do: item |> List.wrap() |> decorate_failures() |> hd()

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
        detail: nil,
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

  defp usage_totals(query) do
    totals =
      Repo.one(
        from(turn in query,
          select: %{
            attempts: count(turn.id),
            admission: fragment("COUNT(*) FILTER (WHERE ? = 'admission')", turn.kind),
            work: fragment("COUNT(*) FILTER (WHERE ? = 'work')", turn.kind),
            unsuccessful:
              fragment(
                "COUNT(*) FILTER (WHERE ? IN ('failed', 'interrupted', 'budget_exhausted', 'cancelled'))",
                turn.status
              ),
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

  defp usage_executions(query, params) do
    selected_page = page(params["page"])

    rows =
      Repo.all(
        from(execution in query,
          order_by: [desc: execution.recorded_at, desc: execution.id],
          offset: ^((selected_page - 1) * @page_size),
          limit: ^(@page_size + 1),
          select:
            map(execution, [
              :id,
              :source_id,
              :kind,
              :episode_id,
              :generation,
              :status,
              :recorded_at,
              :execution_target,
              :usage_recorded,
              :usage_cost_recorded,
              :usage_cost_usd,
              :usage_input_tokens,
              :usage_output_tokens
            ])
        )
      )

    %{items: Enum.take(rows, @page_size), page: selected_page, more: length(rows) > @page_size}
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
        group_by: [turn.transport, turn.conversation_ref],
        order_by: [desc: count(turn.id), asc: turn.transport],
        limit: 100,
        select: %{
          attempts: count(turn.id),
          conversation_ref: turn.conversation_ref,
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
          transport: turn.transport
        }
      )
    )
  end

  defp usage_repositories(query) do
    Repo.all(
      from(turn in query,
        group_by: turn.repository_ref,
        order_by: [desc: count(turn.id), asc: turn.repository_ref],
        limit: 100,
        select: %{
          attempts: count(turn.id),
          cost_usd: fragment("COALESCE(SUM(?), 0)", turn.usage_cost_usd),
          costed: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.usage_cost_recorded),
          measured: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.usage_recorded),
          repository_ref: turn.repository_ref,
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
        group_by: fragment("date(?)", turn.recorded_at),
        order_by: [asc: fragment("date(?)", turn.recorded_at)],
        limit: 366,
        select: %{
          attempts: count(turn.id),
          cost_usd: fragment("COALESCE(SUM(?), 0)", turn.usage_cost_usd),
          date: type(fragment("date(?)", turn.recorded_at), :date),
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
