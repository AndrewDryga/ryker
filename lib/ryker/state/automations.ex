defmodule Ryker.State.Automations do
  @moduledoc """
  Unified, revision-fenced lifecycle for time and source-event automations.

  Model calls create inert change offers. Only a delivered, operator-confirmed
  offer may mutate the exact automation revision, and every confirmed change
  remains in the immutable episode state-record history.
  """

  import Ecto.Query

  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Adapters
  alias Ryker.Operator.FailureDetail
  alias Ryker.Repo

  alias Ryker.State.{
    Behavior,
    BehaviorChangeset,
    CardDelivery,
    Record,
    RecordChangeset,
    Schedule,
    ScheduleChangeset,
    ScheduleOccurrence,
    ScheduleRecurrence,
    StandingAssignmentRun
  }

  alias Ryker.Work.Turn

  @actions ~w(update pause resume delete)
  @confirmation_fields [:actor_ref, :confirmation_ref, :occurred_at, :record_ref, :target]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]
  @time_patch_fields ~w(context_channel delivery_channel expires_at prompt repository title trigger)
  @source_patch_fields @time_patch_fields ++ ["hold"]

  @spec list_for_episode(Episode.t()) :: [map()]
  def list_for_episode(%Episode{} = episode) do
    workspace = workspace_ref(episode)

    schedules =
      Repo.all(
        from(schedule in Schedule,
          where:
            schedule.destination_transport == ^episode.destination_transport and
              schedule.destination_conversation_ref == ^episode.destination_conversation_ref and
              schedule.status != :deleted,
          order_by: [
            asc: schedule.next_occurrence_at,
            asc: schedule.inserted_at,
            asc: schedule.id
          ]
        )
      )

    behaviors =
      Repo.all(
        from(behavior in Behavior,
          where:
            behavior.kind == :standing_assignment and
              behavior.scope_kind == :conversation and
              behavior.scope_ref == ^episode.destination_conversation_ref and
              behavior.workspace_ref == ^workspace and
              behavior.status in [:active, :disabled],
          order_by: [asc: behavior.inserted_at, asc: behavior.id]
        )
      )

    Enum.map(schedules ++ behaviors, &document/1)
  end

  @spec fetch_for_episode(Episode.t(), String.t()) :: {:ok, Schedule.t() | Behavior.t()} | :error
  def fetch_for_episode(%Episode{} = episode, automation_id) when is_binary(automation_id) do
    case visible_schedule(episode, automation_id) do
      %Schedule{} = schedule -> {:ok, schedule}
      nil -> visible_behavior_result(episode, automation_id)
    end
  end

  def fetch_for_episode(_episode, _automation_id), do: :error

  @spec prepare_change(Episode.t(), map()) :: {:ok, map()} | {:error, term()}
  def prepare_change(%Episode{} = episode, %{} = proposal) do
    with action when action in @actions <- proposal["action"],
         automation_id when is_binary(automation_id) <- proposal["automation_id"],
         revision when is_integer(revision) and revision > 0 <- proposal["revision"],
         patch when is_map(patch) <- proposal["patch"],
         {:ok, automation} <- fetch_for_episode(episode, automation_id),
         :ok <- exact_revision(automation, revision),
         before <- document(automation),
         {:ok, after_document} <- changed_document(before, action, patch, episode) do
      {:ok,
       %{
         "action" => action,
         "after" => after_document,
         "automation_id" => automation_id,
         "automation_kind" => automation_kind(automation),
         "before" => before,
         "patch" => patch,
         "revision" => revision
       }}
    else
      nil -> {:error, :invalid_arguments}
      :error -> {:error, :not_found}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def prepare_change(_episode, _proposal), do: {:error, :invalid_arguments}

  @spec confirm(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def confirm(attributes) do
    with {:ok, attributes} <- confirmation_attributes(attributes),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- reference(attributes.confirmation_ref, :confirmation_ref),
         :ok <- reference(attributes.record_ref, :record_ref),
         {:ok, occurred_at} <- utc_datetime(attributes.occurred_at, :occurred_at),
         {:ok, target} <- target(attributes.target) do
      Repo.transaction(fn ->
        confirm_locked(%{attributes | occurred_at: occurred_at, target: target})
      end)
      |> transaction_result()
    end
  end

  @spec document(Schedule.t() | Behavior.t()) :: map()
  def document(%Schedule{} = schedule) do
    %{
      "automation_id" => schedule.ref,
      "context_channel" => schedule.destination_conversation_ref,
      "delivery_channel" => schedule.destination_conversation_ref,
      "expires_at" => schedule.expires_at && DateTime.to_iso8601(schedule.expires_at),
      "next_occurrence_at" =>
        schedule.next_occurrence_at && DateTime.to_iso8601(schedule.next_occurrence_at),
      "repository" => schedule.repository,
      "revision" => schedule.revision,
      "status" => Atom.to_string(schedule.status),
      "prompt" => schedule.task,
      "title" => schedule.title,
      "trigger" => public_time_trigger(schedule.recurrence, schedule.timezone)
    }
  end

  def document(%Behavior{} = behavior) do
    payload = behavior.payload

    %{
      "automation_id" => behavior.ref,
      "context_channel" => payload["context_channel"],
      "delivery_channel" => payload["delivery_channel"],
      "expires_at" => behavior.expires_at && DateTime.to_iso8601(behavior.expires_at),
      "hold" => payload["hold"],
      "next_occurrence_at" => nil,
      "repository" => payload["repository"],
      "revision" => behavior.revision,
      "status" => behavior_status(behavior.status),
      "prompt" => payload["task"],
      "title" => payload["title"],
      "trigger" => %{
        "filter" => payload["filter"],
        "source_kind" => payload["source_kind"],
        "type" => "source_event"
      }
    }
  end

  @spec detail(Schedule.t() | Behavior.t(), pos_integer()) :: map()
  def detail(%Schedule{} = schedule, limit) when is_integer(limit) and limit in 1..20 do
    latest_turns =
      from(turn in Turn,
        distinct: turn.episode_id,
        order_by: [asc: turn.episode_id, desc: turn.inserted_at, desc: turn.id],
        select: %{
          accepted_at: turn.accepted_at,
          delivered_at: turn.delivered_at,
          episode_id: turn.episode_id,
          failure_code: turn.last_error_code,
          failure_detail: turn.last_error_detail,
          finished_at: turn.remote_finished_at,
          started_at: turn.remote_started_at,
          turn_status: turn.status,
          work_attempt_count: turn.work_attempt_count
        }
      )

    runs =
      Repo.all(
        from(occurrence in ScheduleOccurrence,
          left_join: episode in Episode,
          on: episode.id == occurrence.child_episode_id,
          left_join: turn in subquery(latest_turns),
          on: turn.episode_id == occurrence.child_episode_id,
          where: occurrence.schedule_id == ^schedule.id,
          order_by: [desc: occurrence.scheduled_for, desc: occurrence.id],
          limit: ^limit,
          select: %{
            "accepted_at" => turn.accepted_at,
            "delivered_at" => turn.delivered_at,
            "episode_id" => occurrence.child_episode_id,
            "episode_state" => episode.state,
            "event_ref" => occurrence.event_ref,
            "failure_code" => turn.failure_code,
            "failure_detail" => turn.failure_detail,
            "finished_at" => turn.finished_at,
            "missed_reason" => occurrence.missed_reason,
            "outcome" => occurrence.status,
            "run_ref" => occurrence.ref,
            "scheduled_for" => occurrence.scheduled_for,
            "started_at" => turn.started_at,
            "trigger" => occurrence.trigger,
            "turn_status" => turn.turn_status,
            "work_attempt_count" => turn.work_attempt_count
          }
        )
      )
      |> Enum.map(&sanitize_run/1)
      |> Enum.map(&run_document/1)

    document(schedule) |> Map.put("recent_runs", runs)
  end

  def detail(%Behavior{} = behavior, limit) when is_integer(limit) and limit in 1..20 do
    runs =
      Repo.all(
        from(run in StandingAssignmentRun,
          left_join: episode in Episode,
          on: episode.id == run.episode_id,
          where: run.assignment_id == ^behavior.id,
          order_by: [desc: run.inserted_at, desc: run.id],
          limit: ^limit,
          select: %{
            "decision_action" => run.decision_action,
            "decision_ref" => run.decision_ref,
            "episode_id" => run.episode_id,
            "episode_state" => episode.state,
            "outcome" => run.outcome,
            "run_ref" => run.ref,
            "source_event_ref" => run.source_event_ref,
            "source_input_ref" => run.source_input_ref
          }
        )
      )
      |> Enum.map(&run_document/1)

    document(behavior) |> Map.put("recent_runs", runs)
  end

  defp confirm_locked(attributes) do
    with {:ok, record, episode, turn} <- lock_offer(attributes.record_ref),
         :ok <- delivered_from?(episode, turn, attributes.target) do
      case record.status do
        :confirmed -> duplicate_confirmation(record, episode)
        :open -> apply_change(record, episode, attributes)
        _other -> Repo.rollback(:automation_change_offer_stale)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_change(record, episode, attributes) do
    payload = record.payload

    with {:ok, automation} <- lock_visible_automation(episode, payload["automation_id"]),
         :ok <- exact_revision(automation, payload["revision"]),
         :ok <- exact_frozen_change(automation, episode, payload),
         {:ok, changed} <- persist_change(automation, payload, attributes.occurred_at),
         {:ok, _record} <- confirm_record(record, attributes) do
      %{automation: document(changed), status: :confirmed}
    else
      :error -> Repo.rollback(:automation_not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp exact_frozen_change(automation, episode, payload) do
    before = payload["before"]

    with true <- payload["automation_kind"] == automation_kind(automation),
         true <- before["automation_id"] == payload["automation_id"],
         true <- before["revision"] == payload["revision"],
         {:ok, expected_after} <-
           changed_document(before, payload["action"], payload["patch"], episode),
         true <- expected_after == payload["after"] do
      :ok
    else
      false -> {:error, :automation_change_offer_invalid}
      {:error, _reason} = error -> error
    end
  end

  defp duplicate_confirmation(record, episode) do
    case lock_visible_automation(episode, record.payload["automation_id"]) do
      {:ok, automation} -> %{automation: document(automation), status: :duplicate}
      :error -> Repo.rollback(:automation_not_found)
    end
  end

  defp persist_change(%Schedule{} = schedule, payload, occurred_at) do
    with :ok <- idle_schedule(schedule, occurred_at),
         {:ok, attributes} <- schedule_change(schedule, payload, occurred_at) do
      attributes = Map.merge(clear_schedule_lease(), attributes)

      schedule
      |> ScheduleChangeset.update(Map.put(attributes, :revision, schedule.revision + 1))
      |> Repo.update()
      |> persistence_result(:automation_schedule)
    end
  end

  defp persist_change(%Behavior{} = behavior, payload, occurred_at) do
    with {:ok, attributes} <- behavior_change(behavior, payload, occurred_at) do
      behavior
      |> BehaviorChangeset.update(Map.put(attributes, :revision, behavior.revision + 1))
      |> Repo.update()
      |> persistence_result(:automation_behavior)
    end
  end

  defp schedule_change(schedule, %{"action" => action, "after" => after_document}, occurred_at) do
    case action do
      "pause" -> schedule_status(schedule, :paused)
      "resume" -> resume_schedule(schedule, occurred_at)
      "delete" -> schedule_status(schedule, :deleted)
      "update" -> update_schedule_definition(schedule, after_document, occurred_at)
    end
  end

  defp schedule_status(%Schedule{status: :active}, :paused), do: {:ok, %{status: :paused}}
  defp schedule_status(%Schedule{status: :paused}, :deleted), do: {:ok, terminal_schedule()}
  defp schedule_status(%Schedule{status: :active}, :deleted), do: {:ok, terminal_schedule()}
  defp schedule_status(_schedule, _status), do: {:error, :automation_status_conflict}

  defp resume_schedule(%Schedule{status: :paused} = schedule, occurred_at) do
    with {:ok, next_occurrence_at} <-
           ScheduleRecurrence.next_after(schedule.recurrence, schedule.timezone, occurred_at),
         :ok <- future_occurrence(next_occurrence_at, schedule.expires_at, occurred_at) do
      {:ok, %{next_occurrence_at: next_occurrence_at, status: :active}}
    end
  end

  defp resume_schedule(_schedule, _occurred_at),
    do: {:error, :automation_status_conflict}

  defp update_schedule_definition(schedule, after_document, occurred_at) do
    with :ok <- editable_status(schedule.status),
         {:ok, recurrence} <- recurrence_from_trigger(after_document["trigger"]),
         timezone <- after_document["trigger"]["timezone"],
         {:ok, recurrence} <- ScheduleRecurrence.normalize(recurrence, timezone, occurred_at),
         {:ok, next_occurrence_at} <-
           ScheduleRecurrence.next_after(recurrence, timezone, occurred_at),
         {:ok, expires_at} <- optional_datetime(after_document["expires_at"]),
         :ok <- future_occurrence(next_occurrence_at, expires_at, occurred_at) do
      {:ok,
       %{
         authority: if(after_document["repository"], do: :repository_write, else: :read_only),
         expires_at: expires_at,
         failure_count: 0,
         last_error: nil,
         next_attempt_at: nil,
         next_occurrence_at: next_occurrence_at,
         recurrence: recurrence,
         repository: after_document["repository"],
         task: after_document["prompt"],
         timezone: timezone,
         title: after_document["title"]
       }}
    end
  end

  defp behavior_change(behavior, %{"action" => action, "after" => after_document}, occurred_at) do
    case action do
      "pause" -> behavior_status_change(behavior, :disabled)
      "resume" -> behavior_status_change(behavior, :active)
      "delete" -> behavior_delete(behavior)
      "update" -> update_behavior_definition(behavior, after_document, occurred_at)
    end
  end

  defp behavior_status_change(%Behavior{status: :active}, :disabled),
    do: {:ok, %{status: :disabled}}

  defp behavior_status_change(%Behavior{status: :disabled}, :active),
    do: {:ok, %{status: :active}}

  defp behavior_status_change(_behavior, _status),
    do: {:error, :automation_status_conflict}

  defp behavior_delete(%Behavior{status: status}) when status in [:active, :disabled],
    do: {:ok, %{status: :deleted}}

  defp behavior_delete(_behavior), do: {:error, :automation_status_conflict}

  defp update_behavior_definition(behavior, after_document, occurred_at) do
    with :ok <- editable_behavior_status(behavior.status),
         {:ok, expires_at} <- optional_datetime(after_document["expires_at"]),
         :ok <- future_expiry(expires_at, occurred_at) do
      trigger = after_document["trigger"]

      payload = %{
        "context_channel" => after_document["context_channel"],
        "delivery_channel" => after_document["delivery_channel"],
        "expires_at" => after_document["expires_at"],
        "filter" => trigger["filter"],
        "hold" => nil,
        "repository" => after_document["repository"],
        "source_kind" => trigger["source_kind"],
        "task" => after_document["prompt"],
        "title" => after_document["title"]
      }

      {:ok,
       %{expires_at: expires_at, identity_key: source_event_identity(payload), payload: payload}}
    end
  end

  defp changed_document(before, action, patch, episode) do
    with :ok <- change_allowed(before, action, patch),
         after_document <- apply_document_change(before, action, patch),
         :ok <- validate_document(after_document, automation_kind(before), episode),
         :ok <- registered_source(after_document, action) do
      {:ok, after_document}
    end
  end

  defp registered_source(
         %{"trigger" => %{"type" => "source_event", "source_kind" => source_kind}},
         action
       )
       when action in ~w(update resume) do
    if Map.has_key?(Adapters.default(), source_kind),
      do: :ok,
      else: {:error, :invalid_automation_source}
  end

  # Operators must still be able to pause or delete a previously saved bad rule.
  defp registered_source(_document, _action), do: :ok

  defp change_allowed(before, "update", patch) when map_size(patch) > 0 do
    allowed =
      if automation_kind(before) == "time", do: @time_patch_fields, else: @source_patch_fields

    if Enum.all?(Map.keys(patch), &(&1 in allowed)),
      do: :ok,
      else: {:error, :invalid_arguments}
  end

  defp change_allowed(before, action, patch) when action in ~w(pause resume delete) do
    expected =
      case action do
        "pause" -> "active"
        "resume" -> "paused"
        "delete" -> before["status"]
      end

    if map_size(patch) == 0 and before["status"] == expected and
         before["status"] in ~w(active paused),
       do: :ok,
       else: {:error, :automation_status_conflict}
  end

  defp change_allowed(_before, _action, _patch), do: {:error, :invalid_arguments}

  defp apply_document_change(before, "update", patch) do
    before |> Map.merge(patch) |> Map.put("revision", before["revision"] + 1)
  end

  defp apply_document_change(before, action, _patch) do
    status = %{"pause" => "paused", "resume" => "active", "delete" => "deleted"}[action]
    before |> Map.put("status", status) |> Map.put("revision", before["revision"] + 1)
  end

  defp validate_document(document, "time", episode) do
    with :ok <- common_document(document, episode),
         :ok <-
           exact_fields(
             document,
             ~w(automation_id context_channel delivery_channel expires_at next_occurrence_at prompt repository revision status title trigger)
           ),
         :ok <- optional_reference(document["repository"]) do
      time_trigger(document["trigger"])
    end
  end

  defp validate_document(document, "source_event", episode) do
    with :ok <- common_document(document, episode),
         :ok <-
           exact_fields(
             document,
             ~w(automation_id context_channel delivery_channel expires_at hold next_occurrence_at prompt repository revision status title trigger)
           ),
         :ok <- optional_reference(document["repository"]),
         :ok <- enum(document["hold"], [nil]) do
      source_trigger(document["trigger"])
    end
  end

  defp common_document(document, episode) do
    with :ok <- reference(document["automation_id"], :automation_id),
         :ok <- text(document["title"], 120, :title),
         :ok <- text(document["prompt"], 12_000, :prompt),
         true <- document["context_channel"] == episode.destination_conversation_ref,
         true <- document["delivery_channel"] == episode.destination_conversation_ref,
         true <- document["status"] in ~w(active paused deleted),
         true <- is_integer(document["revision"]) and document["revision"] > 0,
         {:ok, _expires_at} <- optional_datetime(document["expires_at"]) do
      :ok
    else
      false -> {:error, :unauthorized}
      {:error, _reason} = error -> error
    end
  end

  defp time_trigger(%{"type" => "time", "timezone" => timezone} = trigger) do
    with :ok <- text(timezone, 128, :timezone),
         {:ok, _recurrence} <- recurrence_from_trigger(trigger) do
      :ok
    end
  end

  defp time_trigger(_trigger), do: {:error, :invalid_arguments}

  defp source_trigger(%{
         "type" => "source_event",
         "source_kind" => source_kind,
         "filter" => filter
       })
       when is_map(filter),
       do: reference(source_kind, :source_kind)

  defp source_trigger(_trigger), do: {:error, :invalid_arguments}

  defp recurrence_from_trigger(%{"type" => "time", "recurrence" => kind} = trigger) do
    trigger
    |> stored_recurrence(kind)
    |> ScheduleRecurrence.prepare_shape()
    |> case do
      {:ok, %{"kind" => ^kind} = recurrence} -> {:ok, recurrence}
      {:ok, _recurrence} -> {:error, :invalid_arguments}
      {:error, _reason} -> {:error, :invalid_arguments}
    end
  end

  defp recurrence_from_trigger(_trigger), do: {:error, :invalid_arguments}

  defp stored_recurrence(trigger, "once"),
    do: %{"at" => trigger["at"], "kind" => "once"}

  defp stored_recurrence(trigger, "interval"),
    do: %{
      "every_seconds" => trigger["every_seconds"],
      "kind" => "interval",
      "starts_at" => trigger["starts_at"]
    }

  defp stored_recurrence(trigger, "daily"),
    do: %{"kind" => "daily", "time" => trigger["time"]}

  defp stored_recurrence(trigger, "weekly"),
    do: %{
      "kind" => "weekly",
      "time" => trigger["time"],
      "weekday" => trigger["weekday"]
    }

  defp stored_recurrence(trigger, "monthly"),
    do: %{"day" => trigger["day"], "kind" => "monthly", "time" => trigger["time"]}

  defp stored_recurrence(_trigger, _kind), do: %{}

  defp public_time_trigger(%{"kind" => kind} = recurrence, timezone) do
    recurrence
    |> Map.delete("kind")
    |> Map.put("recurrence", kind)
    |> Map.put("timezone", timezone)
    |> Map.put("type", "time")
  end

  defp lock_offer(record_ref) do
    query =
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        where: record.ref == ^record_ref and record.kind == "automation_change_offer",
        select: {record, episode, turn},
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :automation_change_offer_not_found}
      {record, episode, turn} -> {:ok, record, episode, turn}
    end
  end

  defp delivered_from?(episode, turn, target) do
    case CardDelivery.delivered_from?(episode, turn, target) do
      :ok -> :ok
      {:error, :mismatch} -> {:error, :automation_change_offer_delivery_mismatch}
      {:error, :not_delivered} -> {:error, :automation_change_offer_not_delivered}
    end
  end

  defp confirm_record(record, attributes) do
    record
    |> RecordChangeset.confirm_resource(%{
      confirmed_at: attributes.occurred_at,
      confirmed_by_actor_ref: attributes.actor_ref,
      confirmation_ref: attributes.confirmation_ref,
      status: :confirmed
    })
    |> Repo.update()
  end

  defp lock_visible_automation(episode, automation_id) do
    case Repo.one(visible_schedule_query(episode, automation_id) |> lock("FOR UPDATE")) do
      %Schedule{} = schedule -> {:ok, schedule}
      nil -> lock_visible_behavior(episode, automation_id)
    end
  end

  defp lock_visible_behavior(episode, automation_id) do
    case Repo.one(visible_behavior_query(episode, automation_id) |> lock("FOR UPDATE")) do
      %Behavior{} = behavior -> {:ok, behavior}
      nil -> :error
    end
  end

  defp visible_schedule(episode, automation_id),
    do: Repo.one(visible_schedule_query(episode, automation_id))

  defp visible_schedule_query(episode, automation_id) do
    from(schedule in Schedule,
      where:
        schedule.ref == ^automation_id and
          schedule.destination_transport == ^episode.destination_transport and
          schedule.destination_conversation_ref == ^episode.destination_conversation_ref
    )
  end

  defp visible_behavior_result(episode, automation_id) do
    case Repo.one(visible_behavior_query(episode, automation_id)) do
      %Behavior{} = behavior -> {:ok, behavior}
      nil -> :error
    end
  end

  defp visible_behavior_query(episode, automation_id) do
    workspace = workspace_ref(episode)

    from(behavior in Behavior,
      where:
        behavior.ref == ^automation_id and behavior.kind == :standing_assignment and
          behavior.workspace_ref == ^workspace and behavior.scope_kind == :conversation and
          behavior.scope_ref == ^episode.destination_conversation_ref
    )
  end

  defp idle_schedule(%Schedule{lease_ref: nil}, _occurred_at), do: :ok

  defp idle_schedule(%Schedule{lease_expires_at: %DateTime{} = expires_at}, occurred_at) do
    if DateTime.compare(expires_at, occurred_at) in [:lt, :eq],
      do: :ok,
      else: {:error, :automation_busy}
  end

  defp idle_schedule(_schedule, _occurred_at), do: {:error, :automation_busy}

  defp terminal_schedule do
    clear_schedule_lease()
    |> Map.merge(%{
      last_error: nil,
      next_attempt_at: nil,
      next_occurrence_at: nil,
      status: :deleted
    })
  end

  defp clear_schedule_lease,
    do: %{lease_expires_at: nil, lease_owner: nil, lease_ref: nil}

  defp editable_status(status) when status in [:active, :paused], do: :ok
  defp editable_status(_status), do: {:error, :automation_status_conflict}

  defp editable_behavior_status(status) when status in [:active, :disabled], do: :ok
  defp editable_behavior_status(_status), do: {:error, :automation_status_conflict}

  defp future_occurrence(nil, _expires_at, _occurred_at),
    do: {:error, :automation_not_future}

  defp future_occurrence(next, expires_at, occurred_at) do
    if DateTime.compare(next, occurred_at) == :gt and
         (is_nil(expires_at) or DateTime.compare(next, expires_at) == :lt),
       do: :ok,
       else: {:error, :automation_not_future}
  end

  defp future_expiry(nil, _occurred_at), do: :ok

  defp future_expiry(expires_at, occurred_at) do
    if DateTime.compare(expires_at, occurred_at) == :gt,
      do: :ok,
      else: {:error, :automation_not_future}
  end

  defp source_event_identity(payload) do
    "source-event:" <> Ryker.CanonicalJSON.digest([payload["title"]])
  end

  defp run_document(run) do
    Map.new(run, fn
      {key, %DateTime{} = value} -> {key, DateTime.to_iso8601(value)}
      {key, value} when is_atom(value) -> {key, Atom.to_string(value)}
      entry -> entry
    end)
  end

  defp sanitize_run(run) do
    Map.update!(run, "failure_detail", &FailureDetail.project/1)
  end

  defp automation_kind(%Schedule{}), do: "time"
  defp automation_kind(%Behavior{}), do: "source_event"
  defp automation_kind(%{"trigger" => %{"type" => type}}), do: type

  defp behavior_status(:active), do: "active"
  defp behavior_status(:disabled), do: "paused"
  defp behavior_status(:deleted), do: "deleted"
  defp behavior_status(:expired), do: "expired"
  defp behavior_status(:superseded), do: "superseded"

  defp exact_revision(%{revision: revision}, revision), do: :ok

  defp exact_revision(%{revision: revision}, _submitted),
    do: {:error, {:automation_revision_conflict, revision}}

  defp confirmation_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> confirmation_attributes(),
       else: {:error, {:invalid_automation_confirmation, :fields}}
  end

  defp confirmation_attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@confirmation_fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_automation_confirmation, :fields}}
  end

  defp confirmation_attributes(_attributes),
    do: {:error, {:invalid_automation_confirmation, :fields}}

  defp target(%{} = target) do
    if Map.keys(target) |> Enum.sort() == Enum.sort(@target_fields) do
      with :ok <- reference(target.transport, :transport),
           :ok <- reference(target.conversation_ref, :conversation_ref),
           :ok <- optional_reference(target.thread_ref),
           :ok <- reference(target.message_ref, :message_ref) do
        {:ok, target}
      end
    else
      {:error, {:invalid_automation_confirmation, :target}}
    end
  end

  defp target(_target), do: {:error, {:invalid_automation_confirmation, :target}}

  defp utc_datetime(%DateTime{} = value, _field) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0 do
      {microsecond, _precision} = value.microsecond
      {:ok, %{value | microsecond: {microsecond, 6}}}
    else
      {:error, {:invalid_automation_confirmation, :datetime}}
    end
  end

  defp utc_datetime(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, {:invalid_automation_confirmation, field}}
    end
  end

  defp utc_datetime(_value, field), do: {:error, {:invalid_automation_confirmation, field}}

  defp optional_datetime(nil), do: {:ok, nil}
  defp optional_datetime(value), do: utc_datetime(value, :expires_at)

  defp optional_reference(nil), do: :ok
  defp optional_reference(value), do: reference(value, :reference)

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_automation_confirmation, field}}
  end

  defp text(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_automation_confirmation, field}}
  end

  defp enum(value, values) do
    if value in values, do: :ok, else: {:error, :invalid_arguments}
  end

  defp exact_fields(document, fields) do
    if Map.keys(document) |> Enum.sort() == Enum.sort(fields),
      do: :ok,
      else: {:error, :invalid_arguments}
  end

  defp workspace_ref(%Episode{
         destination_transport: "slack",
         destination_conversation_ref: "slack:" <> rest
       }),
       do: "slack:" <> (rest |> String.split(":", parts: 2) |> hd())

  defp workspace_ref(%Episode{
         destination_transport: "github",
         destination_conversation_ref: "github:" <> rest
       }),
       do: "github:" <> (rest |> String.split(":", parts: 2) |> hd())

  defp workspace_ref(%Episode{} = episode), do: episode.destination_conversation_ref

  defp persistence_result({:ok, resource}, _kind), do: {:ok, resource}

  defp persistence_result({:error, %Ecto.Changeset{} = changeset}, kind),
    do: {:error, {:automation_persistence_failed, kind, changeset.errors}}

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
