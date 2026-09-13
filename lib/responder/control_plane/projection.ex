defmodule Responder.ControlPlane.Projection do
  @moduledoc """
  Bounded, payload-minimizing read models for the local control plane.

  Raw ingress bodies, model prompts, credentials, and arbitrary state payloads
  never cross this boundary. Detail pages expose durable lifecycle metadata and
  typed record summaries only.
  """

  import Ecto.Query

  alias Responder.ControlPlane.{Activity, AdmissionProgress, InspectionRedactor, UsageProjection}
  alias Responder.ControlPlane.BehaviorLibrary
  alias Responder.ControlPlane.ChannelDetail
  alias Responder.ControlPlane.ConversationMemory
  alias Responder.ControlPlane.CurrentInputs
  alias Responder.ControlPlane.InstructionSettings
  alias Responder.ControlPlane.ModelRequests
  alias Responder.ControlPlane.SettingsView
  alias Responder.ControlPlane.WorkRecovery

  alias Responder.Artifacts.OutputArtifact
  alias Responder.ControlPlane.{Card, EpisodeTrace, LabCursor}
  alias Responder.CoopFleet.Worker, as: FleetWorker
  alias Responder.Delivery.Operator, as: DeliveryOperator
  alias Responder.Delivery.PlatformAction
  alias Responder.Delivery.Reaction
  alias Responder.Emisar.Operator, as: EmisarOperator
  alias Responder.Episodes.{Episode, Event, Reactions}
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Observability
  alias Responder.Operator.FailureDetail
  alias Responder.Publication.Publication
  alias Responder.Repo
  alias Responder.Retention.Custody, as: RetentionCustody
  alias Responder.Slack.{IncidentRoom, InteractionAudit, ThreadStatus}
  alias Responder.State.{Behavior, Memories, MemoryEntry, Record, Schedule}
  alias Responder.Work.{Session, Turn}

  @episode_record_limit 500
  @maximum_page 10_000
  @active_states [:working, :waiting_for_input, :waiting_for_event]
  @lab_prefix "control-plane:lab:"
  # One transcript page. A page is a window onto retained history, not a cap:
  # older pages are reached through `lab_history/3` with the previous page's
  # boundary cursor. Until 2026-09-13 a 200-row window was the whole view.
  @lab_page_size 50
  @lab_page_maximum 200
  @lab_record_limit 64

  @spec callbacks() :: map()
  def callbacks do
    %{
      activity: &Activity.list/1,
      behavior: &BehaviorLibrary.fetch/1,
      behaviors: &BehaviorLibrary.list/2,
      admission: &admission/1,
      channel: &ChannelDetail.fetch/3,
      channels: &channels/1,
      instructions: &InstructionSettings.fetch/1,
      configuration: &configuration/0,
      settings: &SettingsView.fetch/0,
      delivery: &delivery/1,
      emisar: &emisar/1,
      episode: &episode/2,
      model_requests: &ModelRequests.project/2,
      model_timeline: &ModelRequests.timeline/2,
      admission_request: &ModelRequests.project_input/2,
      failures: &failures/1,
      findings: &findings/1,
      incident: &incident/1,
      incidents: &incidents/1,
      lab_artifact: &lab_artifact/3,
      lab_changes: &lab_changes/3,
      lab_conversation: &lab_conversation/1,
      lab_history: &lab_history/3,
      lab_index: &lab_index/0,
      memory: &memory/1,
      overview: &overview/0,
      operator_configuration: &operator_configuration/0,
      repositories: &repositories/1,
      schedule: &schedule/1,
      schedules: &schedules/1,
      subscriptions: &subscriptions/1,
      usage: &usage/1,
      usage_filter_options: &UsageProjection.filter_options/0,
      slack_incident: &slack_incident/1,
      slack_interaction: &slack_interaction/1,
      work: &work/1,
      workspace: &workspace/1,
      workspace_storage: &workspace_storage/0,
      workspaces: &workspaces/1
    }
  end

  defdelegate channel(workspace_ref, channel_ref, params), to: ChannelDetail, as: :fetch
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

  `messages` is the latest page of the merged transcript in display order;
  `history` carries the boundary cursor for `lab_history/3` and whether older
  retained history exists. Processing state is measured on its own, never
  from the rows that happen to be on the page.
  """
  def lab_conversation(conversation_id) do
    case normalized_uuid(conversation_id) do
      {:ok, conversation_id} -> project_lab_conversation(conversation_id)
      :error -> :not_found
    end
  end

  @doc """
  One page of retained transcript older than `cursor`, newest page first.

  A `nil` cursor reads the latest page. Each returned message carries its own
  `cursor` and `sort_key`; `before` is the boundary for the next older page and
  is `nil` exactly when `exhausted` is true. A cursor that is malformed or was
  issued for another conversation is refused rather than interpreted.
  """
  def lab_history(conversation_id, cursor, limit \\ @lab_page_size)

  def lab_history(conversation_id, cursor, limit)
      when is_integer(limit) and limit in 1..@lab_page_maximum do
    with {:ok, conversation_id} <- normalized_uuid(conversation_id),
         {:ok, boundary} <- lab_boundary_key(cursor, conversation_id),
         true <- lab_conversation_exists?(@lab_prefix <> conversation_id) do
      {:ok, lab_page(conversation_id, boundary, limit)}
    else
      :error -> :not_found
      false -> :not_found
      {:error, :invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  def lab_history(_conversation_id, _cursor, _limit), do: {:error, :invalid_cursor}

  @doc "How many transcript rows one history page holds."
  @spec lab_page_size() :: pos_integer()
  def lab_page_size, do: @lab_page_size

  @doc false
  def lab_artifact(conversation_id, turn_id, artifact_ref)
      when is_binary(turn_id) and is_binary(artifact_ref) do
    with {:ok, conversation_id} <- normalized_uuid(conversation_id),
         {:ok, turn_id} <- normalized_uuid(turn_id),
         true <- Regex.match?(~r/\A[A-Za-z0-9_.:-]{1,256}\z/, artifact_ref),
         %OutputArtifact{} = artifact <-
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
                   not is_nil(turn.accepted_at) and not is_nil(turn.delivery_document) and
                   is_nil(turn.operational_pruned_at),
               select: artifact
             )
           ) do
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
    episodes = lab_episodes(ref)

    if episodes == [] and not lab_conversation_exists?(ref) do
      :not_found
    else
      input_queue = lab_input_queue(ref)
      deliveries = lab_delivery_state(ref)
      page = lab_page(conversation_id, nil, @lab_page_size)

      blocked =
        input_queue.blocked > 0 or input_queue.reaction_blocked > 0 or
          Enum.any?(episodes, &(&1.work_status == :blocked)) or
          deliveries.actions_blocked

      {:ok,
       %{
         blocked: blocked,
         admission_progress: AdmissionProgress.conversation(ref),
         conversation_id: conversation_id,
         conversation_ref: ref,
         episodes: episodes,
         history: %{before: page.before, exhausted: page.exhausted, page_size: @lab_page_size},
         live: lab_live?(input_queue, episodes, deliveries),
         messages: page.messages,
         pending: input_queue.pending
       }}
    end
  end

  defp lab_conversation_exists?(ref) do
    Repo.exists?(
      from(entry in Entry,
        where:
          entry.destination_transport == "control_plane" and
            entry.destination_conversation_ref == ^ref and entry.destination_thread_ref == ^ref
      )
    ) or
      Repo.exists?(
        from(episode in Episode,
          where:
            episode.destination_transport == "control_plane" and
              episode.destination_conversation_ref == ^ref and
              episode.destination_thread_ref == ^ref
        )
      )
  end

  # The boundary a cursor names, or nil for the latest page. The identity in
  # a cursor must match its rank's shape, so a rank-1 cursor can only ever be
  # compared with turn identifiers.
  defp lab_boundary_key(nil, _conversation_id), do: {:ok, nil}

  defp lab_boundary_key(cursor, conversation_id) do
    with {:ok, {_micros, rank, identity} = key} <- LabCursor.decode(cursor, conversation_id),
         {:ok, _value} <- lab_identity_value(rank, identity) do
      {:ok, key}
    else
      _invalid -> {:error, :invalid_cursor}
    end
  end

  defp lab_identity_value(0, "input:" <> native_input_id) when byte_size(native_input_id) > 0,
    do: {:ok, native_input_id}

  defp lab_identity_value(1, "reply:" <> id), do: normalized_uuid(id)
  defp lab_identity_value(2, "action:" <> id), do: normalized_uuid(id)
  defp lab_identity_value(3, "publication:" <> id), do: normalized_uuid(id)
  defp lab_identity_value(_rank, _identity), do: :error

  # Every source contributes its `limit + 1` newest rows older than the
  # boundary; the true next page is the newest `limit` of their union, and one
  # spare candidate says whether anything older remains. The boundary is the
  # oldest candidate on the page even when that candidate renders nothing, so
  # an invisible row can never hide the rows behind it.
  defp lab_page(conversation_id, boundary, limit) do
    ref = @lab_prefix <> conversation_id
    lookahead = limit + 1

    candidates =
      lab_candidates(
        ref,
        %{
          input: lab_inputs_older(lab_page_boundary(boundary, :input)),
          reply: lab_replies_older(lab_page_boundary(boundary, :reply)),
          action: lab_actions_older(lab_page_boundary(boundary, :action)),
          publication: lab_publications_older(lab_page_boundary(boundary, :publication))
        },
        lookahead
      )

    more? = length(candidates) > limit
    window = Enum.take(candidates, limit)

    before =
      case {more?, List.last(window)} do
        {true, {key, _kind, _row}} -> LabCursor.encode(conversation_id, key)
        _exhausted_or_empty -> nil
      end

    %{
      before: before,
      exhausted: not more?,
      messages: lab_window_messages(window, conversation_id)
    }
  end

  # Every source's rows matching its filter, newest first, each with the key
  # that places it in the merged transcript.
  defp lab_candidates(ref, filters, limit) do
    Enum.concat([
      ref |> lab_page_inputs(filters.input, limit) |> Enum.map(&{:input, &1}),
      ref |> lab_page_replies(filters.reply, limit) |> Enum.map(&{:reply, &1}),
      ref |> lab_page_actions(filters.action, limit) |> Enum.map(&{:action, &1}),
      ref |> lab_page_publications(filters.publication, limit) |> Enum.map(&{:publication, &1})
    ])
    |> Enum.map(fn {kind, row} -> {lab_candidate_key(kind, row), kind, row} end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
  end

  @doc """
  The current representation of every transcript row that changed at or
  after `since`: a new or revised input, a reaction on one, an accepted or
  confirmed reply, a card whose record moved, a delivered platform message or
  a publication that advanced. Bounded per source; ascending display order.

  This is how a live window learns about a row it holds that is no longer on
  the latest page, such as an edit to a message the reader scrolled up to.
  """
  def lab_changes(conversation_id, since, limit \\ @lab_page_size)

  def lab_changes(conversation_id, %DateTime{} = since, limit)
      when is_integer(limit) and limit in 1..@lab_page_maximum do
    case normalized_uuid(conversation_id) do
      {:ok, conversation_id} ->
        ref = @lab_prefix <> conversation_id

        candidates =
          lab_candidates(
            ref,
            %{
              input: lab_changed_inputs(ref, since, limit),
              reply: lab_changed_replies(ref, since, limit),
              action: lab_changed_actions(ref, since, limit),
              publication: lab_changed_publications(ref, since, limit)
            },
            limit * 2
          )

        {:ok, lab_window_messages(candidates, conversation_id)}

      :error ->
        :not_found
    end
  end

  def lab_changes(_conversation_id, _since, _limit), do: :not_found

  defp lab_changed_inputs(ref, since, limit) do
    revised = lab_revised_input_ids(ref, since, limit)
    reacted = lab_reacted_item_refs(ref, since, limit)

    if revised == [] and reacted == [],
      do: dynamic(false),
      else:
        dynamic(
          [entry, first],
          entry.native_input_id in ^revised or entry.source_item_ref in ^reacted
        )
  end

  defp lab_revised_input_ids(ref, since, limit) do
    Repo.all(
      from(entry in Entry,
        where:
          entry.destination_transport == "control_plane" and
            entry.destination_conversation_ref == ^ref and
            entry.destination_thread_ref == ^ref and
            (entry.inserted_at >= ^since or entry.operational_pruned_at >= ^since),
        distinct: true,
        select: entry.native_input_id,
        limit: ^limit
      )
    )
  end

  defp lab_reacted_item_refs(ref, since, limit) do
    Repo.all(
      from(reaction in Reaction,
        where:
          reaction.transport == "control_plane" and reaction.conversation_ref == ^ref and
            reaction.updated_at >= ^since and not is_nil(reaction.source_item_ref),
        distinct: true,
        select: reaction.source_item_ref,
        limit: ^limit
      )
    ) ++
      Repo.all(
        from(action in PlatformAction,
          where:
            action.transport == "control_plane" and action.conversation_ref == ^ref and
              action.kind == :reaction and action.updated_at >= ^since and
              not is_nil(action.source_item_ref),
          distinct: true,
          select: action.source_item_ref,
          limit: ^limit
        )
      )
  end

  defp lab_changed_replies(ref, since, limit) do
    turn_ids =
      lab_updated_turn_ids(ref, since, limit) ++ lab_moved_record_turn_ids(ref, since, limit)

    delivery_refs = lab_reacted_delivery_refs(ref, since, limit)

    if turn_ids == [] and delivery_refs == [],
      do: dynamic(false),
      else: dynamic([turn], turn.id in ^turn_ids or turn.delivery_ref in ^delivery_refs)
  end

  defp lab_updated_turn_ids(ref, since, limit) do
    Repo.all(
      from(turn in Turn,
        join: episode in Episode,
        on: episode.id == turn.episode_id,
        where:
          episode.destination_transport == "control_plane" and
            episode.destination_conversation_ref == ^ref and
            episode.destination_thread_ref == ^ref and turn.updated_at >= ^since,
        select: turn.id,
        limit: ^limit
      )
    )
  end

  defp lab_moved_record_turn_ids(ref, since, limit) do
    Repo.all(
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        where:
          episode.destination_transport == "control_plane" and
            episode.destination_conversation_ref == ^ref and
            episode.destination_thread_ref == ^ref and record.updated_at >= ^since and
            not is_nil(record.turn_id),
        distinct: true,
        select: record.turn_id,
        limit: ^limit
      )
    )
  end

  defp lab_reacted_delivery_refs(ref, since, limit) do
    Repo.all(
      from(event in Event,
        join: episode in Episode,
        on: episode.id == event.episode_id,
        where:
          episode.destination_transport == "control_plane" and
            episode.destination_conversation_ref == ^ref and
            episode.destination_thread_ref == ^ref and event.kind == :reaction_recorded and
            event.inserted_at >= ^since,
        select: fragment("?::jsonb ->> 'target_delivery_ref'", event.payload),
        limit: ^limit
      )
    )
    |> Enum.filter(&is_binary/1)
  end

  defp lab_changed_actions(ref, since, limit) do
    case Repo.all(
           from(action in PlatformAction,
             where:
               action.transport == "control_plane" and action.conversation_ref == ^ref and
                 action.kind == :message and action.updated_at >= ^since,
             select: action.id,
             limit: ^limit
           )
         ) do
      [] -> dynamic(false)
      ids -> dynamic([action], action.id in ^ids)
    end
  end

  defp lab_changed_publications(ref, since, limit) do
    case Repo.all(
           from(publication in Publication,
             where:
               publication.destination_transport == "control_plane" and
                 publication.destination_conversation_ref == ^ref and
                 publication.destination_thread_ref == ^ref and
                 publication.updated_at >= ^since,
             select: publication.id,
             limit: ^limit
           )
         ) do
      [] -> dynamic(false)
      ids -> dynamic([publication], publication.id in ^ids)
    end
  end

  defp lab_candidate_key(:input, row),
    do: LabCursor.key(row.position, :input, "input:" <> row.native_input_id)

  defp lab_candidate_key(:reply, row),
    do: LabCursor.key(row.occurred_at, :reply, "reply:" <> row.turn_id)

  defp lab_candidate_key(:action, row),
    do: LabCursor.key(row.delivered_at, :action, "action:" <> row.id)

  defp lab_candidate_key(:publication, {publication, _record_ref}),
    do:
      LabCursor.key(
        publication_position(publication),
        :publication,
        "publication:" <> publication.id
      )

  defp lab_window_messages(window, conversation_id) do
    rows = Enum.group_by(window, &elem(&1, 1), &elem(&1, 2))
    inputs = Map.get(rows, :input, [])
    replies = Map.get(rows, :reply, [])
    actions = Map.get(rows, :action, [])
    publications = Map.get(rows, :publication, [])
    item_refs = inputs |> Enum.map(& &1.source_item_ref) |> Enum.filter(&is_binary/1)

    reactions =
      Map.merge(
        lab_delivery_reactions(item_refs),
        lab_input_reaction_actions(item_refs),
        fn _item_ref, delivered, acted -> delivered ++ acted end
      )

    messages =
      lab_messages(
        inputs,
        replies,
        lab_cards(replies),
        lab_output_artifacts(replies, conversation_id),
        actions,
        reactions,
        Reactions.current_for_episodes(Enum.uniq(Enum.map(replies, & &1.episode_id)))
      ) ++ lab_publication_messages(publications)

    messages
    |> attach_lab_execution()
    |> Enum.map(&put_lab_cursor(&1, conversation_id))
    |> sort_lab_messages()
  end

  defp put_lab_cursor(%{sort_key: key} = message, conversation_id),
    do: Map.put(message, :cursor, LabCursor.encode(conversation_id, key))

  # The execution an operator message started, as it stands now: the episode's
  # state, or "blocked" when its owning turn is, so a message whose model work
  # stopped says so beside the message and offers the same retry /failures
  # does. Complete work carries nothing; the reply already sits below it.
  defp attach_lab_execution(messages) do
    episode_ids =
      messages
      |> Enum.filter(&(&1.actor == :operator and is_binary(&1[:episode_id])))
      |> Enum.map(& &1.episode_id)
      |> Enum.uniq()

    executions =
      if episode_ids == [] do
        %{}
      else
        Repo.all(
          from(episode in Episode,
            left_join: turn in Turn,
            on:
              turn.episode_id == episode.id and turn.turn_ref == episode.owner_ref and
                episode.owner_kind == :turn,
            where: episode.id in ^episode_ids,
            select: %{
              id: episode.id,
              key: episode.key,
              state:
                fragment(
                  "CASE WHEN ? = 'blocked' THEN 'blocked' ELSE ?::text END",
                  turn.status,
                  episode.state
                )
            }
          )
        )
        |> Map.new(fn row -> {row.id, %{key: row.key, state: row.state}} end)
      end

    Enum.map(messages, fn message ->
      case message do
        %{actor: :operator, episode_id: id} when is_binary(id) ->
          Map.put(message, :execution, Map.get(executions, id))

        _other ->
          message
      end
    end)
  end

  # Keyset conditions per source. `own` is the rank of the source being read;
  # rows sharing the boundary's microsecond fall before it exactly when their
  # rank is lower, or equal with a smaller identity.
  defp lab_page_boundary(nil, _kind), do: :all

  defp lab_page_boundary({micros, rank, identity}, kind) do
    position = DateTime.from_unix!(micros, :microsecond)
    own = LabCursor.rank(kind)

    cond do
      own < rank ->
        {:before_or_at, position}

      own > rank ->
        {:before, position}

      true ->
        {:ok, value} = lab_identity_value(rank, identity)
        {:before_or_tie, position, value}
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

  def episode(ref, params \\ %{})

  def episode(ref, params) when is_binary(ref) and byte_size(ref) <= 1_024 and is_map(params) do
    ref = ModelRequests.episode_ref(ref)

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
              limit: @episode_record_limit
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

        trace =
          EpisodeTrace.project(episode, event_records, record_records,
            disclosed: ModelRequests.disclosed(params),
            activity_pages: activity_pages(params)
          )

        accounting =
          Responder.Accounting.Query.executions(nil, "all")
          |> where([execution], execution.episode_id == ^episode.id)
          |> usage_totals()

        {:ok,
         %{
           episode: %{
             created_at: episode.inserted_at,
             destination: destination(episode),
             conversation_ref: episode.destination_conversation_ref,
             thread_ref: episode.destination_thread_ref,
             # The identity a card needs to read evidence recorded against this
             # episode; the key is the reader-facing reference and cannot be
             # joined on.
             id: episode.id,
             transport: episode.destination_transport,
             next_action: trace.next_action,
             ref: episode.key,
             state: episode.state,
             updated_at: episode.updated_at
           },
           events: events,
           records: records,
           related_episodes: related_episodes(episode),
           accounting: accounting,
           trace: trace
         }}
    end
  end

  def episode(_ref, _params), do: :not_found

  # Loading older activity is an explicit, bounded step the reader takes. The
  # page keeps its position: the events already read are still the same rows
  # with the same identities, with older ones appended before them.
  defp activity_pages(%{"events" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {pages, ""} when pages in 1..10 -> pages
      _invalid -> 1
    end
  end

  defp activity_pages(_params), do: 1

  defp related_episodes(episode) do
    related =
      Repo.all(
        from(other in Episode,
          where: other.destination_transport == ^episode.destination_transport,
          where: other.destination_conversation_ref == ^episode.destination_conversation_ref,
          where:
            other.linked_episode_id == ^episode.id or
              other.id == ^(episode.linked_episode_id || episode.id),
          where: other.id != ^episode.id,
          order_by: [asc: other.inserted_at, asc: other.id],
          limit: 21
        )
      )

    titles = Activity.request_titles(Enum.map(related, & &1.key))

    %{
      truncated: length(related) > 20,
      items:
        Enum.map(Enum.take(related, 20), fn other ->
          %{
            ref: other.key,
            title: get_in(titles, [other.key, :title]) || "Earlier request",
            href: "/timeline/" <> URI.encode_www_form(other.key),
            at: other.inserted_at,
            state: other.state,
            relation:
              if(other.id == episode.linked_episode_id,
                do: "Previous episode",
                else: "Follow-up episode"
              )
          }
        end)
    }
  end

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

    publications =
      Repo.all(
        from(publication in Publication,
          join: episode in Episode,
          on: episode.id == publication.episode_id,
          where:
            publication.status not in [:published, :discarded] and
              not is_nil(publication.last_error_code),
          order_by: [desc: publication.updated_at, desc: publication.id],
          limit: 100,
          select: {publication, episode}
        )
      )
      |> Enum.map(&publication_item/1)

    with {:ok, delivery_items} <- DeliveryOperator.list_blocked(100),
         {:ok, emisar_items} <- EmisarOperator.list_blocked(100) do
      failures =
        work ++
          admission ++
          Enum.map(delivery_items, &delivery_item/1) ++
          retention ++
          interaction_feedback ++
          incident_rooms ++
          publications ++
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

  defp failure_exact("publication", ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(
           from(publication in Publication,
             join: episode in Episode,
             on: episode.id == publication.episode_id,
             where:
               publication.ref == ^ref and publication.status not in [:published, :discarded] and
                 not is_nil(publication.last_error_code),
             select: {publication, episode}
           )
         ) do
      nil -> :not_found
      row -> {:ok, row |> publication_item() |> decorate_failure()}
    end
  end

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
        select: {session, episode.state, episode.key}
      )
    )
    |> Enum.map(&workspace_item/1)
    |> with_request_titles()
  end

  def workspace(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(
           from(session in Session,
             join: episode in Episode,
             on: episode.id == session.episode_id,
             where: session.external_ref == ^ref,
             select: {session, episode.state, episode.key}
           )
         ) do
      nil -> :not_found
      row -> {:ok, row |> workspace_item() |> then(&with_request_titles([&1])) |> hd()}
    end
  end

  def workspace(_ref), do: :not_found

  @doc """
  Read-only workspace storage accounting and the exact next cleanup targets.

  Preview never mutates anything and never estimates a byte no worker measured:
  a worker that reported nothing is unknown, and a worker whose heartbeat has
  gone stale is reporting a stale measurement.
  """
  @spec workspace_storage() :: map()
  def workspace_storage do
    now = database_now!()
    settings = Application.get_env(:responder, :retention, %{})

    %{
      budget:
        Map.new(
          ~w(disposable_bytes_limit reclaim_target_seconds storage_high_watermark_bytes
             storage_low_watermark_bytes storage_reserve_bytes)a,
          &{&1, safe_setting(settings, &1)}
        ),
      preview: Enum.map(RetentionCustody.eligible_preview(now, 25), &preview_item(&1, now)),
      workers:
        from(worker in FleetWorker, order_by: [asc: worker.id])
        |> Repo.all()
        |> Enum.map(&storage_item(&1, now))
    }
  end

  defp safe_setting(settings, key) when is_map(settings), do: Map.get(settings, key)
  defp safe_setting(_settings, _key), do: nil

  defp storage_item(%FleetWorker{} = worker, now) do
    storage = worker.storage

    %{
      allocation: storage && storage["allocation"],
      bytes:
        Map.new(
          ~w(capacity_bytes free_bytes reserve_bytes disposable_bytes protected_bytes
             unattributed_bytes),
          &{&1, storage && storage[&1]}
        ),
      id: worker.id,
      last_seen_at: worker.last_seen_at,
      measured_at: storage && storage["measured_at"],
      measurement: measurement_state(worker, now),
      reclaimed_bytes: worker.storage_reclaimed_bytes,
      refusal_reason: storage && storage["refusal_reason"],
      state: worker.state
    }
  end

  defp measurement_state(%FleetWorker{storage: storage}, _now) when not is_map(storage),
    do: :unknown

  defp measurement_state(%FleetWorker{last_seen_at: %DateTime{} = last_seen_at}, now) do
    if DateTime.diff(now, last_seen_at, :second) <= 60, do: :fresh, else: :stale
  end

  defp measurement_state(_worker, _now), do: :stale

  defp preview_item({%Session{} = session, eligible_at}, now) do
    %{
      eligible_age_seconds: age_seconds(now, eligible_at),
      kind: session.execution_kind,
      reason: preview_reason(session.cleanup_status),
      ref: session.external_ref,
      repository: session.repository_ref,
      status: session.cleanup_status,
      target: session.coop_session_id
    }
  end

  defp preview_reason(:active), do: "close the remote session"
  defp preview_reason(:close_pending), do: "retry the exact close"
  defp preview_reason(:grace), do: "grace expired; ask Coop for a discard plan"
  defp preview_reason(:plan_pending), do: "retry the exact discard plan"
  defp preview_reason(:discard_pending), do: "discard the planned workspace"
  defp preview_reason(:retained), do: "replan from fresh workspace evidence"
  defp preview_reason(status), do: Atom.to_string(status)

  defp age_seconds(_now, nil), do: 0

  defp age_seconds(%DateTime{} = now, %NaiveDateTime{} = value),
    do: max(NaiveDateTime.diff(DateTime.to_naive(now), value, :second), 0)

  defp age_seconds(now, value), do: max(DateTime.diff(now, value, :second), 0)

  def findings(params) do
    query = from(record in Record, where: record.kind == "finding")
    total = Repo.aggregate(query, :count)
    pages = max(div(total + 29, 30), 1)
    page = min(page(params["page"]), pages)

    rows =
      Repo.all(
        from(record in query,
          join: episode in Episode,
          on: episode.id == record.episode_id,
          order_by: [desc: record.inserted_at, desc: record.id],
          limit: 30,
          offset: ^((page - 1) * 30),
          select: {record, episode.key}
        )
      )

    secrets = InspectionRedactor.configured_secrets()

    refs =
      Enum.flat_map(rows, fn {record, _} -> Map.get(record.payload, "cause_evidence", []) end)

    episode_ids = Enum.map(rows, fn {record, _} -> record.episode_id end)
    visible_records = visible_episode_records(episode_ids)

    evidence =
      Repo.all(
        from(record in Record,
          where:
            record.kind == "evidence" and record.ref in ^refs and
              record.episode_id in ^episode_ids
        )
      )
      |> Map.new(&{{&1.episode_id, &1.ref}, &1})

    %{
      total: total,
      page: page,
      pages: pages,
      items: Enum.map(rows, &finding_item(&1, evidence, visible_records, secrets))
    }
  end

  defp visible_episode_records(episode_ids) do
    ranked =
      from(record in Record,
        where: record.episode_id in ^episode_ids,
        select: %{
          id: record.id,
          position:
            over(row_number(),
              partition_by: record.episode_id,
              order_by: [desc: record.sequence, desc: record.id]
            )
        }
      )

    Repo.all(
      from(record in subquery(ranked),
        where: record.position <= @episode_record_limit,
        select: record.id
      )
    )
    |> MapSet.new()
  end

  defp finding_record_path(path, record_id, visible_records) do
    if MapSet.member?(visible_records, record_id),
      do: path <> "#event-record-" <> record_id,
      else: path
  end

  defp finding_item({record, episode_key}, evidence, visible_records, secrets) do
    payload = finding_payload(record.payload, secrets)
    path = "/timeline/" <> URI.encode_www_form(episode_key)
    refs = Map.get(record.payload, "cause_evidence", [])

    %{
      id: record.id,
      at: record.inserted_at,
      what: payload["what"] || "Finding content is unavailable",
      classification: payload["status"],
      reason: payload["reason"],
      scope: payload["scope"],
      path: finding_record_path(path, record.id, visible_records),
      evidence:
        Enum.map(refs, fn ref ->
          case Map.get(evidence, {record.episode_id, ref}) do
            nil ->
              %{text: "Supporting evidence is no longer available.", path: nil, label: nil}

            item ->
              %{
                text:
                  finding_payload(item.payload, secrets)["observation"] ||
                    "Evidence content is unavailable.",
                path: finding_record_path(path, item.id, visible_records),
                label:
                  if(MapSet.member?(visible_records, item.id),
                    do: "View recorded evidence",
                    else: "Open source investigation"
                  )
              }
          end
        end)
    }
  end

  defp finding_payload(payload, secrets) do
    case InspectionRedactor.artifact(payload, secrets: secrets).text do
      text when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, %{} = value} -> value
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp with_request_titles(rows) do
    titles =
      rows
      |> Enum.map(&Map.get(&1, :episode_ref))
      |> Enum.reject(&is_nil/1)
      |> Activity.request_titles()

    Enum.map(rows, fn row ->
      case Map.get(titles, row[:episode_ref]) do
        nil ->
          row

        title ->
          Map.merge(row, %{request_title: title.title, request_conversation: title.conversation})
      end
    end)
  end

  def memory(params \\ %{}) do
    now = database_now!()

    %{
      conversation_memory: ConversationMemory.project(params),
      behaviors:
        Repo.all(
          from(behavior in Behavior,
            where:
              behavior.status in [:active, :disabled] and
                (is_nil(behavior.expires_at) or behavior.expires_at > ^now),
            order_by: [desc: behavior.updated_at, desc: behavior.id],
            limit: 500,
            select: %{
              kind: behavior.kind,
              ref: behavior.ref,
              status: behavior.status,
              subject:
                fragment(
                  "COALESCE(?::jsonb->>'title', ?::jsonb->>'subject', ?::jsonb->>'key', ?::jsonb->>'task', ?)",
                  behavior.payload,
                  behavior.payload,
                  behavior.payload,
                  behavior.payload,
                  behavior.identity_key
                )
            }
          )
        ),
      memories:
        Repo.all(
          from(memory in MemoryEntry,
            where:
              memory.status == :active and
                (is_nil(memory.expires_at) or memory.expires_at > ^now),
            order_by: [desc: memory.updated_at, desc: memory.id],
            limit: 100,
            select: %{
              kind: memory.kind,
              ref: memory.ref,
              scope: memory.scope_kind,
              applicability: fragment("?::jsonb->>'applicability'", memory.payload),
              value: fragment("?::jsonb->>'value'", memory.payload),
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
    mode = if params["mode"] in ~w(live shadow), do: params["mode"], else: "all"
    query = Responder.Accounting.Query.executions(since, mode)

    UsageProjection.snapshot(query)
    |> Map.merge(%{mode: mode, window: window})
  end

  def usage(_params), do: usage(%{})

  # One row per logical input: its current revision, positioned where its
  # first revision entered the conversation. An edit or delete changes what
  # the row says and records `edited_at`; it never moves the row.
  defp lab_page_inputs(ref, filter, limit) do
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
          decision_action: entry.decision_action,
          episode_id: entry.episode_id,
          event_kind: entry.event_kind,
          id: entry.id,
          inserted_at: entry.inserted_at,
          native_input_id: entry.native_input_id,
          pruned_at: entry.operational_pruned_at,
          ref: entry.event_ref,
          revision: entry.revision,
          source_kind: entry.source_kind,
          source_ref: entry.source_ref,
          source_item_ref: entry.source_item_ref,
          status: entry.status
        }
      )

    positions =
      from(entry in Entry,
        where:
          entry.destination_transport == "control_plane" and
            entry.destination_conversation_ref == ^ref and entry.destination_thread_ref == ^ref,
        group_by: entry.native_input_id,
        select: %{native_input_id: entry.native_input_id, position: min(entry.inserted_at)}
      )

    Repo.all(
      from(entry in subquery(latest),
        join: first in subquery(positions),
        on: first.native_input_id == entry.native_input_id,
        where: ^filter,
        order_by: [desc: first.position, desc: fragment("? COLLATE \"C\"", entry.native_input_id)],
        limit: ^limit,
        # The current revision's own row identity, episode link and decision
        # travel with the message: an inspection link built from them opens
        # exactly this revision's admission, never the original's or the
        # newest episode's.
        select: %{
          content: entry.content,
          decision_action: entry.decision_action,
          edited_at: entry.inserted_at,
          episode_id: entry.episode_id,
          event_kind: entry.event_kind,
          id: entry.id,
          native_input_id: entry.native_input_id,
          position: first.position,
          pruned_at: entry.pruned_at,
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

  defp lab_inputs_older(:all), do: dynamic(true)
  defp lab_inputs_older({:before_or_at, at}), do: dynamic([entry, first], first.position <= ^at)
  defp lab_inputs_older({:before, at}), do: dynamic([entry, first], first.position < ^at)

  defp lab_inputs_older({:before_or_tie, at, native_input_id}) do
    dynamic(
      [entry, first],
      first.position < ^at or
        (first.position == ^at and
           fragment("? COLLATE \"C\"", entry.native_input_id) < ^native_input_id)
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

  defp lab_delivery_reactions([]), do: %{}

  defp lab_delivery_reactions(item_refs) do
    Repo.all(
      from(reaction in Reaction,
        where: reaction.transport == "control_plane" and reaction.source_item_ref in ^item_refs,
        order_by: [asc: reaction.inserted_at, asc: reaction.id],
        limit: ^(@lab_page_maximum * 4),
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

  defp lab_input_reaction_actions([]), do: %{}

  defp lab_input_reaction_actions(item_refs) do
    Repo.all(
      from(action in PlatformAction,
        where:
          action.transport == "control_plane" and action.kind == :reaction and
            action.source_item_ref in ^item_refs,
        order_by: [asc: action.inserted_at, asc: action.id],
        limit: ^(@lab_page_maximum * 4),
        select: %{
          action_ref: action.action_ref,
          document: action.document,
          source_item_ref: action.source_item_ref,
          status: action.status
        }
      )
    )
    |> Enum.filter(&(is_map(&1.document) and is_binary(&1.document["emoji_name"])))
    |> Enum.group_by(& &1.source_item_ref, fn action ->
      %{
        delivery_ref: action.action_ref,
        emoji_name: action.document["emoji_name"],
        status: action.status
      }
    end)
  end

  # Whether anything in this conversation is still being delivered, measured
  # over the whole conversation rather than the page on screen.
  defp lab_delivery_state(ref) do
    %{
      actions_blocked: lab_action_status?(ref, :blocked),
      actions_pending: lab_action_status?(ref, :pending),
      publications_pending:
        Repo.exists?(
          from(publication in Publication,
            where:
              publication.destination_transport == "control_plane" and
                publication.destination_conversation_ref == ^ref and
                publication.destination_thread_ref == ^ref and
                publication.status in [
                  :review_pending,
                  :review_ready,
                  :publish_pending,
                  :published_ready
                ]
          )
        ),
      replies_pending:
        Repo.exists?(
          from(turn in Turn,
            join: episode in Episode,
            on: episode.id == turn.episode_id,
            where:
              episode.destination_transport == "control_plane" and
                episode.destination_conversation_ref == ^ref and
                episode.destination_thread_ref == ^ref and
                turn.status == :delivery_pending and not is_nil(turn.delivery_document)
          )
        )
    }
  end

  defp lab_action_status?(ref, status) do
    Repo.exists?(
      from(action in PlatformAction,
        where:
          action.transport == "control_plane" and action.conversation_ref == ^ref and
            action.status == ^status
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
        id: episode.id,
        next_action: next_action(episode, turn_status, coop_turn_id),
        ref: episode.key,
        state: episode.state,
        updated_at: episode.updated_at,
        work_status: turn_status
      }
    end)
  end

  # Accepted replies, positioned at acceptance. A pruned reply keeps its row
  # and reads as expired; only an unaccepted or invisible result is absent.
  defp lab_page_replies(ref, filter, limit) do
    Repo.all(
      from(turn in Turn,
        join: episode in Episode,
        on: episode.id == turn.episode_id,
        where:
          episode.destination_transport == "control_plane" and
            episode.destination_conversation_ref == ^ref and
            episode.destination_thread_ref == ^ref and
            not is_nil(turn.delivery_document) and not is_nil(turn.accepted_at) and
            fragment(
              "(jsonb_typeof(?::jsonb -> 'message') = 'string' OR ?::jsonb ->> 'retention' = 'pruned')",
              turn.delivery_document,
              turn.delivery_document
            ),
        where: ^filter,
        order_by: [desc: turn.accepted_at, desc: turn.id],
        limit: ^limit,
        select: %{
          document: turn.delivery_document,
          episode_id: turn.episode_id,
          episode_ref: episode.key,
          external_receipt: turn.external_receipt,
          occurred_at: turn.accepted_at,
          pruned_at: turn.operational_pruned_at,
          ref: turn.delivery_ref,
          status: turn.status,
          turn_id: turn.id
        }
      )
    )
  end

  defp lab_replies_older(:all), do: dynamic(true)
  defp lab_replies_older({:before_or_at, at}), do: dynamic([turn], turn.accepted_at <= ^at)
  defp lab_replies_older({:before, at}), do: dynamic([turn], turn.accepted_at < ^at)

  defp lab_replies_older({:before_or_tie, at, turn_id}) do
    dynamic(
      [turn],
      turn.accepted_at < ^at or (turn.accepted_at == ^at and turn.id < ^turn_id)
    )
  end

  # The delivery a publication currently shows, as SQL. It must agree with
  # `publication_position/1`, which computes the same value for the cursor.
  defmacrop publication_position_sql(publication) do
    quote do
      fragment(
        "COALESCE(CASE WHEN ? = 'published' THEN ? END, ?, ?, ?)",
        unquote(publication).status,
        unquote(publication).published_at,
        unquote(publication).reviewed_at,
        unquote(publication).updated_at,
        unquote(publication).inserted_at
      )
    end
  end

  # A publication is one logical row that advances from reviewed to
  # published; its position is the delivery it currently shows.
  defp lab_page_publications(ref, filter, limit) do
    Repo.all(
      from(publication in Publication,
        join: record in Record,
        on: record.id == publication.record_id and record.episode_id == publication.episode_id,
        where:
          publication.destination_transport == "control_plane" and
            publication.destination_conversation_ref == ^ref and
            publication.destination_thread_ref == ^ref and
            ((publication.status in [:reviewed, :blocked] and
                not is_nil(publication.review_delivery_receipt)) or
               (publication.status == :published and
                  not is_nil(publication.published_delivery_receipt))),
        where: ^filter,
        order_by: [desc: publication_position_sql(publication), desc: publication.id],
        limit: ^limit,
        select: {publication, record.ref}
      )
    )
  end

  defp lab_publications_older(:all), do: dynamic(true)

  defp lab_publications_older({:before_or_at, at}),
    do: dynamic([publication], publication_position_sql(publication) <= ^at)

  defp lab_publications_older({:before, at}),
    do: dynamic([publication], publication_position_sql(publication) < ^at)

  defp lab_publications_older({:before_or_tie, at, publication_id}) do
    dynamic(
      [publication],
      publication_position_sql(publication) < ^at or
        (publication_position_sql(publication) == ^at and publication.id < ^publication_id)
    )
  end

  defp publication_position(publication) do
    if publication.status == :published,
      do: publication.published_at || publication.updated_at || publication.inserted_at,
      else: publication.reviewed_at || publication.updated_at || publication.inserted_at
  end

  # Delivered platform messages, positioned at delivery.
  defp lab_page_actions(ref, filter, limit) do
    Repo.all(
      from(action in PlatformAction,
        join: episode in Episode,
        on: episode.id == action.episode_id,
        where:
          action.transport == "control_plane" and action.conversation_ref == ^ref and
            episode.destination_transport == "control_plane" and
            episode.destination_conversation_ref == ^ref and
            action.kind == :message and action.status == :delivered and
            action.tool == :post_slack_message and not is_nil(action.delivered_at),
        where: ^filter,
        order_by: [desc: action.delivered_at, desc: action.id],
        limit: ^limit,
        select: %{
          action_ref: action.action_ref,
          delivered_at: action.delivered_at,
          document: action.document,
          episode_ref: episode.key,
          id: action.id,
          kind: action.kind,
          status: action.status,
          tool: action.tool
        }
      )
    )
  end

  defp lab_actions_older(:all), do: dynamic(true)
  defp lab_actions_older({:before_or_at, at}), do: dynamic([action], action.delivered_at <= ^at)
  defp lab_actions_older({:before, at}), do: dynamic([action], action.delivered_at < ^at)

  defp lab_actions_older({:before_or_tie, at, action_id}) do
    dynamic(
      [action],
      action.delivered_at < ^at or (action.delivered_at == ^at and action.id < ^action_id)
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
    replies
    |> Enum.map(& &1.turn_id)
    |> Enum.uniq()
    |> project_lab_output_artifacts(conversation_id)
  end

  defp project_lab_output_artifacts([], _conversation_id), do: %{}

  defp project_lab_output_artifacts(turn_ids, conversation_id) do
    Repo.all(
      from(artifact in OutputArtifact,
        where: artifact.turn_id in ^turn_ids,
        order_by: [asc: artifact.name, asc: artifact.ref],
        limit: ^(@lab_page_maximum * 5)
      )
    )
    |> Map.new(&{{&1.turn_id, &1.ref}, lab_output_artifact(&1, conversation_id)})
  end

  defp lab_output_artifact(artifact, conversation_id) do
    %{
      bytes: artifact.byte_size,
      media_type: artifact.media_type,
      name: artifact.name,
      path:
        "/conversations/#{conversation_id}/turns/#{artifact.turn_id}/artifacts/#{URI.encode(artifact.ref, &URI.char_unreserved?/1)}",
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
         reactions,
         feedback_reactions
       ) do
    input_messages =
      Enum.flat_map(inputs, fn input ->
        case input do
          %{pruned_at: %DateTime{}, source_kind: "control_plane", source_ref: "local"} ->
            [lab_expired_input_message(input)]

          %{
            content: %{"text" => text},
            source_kind: "control_plane",
            source_ref: "local"
          }
          when is_binary(text) ->
            deleted = input.event_kind == :delete

            [
              lab_input_identity(input, %{
                actor: :operator,
                artifact_refs: if(deleted, do: [], else: lab_input_artifact_refs(input.content)),
                attachments: if(deleted, do: [], else: lab_input_attachments(input.content)),
                cards: [],
                editable: not deleted,
                event_kind: input.event_kind,
                item_id: lab_item_id(input.source_item_ref),
                reactions: Map.get(reactions, input.source_item_ref, []),
                record_refs: [],
                ref: input.ref,
                retained: true,
                revision: input.revision,
                state: nil,
                status: input.status,
                text: if(deleted, do: "Message deleted", else: text)
              })
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

  # Position, identity and sort key of one logical input: where its first
  # revision entered the conversation, named by the durable input id.
  # The exact provenance rides along: the current revision's own row id, its
  # episode link and decision, so the page can link this message's own
  # admission or recorded decision, and the native input id so admission
  # progress can sit beside the message that caused it.
  defp lab_input_identity(input, message) do
    Map.merge(message, %{
      decision_action: input.decision_action,
      edited_at: if(input.revision > 1, do: input.edited_at),
      episode_id: input.episode_id,
      identity: "input:" <> input.native_input_id,
      input_id: input.id,
      native_input_id: input.native_input_id,
      occurred_at: input.position,
      sort_key: LabCursor.key(input.position, :input, "input:" <> input.native_input_id)
    })
  end

  # Retention replaced the body. The row stays where the message was so the
  # transcript never reads as shorter than it was, and nothing can edit it.
  defp lab_expired_input_message(input) do
    lab_input_identity(input, %{
      actor: :operator,
      artifact_refs: [],
      attachments: [],
      cards: [],
      editable: false,
      event_kind: input.event_kind,
      item_id: lab_item_id(input.source_item_ref),
      reactions: [],
      record_refs: [],
      ref: input.ref,
      retained: false,
      revision: input.revision,
      state: nil,
      status: input.status,
      text: "This message expired under retention."
    })
  end

  defp lab_integration_message(input) do
    event_type =
      case input.content do
        %{"event_type" => value} when is_binary(value) -> lab_marker_component(value, "event")
        _other -> input.event_kind |> Atom.to_string() |> lab_marker_component("event")
      end

    lab_input_identity(input, %{
      actor: :integration,
      artifact_refs: [],
      attachments: [],
      cards: [],
      editable: false,
      event_kind: input.event_kind,
      item_id: nil,
      reactions: [],
      record_refs: [],
      ref: input.ref,
      retained: is_nil(input.pruned_at),
      revision: input.revision,
      state: nil,
      status: input.status,
      text:
        "#{lab_source_label(input.source_kind)} #{lab_marker_component(input.source_ref, "integration")} · #{event_type} · revision #{input.revision}"
    })
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

  defp lab_action_message(
         %{
           action_ref: action_ref,
           delivered_at: %DateTime{} = delivered_at,
           document: %{"message" => message},
           kind: :message,
           status: :delivered,
           tool: :post_slack_message
         } = action
       )
       when is_binary(action_ref) and is_binary(message) do
    [
      %{
        actor: :responder,
        artifact_refs: [],
        attachments: [],
        cards: [],
        episode_ref: action.episode_ref,
        identity: "action:" <> action.id,
        occurred_at: delivered_at,
        reactions: [],
        record_refs: [],
        ref: action_ref,
        retained: true,
        sort_key: LabCursor.key(delivered_at, :action, "action:" <> action.id),
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
    occurred_at = publication_position(publication)
    identity = "publication:" <> publication.id

    %{
      actor: :responder,
      artifact_refs: [],
      attachments: [],
      cards: [card],
      identity: identity,
      occurred_at: occurred_at,
      record_refs: [],
      ref: receipt["delivery_ref"],
      retained: true,
      sort_key: LabCursor.key(occurred_at, :publication, identity),
      state: nil,
      status: publication.status,
      text: message
    }
  end

  defp sort_lab_messages(messages), do: Enum.sort_by(messages, & &1.sort_key)

  # Retention replaced the delivered document. The reply keeps its place in
  # the transcript so the answer's absence is visible as retention, not as a
  # question nobody answered.
  defp lab_reply_message(
         %{document: %{"retention" => "pruned"}, pruned_at: %DateTime{}} = reply,
         _cards,
         _artifacts,
         _feedback_reactions
       ) do
    [
      %{
        actor: :responder,
        artifact_refs: [],
        attachments: [],
        cards: [],
        episode_ref: reply.episode_ref,
        feedback_reactions: [],
        generated_files: [],
        identity: "reply:" <> reply.turn_id,
        message_ref: nil,
        occurred_at: reply.occurred_at,
        record_refs: [],
        ref: reply.ref,
        retained: false,
        sort_key: LabCursor.key(reply.occurred_at, :reply, "reply:" <> reply.turn_id),
        state: nil,
        status: reply.status,
        text: "This reply expired under retention.",
        turn_id: reply.turn_id
      }
    ]
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
        identity: "reply:" <> reply.turn_id,
        retained: true,
        sort_key: LabCursor.key(reply.occurred_at, :reply, "reply:" <> reply.turn_id),
        generated_files:
          artifacts
          |> Enum.filter(fn {{turn_id, ref}, _artifact} ->
            turn_id == reply.turn_id and ref not in artifact_refs
          end)
          |> Enum.map(&elem(&1, 1))
          |> Enum.sort_by(& &1.name),
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
        episode_ref: reply.episode_ref,
        feedback_reactions: Map.get(feedback_reactions, reply.ref, []),
        message_ref: lab_reply_message_ref(reply),
        occurred_at: reply.occurred_at,
        record_refs: record_refs,
        ref: reply.ref,
        state: outcome["state"],
        status: reply.status,
        text: text,
        turn_id: reply.turn_id
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

  defp lab_live?(input_queue, episodes, deliveries) do
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
      deliveries.replies_pending or deliveries.actions_pending or
      deliveries.publications_pending
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
      diagnosis: FailureDetail.facts(item.error_detail),
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
      diagnosis: FailureDetail.facts(entry.last_error_detail),
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
    recovery = WorkRecovery.brief(turn)

    %{
      action: recovery.action,
      work_recovery: recovery,
      attempt_count: max(turn.work_attempt_count, turn.cancel_attempt_count),
      detail: FailureDetail.project(turn.last_error_detail),
      diagnosis: FailureDetail.facts(turn.last_error_detail),
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
      diagnosis: FailureDetail.facts(audit.last_error_detail),
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
      diagnosis: FailureDetail.facts(room.last_error_detail),
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
      diagnosis: FailureDetail.facts(item.last_error),
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
      diagnosis: FailureDetail.facts(session.cleanup_last_error_detail),
      cleanup_phase: session.cleanup_blocked_from,
      request_state: episode.state,
      closed_at: session.closed_at,
      discarded_at: session.discarded_at,
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

  # A publication that keeps failing was invisible: not a failure kind here, and
  # not action_needed on its task card until it is `:blocked`. Production ran two
  # for days — 2,902 attempts against a Coop session that closed on the 10th, and
  # 1,087 against a repository whose GitHub App is not installed — while this
  # page, whose question is "what is broken and can I retry it?", said nothing.
  # A recorded failure is the same evidence custody already requires before it
  # offers recovery: a publication that is merely slow is not stuck.
  defp publication_item({%Publication{} = publication, %Episode{} = episode}) do
    %{
      action: nil,
      attempt_count: publication.attempt_count || 0,
      detail: FailureDetail.project(publication.last_error_detail),
      diagnosis: FailureDetail.facts(publication.last_error_detail),
      destination: failure_destination(episode),
      episode_id: episode.id,
      episode_ref: episode.key,
      kind: "publication",
      ref: publication.ref,
      source: publication.repository || "no repository",
      status: publication.status,
      summary: publication.last_error_code || "publication blocked",
      updated_at: publication.updated_at
    }
  end

  defp decorate_failures(items) do
    items
    |> attach_input_contexts()
    |> attach_episode_contexts()
    |> with_request_titles()
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

  defp workspace_item({%Session{} = session, episode_state, episode_ref}) do
    %{
      action: workspace_action(session),
      kind: "coop_session",
      episode_ref: episode_ref,
      repository: session.repository_ref,
      discard_after: session.discard_after,
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

  defp usage_totals(query), do: UsageProjection.totals(query)

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

  defp count(query), do: Repo.aggregate(query, :count, :id)

  defp database_now! do
    {:ok, %{rows: [[%DateTime{} = now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end
end
