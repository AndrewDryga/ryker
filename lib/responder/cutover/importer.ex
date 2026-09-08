defmodule Responder.Cutover.Importer do
  @moduledoc """
  Applies one reviewed cutover plan atomically into the replacement schema.

  Imported rows point at the sealed cutover item that authorized them. They do
  not fabricate model offers, Work turns, or platform confirmations. Unfinished
  episodes start a fresh Coop session under an explicit trusted placement; old
  provider-native sessions remain audit data only.
  """

  import Ecto.Query

  alias Responder.{CanonicalJSON, Cutover.Item, Cutover.Run, Episodes, Repo}
  alias Responder.Episodes.{Command, Episode, EpisodeChangeset, Event}
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Ingress.WorkProfile

  alias Responder.State.{
    Behavior,
    BehaviorChangeset,
    MemoryEntry,
    MemoryEntryChangeset,
    Record,
    RecordChangeset,
    RecordPayload,
    Schedule,
    ScheduleChangeset,
    ScheduleRecurrence
  }

  alias Responder.State.{ScheduleOccurrence, StandingAssignmentRun}
  alias Responder.Work.{Custody, Session, Turn}

  @options [:work_profiles]
  @memory_kinds %{
    "alias_of" => :alias,
    "repository_binding" => :repository_binding,
    "repository_for_channel" => :repository_binding,
    "evidence_route" => :evidence_route,
    "entity_relationship_correction" => :entity_relationship
  }
  @weekdays ~w(monday tuesday wednesday thursday friday saturday sunday)

  @spec apply(Ecto.UUID.t(), keyword()) ::
          {:ok, %{run: Run.t(), status: :applied | :duplicate}} | {:error, term()}
  def apply(run_id, options \\ []) do
    with {:ok, run_id} <- uuid(run_id),
         {:ok, profiles} <- options(options) do
      Repo.transaction(fn -> apply_locked(run_id, profiles) end)
      |> transaction_result()
    end
  end

  defp apply_locked(run_id, profiles) do
    lock_global!()

    case Repo.one(from(run in Run, where: run.id == ^run_id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback(:cutover_run_not_found)

      %Run{status: :applied} = run ->
        %{run: run, status: :duplicate}

      %Run{status: :prepared} = run ->
        items =
          Repo.all(
            from(item in Item,
              where: item.run_id == ^run.id,
              order_by: [asc: item.id],
              lock: "FOR UPDATE"
            )
          )

        with :ok <- complete_plan(run, items),
             {:ok, targets} <- import_items(run, items, profiles),
             :ok <- persist_targets(items, targets),
             {:ok, applied_at} <- database_now(),
             {:ok, applied} <- update_run(run, :applied, applied_at) do
          %{run: applied, status: :applied}
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      %Run{status: status} ->
        Repo.rollback({:cutover_run_not_applicable, status})
    end
  end

  defp complete_plan(run, items) do
    cond do
      length(items) != run.item_count ->
        {:error, :cutover_item_count_mismatch}

      Enum.any?(items, &(&1.status not in [:pending, :skipped])) ->
        {:error, :cutover_items_not_pending}

      true ->
        :ok
    end
  end

  defp import_items(run, items, profiles) do
    items
    |> Enum.sort_by(&{kind_rank(&1.kind), &1.ref})
    |> Enum.reduce_while({:ok, %{}}, fn
      %Item{status: :skipped}, {:ok, targets} ->
        {:cont, {:ok, targets}}

      %Item{} = item, {:ok, targets} ->
        case import_item(run, item, profiles) do
          {:ok, refs} -> {:cont, {:ok, Map.put(targets, item.id, refs)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp import_item(run, %Item{kind: :memory} = item, _profiles) do
    with {:ok, attributes} <- memory_attributes(run, item),
         {:ok, memory} <- insert(MemoryEntryChangeset.cutover(attributes), :memory) do
      {:ok, [memory.ref]}
    end
  end

  defp import_item(run, %Item{kind: :behavior} = item, _profiles) do
    with {:ok, attributes} <- behavior_attributes(run, item),
         {:ok, behavior} <- insert(BehaviorChangeset.cutover(attributes), :behavior) do
      {:ok, [behavior.ref]}
    end
  end

  defp import_item(run, %Item{kind: :schedule} = item, _profiles) do
    with {:ok, rows} <- schedule_attributes(run, item) do
      insert_schedules(rows)
    end
  end

  defp import_item(run, %Item{kind: :episode} = item, profiles) do
    with {:ok, profile} <- episode_profile(item.data, profiles),
         {:ok, command} <- episode_command(run, item),
         {:ok, [transition]} <- Episodes.apply_batch_in_transaction([command]),
         {:ok, episode} <- bind_episode(transition.episode, item.id),
         {:ok, _session} <-
           Custody.pin_episode_in_transaction(
             episode.id,
             profile.policy,
             profile.policy_digest,
             profile.repository_ref
           ) do
      {:ok, [episode.key]}
    end
  end

  defp import_item(run, %Item{kind: :wait} = item, _profiles) do
    with {:ok, episode} <- imported_episode(item),
         {:ok, wait} <- wait_attributes(run, item, episode),
         {:ok, record} <- insert(RecordChangeset.cutover(wait.record), :wait),
         {:ok, [_transition]} <- Episodes.apply_batch_in_transaction([wait.command]) do
      {:ok, [record.ref]}
    end
  end

  defp insert_schedules(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, &insert_schedule/2)
    |> case do
      {:ok, refs} -> {:ok, Enum.sort(refs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_schedule(attributes, {:ok, refs}) do
    case insert(ScheduleChangeset.cutover(attributes), :schedule) do
      {:ok, schedule} -> {:cont, {:ok, [schedule.ref | refs]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp memory_attributes(run, item) do
    data = item.data

    with {:ok, kind} <- memory_kind(data["predicate"]),
         {:ok, subject} <- text(data["subject_key"], 120, :memory_subject),
         {:ok, value} <- memory_value(data["value_json"]),
         {:ok, expires_at} <- datetime(data["expires_at"], :memory_expires_at),
         {:ok, source} <- source(run, data),
         {:ok, scope} <- memory_scope(run, data),
         {:ok, visibility} <- memory_visibility(data["visibility_kind"]) do
      payload = %{
        "kind" => Atom.to_string(kind),
        "repository" => if(scope.kind == :repository, do: scope.ref),
        "scope" => Atom.to_string(scope.kind),
        "subject" => subject,
        "value" => value,
        "visibility" => Atom.to_string(visibility)
      }

      {:ok,
       %{
         confirmation_ref: confirmation_ref(run, item),
         confirmed_at: run.reviewed_at,
         confirmed_by_actor_ref: run.operator_ref,
         cutover_item_id: item.id,
         expires_at: expires_at,
         id: Ecto.UUID.generate(),
         kind: kind,
         payload: payload,
         payload_fingerprint: CanonicalJSON.digest(payload),
         ref: target_ref("memory", run, item),
         scope_kind: scope.kind,
         scope_ref: scope.ref,
         source_conversation_ref: source.conversation_ref,
         source_message_ref: source.message_ref,
         source_thread_ref: source.thread_ref,
         source_transport: "slack",
         status: :active,
         subject: subject,
         visibility: visibility,
         workspace_ref: run.workspace_ref
       }}
    end
  end

  defp behavior_attributes(run, %Item{source_table: "memory_entries"} = item) do
    data = item.data

    with "guidance" <- data["predicate"],
         {:ok, subject} <- text(data["subject_key"], 120, :behavior_subject),
         {:ok, value} <- memory_value(data["value_json"]),
         {:ok, expires_at} <- datetime(data["expires_at"], :behavior_expires_at),
         {:ok, source} <- source(run, data),
         {:ok, scope} <- behavior_scope(run, data),
         {:ok, visibility} <- guidance_visibility(data["visibility_kind"]) do
      payload = %{
        "expires_in" => "365d",
        "repository" => if(scope.kind == :repository, do: scope.ref),
        "scope" => Atom.to_string(scope.kind),
        "subject" => subject,
        "summary" => subject,
        "text" => value,
        "visibility" => visibility
      }

      behavior(run, item, source, %{
        expires_at: expires_at,
        identity_key: subject,
        kind: :guidance,
        payload: payload,
        scope_kind: scope.kind,
        scope_ref: scope.ref,
        status: :active
      })
    else
      _invalid -> {:error, {:cutover_mapping_invalid, item.ref}}
    end
  end

  defp behavior_attributes(run, %Item{source_table: "standing_rules"} = item) do
    data = item.data

    with {:ok, channel} <- text(data["channel_id"], 256, :behavior_channel),
         {:ok, trigger} <- text(data["trigger_name"], 256, :behavior_trigger),
         {:ok, action} <- text(data["action_name"], 256, :behavior_action),
         {:ok, source_filter} <- source_filter(data["source_kind"]),
         {:ok, task} <- standing_task(data),
         {:ok, expires_at} <- datetime(data["expires_at"], :behavior_expires_at),
         {:ok, repository} <- optional_text(data["repository"], 1_024, :behavior_repository),
         {:ok, status} <- behavior_status(data["enabled"]),
         {:ok, conversation_ref} <- conversation_ref(run.workspace_ref, channel) do
      source = %{
        conversation_ref: conversation_ref,
        message_ref: source_message_ref(data, item),
        thread_ref: nil
      }

      payload = %{
        "action" => action,
        "expires_in" => "365d",
        "repository" => repository,
        "source_filter" => source_filter,
        "task" => task,
        "trigger" => trigger
      }

      behavior(run, item, source, %{
        expires_at: expires_at,
        identity_key: trigger,
        kind: :standing_assignment,
        payload: payload,
        scope_kind: :conversation,
        scope_ref: conversation_ref,
        status: status,
        use_count: nonnegative(data["acted_count"])
      })
    end
  end

  defp behavior_attributes(_run, item),
    do: {:error, {:cutover_mapping_invalid, item.ref}}

  defp behavior(run, item, source, attributes) do
    {:ok,
     Map.merge(attributes, %{
       confirmation_ref: confirmation_ref(run, item),
       confirmed_at: run.reviewed_at,
       confirmed_by_actor_ref: run.operator_ref,
       cutover_item_id: item.id,
       id: Ecto.UUID.generate(),
       ref: target_ref("behavior", run, item),
       revision: 1,
       source_conversation_ref: source.conversation_ref,
       source_message_ref: source.message_ref,
       source_thread_ref: source.thread_ref,
       source_transport: "slack",
       workspace_ref: run.workspace_ref
     })}
  end

  defp schedule_attributes(run, item) do
    data = item.data

    with {:ok, title} <- text(data["title"], 120, :schedule_title),
         {:ok, task} <- text(data["prompt"], 12_000, :schedule_task),
         {:ok, timezone} <- text(data["timezone"], 128, :schedule_timezone),
         {:ok, repository} <- optional_text(data["repository"], 1_024, :schedule_repository),
         {:ok, status} <- enabled_status(data["enabled"]),
         {:ok, catch_up} <- catch_up(data["catch_up"]),
         {:ok, expires_at} <- datetime(data["expires_at"], :schedule_expires_at),
         {:ok, destination} <- schedule_destination(run, data),
         {:ok, recurrences} <- recurrences(data) do
      schedule_rows(run, item, recurrences, timezone, expires_at, %{
        catch_up: catch_up,
        destination: destination,
        repository: repository,
        status: status,
        task: task,
        title: title
      })
    end
  end

  defp schedule_rows(run, item, recurrences, timezone, expires_at, base) do
    recurrences
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {recurrence, index}, {:ok, rows} ->
      with {:ok, recurrence} <- ScheduleRecurrence.normalize(recurrence, timezone, run.cutover_at),
           {:ok, %DateTime{} = next_occurrence_at} <-
             ScheduleRecurrence.next_after(recurrence, timezone, run.cutover_at),
           true <- DateTime.compare(expires_at, next_occurrence_at) == :gt do
        row = %{
          authority: :read_only,
          catch_up: base.catch_up,
          confirmation_ref: confirmation_ref(run, item),
          confirmed_at: run.reviewed_at,
          confirmed_by_actor_ref: run.operator_ref,
          cutover_item_id: item.id,
          destination_conversation_ref: base.destination.conversation_ref,
          destination_thread_ref: base.destination.thread_ref,
          destination_transport: "slack",
          expires_at: expires_at,
          id: Ecto.UUID.generate(),
          next_occurrence_at: next_occurrence_at,
          recurrence: recurrence,
          ref: target_ref("schedule-#{index + 1}", run, item),
          repository: base.repository,
          revision: 1,
          status: base.status,
          task: base.task,
          timezone: timezone,
          title: base.title
        }

        {:cont, {:ok, [row | rows]}}
      else
        {:error, reason} -> {:halt, {:error, {:cutover_schedule_invalid, item.ref, reason}}}
        _invalid -> {:halt, {:error, {:cutover_schedule_invalid, item.ref, :no_occurrence}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp episode_profile(data, profiles) do
    authority = data["authority"]
    repository = blank_to_nil(data["repository"])

    case Map.fetch(profiles, {authority, repository}) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, {:cutover_work_profile_missing, authority, repository}}
    end
  end

  defp episode_command(run, item) do
    data = item.data

    with "slack" <- data["platform"],
         {:ok, channel} <-
           text(data["destination_channel_id"] || data["channel_id"], 256, :episode_channel),
         {:ok, conversation_ref} <- conversation_ref(run.workspace_ref, channel),
         {:ok, thread_ref} <-
           optional_text(
             blank_to_nil(data["destination_thread_ts"] || data["thread_ts"]),
             1_024,
             :episode_thread
           ),
         {:ok, payload} <- episode_payload(item),
         episode_id <- Ecto.UUID.generate() do
      digest = CanonicalJSON.digest([run.id, item.id])

      {:ok,
       %Command.AdmitInput{
         actor_ref: run.operator_ref,
         destination: %{
           conversation_ref: conversation_ref,
           thread_ref: thread_ref,
           transport: "slack"
         },
         episode_id: episode_id,
         episode_key: "cutover:episode:#{digest}",
         native_input_id: "cutover-input:#{digest}",
         occurred_at: run.cutover_at,
         payload: payload,
         revision: 1,
         turn_ref: "cutover-turn:#{digest}"
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:cutover_episode_invalid, item.ref}}
    end
  end

  defp episode_payload(item) do
    payload = %{
      "kind" => "legacy_cutover",
      "legacy" =>
        Map.take(item.data, [
          "authority",
          "completion_criteria_json",
          "effort",
          "mode",
          "next_action",
          "objective",
          "phase",
          "repository",
          "required_coverage_json",
          "run_state",
          "status"
        ]),
      "source_ref" => item.source_ref,
      "source_sha256" => item.source_sha256
    }

    case CanonicalJSON.validate(payload, max_bytes: 65_536) do
      :ok -> {:ok, payload}
      {:error, reason} -> {:error, {:cutover_episode_payload_invalid, item.ref, reason}}
    end
  end

  defp bind_episode(episode, cutover_item_id) do
    episode
    |> EpisodeChangeset.bind_cutover(cutover_item_id)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, {:cutover_persistence_failed, :episode, changeset.errors}}
    end
  end

  defp imported_episode(item) do
    parent_ref = item.data["episode_id"]

    with true <- is_binary(parent_ref),
         %Item{} = parent <-
           Repo.one(
             from(value in Item,
               where:
                 value.run_id == ^item.run_id and value.kind == :episode and
                   value.source_ref == ^parent_ref
             )
           ),
         %Episode{} = episode <-
           Repo.one(from(value in Episode, where: value.cutover_item_id == ^parent.id)) do
      {:ok, episode}
    else
      _missing -> {:error, {:cutover_wait_episode_missing, item.ref}}
    end
  end

  defp wait_attributes(run, item, episode) do
    data = item.data
    wait_ref = target_ref("wait", run, item)

    case data["kind"] do
      "input" -> input_wait(run, item, episode, wait_ref)
      _event_kind -> event_wait(run, item, episode, wait_ref)
    end
  end

  defp input_wait(run, item, episode, wait_ref) do
    question = blank_to_nil(item.data["verification"]) || "Resume the imported pending work."
    payload = %{"choices" => [], "question" => question}

    with {:ok, prepared} <- RecordPayload.prepare("input_request", payload, wait_ref) do
      {:ok,
       %{
         command: %Command.StartWait{
           episode_key: episode.key,
           expected_turn_ref: episode.owner_ref,
           kind: :input,
           occurred_at: run.cutover_at,
           wait_ref: wait_ref
         },
         record: wait_record(run, item, episode, wait_ref, "input_request", prepared)
       }}
    end
  end

  defp event_wait(run, item, episode, wait_ref) do
    data = item.data

    with {:ok, deadline} <- wait_deadline(data, run.cutover_at),
         {:ok, verification} <-
           text(
             blank_to_nil(data["verification"]) || "Resume the imported pending work.",
             2_000,
             :wait_verification
           ),
         matcher when is_map(matcher) <- data["event_matcher_json"],
         kind when is_binary(kind) and kind != "" <- data["kind"],
         payload <- %{
           "deadline_at" => DateTime.to_iso8601(deadline),
           "event_matcher" => matcher,
           "kind" => kind,
           "verification" => verification
         },
         {:ok, prepared} <- RecordPayload.prepare("event_wait", payload, wait_ref) do
      {:ok,
       %{
         command: %Command.StartWait{
           deadline_at: deadline,
           episode_key: episode.key,
           expected_turn_ref: episode.owner_ref,
           kind: :event,
           occurred_at: run.cutover_at,
           wait_ref: wait_ref
         },
         record: wait_record(run, item, episode, wait_ref, "event_wait", prepared)
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:cutover_wait_invalid, item.ref}}
    end
  end

  defp wait_record(run, item, episode, wait_ref, kind, prepared) do
    digest = CanonicalJSON.digest([run.id, item.id])

    %{
      continuation: prepared.continuation,
      cutover_item_id: item.id,
      episode_id: episode.id,
      id: Ecto.UUID.generate(),
      kind: kind,
      operation_id: "cutover-#{String.slice(digest, 0, 64)}",
      payload: prepared.payload,
      payload_fingerprint: CanonicalJSON.digest(prepared.payload),
      ref: wait_ref,
      status: :open,
      subject_ref: Map.get(prepared, :subject_ref)
    }
  end

  defp persist_targets(items, targets) do
    Enum.reduce_while(items, :ok, fn
      %Item{status: :skipped}, :ok ->
        {:cont, :ok}

      %Item{} = item, :ok ->
        refs = Map.fetch!(targets, item.id)

        with {:ok, fingerprint} <- target_fingerprint(item, refs),
             {:ok, _item} <- update_item(item, refs, fingerprint) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  @doc false
  @spec target_fingerprint(Item.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def target_fingerprint(%Item{kind: :memory}, [ref]) do
    case Repo.one(from(row in MemoryEntry, where: row.ref == ^ref)) do
      %MemoryEntry{} = value -> {:ok, fingerprint(memory_document(value))}
      nil -> {:error, :cutover_target_missing}
    end
  end

  def target_fingerprint(%Item{kind: :behavior}, [ref]) do
    case Repo.one(from(row in Behavior, where: row.ref == ^ref)) do
      %Behavior{} = value -> {:ok, fingerprint(behavior_document(value))}
      nil -> {:error, :cutover_target_missing}
    end
  end

  def target_fingerprint(%Item{kind: :schedule}, refs) do
    values =
      Repo.all(from(row in Schedule, where: row.ref in ^refs, order_by: [asc: row.ref]))

    if length(values) == length(refs),
      do: {:ok, fingerprint(Enum.map(values, &schedule_document_with_occurrences/1))},
      else: {:error, :cutover_target_missing}
  end

  def target_fingerprint(%Item{kind: :episode}, [key]) do
    with %Episode{} = episode <- Repo.one(from(row in Episode, where: row.key == ^key)),
         %Session{} = session <-
           Repo.one(
             from(row in Session, where: row.episode_id == ^episode.id and row.generation == 1)
           ) do
      {:ok, fingerprint(episode_document_with_dependencies(episode, session))}
    else
      _missing -> {:error, :cutover_target_missing}
    end
  end

  def target_fingerprint(%Item{kind: :wait}, [ref]) do
    with %Record{} = record <- Repo.one(from(row in Record, where: row.ref == ^ref)),
         %Episode{} = episode <- Repo.get(Episode, record.episode_id) do
      {:ok, fingerprint(wait_document(record, episode))}
    else
      _missing -> {:error, :cutover_target_missing}
    end
  end

  defp update_item(item, refs, fingerprint) do
    item
    |> Ecto.Changeset.change(%{
      status: :applied,
      target_fingerprint: fingerprint,
      target_refs: refs
    })
    |> Ecto.Changeset.check_constraint(:status, name: :responder_cutover_item_valid)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, {:cutover_persistence_failed, :item, changeset.errors}}
    end
  end

  defp update_run(run, :applied, applied_at) do
    run
    |> Ecto.Changeset.change(%{applied_at: applied_at, status: :applied})
    |> Ecto.Changeset.check_constraint(:status, name: :responder_cutover_run_valid)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, {:cutover_persistence_failed, :run, changeset.errors}}
    end
  end

  defp memory_document(value) do
    Map.take(value, [
      :confirmed_at,
      :confirmed_by_actor_ref,
      :cutover_item_id,
      :expires_at,
      :kind,
      :last_recalled_at,
      :payload,
      :payload_fingerprint,
      :ref,
      :recall_count,
      :scope_kind,
      :scope_ref,
      :source_conversation_ref,
      :source_message_ref,
      :source_thread_ref,
      :source_transport,
      :status,
      :subject,
      :visibility,
      :workspace_ref
    ])
  end

  defp behavior_document(value) do
    document =
      Map.take(value, [
        :confirmed_at,
        :confirmed_by_actor_ref,
        :cutover_item_id,
        :expires_at,
        :identity_key,
        :kind,
        :payload,
        :ref,
        :revision,
        :scope_kind,
        :scope_ref,
        :source_conversation_ref,
        :source_message_ref,
        :source_thread_ref,
        :source_transport,
        :status,
        :use_count,
        :workspace_ref
      ])

    runs =
      Repo.all(
        from(run in StandingAssignmentRun,
          where: run.assignment_id == ^value.id,
          order_by: [asc: run.ref]
        )
      )
      |> Enum.map(&struct_document/1)

    %{behavior: document, runs: runs}
  end

  defp schedule_document(value) do
    Map.take(value, [
      :authority,
      :catch_up,
      :confirmed_at,
      :confirmed_by_actor_ref,
      :cutover_item_id,
      :destination_conversation_ref,
      :destination_thread_ref,
      :destination_transport,
      :expires_at,
      :failure_count,
      :last_error,
      :lease_expires_at,
      :lease_owner,
      :lease_ref,
      :next_attempt_at,
      :next_occurrence_at,
      :recurrence,
      :ref,
      :repository,
      :revision,
      :status,
      :task,
      :timezone,
      :title
    ])
  end

  defp schedule_document_with_occurrences(value) do
    occurrences =
      Repo.all(
        from(occurrence in ScheduleOccurrence,
          where: occurrence.schedule_id == ^value.id,
          order_by: [asc: occurrence.ref]
        )
      )
      |> Enum.map(&struct_document/1)

    %{occurrences: occurrences, schedule: schedule_document(value)}
  end

  defp episode_document(episode, session) do
    %{
      episode:
        Map.take(episode, [
          :active_input_refs,
          :cutover_item_id,
          :destination_conversation_ref,
          :destination_thread_ref,
          :destination_transport,
          :input_revisions,
          :key,
          :next_sequence,
          :owner_deadline_at,
          :owner_kind,
          :owner_ref,
          :queued_input_order_keys,
          :queued_input_refs,
          :semantic_version,
          :state
        ]),
      session: struct_document(session)
    }
  end

  defp episode_document_with_dependencies(episode, session) do
    events =
      Repo.all(
        from(event in Event, where: event.episode_id == ^episode.id, order_by: event.sequence)
      )
      |> Enum.map(&struct_document/1)

    records =
      Repo.all(
        from(record in Record, where: record.episode_id == ^episode.id, order_by: record.ref)
      )
      |> Enum.map(&struct_document/1)

    turns =
      Repo.all(from(turn in Turn, where: turn.episode_id == ^episode.id, order_by: turn.turn_ref))
      |> Enum.map(&struct_document/1)

    inbox =
      Repo.all(from(entry in Entry, where: entry.episode_id == ^episode.id, order_by: entry.id))
      |> Enum.map(&struct_document/1)

    episode_document(episode, session)
    |> Map.merge(%{events: events, inbox: inbox, records: records, turns: turns})
  end

  defp wait_document(record, episode) do
    %{
      episode:
        Map.take(episode, [:owner_deadline_at, :owner_kind, :owner_ref, :semantic_version, :state]),
      record:
        Map.take(record, [
          :continuation,
          :cutover_item_id,
          :episode_id,
          :kind,
          :operation_id,
          :payload,
          :payload_fingerprint,
          :ref,
          :status
        ])
    }
  end

  defp struct_document(value) do
    value
    |> Map.from_struct()
    |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
    |> Enum.reject(fn {_key, nested} -> match?(%Ecto.Association.NotLoaded{}, nested) end)
    |> Map.new()
  end

  defp recurrences(%{"recurrence" => "once", "next_run_at" => at}),
    do: {:ok, [%{"at" => at, "kind" => "once"}]}

  defp recurrences(%{
         "interval_seconds" => seconds,
         "recurrence" => "interval",
         "start_at" => starts_at
       })
       when is_integer(seconds),
       do: {:ok, [%{"every_seconds" => seconds, "kind" => "interval", "starts_at" => starts_at}]}

  defp recurrences(%{"local_time" => time, "recurrence" => "daily"}) do
    with {:ok, time} <- legacy_local_time(time) do
      {:ok, [%{"kind" => "daily", "time" => time}]}
    end
  end

  defp recurrences(%{
         "local_time" => time,
         "recurrence" => "weekly",
         "weekdays_json" => weekdays
       })
       when is_list(weekdays) do
    with {:ok, time} <- legacy_local_time(time) do
      if weekdays != [] and Enum.uniq(weekdays) == weekdays and
           Enum.all?(weekdays, &(&1 in @weekdays)) do
        {:ok,
         Enum.map(Enum.sort(weekdays), &%{"kind" => "weekly", "time" => time, "weekday" => &1})}
      else
        {:error, :invalid_weekdays}
      end
    end
  end

  defp recurrences(%{
         "day_of_month" => day,
         "local_time" => time,
         "recurrence" => "monthly"
       })
       when is_integer(day) do
    with {:ok, time} <- legacy_local_time(time) do
      {:ok, [%{"day" => day, "kind" => "monthly", "time" => time}]}
    end
  end

  defp recurrences(_data), do: {:error, :invalid_recurrence}

  defp legacy_local_time(value) when is_binary(value) do
    candidate = if Regex.match?(~r/\A[0-9]{2}:[0-9]{2}\z/, value), do: value <> ":00", else: value

    case Time.from_iso8601(candidate) do
      {:ok, time} -> {:ok, Time.to_iso8601(time)}
      _invalid -> {:error, :invalid_recurrence}
    end
  end

  defp legacy_local_time(_value), do: {:error, :invalid_recurrence}

  defp memory_kind(value) do
    case Map.fetch(@memory_kinds, value) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, {:cutover_memory_predicate_unsupported, value}}
    end
  end

  defp memory_value(%{"value" => value}), do: text(value, 4_000, :memory_value)
  defp memory_value(value) when is_binary(value), do: text(value, 4_000, :memory_value)

  defp memory_value(value) do
    value
    |> CanonicalJSON.encode!()
    |> text(4_000, :memory_value)
  rescue
    _error -> {:error, {:cutover_mapping_invalid, :memory_value}}
  end

  defp memory_scope(run, data) do
    case data["scope_kind"] do
      kind when kind in ["channel", "conversation"] ->
        with {:ok, ref} <- conversation_ref(run.workspace_ref, data["scope_key"]),
             do: {:ok, %{kind: :conversation, ref: ref}}

      "repository" ->
        with {:ok, ref} <- text(data["scope_key"], 1_024, :memory_scope),
             do: {:ok, %{kind: :repository, ref: ref}}

      kind when kind in ["workspace", "public"] ->
        {:ok, %{kind: :workspace, ref: run.workspace_ref}}

      _invalid ->
        {:error, {:cutover_mapping_invalid, :memory_scope}}
    end
  end

  defp behavior_scope(run, data) do
    case memory_scope(run, data) do
      {:ok, %{kind: kind} = scope} when kind in [:conversation, :repository, :workspace] ->
        {:ok, scope}

      {:error, _reason} = error ->
        error
    end
  end

  defp memory_visibility(value) when value in ["channel", "conversation"],
    do: {:ok, :conversation}

  defp memory_visibility(value) when value in ["public", "workspace"], do: {:ok, :workspace}
  defp memory_visibility(_value), do: {:error, {:cutover_mapping_invalid, :memory_visibility}}

  defp guidance_visibility(value) when value in ["channel", "conversation"],
    do: {:ok, "conversation"}

  defp guidance_visibility(value) when value in ["public", "workspace"],
    do: {:ok, "workspace"}

  defp guidance_visibility(_value),
    do: {:error, {:cutover_mapping_invalid, :behavior_visibility}}

  defp source(run, data) do
    channel = blank_to_nil(data["visibility_id"]) || blank_to_nil(data["scope_key"])

    with {:ok, conversation_ref} <- conversation_ref(run.workspace_ref, channel) do
      {:ok,
       %{
         conversation_ref: conversation_ref,
         message_ref: source_message_ref(data, nil),
         thread_ref: nil
       }}
    end
  end

  defp source_message_ref(data, nil), do: blank_to_nil(data["source_ref"]) || data["id"]
  defp source_message_ref(data, item), do: blank_to_nil(data["source_ref"]) || item.source_ref

  defp schedule_destination(run, data) do
    channel = blank_to_nil(data["delivery_channel_id"]) || data["channel_id"]

    with {:ok, conversation_ref} <- conversation_ref(run.workspace_ref, channel),
         {:ok, thread_ref} <-
           optional_text(blank_to_nil(data["thread_ts"]), 1_024, :schedule_thread) do
      {:ok, %{conversation_ref: conversation_ref, thread_ref: thread_ref}}
    end
  end

  defp conversation_ref("slack:" <> workspace, channel) do
    with {:ok, workspace} <- text(workspace, 256, :workspace_ref),
         {:ok, channel} <- text(channel, 256, :conversation_ref) do
      {:ok, "slack:#{workspace}:#{channel}"}
    end
  end

  defp conversation_ref(_workspace, _channel),
    do: {:error, {:cutover_mapping_invalid, :workspace_ref}}

  defp standing_task(data) do
    case data["workflow_json"] do
      %{"task" => task} when is_binary(task) and task != "" -> text(task, 4_000, :behavior_task)
      _other -> text(data["action_name"], 4_000, :behavior_task)
    end
  end

  defp source_filter(value) when value in ["human", "app", "any"], do: {:ok, value}
  defp source_filter(_value), do: {:error, {:cutover_mapping_invalid, :source_kind}}

  defp enabled_status(1), do: {:ok, :active}
  defp enabled_status(0), do: {:ok, :paused}

  defp behavior_status(1), do: {:ok, :active}
  defp behavior_status(0), do: {:ok, :disabled}

  defp catch_up("latest"), do: {:ok, :latest}
  defp catch_up("skip"), do: {:ok, :skip}
  defp catch_up(_value), do: {:error, {:cutover_mapping_invalid, :catch_up}}

  defp wait_deadline(data, cutover_at) do
    [data["deadline"], data["due_at"], data["poll_after"]]
    |> Enum.find_value(fn value ->
      case datetime(value, :wait_deadline) do
        {:ok, datetime} -> datetime
        {:error, _reason} -> nil
      end
    end)
    |> case do
      nil ->
        {:error, {:cutover_mapping_invalid, :wait_deadline}}

      deadline ->
        {:ok,
         if(DateTime.compare(deadline, cutover_at) == :gt,
           do: deadline,
           else: DateTime.add(cutover_at, 1, :second)
         )}
    end
  end

  defp options(options) do
    valid =
      Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
        Keyword.keys(options) -- @options == []

    if valid,
      do: profiles(Keyword.get(options, :work_profiles, %{})),
      else: {:error, {:invalid_cutover_import, :options}}
  end

  defp profiles(profiles) when is_map(profiles) do
    Enum.reduce_while(profiles, {:ok, %{}}, fn
      {{authority, repository} = key, profile}, {:ok, prepared}
      when is_binary(authority) and (is_binary(repository) or is_nil(repository)) ->
        case WorkProfile.new(profile) do
          {:ok, profile} -> {:cont, {:ok, Map.put(prepared, key, profile)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _invalid, _accumulator ->
        {:halt, {:error, {:invalid_cutover_import, :work_profiles}}}
    end)
  end

  defp profiles(_profiles), do: {:error, {:invalid_cutover_import, :work_profiles}}

  defp insert(changeset, kind) when kind in [:memory, :behavior] do
    with {:ok, now} <- database_now() do
      changeset
      |> Ecto.Changeset.change(inserted_at: now, updated_at: now)
      |> persist(kind)
    end
  end

  defp insert(changeset, kind), do: persist(changeset, kind)

  defp persist(changeset, kind) do
    case Repo.insert(changeset) do
      {:ok, value} -> {:ok, value}
      {:error, changeset} -> {:error, {:cutover_persistence_failed, kind, changeset.errors}}
    end
  end

  defp target_ref(kind, run, item) do
    digest = CanonicalJSON.digest([run.id, item.id, kind])
    "#{kind}:cutover:#{digest}"
  end

  defp confirmation_ref(run, item),
    do: "cutover:#{run.manifest_sha256}:#{item.source_sha256}"

  defp fingerprint(value), do: value |> json_value() |> CanonicalJSON.digest()

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_value(%{} = value) do
    Map.new(value, fn {key, nested} -> {to_string(key), json_value(nested)} end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp json_value(value), do: value

  defp datetime(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{} = datetime, 0} -> {:ok, normalize(datetime)}
      _invalid -> {:error, {:cutover_datetime_invalid, field}}
    end
  end

  defp datetime(_value, field), do: {:error, {:cutover_datetime_invalid, field}}

  defp normalize(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}

  defp text(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch,
       do: {:ok, value},
       else: {:error, {:cutover_mapping_invalid, field}}
  end

  defp optional_text(nil, _maximum, _field), do: {:ok, nil}
  defp optional_text("", _maximum, _field), do: {:ok, nil}
  defp optional_text(value, maximum, field), do: text(value, maximum, field)

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  defp nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value), do: 0

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_cutover_import, :run_id}}
    end
  end

  defp database_now do
    case Repo.query("SELECT clock_timestamp()") do
      {:ok, %{rows: [[%DateTime{} = now]]}} -> {:ok, normalize(now)}
      {:error, reason} -> {:error, {:cutover_database_time_failed, reason}}
    end
  end

  defp lock_global! do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["responder-cutover"]) do
      {:ok, _result} -> :ok
      {:error, reason} -> Repo.rollback({:cutover_lock_failed, reason})
    end
  end

  defp kind_rank(:memory), do: 0
  defp kind_rank(:behavior), do: 1
  defp kind_rank(:schedule), do: 2
  defp kind_rank(:episode), do: 3
  defp kind_rank(:wait), do: 4

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
