defmodule Ryker.Behaviors.Automations do
  @moduledoc """
  Unified, revision-fenced lifecycle for time and source-event automations.

  Model calls create inert change offers. Only a delivered, operator-confirmed
  offer may mutate the exact automation revision, and every confirmed change
  remains in the immutable episode state-record history.
  """
  alias Ryker.Behaviors
  alias Ryker.Behaviors.Behavior
  alias Ryker.Behaviors.StandingAssignmentRun
  alias Ryker.Episodes.Episode
  alias Ryker.Episodes.Scope
  alias Ryker.Ingress.Adapters
  alias Ryker.Operator.FailureDetail
  alias Ryker.Records
  alias Ryker.Records.CardDelivery
  alias Ryker.Records.OfferConfirmation
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Schedules
  alias Ryker.Schedules.Schedule
  alias Ryker.Schedules.ScheduleOccurrence
  alias Ryker.Schedules.ScheduleRecurrence
  alias Ryker.Slack.ChannelFence
  alias Ryker.UTCDateTime

  @actions ~w(update pause resume delete)
  # An automation lives in the conversation that made it, so its channels are
  # not part of a change: a patch naming them is refused, not silently kept.
  @time_patch_fields ~w(expires_at prompt repository title trigger)
  @source_patch_fields @time_patch_fields ++ ["hold"]

  @spec list_for_episode(Episode.t()) :: [map()]
  def list_for_episode(%Episode{} = episode) do
    workspace = Scope.workspace_ref(episode)

    schedules =
      Schedule.Query.by_conversation(
        episode.destination_transport,
        episode.destination_conversation_ref
      )
      |> Schedule.Query.not_deleted()
      |> Schedule.Query.ordered_by_next_occurrence_at()
      |> Repo.all()

    behaviors =
      workspace
      |> conversation_assignments(episode)
      |> Behavior.Query.ordered_by_oldest()
      |> Repo.all()

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
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def prepare_change(_episode, _proposal), do: {:error, :invalid_arguments}

  @spec confirm(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def confirm(attributes) do
    with {:ok, confirmation} <-
           OfferConfirmation.new(attributes, :invalid_automation_confirmation) do
      Repo.transaction(fn -> confirm_locked(confirmation) end)
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
    runs =
      schedule.id
      |> ScheduleOccurrence.Query.recent_runs(limit)
      |> Repo.all()
      |> Enum.map(&sanitize_run/1)
      |> Enum.map(&run_document/1)

    document(schedule) |> Map.put("recent_runs", runs)
  end

  def detail(%Behavior{} = behavior, limit) when is_integer(limit) and limit in 1..20 do
    runs =
      behavior.id
      |> StandingAssignmentRun.Query.recent_for_assignment(limit)
      |> Repo.all()
      |> Enum.map(&run_document/1)

    document(behavior) |> Map.put("recent_runs", runs)
  end

  defp confirm_locked(attributes) do
    with {:ok, record, episode, turn} <- lock_offer(attributes.record_ref),
         :ok <-
           ChannelFence.authorize_in_transaction(
             episode.destination_transport,
             episode.destination_conversation_ref
           ),
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
         {:ok, _record} <- Records.confirm_offer(record, attributes) do
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
      {:error, reason} -> {:error, reason}
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
      |> Schedule.Changeset.update(Map.put(attributes, :revision, schedule.revision + 1))
      |> Repo.update()
      |> persistence_result(:automation_schedule)
    end
  end

  defp persist_change(%Behavior{} = behavior, payload, occurred_at) do
    case behavior_change(behavior, payload, occurred_at) do
      {:ok, %{status: :deleted}} ->
        {:ok, Behaviors.redact!(behavior, :deleted, "deleted_payload_sha256")}

      {:ok, attributes} ->
        :ok = Behaviors.supersede_namesakes_in_transaction(struct(behavior, attributes))

        behavior
        |> Behavior.Changeset.update(Map.put(attributes, :revision, behavior.revision + 1))
        |> Repo.update()
        |> persistence_result(:automation_behavior)

      {:error, reason} ->
        {:error, reason}
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
       %{
         expires_at: expires_at,
         identity_key: Behaviors.source_event_identity(payload),
         payload: payload
       }}
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
      {:error, reason} -> {:error, reason}
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

  # The same reading of a trigger as creation's, so an update can neither
  # narrow a set of days to one nor save a recurrence a new offer could not.
  defp recurrence_from_trigger(trigger) do
    with {:ok, recurrence} <- ScheduleRecurrence.from_trigger(trigger) do
      case ScheduleRecurrence.prepare_shape(recurrence) do
        {:ok, prepared} -> {:ok, prepared}
        {:error, _reason} -> {:error, :invalid_arguments}
      end
    end
  end

  defp public_time_trigger(%{"kind" => kind} = recurrence, timezone) do
    recurrence
    |> Map.delete("kind")
    |> Map.put("recurrence", kind)
    |> Map.put("timezone", timezone)
    |> Map.put("type", "time")
  end

  defp lock_offer(record_ref) do
    case Records.lock_offer(record_ref, ["automation_change_offer"]) do
      {:error, :not_found} -> {:error, :automation_change_offer_not_found}
      found -> found
    end
  end

  defp delivered_from?(episode, turn, target) do
    case CardDelivery.delivered_from?(episode, turn, target) do
      :ok -> :ok
      {:error, :mismatch} -> {:error, :automation_change_offer_delivery_mismatch}
      {:error, :not_delivered} -> {:error, :automation_change_offer_not_delivered}
    end
  end

  defp lock_visible_automation(episode, automation_id) do
    schedule =
      episode
      |> visible_schedule_query(automation_id)
      |> Schedule.Query.lock_for_update()
      |> Repo.one()

    case schedule do
      %Schedule{} = schedule -> {:ok, schedule}
      nil -> lock_visible_behavior(episode, automation_id)
    end
  end

  defp lock_visible_behavior(episode, automation_id) do
    behavior =
      episode
      |> visible_behavior_query(automation_id)
      |> Behavior.Query.lock_for_update()
      |> Repo.one()

    case behavior do
      %Behavior{} = behavior -> {:ok, behavior}
      nil -> :error
    end
  end

  defp visible_schedule(episode, automation_id),
    do: Repo.one(visible_schedule_query(episode, automation_id))

  # One automation is found exactly where the list finds it: a deleted one is
  # gone from both, so it can be neither read nor changed.
  defp visible_schedule_query(episode, automation_id) do
    automation_id
    |> Schedule.Query.by_ref()
    |> Schedule.Query.by_conversation(
      episode.destination_transport,
      episode.destination_conversation_ref
    )
    |> Schedule.Query.not_deleted()
  end

  defp visible_behavior_result(episode, automation_id) do
    case Repo.one(visible_behavior_query(episode, automation_id)) do
      %Behavior{} = behavior -> {:ok, behavior}
      nil -> :error
    end
  end

  defp visible_behavior_query(episode, automation_id) do
    episode
    |> Scope.workspace_ref()
    |> conversation_assignments(episode)
    |> Behavior.Query.by_ref(automation_id)
  end

  # The standing assignments a conversation lists as its automations.
  defp conversation_assignments(workspace, episode) do
    Behavior.Query.by_kind(:standing_assignment)
    |> Behavior.Query.by_workspace(workspace)
    |> Behavior.Query.scoped_to(:conversation, episode.destination_conversation_ref)
    |> Behavior.Query.by_status([:active, :disabled])
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

  defp optional_datetime(nil), do: {:ok, nil}

  defp optional_datetime(value) do
    case UTCDateTime.parse(value) do
      {:ok, datetime} -> {:ok, datetime}
      :error -> {:error, {:invalid_automation_confirmation, :expires_at}}
    end
  end

  defp optional_reference(nil), do: :ok
  defp optional_reference(value), do: reference(value, :reference)

  defp reference(value, field) do
    if Reference.valid?(value), do: :ok, else: {:error, {:invalid_automation_confirmation, field}}
  end

  defp text(value, maximum, field) do
    if Reference.valid?(value, maximum),
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

  defp persistence_result({:ok, resource}, _kind) do
    announce(resource)
    {:ok, resource}
  end

  defp persistence_result({:error, %Ecto.Changeset{} = changeset}, kind),
    do: {:error, {:automation_persistence_failed, kind, changeset.errors}}

  # The owning context announces each automation changed here; `Records`
  # announces the record that confirmed the change.
  defp announce(%Schedule{} = schedule), do: Schedules.broadcast_schedule_updated(schedule)
  defp announce(%Behavior{id: id}), do: Behaviors.broadcast_behavior_updated(id)
end
