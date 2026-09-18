defmodule Ryker.State.Schedules do
  @moduledoc """
  Operator-confirmed, restart-safe recurring work.

  A schedule stores an inert typed goal and a resolved destination. Each due
  occurrence creates one fresh linked episode under the policy resolved at
  dispatch time; controls, Coop sessions, and writable forks are never reused.
  """

  import Ecto.Query

  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Episode}
  alias Ryker.Ingress.Input
  alias Ryker.Operator.Actions
  alias Ryker.Reference
  alias Ryker.Repo

  alias Ryker.State.{
    CardDelivery,
    Record,
    RecordChangeset,
    Schedule,
    ScheduleChangeset,
    ScheduleOccurrence,
    ScheduleOccurrenceChangeset,
    ScheduleRecurrence
  }

  alias Ryker.UTCDateTime
  alias Ryker.Work.{Custody, Turn}

  @confirmation_fields [:actor_ref, :confirmation_ref, :occurred_at, :record_ref, :target]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]

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
    end
  end

  @spec claim_due(String.t(), pos_integer()) :: {:ok, map() | nil} | {:error, term()}
  def claim_due(worker_ref, lease_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> claim_due_locked(worker_ref, lease_seconds, 0) end)
    end
  end

  @spec dispatch(
          String.t(),
          String.t(),
          (Schedule.t() -> {:ok, map()} | {:error, term()}),
          non_neg_integer()
        ) ::
          {:ok, map()} | {:error, term()}
  def dispatch(schedule_ref, lease_ref, policy_resolver, misfire_grace_seconds)
      when is_function(policy_resolver, 1) do
    with :ok <- reference(schedule_ref, :schedule_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- non_negative(misfire_grace_seconds, :misfire_grace_seconds) do
      Repo.transaction(fn ->
        dispatch_locked(schedule_ref, lease_ref, policy_resolver, misfire_grace_seconds)
      end)
    end
  end

  def dispatch(_schedule_ref, _lease_ref, _resolver, _grace),
    do: {:error, {:invalid_schedule_dispatch, :policy_resolver}}

  @spec renew(String.t(), String.t(), pos_integer()) :: {:ok, Schedule.t()} | {:error, term()}
  def renew(schedule_ref, lease_ref, lease_seconds) do
    with :ok <- reference(schedule_ref, :schedule_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> renew_locked(schedule_ref, lease_ref, lease_seconds) end)
    end
  end

  @spec defer(String.t(), String.t(), pos_integer(), term()) ::
          {:ok, Schedule.t()} | {:error, term()}
  def defer(schedule_ref, lease_ref, delay_seconds, reason) do
    with :ok <- reference(schedule_ref, :schedule_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive(delay_seconds, :delay_seconds) do
      Repo.transaction(fn -> defer_locked(schedule_ref, lease_ref, delay_seconds, reason) end)
    end
  end

  @spec set_status(String.t(), :paused | :active | :deleted) ::
          {:ok, Schedule.t()} | {:error, term()}
  def set_status(schedule_ref, status) when status in [:paused, :active, :deleted] do
    with :ok <- reference(schedule_ref, :schedule_ref) do
      Repo.transaction(fn -> set_status_locked(schedule_ref, status, nil) end)
    end
  end

  def set_status(_schedule_ref, _status), do: {:error, {:invalid_schedule, :status}}

  @spec set_status(String.t(), :paused | :active | :deleted, map()) ::
          {:ok, Schedule.t()} | {:error, term()}
  def set_status(schedule_ref, status, scope) when status in [:paused, :active, :deleted] do
    with :ok <- reference(schedule_ref, :schedule_ref),
         {:ok, scope} <- status_scope(scope) do
      Repo.transaction(fn -> set_status_locked(schedule_ref, status, scope) end)
    end
  end

  def set_status(_schedule_ref, _status, _scope),
    do: {:error, {:invalid_schedule, :status}}

  @doc "Changes one App Home schedule through revision-fenced operator action custody."
  @spec set_home_status(
          String.t(),
          :paused | :active | :deleted,
          pos_integer(),
          String.t(),
          String.t(),
          map()
        ) :: {:ok, map()} | {:error, term()}
  def set_home_status(
        schedule_ref,
        status,
        expected_revision,
        actor_ref,
        action_ref,
        scope
      )
      when status in [:paused, :active, :deleted] and is_integer(expected_revision) and
             expected_revision > 0 do
    with :ok <- reference(schedule_ref, :schedule_ref),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- reference(action_ref, :action_ref),
         {:ok, scope} <- status_scope(scope) do
      Actions.run(
        %{
          action: :update,
          action_ref: action_ref,
          actor_ref: actor_ref,
          kind: "schedule",
          request: %{
            "expected_revision" => expected_revision,
            "scope" => scope_document(scope),
            "status" => Atom.to_string(status)
          },
          resource_ref: schedule_ref
        },
        fn -> set_home_status_locked(schedule_ref, status, expected_revision, scope) end
      )
    end
  end

  def set_home_status(
        _schedule_ref,
        _status,
        _expected_revision,
        _actor_ref,
        _action_ref,
        _scope
      ),
      do: {:error, {:invalid_schedule, :status}}

  @doc "Starts one immediate occurrence without moving the saved recurrence cadence."
  @spec run_now(String.t(), String.t(), String.t(), map(), (Schedule.t() ->
                                                              {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def run_now(schedule_ref, actor_ref, action_ref, scope, policy_resolver)
      when is_function(policy_resolver, 1) do
    with :ok <- reference(schedule_ref, :schedule_ref),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- reference(action_ref, :action_ref),
         {:ok, scope} <- status_scope(scope) do
      Actions.run(
        %{
          action: :replay,
          action_ref: action_ref,
          actor_ref: actor_ref,
          kind: "schedule",
          request: %{"operation" => "run_now", "scope" => scope_document(scope)},
          resource_ref: schedule_ref
        },
        fn -> run_now_locked(schedule_ref, scope, policy_resolver) end
      )
    end
  end

  def run_now(_schedule_ref, _actor_ref, _action_ref, _scope, _policy_resolver),
    do: {:error, {:invalid_schedule, :run_now}}

  @doc false
  @spec run_now_for_operator(String.t(), String.t(), String.t(), (Schedule.t() ->
                                                                    {:ok, map()}
                                                                    | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def run_now_for_operator(schedule_ref, actor_ref, action_ref, policy_resolver)
      when is_function(policy_resolver, 1) do
    with :ok <- reference(schedule_ref, :schedule_ref),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- reference(action_ref, :action_ref) do
      Actions.run(
        %{
          action: :replay,
          action_ref: action_ref,
          actor_ref: actor_ref,
          kind: "schedule",
          request: %{"operation" => "run_now", "scope" => %{"kind" => "local_operator"}},
          resource_ref: schedule_ref
        },
        fn -> run_now_locked(schedule_ref, nil, policy_resolver) end
      )
    end
  end

  def run_now_for_operator(_schedule_ref, _actor_ref, _action_ref, _policy_resolver),
    do: {:error, {:invalid_schedule, :run_now}}

  defp confirm_locked(attributes) do
    with {:ok, record, source_episode, source_turn} <- lock_offer(attributes.record_ref),
         :ok <- delivered_from?(source_episode, source_turn, attributes.target) do
      case Repo.one(from(schedule in Schedule, where: schedule.offer_record_id == ^record.id)) do
        %Schedule{} = schedule ->
          %{schedule: schedule, status: :duplicate}

        nil when record.status == :open ->
          create_schedule(record, source_episode, attributes)

        nil ->
          Repo.rollback(:schedule_offer_stale)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp create_schedule(record, source_episode, attributes) do
    payload = record.payload

    with {:ok, recurrence} <-
           ScheduleRecurrence.normalize(
             payload["recurrence"],
             payload["timezone"],
             attributes.occurred_at
           ),
         {:ok, next_occurrence_at} <-
           ScheduleRecurrence.next_after(recurrence, payload["timezone"], attributes.occurred_at),
         :ok <- next_occurrence(next_occurrence_at, payload["expires_at"], attributes.occurred_at),
         {:ok, schedule} <-
           insert_schedule(record, source_episode, attributes, recurrence, next_occurrence_at),
         {:ok, _record} <-
           record
           |> RecordChangeset.confirm_resource(%{
             confirmed_at: attributes.occurred_at,
             confirmed_by_actor_ref: attributes.actor_ref,
             confirmation_ref: attributes.confirmation_ref,
             status: :confirmed
           })
           |> Repo.update() do
      %{schedule: schedule, status: :confirmed}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_schedule(record, source_episode, attributes, recurrence, next_occurrence_at) do
    payload = record.payload

    with {:ok, expires_at} <- optional_datetime(payload["expires_at"]) do
      id = Ecto.UUID.generate()

      %{
        authority: payload["authority"],
        confirmation_ref: attributes.confirmation_ref,
        confirmed_at: attributes.occurred_at,
        confirmed_by_actor_ref: attributes.actor_ref,
        destination_conversation_ref: source_episode.destination_conversation_ref,
        destination_thread_ref: source_episode.destination_thread_ref,
        destination_transport: source_episode.destination_transport,
        expires_at: expires_at,
        id: id,
        next_occurrence_at: next_occurrence_at,
        offer_record_id: record.id,
        recurrence: recurrence,
        ref: "schedule:#{id}",
        repository: payload["repository"],
        source_episode_id: source_episode.id,
        status: :active,
        task: payload["task"],
        timezone: payload["timezone"],
        title: payload["title"]
      }
      |> ScheduleChangeset.insert()
      |> Repo.insert()
      |> case do
        {:ok, schedule} -> {:ok, schedule}
        {:error, changeset} -> {:error, {:schedule_persistence_failed, changeset.errors}}
      end
    end
  end

  defp claim_due_locked(worker_ref, lease_seconds, skipped) when skipped < 100 do
    now = Repo.now!()

    schedule =
      Repo.one(
        from(schedule in Schedule,
          where: schedule.status == :active and schedule.next_occurrence_at <= ^now,
          where: is_nil(schedule.next_attempt_at) or schedule.next_attempt_at <= ^now,
          where: is_nil(schedule.lease_ref) or schedule.lease_expires_at <= ^now,
          order_by: [
            asc: schedule.next_occurrence_at,
            asc: schedule.inserted_at,
            asc: schedule.id
          ],
          limit: 1,
          lock: "FOR UPDATE SKIP LOCKED"
        )
      )

    case schedule do
      nil ->
        nil

      %Schedule{} = schedule ->
        if expired?(schedule, now) do
          update_schedule!(schedule, terminal_attributes(:expired))
          claim_due_locked(worker_ref, lease_seconds, skipped + 1)
        else
          lease_ref = "schedule-lease:#{Ecto.UUID.generate()}"

          claimed =
            update_schedule!(schedule, %{
              last_error: nil,
              lease_expires_at: DateTime.add(now, lease_seconds, :second),
              lease_owner: worker_ref,
              lease_ref: lease_ref,
              next_attempt_at: nil
            })

          %{lease_ref: lease_ref, schedule: claimed}
        end
    end
  end

  defp claim_due_locked(_worker_ref, _lease_seconds, _skipped), do: nil

  defp renew_locked(schedule_ref, lease_ref, lease_seconds) do
    now = Repo.now!()

    case live_schedule_lease(schedule_ref, lease_ref, now) do
      {:ok, schedule} ->
        update_schedule!(schedule, %{
          lease_expires_at: DateTime.add(now, lease_seconds, :second)
        })

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp defer_locked(schedule_ref, lease_ref, delay_seconds, reason) do
    now = Repo.now!()

    case live_schedule_lease(schedule_ref, lease_ref, now) do
      {:ok, schedule} ->
        update_schedule!(schedule, %{
          failure_count: schedule.failure_count + 1,
          last_error: bounded_error(reason),
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: DateTime.add(now, delay_seconds, :second)
        })

      {:error, defer_reason} ->
        Repo.rollback(defer_reason)
    end
  end

  defp dispatch_locked(schedule_ref, lease_ref, policy_resolver, misfire_grace_seconds) do
    now = Repo.now!()

    case live_schedule_lease(schedule_ref, lease_ref, now) do
      {:ok, schedule} ->
        dispatch_live_schedule(schedule, now, policy_resolver, misfire_grace_seconds)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp dispatch_live_schedule(schedule, now, policy_resolver, misfire_grace_seconds) do
    cond do
      active_occurrence?(schedule.id) ->
        released = release_schedule(schedule, DateTime.add(now, 60, :second))
        %{schedule: released, status: :overlap}

      DateTime.diff(now, schedule.next_occurrence_at, :second) > misfire_grace_seconds ->
        miss_occurrence(schedule, now)

      true ->
        dispatch_occurrence(schedule, now, policy_resolver)
    end
  end

  defp dispatch_occurrence(schedule, now, policy_resolver) do
    with {:ok, scheduled_for} <- scheduled_for(schedule, now),
         {:ok, policy} <- policy_resolver.(schedule),
         :ok <- policy(policy),
         {:ok, result} <- create_occurrence(schedule, scheduled_for, policy),
         {:ok, next_at} <-
           ScheduleRecurrence.next_after(schedule.recurrence, schedule.timezone, scheduled_for) do
      schedule = advance_schedule(schedule, next_at)
      Map.merge(result, %{schedule: schedule, status: :dispatched})
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp miss_occurrence(schedule, now) do
    scheduled_for = schedule.next_occurrence_at
    occurrence = insert_missed!(schedule, scheduled_for, "outside_misfire_grace")

    case ScheduleRecurrence.next_after(schedule.recurrence, schedule.timezone, now) do
      {:ok, next_at} ->
        schedule = advance_schedule(schedule, next_at)
        %{occurrence: occurrence, schedule: schedule, status: :missed}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # A run whose moment has passed is recorded as missed and the next one runs on
  # time. Catching up meant a morning check could fire in the afternoon because
  # the host had been down, and the card had to carry an option explaining it.
  defp scheduled_for(%Schedule{next_occurrence_at: scheduled_for}, _now), do: {:ok, scheduled_for}

  defp create_occurrence(schedule, scheduled_for, policy, trigger \\ :scheduled) do
    occurrence_id = Ecto.UUID.generate()
    episode_id = Ecto.UUID.generate()
    event_ref = "schedule-occurrence:#{occurrence_id}"
    turn_ref = "turn:schedule:#{occurrence_id}"

    with {:ok, input} <- schedule_input(schedule, scheduled_for, event_ref),
         command <- schedule_command(schedule, episode_id, turn_ref, input),
         {:ok, [transition]} <- Episodes.apply_batch_in_transaction([command]),
         {:ok, _session} <-
           Custody.pin_episode_in_transaction(
             transition.episode.id,
             policy.name,
             policy.digest,
             schedule.repository
           ),
         {:ok, occurrence} <-
           insert_occurrence(%{
             child_episode_id: transition.episode.id,
             event_ref: event_ref,
             id: occurrence_id,
             ref: "schedule-run:#{occurrence_id}",
             schedule_id: schedule.id,
             scheduled_for: scheduled_for,
             status: :dispatched,
             trigger: trigger
           }) do
      {:ok, %{episode: transition.episode, occurrence: occurrence}}
    end
  end

  defp schedule_input(schedule, scheduled_for, event_ref) do
    Input.new(%{
      actor: %{kind: :system, ref: "schedule"},
      content: %{
        "kind" => "scheduled_task",
        "schedule" => %{
          "authority" => Atom.to_string(schedule.authority),
          "repository" => schedule.repository,
          "scheduled_for" => DateTime.to_iso8601(scheduled_for),
          "schedule_ref" => schedule.ref,
          "task" => schedule.task,
          "title" => schedule.title
        }
      },
      destination: %{
        conversation_ref: schedule.destination_conversation_ref,
        thread_ref: schedule.destination_thread_ref,
        transport: schedule.destination_transport
      },
      event_kind: :event,
      event_ref: event_ref,
      native_input_id: event_ref,
      occurred_at: scheduled_for,
      occurred_at_source: :source,
      revision: 1,
      source: %{kind: "schedule", ref: schedule.ref},
      source_capabilities: %{},
      source_item_ref: nil
    })
  end

  defp schedule_command(schedule, episode_id, turn_ref, input) do
    %Command.AdmitInput{
      actor_ref: Input.actor_ref(input),
      destination: input.destination,
      episode_id: episode_id,
      episode_key: "schedule:#{schedule.id}:#{Ecto.UUID.generate()}",
      linked_episode_id: schedule.source_episode_id,
      native_input_id: input.native_input_id,
      occurred_at: input.occurred_at,
      payload: Input.document(input),
      revision: input.revision,
      turn_ref: turn_ref
    }
  end

  defp insert_occurrence(attributes) do
    attributes
    |> ScheduleOccurrenceChangeset.insert()
    |> Repo.insert()
    |> case do
      {:ok, occurrence} -> {:ok, occurrence}
      {:error, changeset} -> {:error, {:schedule_occurrence_persistence_failed, changeset.errors}}
    end
  end

  defp insert_missed!(schedule, scheduled_for, reason) do
    id = Ecto.UUID.generate()

    {:ok, occurrence} =
      insert_occurrence(%{
        id: id,
        missed_reason: reason,
        ref: "schedule-run:#{id}",
        schedule_id: schedule.id,
        scheduled_for: scheduled_for,
        status: :missed
      })

    occurrence
  end

  defp advance_schedule(schedule, nil),
    do: update_schedule!(schedule, terminal_attributes(:completed))

  defp advance_schedule(schedule, next_occurrence_at) do
    status =
      if is_struct(schedule.expires_at, DateTime) and
           DateTime.compare(next_occurrence_at, schedule.expires_at) != :lt,
         do: :expired,
         else: :active

    attributes =
      if status == :active,
        do: release_attributes(next_occurrence_at),
        else: terminal_attributes(status)

    update_schedule!(schedule, attributes)
  end

  defp release_schedule(schedule, next_attempt_at),
    do:
      update_schedule!(schedule, %{
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: next_attempt_at
      })

  defp release_attributes(next_occurrence_at) do
    %{
      failure_count: 0,
      last_error: nil,
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      next_attempt_at: nil,
      next_occurrence_at: next_occurrence_at,
      status: :active
    }
  end

  defp terminal_attributes(status) do
    %{
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      next_attempt_at: nil,
      next_occurrence_at: nil,
      status: status
    }
  end

  defp active_occurrence?(schedule_id) do
    Repo.exists?(
      from(occurrence in ScheduleOccurrence,
        join: episode in Episode,
        on: episode.id == occurrence.child_episode_id,
        where:
          occurrence.schedule_id == ^schedule_id and occurrence.status == :dispatched and
            episode.state not in [:complete, :cancelled]
      )
    )
  end

  defp lock_offer(record_ref) do
    query =
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        where: record.ref == ^record_ref and record.kind == "schedule_offer",
        select: {record, episode, turn},
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :schedule_offer_not_found}
      {record, episode, turn} -> {:ok, record, episode, turn}
    end
  end

  defp delivered_from?(episode, turn, target) do
    case CardDelivery.delivered_from?(episode, turn, target) do
      :ok -> :ok
      {:error, :mismatch} -> {:error, :schedule_offer_delivery_mismatch}
      {:error, :not_delivered} -> {:error, :schedule_offer_not_delivered}
    end
  end

  defp live_schedule_lease(schedule_ref, lease_ref, now) do
    case lock_schedule(schedule_ref) do
      nil ->
        {:error, :schedule_not_found}

      %Schedule{status: :active, lease_ref: ^lease_ref, lease_expires_at: %DateTime{} = expires} =
          schedule ->
        if DateTime.compare(expires, now) == :gt,
          do: {:ok, schedule},
          else: {:error, :schedule_lease_lost}

      %Schedule{} ->
        {:error, :schedule_lease_lost}
    end
  end

  defp lock_schedule(schedule_ref) do
    Repo.one(from(schedule in Schedule, where: schedule.ref == ^schedule_ref, lock: "FOR UPDATE"))
  end

  defp set_status_locked(schedule_ref, status, scope) do
    case lock_schedule(schedule_ref) do
      nil ->
        Repo.rollback(:schedule_not_found)

      %Schedule{} = schedule when not is_nil(scope) ->
        if schedule.destination_transport == scope.transport and
             String.starts_with?(schedule.destination_conversation_ref, scope.conversation_prefix) do
          update_schedule_status(schedule, status)
        else
          Repo.rollback(:schedule_scope_mismatch)
        end

      %Schedule{} = schedule ->
        update_schedule_status(schedule, status)
    end
  end

  defp run_now_locked(schedule_ref, scope, policy_resolver) do
    case lock_schedule(schedule_ref) do
      nil ->
        {:error, :schedule_not_found}

      %Schedule{} = schedule ->
        run_now_schedule(schedule, Repo.now!(), scope, policy_resolver)
    end
  end

  defp set_home_status_locked(schedule_ref, status, expected_revision, scope) do
    case lock_schedule(schedule_ref) do
      nil ->
        {:error, :schedule_not_found}

      %Schedule{} = schedule ->
        now = Repo.now!()

        cond do
          not schedule_in_scope?(schedule, scope) ->
            {:error, :schedule_scope_mismatch}

          schedule.status in [:expired, :deleted] ->
            {:error, :schedule_terminal}

          schedule.revision != expected_revision ->
            {:error, :schedule_revision_stale}

          expired?(schedule, now) ->
            expired_schedule_result(schedule)

          true ->
            updated = update_schedule_status(schedule, status)

            {:ok,
             %{
               previous: %{
                 "revision" => schedule.revision,
                 "status" => Atom.to_string(schedule.status)
               },
               outcome: %{
                 "revision" => updated.revision,
                 "status" => Atom.to_string(updated.status)
               }
             }}
        end
    end
  end

  defp run_now_schedule(schedule, now, scope, policy_resolver) do
    cond do
      not schedule_in_scope?(schedule, scope) ->
        {:error, :schedule_scope_mismatch}

      schedule.status in [:expired, :deleted] ->
        {:error, :schedule_terminal}

      expired?(schedule, now) ->
        expired_schedule_result(schedule)

      schedule.status not in [:active, :paused, :completed] ->
        {:error, :schedule_terminal}

      active_occurrence?(schedule.id) ->
        {:error, :schedule_occurrence_active}

      true ->
        create_manual_occurrence(schedule, now, policy_resolver)
    end
  end

  defp create_manual_occurrence(schedule, now, policy_resolver) do
    with {:ok, policy} <- policy_resolver.(schedule),
         :ok <- policy(policy),
         {:ok, result} <- create_occurrence(schedule, now, policy, :manual) do
      updated = update_schedule!(schedule, %{revision: schedule.revision + 1})

      {:ok,
       %{
         previous: %{
           "next_occurrence_at" => datetime(schedule.next_occurrence_at),
           "revision" => schedule.revision,
           "status" => Atom.to_string(schedule.status)
         },
         outcome: %{
           "episode_id" => result.episode.id,
           "revision" => updated.revision,
           "run_ref" => result.occurrence.ref,
           "scheduled_for" => DateTime.to_iso8601(result.occurrence.scheduled_for),
           "status" => "dispatched"
         }
       }}
    end
  end

  defp expired_schedule_result(schedule) do
    expired = update_schedule!(schedule, terminal_attributes(:expired))

    {:ok,
     %{
       previous: %{
         "next_occurrence_at" => datetime(schedule.next_occurrence_at),
         "revision" => schedule.revision,
         "status" => Atom.to_string(schedule.status)
       },
       outcome: %{
         "revision" => expired.revision,
         "status" => "expired"
       }
     }}
  end

  defp schedule_in_scope?(_schedule, nil), do: true

  defp schedule_in_scope?(schedule, scope) do
    schedule.destination_transport == scope.transport and
      String.starts_with?(schedule.destination_conversation_ref, scope.conversation_prefix)
  end

  defp scope_document(scope) do
    %{
      "conversation_prefix" => scope.conversation_prefix,
      "transport" => scope.transport
    }
  end

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(nil), do: nil

  defp update_schedule_status(%Schedule{status: status} = schedule, status), do: schedule

  defp update_schedule_status(%Schedule{status: current}, _status)
       when current in [:completed, :expired, :deleted],
       do: Repo.rollback(:schedule_terminal)

  defp update_schedule_status(%Schedule{} = schedule, status) do
    update_schedule!(schedule, %{
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      next_attempt_at: nil,
      revision: schedule.revision + 1,
      status: status
    })
  end

  defp status_scope(%{conversation_prefix: prefix, transport: transport} = scope) do
    if Map.keys(scope) |> Enum.sort() == [:conversation_prefix, :transport] and
         Reference.valid?(prefix) and Reference.valid?(transport) do
      {:ok, scope}
    else
      {:error, {:invalid_schedule, :scope}}
    end
  end

  defp status_scope(_scope), do: {:error, {:invalid_schedule, :scope}}

  defp next_occurrence(nil, _expires_at, _now), do: {:error, :schedule_not_future}

  defp next_occurrence(next, expires_at, now) do
    with true <- DateTime.compare(next, now) == :gt,
         {:ok, expiry} <- optional_datetime(expires_at),
         true <- is_nil(expiry) or DateTime.compare(next, expiry) == :lt do
      :ok
    else
      false -> {:error, :schedule_not_future}
      {:error, _reason} = error -> error
    end
  end

  defp policy(%{digest: digest, name: name}) do
    if Reference.valid?(name) and is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
      do: :ok,
      else: {:error, :schedule_policy_unavailable}
  end

  defp policy(_policy), do: {:error, :schedule_policy_unavailable}

  defp update_schedule!(schedule, attributes) do
    schedule
    |> ScheduleChangeset.update(attributes)
    |> Repo.update!()
  end

  defp confirmation_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> confirmation_attributes(),
       else: {:error, {:invalid_schedule_confirmation, :fields}}
  end

  defp confirmation_attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@confirmation_fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_schedule_confirmation, :fields}}
  end

  defp confirmation_attributes(_attributes),
    do: {:error, {:invalid_schedule_confirmation, :fields}}

  defp target(%{} = target) do
    if Map.keys(target) |> Enum.sort() == Enum.sort(@target_fields) do
      with :ok <- reference(target.transport, :transport),
           :ok <- reference(target.conversation_ref, :conversation_ref),
           :ok <- optional_reference(target.thread_ref, :thread_ref),
           :ok <- reference(target.message_ref, :message_ref) do
        {:ok, target}
      end
    else
      {:error, {:invalid_schedule_confirmation, :target}}
    end
  end

  defp target(_target), do: {:error, {:invalid_schedule_confirmation, :target}}

  defp optional_datetime(nil), do: {:ok, nil}
  defp optional_datetime(value), do: utc_datetime(value, :expires_at)

  defp utc_datetime(%DateTime{} = value, _field) do
    case UTCDateTime.exact(value) do
      {:ok, exact} -> {:ok, exact}
      :error -> {:error, {:invalid_schedule_confirmation, :datetime}}
    end
  end

  defp utc_datetime(value, field) do
    case UTCDateTime.parse(value) do
      {:ok, datetime} -> {:ok, datetime}
      :error -> {:error, {:invalid_schedule_confirmation, field}}
    end
  end

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field) do
    if Reference.valid?(value), do: :ok, else: {:error, {:invalid_schedule_confirmation, field}}
  end

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_schedule, field}}

  defp non_negative(value, _field) when is_integer(value) and value >= 0, do: :ok
  defp non_negative(_value, field), do: {:error, {:invalid_schedule, field}}

  defp expired?(%Schedule{expires_at: nil}, _now), do: false

  defp expired?(%Schedule{expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  defp bounded_error(reason) do
    value = inspect(reason, limit: 20, printable_limit: 3_500, width: 120)
    if byte_size(value) <= 4_096, do: value, else: String.byte_slice(value, 0, 4_093) <> "..."
  end
end
