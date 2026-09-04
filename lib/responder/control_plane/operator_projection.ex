defmodule Responder.ControlPlane.OperatorProjection do
  @moduledoc """
  Bounded read models for the local operator workbench.

  Every field is selected explicitly. Source payloads, prompts, model candidates,
  credentials, callback values, and raw failure bodies never cross this boundary.
  """

  import Ecto.Query

  alias Responder.CoopFleet.Worker
  alias Responder.Episodes.Episode
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Operator.FailureDetail
  alias Responder.Publication.Publication
  alias Responder.Repo

  alias Responder.Slack.{
    ChannelConfiguration,
    ChannelMembership,
    ChannelSettingOverride,
    IncidentRoom,
    IncidentRoomLifecycleEvent
  }

  alias Responder.State.{ConversationSummary, Record, Schedule, ScheduleOccurrence}
  alias Responder.Work.{Measurement, Session, Turn}

  @list_limit 100
  @detail_limit 200
  @configuration_owners ~w(admission work control_plane coop_worker_gateway delivery publication retention state_tools event_waits schedules emisar slack github webhooks)a
  @schedule_statuses ~w(active paused completed expired deleted)a
  @incident_statuses ~w(requested ready blocked closed)a

  def incidents(params) when is_map(params) do
    latest_publications =
      from(publication in Publication,
        distinct: publication.episode_id,
        order_by: [
          asc: publication.episode_id,
          desc: publication.updated_at,
          desc: publication.id
        ],
        select: %{
          episode_id: publication.episode_id,
          ref: publication.ref,
          status: publication.status
        }
      )

    query =
      from(room in IncidentRoom,
        left_join: episode in Episode,
        on: episode.id == room.episode_id,
        left_join: publication in subquery(latest_publications),
        on: publication.episode_id == room.episode_id,
        order_by: [desc: room.updated_at, desc: room.id],
        limit: @list_limit,
        select: %{
          channel_ref: room.channel_ref,
          channel_state: room.channel_state,
          episode_ref: episode.key,
          private: room.private,
          publication_ref: publication.ref,
          publication_status: publication.status,
          ref: room.ref,
          repository_ref: room.repository_ref,
          status: room.status,
          title: room.title,
          updated_at: room.updated_at,
          workspace_ref: room.workspace_ref
        }
      )
      |> incident_status(filter_enum(params["status"], @incident_statuses))
      |> incident_search(search(params["q"]))

    Repo.all(query)
  end

  def incidents(_params), do: incidents(%{})

  def incident(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(from(room in IncidentRoom, where: room.ref == ^ref, limit: 1)) do
      nil ->
        :not_found

      room ->
        episode = if room.episode_id, do: Repo.get(Episode, room.episode_id)

        lifecycle =
          Repo.all(
            from(event in IncidentRoomLifecycleEvent,
              where: event.room_id == ^room.id,
              order_by: [asc: event.occurred_at, asc: event.id],
              limit: @detail_limit,
              select: %{
                kind: event.kind,
                occurred_at: event.occurred_at,
                channel_ref: event.channel_ref
              }
            )
          )

        records =
          if room.episode_id do
            Repo.all(
              from(record in Record,
                where: record.episode_id == ^room.episode_id,
                order_by: [asc: record.sequence, asc: record.id],
                limit: @detail_limit,
                select: %{
                  kind: record.kind,
                  ref: record.ref,
                  status: record.status,
                  subject: record.subject_ref
                }
              )
            )
          else
            []
          end

        publication =
          if room.episode_id do
            Repo.one(
              from(publication in Publication,
                where: publication.episode_id == ^room.episode_id,
                order_by: [desc: publication.updated_at, desc: publication.id],
                limit: 1,
                select: %{
                  branch_ref: publication.branch_ref,
                  commit_sha: publication.commit_sha,
                  last_error: publication.last_error_detail,
                  pr_number: publication.pull_request_number,
                  pr_url: publication.pull_request_url,
                  ref: publication.ref,
                  repository: publication.repository,
                  status: publication.status,
                  updated_at: publication.updated_at
                }
              )
            )
            |> sanitize_publication()
          end

        {:ok,
         %{
           lifecycle: lifecycle,
           publication: publication,
           records: records,
           room: %{
             channel_ref: room.channel_ref,
             channel_state: room.channel_state,
             episode_ref: episode && episode.key,
             private: room.private,
             ref: room.ref,
             repository_ref: room.repository_ref,
             requested_at: room.requested_at,
             source_channel_ref: room.source_channel_ref,
             source_episode_ref: episode_ref(room.source_episode_id),
             status: room.status,
             title: room.title,
             updated_at: room.updated_at,
             workspace_ref: room.workspace_ref
           }
         }}
    end
  end

  def incident(_ref), do: :not_found

  def schedules(params) when is_map(params) do
    query =
      from(schedule in Schedule,
        order_by: [asc: schedule.status, asc: schedule.next_occurrence_at, desc: schedule.id],
        limit: @list_limit,
        select: %{
          authority: schedule.authority,
          catch_up: schedule.catch_up,
          destination_conversation_ref: schedule.destination_conversation_ref,
          destination_transport: schedule.destination_transport,
          failures: schedule.failure_count,
          next_occurrence_at: schedule.next_occurrence_at,
          ref: schedule.ref,
          repository: schedule.repository,
          status: schedule.status,
          timezone: schedule.timezone,
          title: schedule.title,
          updated_at: schedule.updated_at
        }
      )
      |> schedule_status(filter_enum(params["status"], @schedule_statuses))
      |> schedule_search(search(params["q"]))

    Repo.all(query)
  end

  def schedules(_params), do: schedules(%{})

  def schedule(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(from(schedule in Schedule, where: schedule.ref == ^ref, limit: 1)) do
      nil ->
        :not_found

      schedule ->
        occurrences =
          Repo.all(
            from(occurrence in ScheduleOccurrence,
              left_join: episode in Episode,
              on: episode.id == occurrence.child_episode_id,
              where: occurrence.schedule_id == ^schedule.id,
              order_by: [desc: occurrence.scheduled_for, desc: occurrence.id],
              limit: @detail_limit,
              select: %{
                episode_ref: episode.key,
                missed_reason: occurrence.missed_reason,
                ref: occurrence.ref,
                scheduled_for: occurrence.scheduled_for,
                status: occurrence.status
              }
            )
          )

        {:ok,
         %{
           occurrences: occurrences,
           schedule: %{
             authority: schedule.authority,
             catch_up: schedule.catch_up,
             confirmed_at: schedule.confirmed_at,
             destination_conversation_ref: schedule.destination_conversation_ref,
             destination_thread_ref: schedule.destination_thread_ref,
             destination_transport: schedule.destination_transport,
             expires_at: schedule.expires_at,
             failure_count: schedule.failure_count,
             last_error: FailureDetail.project(schedule.last_error),
             next_occurrence_at: schedule.next_occurrence_at,
             recurrence: recurrence_label(schedule.recurrence),
             ref: schedule.ref,
             repository: schedule.repository,
             revision: schedule.revision,
             source_episode_ref: episode_ref(schedule.source_episode_id),
             status: schedule.status,
             task: schedule.task,
             timezone: schedule.timezone,
             title: schedule.title,
             updated_at: schedule.updated_at
           }
         }}
    end
  end

  def schedule(_ref), do: :not_found

  def channels(params) when is_map(params) do
    configurations =
      Repo.all(
        from(configuration in ChannelConfiguration,
          order_by: [asc: configuration.workspace_ref, asc: configuration.channel_ref],
          limit: 500
        )
      )

    memberships =
      Repo.all(
        from(membership in ChannelMembership,
          order_by: [asc: membership.workspace_ref, asc: membership.channel_ref],
          limit: 500
        )
      )

    rooms =
      Repo.all(
        from(room in IncidentRoom,
          where: not is_nil(room.channel_ref),
          order_by: [desc: room.updated_at],
          limit: 500,
          select: {room.workspace_ref, room.channel_ref}
        )
      )
      |> MapSet.new()

    episode_counts = slack_episode_counts()

    keys =
      (Enum.map(configurations, &{&1.workspace_ref, &1.channel_ref}) ++
         Enum.map(memberships, &{&1.workspace_ref, &1.channel_ref}) ++
         Map.keys(episode_counts) ++ MapSet.to_list(rooms))
      |> Enum.uniq()

    configurations = Map.new(configurations, &{{&1.workspace_ref, &1.channel_ref}, &1})
    memberships = Map.new(memberships, &{{&1.workspace_ref, &1.channel_ref}, &1})

    keys
    |> Enum.map(fn {workspace_ref, channel_ref} = key ->
      configuration = configurations[key]
      membership = memberships[key]
      counts = Map.get(episode_counts, key, %{episodes: 0, last_at: nil})

      %{
        channel_ref: channel_ref,
        episodes: counts.episodes,
        incident_room: MapSet.member?(rooms, key),
        last_at: counts.last_at || updated_at(configuration) || updated_at(membership),
        membership: membership && membership.status,
        participation: configuration && configuration.participation,
        private: membership && membership.private,
        repository_ref: configuration && configuration.repository_ref,
        workspace_ref: workspace_ref
      }
    end)
    |> filter_channel_search(search(params["q"]))
    |> Enum.sort_by(&{date_sort(&1.last_at), &1.workspace_ref, &1.channel_ref}, :desc)
    |> Enum.take(@list_limit)
  end

  def channels(_params), do: channels(%{})

  def channel(workspace_ref, channel_ref)
      when is_binary(workspace_ref) and is_binary(channel_ref) and
             byte_size(workspace_ref) <= 1_024 and byte_size(channel_ref) <= 1_024 do
    conversation_ref = "slack:#{workspace_ref}:#{channel_ref}"
    configuration = channel_configuration(workspace_ref, channel_ref)
    membership = channel_membership(workspace_ref, channel_ref)
    incident_room = channel_incident_room(workspace_ref, channel_ref)
    episodes = channel_episodes(conversation_ref)

    if is_nil(configuration) and is_nil(membership) and is_nil(incident_room) and episodes == [] do
      :not_found
    else
      {:ok,
       %{
         channel:
           channel_detail(configuration, membership, incident_room, workspace_ref, channel_ref),
         episodes: episodes,
         overrides: channel_overrides(workspace_ref, conversation_ref),
         schedules: channel_schedules(conversation_ref),
         summaries: channel_summaries(workspace_ref, conversation_ref)
       }}
    end
  end

  def channel(_workspace_ref, _channel_ref), do: :not_found

  defp channel_configuration(workspace_ref, channel_ref) do
    Repo.one(
      from(configuration in ChannelConfiguration,
        where:
          configuration.workspace_ref == ^workspace_ref and
            configuration.channel_ref == ^channel_ref,
        limit: 1
      )
    )
  end

  defp channel_membership(workspace_ref, channel_ref) do
    Repo.one(
      from(membership in ChannelMembership,
        where:
          membership.workspace_ref == ^workspace_ref and
            membership.channel_ref == ^channel_ref,
        limit: 1
      )
    )
  end

  defp channel_incident_room(workspace_ref, channel_ref) do
    Repo.one(
      from(room in IncidentRoom,
        where: room.workspace_ref == ^workspace_ref and room.channel_ref == ^channel_ref,
        order_by: [desc: room.updated_at, desc: room.id],
        limit: 1,
        select: %{
          channel_state: room.channel_state,
          private: room.private,
          repository_ref: room.repository_ref
        }
      )
    )
  end

  defp channel_episodes(conversation_ref) do
    Repo.all(
      from(episode in Episode,
        where:
          episode.destination_transport == "slack" and
            episode.destination_conversation_ref == ^conversation_ref,
        order_by: [desc: episode.updated_at, desc: episode.id],
        limit: @detail_limit,
        select: %{
          ref: episode.key,
          state: episode.state,
          thread_ref: episode.destination_thread_ref,
          updated_at: episode.updated_at
        }
      )
    )
  end

  defp channel_schedules(conversation_ref) do
    Repo.all(
      from(schedule in Schedule,
        where:
          schedule.destination_transport == "slack" and
            schedule.destination_conversation_ref == ^conversation_ref,
        order_by: [asc: schedule.next_occurrence_at, desc: schedule.id],
        limit: @detail_limit,
        select: %{
          next_occurrence_at: schedule.next_occurrence_at,
          ref: schedule.ref,
          status: schedule.status,
          title: schedule.title
        }
      )
    )
  end

  defp channel_overrides(workspace_ref, conversation_ref) do
    Repo.all(
      from(setting in ChannelSettingOverride,
        where:
          setting.workspace_ref == ^workspace_ref and
            ((setting.scope_kind == :channel and setting.scope_ref == ^conversation_ref) or
               (setting.scope_kind == :workspace and setting.scope_ref == ^workspace_ref)),
        order_by: [asc: setting.setting, desc: setting.scope_kind, desc: setting.revision],
        limit: 20,
        select: %{
          revision: setting.revision,
          scope: setting.scope_kind,
          setting: setting.setting,
          updated_at: setting.updated_at,
          value: setting.value
        }
      )
    )
  end

  defp channel_summaries(workspace_ref, conversation_ref) do
    Repo.all(
      from(summary in ConversationSummary,
        where:
          summary.transport == "slack" and summary.workspace_ref == ^workspace_ref and
            summary.conversation_ref == ^conversation_ref,
        order_by: [desc: summary.updated_at, desc: summary.id],
        limit: 50,
        select: %{
          ref: summary.ref,
          repository_ref: summary.repository_ref,
          thread_ref: summary.thread_ref,
          updated_at: summary.updated_at
        }
      )
    )
  end

  defp channel_detail(configuration, membership, incident_room, workspace_ref, channel_ref) do
    %{
      alert_policy: optional_field(configuration, :alert_policy),
      channel_ref: channel_ref,
      channel_state: optional_field(incident_room, :channel_state),
      configuration_revision: optional_field(configuration, :revision),
      configuration_saved_at: optional_field(configuration, :saved_at),
      incident_room: not is_nil(incident_room),
      membership: optional_field(membership, :status),
      participation: optional_field(configuration, :participation),
      private: preferred_field(membership, :private, incident_room, :private),
      repository_ref:
        preferred_field(configuration, :repository_ref, incident_room, :repository_ref),
      workspace_ref: workspace_ref
    }
  end

  defp optional_field(nil, _field), do: nil
  defp optional_field(record, field), do: Map.fetch!(record, field)

  defp preferred_field(nil, _field, fallback, fallback_field),
    do: optional_field(fallback, fallback_field)

  defp preferred_field(record, field, _fallback, _fallback_field), do: Map.fetch!(record, field)

  def repositories(params) when is_map(params) do
    runtime = runtime_repositories()
    channels = grouped_count(ChannelConfiguration, :repository_ref)
    schedules = grouped_count(Schedule, :repository)
    sessions = grouped_count(Session, :repository_ref)
    publications = grouped_count(Publication, :repository)
    workers = repository_workers()
    freshness = repository_freshness()

    names =
      [
        Map.keys(runtime),
        Map.keys(channels),
        Map.keys(schedules),
        Map.keys(sessions),
        Map.keys(publications),
        Map.keys(workers),
        Map.keys(freshness)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    names
    |> filter_repository_search(search(params["q"]))
    |> Enum.sort()
    |> Enum.take(@list_limit)
    |> Enum.map(fn repository_ref ->
      %{
        channels: Map.get(channels, repository_ref, 0),
        configured: Map.get(runtime, repository_ref),
        freshness: Map.get(freshness, repository_ref),
        publications: Map.get(publications, repository_ref, 0),
        ref: repository_ref,
        schedules: Map.get(schedules, repository_ref, 0),
        sessions: Map.get(sessions, repository_ref, 0),
        workers: Map.get(workers, repository_ref, [])
      }
    end)
  end

  def repositories(_params), do: repositories(%{})

  def operator_configuration do
    source = System.get_env("RESPONDER_ELIXIR_CONFIG") || "application environment"

    %{
      grants: mcp_grants(source),
      rows: configuration_rows(source),
      source: source
    }
  end

  def calibration(params) when is_map(params) do
    {window, since} = window(params["window"])

    base =
      from(turn in Turn,
        join: entry in Entry,
        on: turn.turn_ref == fragment("'ingress-turn:' || (?::text)", entry.id),
        where: not is_nil(turn.accepted_at)
      )
      |> since(since)

    rows =
      Repo.all(
        from([turn, entry] in base,
          group_by: [
            fragment(
              "COALESCE((?::jsonb ->> 'work_class'), 'unrecorded')",
              entry.decision_document
            ),
            turn.execution_target
          ],
          order_by: [desc: count(turn.id)],
          limit: @list_limit,
          select: %{
            attempts: count(turn.id),
            class:
              fragment(
                "COALESCE((?::jsonb ->> 'work_class'), 'unrecorded')",
                entry.decision_document
              ),
            cost_usd: fragment("COALESCE(SUM(?), 0)", turn.usage_cost_usd),
            costed: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.usage_cost_recorded),
            host_ms: type(fragment("COALESCE(SUM(?), 0)::bigint", turn.usage_host_ms), :integer),
            measured: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.usage_recorded),
            provider_ms:
              type(fragment("COALESCE(SUM(?), 0)::bigint", turn.usage_provider_ms), :integer),
            queued_ms:
              type(fragment("COALESCE(SUM(?), 0)::bigint", turn.usage_queued_ms), :integer),
            repair_rounds:
              type(
                fragment(
                  "COALESCE(SUM(GREATEST(? - 1, 0)), 0)::bigint",
                  turn.validation_generation
                ),
                :integer
              ),
            target: turn.execution_target,
            timed: fragment("COUNT(*) FILTER (WHERE ? = TRUE)", turn.timing_recorded),
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
      |> Enum.map(fn row ->
        row
        |> Map.merge(Measurement.target_parts(row.target))
        |> Map.put(:average_queued_ms, average(row.queued_ms, row.timed))
        |> Map.put(:average_provider_ms, average(row.provider_ms, row.timed))
        |> Map.put(:average_host_ms, average(row.host_ms, row.timed))
        |> Map.drop([:queued_ms, :provider_ms, :host_ms])
      end)

    %{rows: rows, window: window}
  end

  def calibration(_params), do: calibration(%{})

  defp incident_status(query, nil), do: query

  defp incident_status(query, status),
    do: from([room, _, _] in query, where: room.status == ^status)

  defp incident_search(query, nil), do: query

  defp incident_search(query, search) do
    pattern = "%#{escape_like(search)}%"

    from([room, _, _] in query,
      where:
        ilike(room.ref, ^pattern) or ilike(room.title, ^pattern) or
          ilike(room.repository_ref, ^pattern) or ilike(room.workspace_ref, ^pattern) or
          ilike(room.source_channel_ref, ^pattern) or ilike(room.channel_ref, ^pattern)
    )
  end

  defp schedule_status(query, nil), do: query

  defp schedule_status(query, status),
    do: from(schedule in query, where: schedule.status == ^status)

  defp schedule_search(query, nil), do: query

  defp schedule_search(query, search) do
    pattern = "%#{escape_like(search)}%"

    from(schedule in query,
      where:
        ilike(schedule.ref, ^pattern) or ilike(schedule.title, ^pattern) or
          ilike(schedule.repository, ^pattern) or
          ilike(schedule.destination_conversation_ref, ^pattern)
    )
  end

  defp sanitize_publication(nil), do: nil

  defp sanitize_publication(publication) do
    Map.put(publication, :last_error, FailureDetail.project(publication.last_error))
  end

  defp episode_ref(nil), do: nil

  defp episode_ref(id) do
    Repo.one(from(episode in Episode, where: episode.id == ^id, select: episode.key, limit: 1))
  end

  defp recurrence_label(%{"kind" => "interval", "every_seconds" => seconds})
       when is_integer(seconds),
       do: "every #{seconds} seconds"

  defp recurrence_label(%{"kind" => "daily", "time" => time}), do: "daily at #{time}"

  defp recurrence_label(%{"kind" => "weekly", "weekday" => day, "time" => time}),
    do: "weekly on #{day} at #{time}"

  defp recurrence_label(%{"day" => day, "kind" => "monthly", "time" => time}),
    do: "monthly on day #{day} at #{time}"

  defp recurrence_label(%{"at" => at, "kind" => "once"}), do: "once at #{at}"
  defp recurrence_label(_unknown), do: "recorded recurrence"

  defp slack_episode_counts do
    Repo.all(
      from(episode in Episode,
        where:
          episode.destination_transport == "slack" and
            like(episode.destination_conversation_ref, "slack:%"),
        group_by: episode.destination_conversation_ref,
        order_by: [desc: max(episode.updated_at)],
        limit: 500,
        select: %{
          conversation_ref: episode.destination_conversation_ref,
          episodes: count(episode.id),
          last_at: max(episode.updated_at)
        }
      )
    )
    |> Enum.reduce(%{}, fn row, found ->
      case String.split(row.conversation_ref, ":", parts: 3) do
        ["slack", workspace_ref, channel_ref] ->
          Map.put(found, {workspace_ref, channel_ref}, Map.drop(row, [:conversation_ref]))

        _invalid ->
          found
      end
    end)
  end

  defp filter_channel_search(rows, nil), do: rows

  defp filter_channel_search(rows, search) do
    search = String.downcase(search)

    Enum.filter(rows, fn row ->
      Enum.any?(
        [row.workspace_ref, row.channel_ref, row.repository_ref, row.participation],
        &(is_binary(&1) and String.contains?(String.downcase(&1), search))
      )
    end)
  end

  defp filter_repository_search(names, nil), do: names

  defp filter_repository_search(names, search) do
    search = String.downcase(search)
    Enum.filter(names, &String.contains?(String.downcase(&1), search))
  end

  defp updated_at(nil), do: nil
  defp updated_at(record), do: record.updated_at

  defp date_sort(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp date_sort(_missing), do: 0

  defp grouped_count(schema, field) do
    Repo.all(
      from(row in schema,
        where: not is_nil(field(row, ^field)),
        group_by: field(row, ^field),
        select: {field(row, ^field), count(row.id)},
        limit: 500
      )
    )
    |> Map.new()
  end

  defp runtime_repositories do
    control_plane = Application.get_env(:responder, :control_plane, %{})
    schedules = Application.get_env(:responder, :schedules, %{})

    task_policies =
      control_plane
      |> safe_map(:task_policies)
      |> Enum.map(fn {ref, policy} ->
        {to_string(ref), %{contributor_policy: safe_policy_name(policy)}}
      end)

    schedule_policies =
      schedules
      |> safe_map(:repositories)
      |> Enum.map(fn {ref, policy} ->
        {to_string(ref), %{schedule_policy: safe_policy_name(policy)}}
      end)

    Enum.reduce(task_policies ++ schedule_policies, %{}, fn {ref, value}, found ->
      Map.update(found, ref, value, &Map.merge(&1, value))
    end)
  end

  defp repository_workers do
    Repo.all(
      from(worker in Worker,
        where: worker.state in [:eligible, :busy, :draining],
        order_by: [asc: worker.id],
        limit: 200,
        select: %{
          id: worker.id,
          last_seen_at: worker.last_seen_at,
          repositories: worker.repositories,
          state: worker.state
        }
      )
    )
    |> Enum.reduce(%{}, fn worker, found ->
      worker.repositories
      |> List.wrap()
      |> Enum.reduce(found, fn
        %{"ref" => ref} = repository, acc when is_binary(ref) ->
          item = %{
            revision: Map.get(repository, "revision"),
            state: worker.state,
            worker_ref: worker.id,
            last_seen_at: worker.last_seen_at
          }

          Map.update(acc, ref, [item], &[item | &1])

        _invalid, acc ->
          acc
      end)
    end)
  end

  defp repository_freshness do
    Repo.all(
      from(turn in Turn,
        join: session in Session,
        on: session.id == turn.session_id,
        where: not is_nil(session.repository_ref) and not is_nil(turn.submission),
        order_by: [desc: turn.updated_at, desc: turn.id],
        limit: 500,
        select: %{
          recorded_at: turn.updated_at,
          repository_ref: session.repository_ref,
          submission: turn.submission
        }
      )
    )
    |> Enum.reduce(%{}, &put_repository_freshness/2)
  end

  defp put_repository_freshness(row, found) do
    case {Map.has_key?(found, row.repository_ref), primary_freshness(row.submission)} do
      {true, _freshness} ->
        found

      {false, nil} ->
        found

      {false, freshness} ->
        Map.put(found, row.repository_ref, Map.put(freshness, :recorded_at, row.recorded_at))
    end
  end

  defp primary_freshness(submission) when is_map(submission) do
    with %{"owner" => "coop", "repositories" => repositories, "status" => "recorded"} <-
           get_in(submission, ["context", "workspace", "freshness"]),
         true <- is_list(repositories),
         %{} = receipt <- Enum.find(repositories, &(&1["name"] == "primary")) do
      %{
        fetched_at: receipt["fetched_at"],
        remote_identity: receipt["remote_identity"],
        requested_revision: receipt["requested_revision"],
        resolved_revision: receipt["resolved_revision"],
        stale_base_revision: receipt["stale_base_revision"],
        stale_base_status: receipt["stale_base_status"],
        version: receipt["version"],
        workspace_base_revision: receipt["workspace_base_revision"]
      }
    else
      _missing -> nil
    end
  end

  defp primary_freshness(_submission), do: nil

  defp configuration_rows(source) do
    presence =
      Enum.map(@configuration_owners, fn owner ->
        %{
          key: Atom.to_string(owner),
          source: source,
          value: if(Application.get_env(:responder, owner), do: "enabled", else: "disabled")
        }
      end)

    admission = Application.get_env(:responder, :admission, %{})
    work = Application.get_env(:responder, :work, %{})
    retention = Application.get_env(:responder, :retention, %{})

    details =
      []
      |> maybe_config("runtime.mode", Application.get_env(:responder, :runtime_mode), source)
      |> maybe_config("admission.policy", safe_value(admission, :policy), source)
      |> maybe_config(
        "admission.decision_timeout_ms",
        safe_value(admission, :decision_timeout_ms),
        source
      )
      |> maybe_config("work.concurrency", safe_value(work, :concurrency), source)
      |> maybe_config("work.poll_interval_ms", safe_value(work, :poll_interval_ms), source)
      |> maybe_config(
        "retention.operational_data_seconds",
        safe_value(retention, :operational_data_seconds),
        source
      )
      |> maybe_config(
        "retention.closed_work_seconds",
        safe_value(retention, :closed_work_seconds),
        source
      )
      |> maybe_config(
        "retention.episode_history_seconds",
        safe_value(retention, :episode_history_seconds),
        source
      )
      |> maybe_config(
        "retention.audit_data_seconds",
        safe_value(retention, :audit_data_seconds),
        source
      )

    presence ++ Enum.reverse(details)
  end

  defp mcp_grants(source) do
    state_tools = Application.get_env(:responder, :state_tools, %{})
    work = Application.get_env(:responder, :work, %{})

    capabilities =
      state_tools
      |> safe_list(:capabilities)
      |> Enum.filter(&(is_atom(&1) or is_binary(&1)))
      |> Enum.map(&to_string/1)

    tools =
      state_tools
      |> safe_list(:additional_tools)
      |> Enum.flat_map(fn
        %{"name" => name} when is_binary(name) -> [name]
        %{name: name} when is_binary(name) -> [name]
        _invalid -> []
      end)

    platform_tools =
      work
      |> safe_list(:platform_tools)
      |> Enum.filter(&is_binary/1)

    (Enum.map(capabilities, &%{kind: "host capability", name: &1, source: source}) ++
       Enum.map(tools, &%{kind: "MCP tool", name: &1, source: source}) ++
       Enum.map(platform_tools, &%{kind: "source/action tool", name: &1, source: source}))
    |> Enum.uniq_by(&{&1.kind, &1.name})
    |> Enum.sort_by(&{&1.kind, &1.name})
    |> Enum.take(512)
  end

  defp maybe_config(rows, _key, nil, _source), do: rows

  defp maybe_config(rows, key, value, source)
       when is_binary(value) or is_atom(value) or is_integer(value) or is_boolean(value),
       do: [%{key: key, source: source, value: to_string(value)} | rows]

  defp maybe_config(rows, _key, _value, _source), do: rows

  defp safe_value(value, key) when is_map(value), do: Map.get(value, key)
  defp safe_value(_value, _key), do: nil

  defp safe_map(value, key) when is_map(value) do
    case Map.get(value, key, %{}) do
      map when is_map(map) -> map
      _other -> %{}
    end
  end

  defp safe_map(_value, _key), do: %{}

  defp safe_list(value, key) when is_map(value) do
    case Map.get(value, key, []) do
      list when is_list(list) -> list
      _other -> []
    end
  end

  defp safe_list(_value, _key), do: []

  defp safe_policy_name(%{name: name}) when is_binary(name), do: name
  defp safe_policy_name(%{"name" => name}) when is_binary(name), do: name
  defp safe_policy_name(_unknown), do: "configured"

  defp filter_enum(value, allowed) when is_binary(value) do
    Enum.find(allowed, &(Atom.to_string(&1) == String.trim(value)))
  end

  defp filter_enum(_value, _allowed), do: nil

  defp search(value) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, 200) do
      "" -> nil
      search -> search
    end
  end

  defp search(_value), do: nil

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp window("24h"), do: {"24h", DateTime.add(DateTime.utc_now(), -24, :hour)}
  defp window("7d"), do: {"7d", DateTime.add(DateTime.utc_now(), -7, :day)}
  defp window("all"), do: {"all", nil}
  defp window(_other), do: {"30d", DateTime.add(DateTime.utc_now(), -30, :day)}

  defp since(query, nil), do: query
  defp since(query, value), do: from([turn, _entry] in query, where: turn.accepted_at >= ^value)

  defp average(_sum, 0), do: nil
  defp average(sum, count), do: div(sum, count)
end
