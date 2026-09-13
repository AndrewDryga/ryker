defmodule Ryker.CoopFleet.ControlPlane.Events do
  @moduledoc """
  Ordered event custody for a placement.

  Records each event batch a worker reports under the placement's cursor
  before any runtime projection sees it, verifies a replayed batch against
  what was stored, and ingests session events into Work activity only once
  the placement's authority, or the proven pre-binding exception to it,
  allows.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.{Command, Event, Placement}
  alias Ryker.CoopFleet.ControlPlane.{Commands, Shared}
  alias Ryker.Repo
  alias Ryker.Work.{Activity, Session}

  @doc false
  def apply_event_batches(worker_id, batches, now) do
    Enum.map(batches, fn batch -> apply_event_batch(worker_id, batch, now) end)
  end

  defp apply_event_batch(worker_id, batch, now) do
    placement =
      Repo.one(
        from(placement in Placement,
          where:
            placement.worker_id == ^worker_id and
              placement.session_id == ^batch["session_ref"] and
              placement.generation == ^batch["placement_generation"],
          lock: "FOR UPDATE"
        )
      ) || Shared.rollback({:coop_session_placement_not_found, batch["session_ref"]})

    after_sequence = batch["after_sequence"]
    events = batch["events"]
    last_sequence = last_event_sequence(events, after_sequence)
    session_events? = session_event_batch?(events)
    cursor = event_cursor(placement, session_events?)

    case event_batch_disposition(placement, after_sequence, last_sequence, events, cursor, now) do
      :unauthorized ->
        Shared.rollback({:coop_worker_event_placement_not_authorized, placement.id})

      :terminal_cleanup ->
        apply_terminal_cleanup_event_batch(
          placement,
          events,
          cursor,
          last_sequence,
          session_events?
        )

      disposition when disposition in [:fresh, :late_session_activity] ->
        apply_fresh_event_batch(placement, events, cursor, last_sequence, session_events?)

      :replay ->
        apply_replayed_event_batch(placement, events, cursor, session_events?)

      :conflict ->
        Shared.rollback({:coop_worker_event_cursor_conflict, cursor, after_sequence})
    end

    %{
      "placement_generation" => placement.generation,
      "sequence" => max(last_sequence, cursor),
      "session_ref" => placement.session_id
    }
  end

  defp last_event_sequence([], after_sequence), do: after_sequence
  defp last_event_sequence(events, _after_sequence), do: List.last(events)["sequence"]

  defp event_batch_disposition(_placement, cursor, _last_sequence, [], cursor, _now),
    do: :fresh

  defp event_batch_disposition(
         %Placement{state: :replaced} = placement,
         cursor,
         _last_sequence,
         events,
         cursor,
         _now
       ) do
    cond do
      terminal_workspace_discard?(placement, events) -> :terminal_cleanup
      bound_session_activity?(placement, events) -> :late_session_activity
      prebinding_session_activity?(placement, events, cursor) -> :late_session_activity
      true -> :unauthorized
    end
  end

  defp event_batch_disposition(placement, cursor, _last_sequence, events, cursor, now) do
    cond do
      Commands.command_result_authorized?(placement, now) -> :fresh
      prebinding_session_activity?(placement, events, cursor) -> :late_session_activity
      true -> :unauthorized
    end
  end

  defp event_batch_disposition(_placement, _after_sequence, last_sequence, _events, cursor, _now)
       when last_sequence <= cursor,
       do: :replay

  defp event_batch_disposition(
         _placement,
         _after_sequence,
         _last_sequence,
         _events,
         _cursor,
         _now
       ),
       do: :conflict

  defp apply_fresh_event_batch(placement, events, cursor, last_sequence, session_events?) do
    Enum.each(events, &insert_event!(placement, &1))
    ingest_session_events!(placement, events, cursor, session_events?)
    advance_event_cursor(placement, cursor, last_sequence, session_events?)
  end

  defp apply_terminal_cleanup_event_batch(
         placement,
         events,
         cursor,
         last_sequence,
         session_events?
       ) do
    Enum.each(events, &insert_event!(placement, &1))
    advance_event_cursor(placement, cursor, last_sequence, session_events?)
  end

  defp apply_replayed_event_batch(placement, events, cursor, session_events?) do
    Enum.each(events, &verify_replayed_event!(placement, &1))
    ingest_session_events!(placement, events, cursor, session_events?)
  end

  defp advance_event_cursor(_placement, cursor, cursor, _session_events?), do: :ok

  defp advance_event_cursor(placement, _cursor, last_sequence, session_events?) do
    placement
    |> change(event_cursor_change(session_events?, last_sequence))
    |> check_constraint(event_cursor_field(session_events?),
      name: event_cursor_constraint(session_events?)
    )
    |> Repo.update!()
  end

  defp event_cursor_constraint(true),
    do: :coop_session_placement_session_event_cursor_valid

  defp event_cursor_constraint(false), do: :coop_session_placement_identity_valid

  defp session_event_batch?([%{"kind" => "session_event"} | _rest]), do: true
  defp session_event_batch?(_events), do: false

  defp event_cursor(placement, true), do: placement.last_acked_session_event_sequence
  defp event_cursor(placement, false), do: placement.last_acked_event_sequence

  defp event_cursor_change(true, sequence),
    do: %{last_acked_session_event_sequence: sequence}

  defp event_cursor_change(false, sequence), do: %{last_acked_event_sequence: sequence}

  defp event_cursor_field(true), do: :last_acked_session_event_sequence
  defp event_cursor_field(false), do: :last_acked_event_sequence

  defp ingest_session_events!(_placement, _events, _cursor, false), do: :ok

  defp ingest_session_events!(placement, events, cursor, true) do
    session_events =
      Enum.flat_map(events, fn
        %{"kind" => "session_event", "payload" => event} -> [event]
        _coarse_event -> []
      end)

    case session_events do
      [] ->
        :ok

      [%{"session_id" => remote_id} | _rest] = values ->
        ingest_bound_session_events!(placement, remote_id, values, cursor)
    end
  end

  defp ingest_bound_session_events!(placement, remote_id, values, cursor) do
    expected_cursor = List.last(values)["sequence"]

    case Repo.get(Session, placement.session_id) do
      %Session{coop_session_id: nil} = session ->
        if prebinding_session_events?(placement, session, values, cursor),
          do: :ok,
          else: Shared.rollback({:coop_activity_session_conflict, remote_id})

      %Session{} ->
        case Activity.ingest_fleet(placement.session_id, remote_id, cursor, values) do
          {:ok, %{cursor: ^expected_cursor}} -> :ok
          {:error, reason} -> Shared.rollback(reason)
          _invalid -> Shared.rollback({:invalid_coop_activity, :cursor})
        end

      nil ->
        Shared.rollback(:work_session_not_found)
    end
  end

  defp prebinding_session_events?(_placement, _session, [created], 0),
    do: prebinding_session_created?(created)

  defp prebinding_session_events?(placement, session, [created, task_bound], 0) do
    prebinding_session_created?(created) and
      created["session_id"] == task_bound["session_id"] and
      prebinding_workspace_task_bound?(placement, session, task_bound)
  end

  defp prebinding_session_events?(placement, session, [task_bound], 1),
    do: prebinding_workspace_task_bound?(placement, session, task_bound)

  defp prebinding_session_events?(_placement, _session, _events, _cursor), do: false

  defp prebinding_session_created?(%{
         "sequence" => 1,
         "session_id" => remote_id,
         "type" => "session.created"
       })
       when is_binary(remote_id),
       do: true

  defp prebinding_session_created?(_event), do: false

  defp prebinding_workspace_task_bound?(
         placement,
         %Session{workspace_task: %{"offer_ref" => offer_ref} = workspace_task},
         %{
           "sequence" => 2,
           "session_id" => remote_id,
           "type" => "workspace.task_bound"
         } = event
       )
       when is_binary(remote_id) and is_binary(offer_ref) do
    command =
      Repo.one(
        from(command in Command,
          where:
            command.session_id == ^placement.session_id and
              command.placement_generation == ^placement.generation and
              command.kind == "ensure_workspace" and command.status == :succeeded,
          order_by: [desc: command.completed_at, desc: command.id],
          limit: 1
        )
      )

    Map.get(event, "turn_id") in [nil, ""] and
      match?(
        %Command{
          payload: %{"coop_session_id" => ^remote_id, "task" => ^workspace_task},
          result: %{
            "session" => %{
              "id" => ^remote_id,
              "workspace_task" => %{"offer_ref" => ^offer_ref}
            }
          }
        },
        command
      )
  end

  defp prebinding_workspace_task_bound?(_placement, _session, _event), do: false

  defp terminal_workspace_discard?(placement, [
         %{
           "kind" => "session_event",
           "payload" =>
             %{
               "session_id" => remote_id,
               "type" => "workspace.discarded"
             } = event
         }
       ]) do
    Map.get(event, "turn_id") in [nil, ""] and
      match?(%Session{coop_session_id: ^remote_id}, Repo.get(Session, placement.session_id))
  end

  defp terminal_workspace_discard?(_placement, _events), do: false

  defp bound_session_activity?(placement, [_event | _rest] = events) do
    case Repo.get(Session, placement.session_id) do
      %Session{coop_session_id: remote_id} when is_binary(remote_id) ->
        Enum.all?(events, fn
          %{"kind" => "session_event", "payload" => %{"session_id" => ^remote_id}} -> true
          _other -> false
        end)

      _unbound_or_missing ->
        false
    end
  end

  defp bound_session_activity?(_placement, _events), do: false

  defp prebinding_session_activity?(placement, events, cursor) do
    values =
      Enum.map(events, fn
        %{"kind" => "session_event", "payload" => event} -> event
        _other -> nil
      end)

    case Repo.get(Session, placement.session_id) do
      %Session{coop_session_id: nil} = session ->
        Enum.all?(values, &is_map/1) and
          prebinding_session_events?(placement, session, values, cursor)

      _bound_or_missing ->
        false
    end
  end

  defp insert_event!(placement, event) do
    fingerprint = event_fingerprint(event)

    stored_payload = if event["kind"] == "session_event", do: %{}, else: event["payload"]

    %Event{}
    |> cast(
      %{
        kind: event["kind"],
        payload: stored_payload,
        payload_fingerprint: fingerprint,
        placement_generation: placement.generation,
        placement_id: placement.id,
        sequence: event["sequence"],
        session_id: placement.session_id,
        worker_id: placement.worker_id
      },
      [
        :kind,
        :payload,
        :payload_fingerprint,
        :placement_generation,
        :placement_id,
        :sequence,
        :session_id,
        :worker_id
      ]
    )
    |> validate_required([
      :kind,
      :payload,
      :payload_fingerprint,
      :placement_generation,
      :placement_id,
      :sequence,
      :session_id,
      :worker_id
    ])
    |> unique_constraint([:placement_id, :sequence])
    |> foreign_key_constraint(:placement_id,
      name: :coop_worker_event_placement_identity_fkey
    )
    |> check_constraint(:kind, name: :coop_worker_event_identity_valid)
    |> Repo.insert()
    |> Shared.unwrap_write()
  end

  defp verify_replayed_event!(placement, event) do
    stored = replayed_event(placement.id, event)

    if stored == nil or stored.kind != event["kind"] or
         stored.payload_fingerprint != event_fingerprint(event) do
      Shared.rollback({:coop_worker_event_replay_conflict, event["sequence"]})
    end
  end

  defp replayed_event(placement_id, %{"kind" => "session_event", "sequence" => sequence}) do
    Repo.one(
      from(stored in Event,
        where:
          stored.placement_id == ^placement_id and stored.sequence == ^sequence and
            stored.kind == "session_event"
      )
    )
  end

  defp replayed_event(placement_id, %{"sequence" => sequence}) do
    Repo.one(
      from(stored in Event,
        where:
          stored.placement_id == ^placement_id and stored.sequence == ^sequence and
            stored.kind != "session_event"
      )
    )
  end

  defp event_fingerprint(event) do
    CanonicalJSON.digest(%{"kind" => event["kind"], "payload" => event["payload"]})
  end
end
