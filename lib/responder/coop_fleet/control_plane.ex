defmodule Responder.CoopFleet.ControlPlane do
  @moduledoc """
  Durable registry, placement, command, and ordered-event custody for Coop workers.

  The caller authenticates the worker transport before `handle_poll/3`. This
  module then binds that identity to an enrolled worker row, applies the whole
  poll transactionally, and returns only commands for current leased
  placements. It records remote events before later runtime projection; a
  network acknowledgement never outruns durable receipt.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.CoopFleet.{Certificate, Command, Event, Placement, Protocol, Worker}
  alias Responder.Repo
  alias Responder.StateTools.Binding
  alias Responder.Work.{Activity, Session, StateBinding, Turn}

  @current_placement_states [:assigning, :active, :draining, :revoking]
  @terminal_command_states [:succeeded, :failed, :uncertain]
  @command_kinds ~w(
    ensure_workspace
    create_session
    get_session
    submit_turn
    get_turn
    get_output_artifact
    get_changes
    get_changes_page
    run_review
    plan_discard
    discard_session
    get_review_patch
    validate_candidate
    cancel_turn
    fence_operation
    checkpoint_workspace
    close_session
    reconcile_operation
  )
  @reference ~r/\A[A-Za-z0-9_.:-]+\z/
  @maximum_lease_seconds 3_600
  @heartbeat_stale_seconds 60
  @maximum_clock_skew_seconds 30

  @spec authorize_worker(String.t(), String.t(), String.t()) ::
          {:ok, Worker.t()} | {:error, term()}
  def authorize_worker(worker_id, workspace_ref, certificate_sha256) do
    with :ok <- reference(worker_id, 256, :worker_id),
         :ok <- reference(workspace_ref, 256, :workspace_ref),
         :ok <- digest(certificate_sha256, :certificate_sha256) do
      transaction(fn ->
        authorize_worker_locked(worker_id, workspace_ref, certificate_sha256)
      end)
    end
  end

  @spec handle_poll_certificate(binary(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def handle_poll_certificate(certificate, document, options \\ [])

  def handle_poll_certificate(certificate, document, options) when is_binary(certificate) do
    certificate_sha256 = :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower)

    case active_certificate_worker(certificate_sha256) do
      nil ->
        {:error, :coop_worker_certificate_not_authorized}

      worker_id ->
        handle_poll(
          worker_id,
          document,
          Keyword.put(options, :certificate_sha256, certificate_sha256)
        )
    end
  end

  def handle_poll_certificate(_certificate, _document, _options),
    do: {:error, :coop_worker_certificate_not_authorized}

  @spec authenticate_certificate(binary()) :: {:ok, String.t()} | {:error, term()}
  def authenticate_certificate(certificate)
      when is_binary(certificate) and byte_size(certificate) > 0 do
    certificate_sha256 = :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower)

    case active_certificate_worker(certificate_sha256) do
      worker_id when is_binary(worker_id) -> {:ok, worker_id}
      nil -> {:error, :coop_worker_certificate_not_authorized}
    end
  end

  def authenticate_certificate(_certificate),
    do: {:error, :coop_worker_certificate_not_authorized}

  @spec handle_poll(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_poll(authenticated_worker_id, document, options \\ []) do
    lease_seconds = Keyword.get(options, :lease_seconds, 60)
    certificate_sha256 = Keyword.get(options, :certificate_sha256)
    state_tools_secret = Keyword.get(options, :state_tools_secret)

    with :ok <- reference(authenticated_worker_id, 256, :worker_id),
         :ok <- lease_seconds(lease_seconds),
         {:ok, poll} <- Protocol.poll(document),
         :ok <- poll_identity(authenticated_worker_id, poll) do
      transaction(fn ->
        apply_poll(
          authenticated_worker_id,
          poll,
          lease_seconds,
          certificate_sha256,
          state_tools_secret
        )
      end)
    end
  end

  @spec place_session(Ecto.UUID.t(), map(), pos_integer()) ::
          {:ok, Placement.t()} | {:error, term()}
  def place_session(session_id, requirements, lease_seconds) do
    with :ok <- uuid(session_id, :session_id),
         {:ok, prepared} <- requirements(requirements),
         :ok <- lease_seconds(lease_seconds) do
      result = transaction(fn -> place_session_locked(session_id, prepared, lease_seconds) end)
      placement_result(result, session_id)
    end
  end

  defp placement_result({:ok, {:replacement_required, generation}}, session_id),
    do: {:error, {:coop_session_replacement_required, session_id, generation}}

  defp placement_result(
         {:ok, {:replacement_pending, generation, lease_expires_at}},
         session_id
       ),
       do: {:error, {:coop_session_replacement_pending, session_id, generation, lease_expires_at}}

  defp placement_result(result, _session_id), do: result

  @spec enqueue_command(Ecto.UUID.t(), String.t(), map(), String.t()) ::
          {:ok, Command.t()} | {:error, term()}
  def enqueue_command(placement_id, kind, payload, idempotency_key) do
    with :ok <- uuid(placement_id, :placement_id),
         :ok <- enum(kind, @command_kinds, :command_kind),
         :ok <- CanonicalJSON.validate(payload, max_bytes: 768 * 1_024),
         :ok <- reference(idempotency_key, 512, :idempotency_key) do
      transaction(fn ->
        enqueue_command_locked(placement_id, kind, payload, idempotency_key)
      end)
    else
      {:error, {:too_large, _actual, _limit}} ->
        {:error, {:invalid_coop_worker_command, :payload}}

      {:error, _reason} = error ->
        error
    end
  end

  defp authorize_worker_locked(worker_id, workspace_ref, certificate_sha256) do
    worker =
      case locked_worker(worker_id) do
        nil ->
          %Worker{}
          |> cast(
            %{
              certificate_sha256: certificate_sha256,
              id: worker_id,
              workspace_ref: workspace_ref,
              state: :offline
            },
            [:certificate_sha256, :id, :workspace_ref, :state]
          )
          |> validate_required([:certificate_sha256, :id, :workspace_ref, :state])
          |> unique_constraint(:certificate_sha256)
          |> check_constraint(:id, name: :coop_worker_identity_valid)
          |> Repo.insert()
          |> unwrap_write()

        %Worker{workspace_ref: ^workspace_ref, certificate_sha256: ^certificate_sha256} = worker ->
          worker

        %Worker{workspace_ref: ^workspace_ref, certificate_sha256: stored} ->
          rollback({:coop_worker_certificate_conflict, stored, certificate_sha256})

        %Worker{workspace_ref: stored} ->
          rollback({:coop_worker_workspace_conflict, stored, workspace_ref})
      end

    ensure_manual_certificate!(worker_id, certificate_sha256)
    worker
  end

  defp apply_poll(worker_id, poll, lease_seconds, certificate_sha256, state_tools_secret) do
    now = database_now!()
    hello = poll["worker"]
    worker = authenticated_worker!(worker_id, hello["workspace_ref"], certificate_sha256)
    clock_at = parse_timestamp!(hello["clock_at"])
    ensure_clock_skew!(worker_id, clock_at, now)

    worker =
      worker
      |> change(%{
        build_version: hello["build_version"],
        capabilities: hello["capabilities"],
        capacity: hello["capacity"],
        clock_at: clock_at,
        last_seen_at: now,
        policy_authority_digests: hello["policy_authority_digests"],
        policy_digests: hello["policy_digests"],
        protocol_version: hello["protocol_version"],
        repositories: hello["repositories"],
        sandbox_digest: hello["sandbox_digest"],
        state: heartbeat_state(worker, hello["state"])
      })
      |> validate_required([
        :build_version,
        :capabilities,
        :capacity,
        :clock_at,
        :last_seen_at,
        :policy_authority_digests,
        :policy_digests,
        :protocol_version,
        :repositories,
        :sandbox_digest,
        :state
      ])
      |> check_constraint(:id, name: :coop_worker_identity_valid)
      |> check_constraint(:capacity, name: :coop_worker_documents_valid)
      |> Repo.update()
      |> unwrap_write()

    renew_worker_placements(worker, now, lease_seconds)
    acknowledge_commands(worker_id, poll["acknowledged_command_ids"], now)

    acknowledged_result_command_ids =
      apply_command_results(worker_id, poll["command_results"], now)

    event_acknowledgements = apply_event_batches(worker_id, poll["event_batches"], now)
    commands = deliver_commands(worker_id, now, state_tools_secret)

    response = %{
      "acknowledged_result_command_ids" => acknowledged_result_command_ids,
      "commands" => commands,
      "event_acknowledgements" => event_acknowledgements,
      "poll_ref" => poll["poll_ref"],
      "server_time" => DateTime.to_iso8601(now),
      "version" => Protocol.version()
    }

    case Protocol.response(response) do
      {:ok, prepared} -> prepared
      {:error, reason} -> rollback(reason)
    end
  end

  defp place_session_locked(session_id, requirements, lease_seconds) do
    session =
      Repo.one(
        from(session in Session,
          where: session.id == ^session_id,
          lock: "FOR UPDATE"
        )
      ) || rollback({:coop_session_not_found, session_id})

    now = database_now!()

    case current_placement(session_id) do
      %Placement{} = placement ->
        if placement.state == :active and
             DateTime.compare(placement.lease_expires_at, now) == :gt do
          placement
        else
          replacement_required(placement, now)
        end

      nil ->
        case latest_placement(session_id) do
          %Placement{generation: generation} = placement ->
            fail_undelivered_commands(placement, now)

            if cancelling_bound_session?(session) do
              recover_cancellation_placement(
                session,
                placement,
                requirements,
                lease_seconds,
                now
              )
            else
              {:replacement_required, generation}
            end

          nil ->
            insert_placement(session, requirements, lease_seconds, now)
        end
    end
  end

  defp replacement_required(placement, now) do
    if DateTime.compare(placement.lease_expires_at, now) == :gt do
      {:replacement_pending, placement.generation, placement.lease_expires_at}
    else
      replaced =
        placement
        |> change(%{state: :replaced})
        |> Repo.update!()

      fail_undelivered_commands(replaced, now)

      {:replacement_required, placement.generation}
    end
  end

  defp insert_placement(session, requirements, lease_seconds, now) do
    worker = choose_worker!(session, requirements, now)
    insert_placement_on_worker(session, worker, requirements, lease_seconds, now)
  end

  defp insert_placement_on_worker(session, worker, requirements, lease_seconds, now) do
    generation = next_placement_generation(session.id)
    id = Ecto.UUID.generate()
    frozen_requirements = placement_requirements(session, worker, requirements)

    %Placement{}
    |> cast(
      %{
        episode_id: session.episode_id,
        generation: generation,
        id: id,
        last_acked_event_sequence: 0,
        last_acked_session_event_sequence: 0,
        lease_expires_at: DateTime.add(now, lease_seconds, :second),
        lease_ref: "placement-lease:#{id}",
        requirements: frozen_requirements,
        requirements_fingerprint: CanonicalJSON.digest(frozen_requirements),
        session_id: session.id,
        state: :active,
        worker_id: worker.id
      },
      [
        :episode_id,
        :generation,
        :id,
        :last_acked_event_sequence,
        :last_acked_session_event_sequence,
        :lease_expires_at,
        :lease_ref,
        :requirements,
        :requirements_fingerprint,
        :session_id,
        :state,
        :worker_id
      ]
    )
    |> validate_required([
      :generation,
      :id,
      :lease_expires_at,
      :lease_ref,
      :requirements,
      :requirements_fingerprint,
      :session_id,
      :state,
      :worker_id
    ])
    |> unique_constraint([:session_id, :generation])
    |> unique_constraint(:session_id, name: :coop_session_placements_one_current)
    |> foreign_key_constraint(:session_id,
      name: :coop_session_placement_session_episode_fkey
    )
    |> foreign_key_constraint(:session_id,
      name: :coop_session_placements_session_id_fkey
    )
    |> foreign_key_constraint(:worker_id)
    |> check_constraint(:generation, name: :coop_session_placement_identity_valid)
    |> Repo.insert()
    |> unwrap_write()
  end

  defp cancelling_bound_session?(%Session{id: session_id, coop_session_id: remote_id})
       when is_binary(remote_id) do
    Repo.exists?(
      from(turn in Turn,
        where: turn.session_id == ^session_id and turn.status == :cancel_pending
      )
    )
  end

  defp cancelling_bound_session?(_session), do: false

  defp recover_cancellation_placement(
         session,
         previous,
         requirements,
         lease_seconds,
         now
       ) do
    cutoff = DateTime.add(now, -@heartbeat_stale_seconds, :second)
    worker = locked_worker(previous.worker_id)

    eligible =
      match?(%Worker{}, worker) and worker.workspace_ref == requirements.workspace_ref and
        worker.state == :eligible and is_nil(worker.drain_requested_at) and
        is_nil(worker.revoked_at) and match?(%DateTime{}, worker.last_seen_at) and
        DateTime.compare(worker.last_seen_at, cutoff) != :lt and
        worker_eligible?(worker, session, requirements, now) and
        placement_authority_current?(previous.requirements, worker) and
        worker_has_capacity?(worker)

    if eligible,
      do: insert_placement_on_worker(session, worker, requirements, lease_seconds, now),
      else: rollback({:coop_worker_capacity_unavailable, session.id})
  end

  defp enqueue_command_locked(placement_id, kind, payload, idempotency_key) do
    fingerprint =
      CanonicalJSON.digest(%{
        "idempotency_key" => idempotency_key,
        "kind" => kind,
        "payload" => payload,
        "placement_id" => placement_id,
        "version" => Protocol.version()
      })

    case Repo.one(from(command in Command, where: command.idempotency_key == ^idempotency_key)) do
      %Command{payload_fingerprint: ^fingerprint} = command ->
        command

      %Command{} ->
        rollback({:coop_worker_command_conflict, idempotency_key})

      nil ->
        now = database_now!()

        placement =
          Repo.one(
            from(placement in Placement,
              where: placement.id == ^placement_id,
              lock: "FOR UPDATE"
            )
          ) || rollback({:coop_session_placement_not_found, placement_id})

        if placement.state != :active or
             DateTime.compare(placement.lease_expires_at, now) != :gt do
          rollback({:coop_session_placement_not_current, placement_id})
        end

        %Command{}
        |> cast(
          %{
            command_version: Protocol.version(),
            id: Ecto.UUID.generate(),
            idempotency_key: idempotency_key,
            kind: kind,
            payload: payload,
            payload_fingerprint: fingerprint,
            placement_generation: placement.generation,
            placement_id: placement.id,
            session_id: placement.session_id,
            status: :queued,
            worker_id: placement.worker_id
          },
          [
            :command_version,
            :id,
            :idempotency_key,
            :kind,
            :payload,
            :payload_fingerprint,
            :placement_generation,
            :placement_id,
            :session_id,
            :status,
            :worker_id
          ]
        )
        |> validate_required([
          :command_version,
          :id,
          :idempotency_key,
          :kind,
          :payload,
          :payload_fingerprint,
          :placement_generation,
          :placement_id,
          :session_id,
          :status,
          :worker_id
        ])
        |> unique_constraint(:idempotency_key)
        |> foreign_key_constraint(:placement_id,
          name: :coop_worker_command_placement_identity_fkey
        )
        |> check_constraint(:kind, name: :coop_worker_command_identity_valid)
        |> check_constraint(:status, name: :coop_worker_command_result_valid)
        |> Repo.insert()
        |> unwrap_write()
    end
  end

  defp authenticated_worker!(worker_id, workspace_ref, certificate_sha256) do
    case locked_worker(worker_id) do
      nil ->
        rollback({:coop_worker_not_authorized, worker_id})

      %Worker{workspace_ref: stored} when stored != workspace_ref ->
        rollback({:coop_worker_workspace_mismatch, stored, workspace_ref})

      %Worker{state: :revoked} ->
        rollback({:coop_worker_revoked, worker_id})

      %Worker{} = worker when is_binary(certificate_sha256) ->
        unless active_certificate_for_worker?(certificate_sha256, worker_id),
          do: rollback(:coop_worker_certificate_not_authorized)

        worker

      %Worker{} = worker ->
        worker
    end
  end

  defp heartbeat_state(%Worker{drain_requested_at: %DateTime{}}, _reported), do: :draining
  defp heartbeat_state(%Worker{}, reported), do: String.to_existing_atom(reported)

  defp renew_worker_placements(worker, now, lease_seconds) do
    expires_at = DateTime.add(now, lease_seconds, :second)

    placements =
      Repo.all(
        from(placement in Placement,
          where: placement.worker_id == ^worker.id and placement.state == :active,
          lock: "FOR UPDATE"
        )
      )

    Enum.each(placements, fn placement ->
      attributes =
        cond do
          DateTime.compare(placement.lease_expires_at, now) != :gt ->
            %{state: :replaced}

          placement_authority_current?(placement.requirements, worker) ->
            %{lease_expires_at: expires_at}

          true ->
            %{state: :revoking}
        end

      updated =
        placement
        |> change(attributes)
        |> Repo.update!()

      if updated.state == :replaced, do: fail_undelivered_commands(updated, now)
    end)

    :ok
  end

  defp fail_undelivered_commands(placement, now) do
    commands =
      Repo.all(
        from(command in Command,
          where: command.placement_id == ^placement.id and command.status == :queued,
          lock: "FOR UPDATE"
        )
      )

    Enum.each(commands, fn command ->
      error = %{
        "code" => "operation_not_enqueued",
        "detail" => "command never left Responder before its placement ended",
        "status" => 409
      }

      fingerprint =
        CanonicalJSON.digest(%{
          "command_id" => command.id,
          "error" => error,
          "operation_key" => command.idempotency_key,
          "resource" => nil,
          "state" => "failed"
        })

      command
      |> change(%{
        completed_at: now,
        error: error,
        operation_key: command.idempotency_key,
        result_fingerprint: fingerprint,
        status: :failed
      })
      |> check_constraint(:status, name: :coop_worker_command_result_valid)
      |> Repo.update!()
    end)

    :ok
  end

  defp acknowledge_commands(worker_id, command_ids, now) do
    Enum.each(command_ids, fn command_id ->
      command = locked_command!(command_id, worker_id)

      cond do
        command.status in @terminal_command_states or command.status == :acknowledged ->
          :ok

        command.status == :delivered ->
          command
          |> change(%{acknowledged_at: now, status: :acknowledged})
          |> Repo.update!()

        true ->
          rollback({:coop_worker_command_not_delivered, command_id})
      end
    end)
  end

  defp apply_command_results(worker_id, results, now) do
    Enum.map(results, fn result ->
      command = locked_command!(result["command_id"], worker_id)
      fingerprint = CanonicalJSON.digest(result)
      placement = locked_command_placement!(command)

      cond do
        command.operation_key != nil and command.result_fingerprint == fingerprint ->
          :ok

        command.operation_key != nil ->
          rollback({:coop_worker_command_result_conflict, command.id})

        command.status == :queued ->
          rollback({:coop_worker_command_not_delivered, command.id})

        command.idempotency_key != result["operation_key"] ->
          rollback({:coop_worker_operation_key_mismatch, command.id})

        not command_result_authorized?(placement, now) ->
          command
          |> change(%{
            completed_at: now,
            error: %{
              "code" => "placement_not_authorized",
              "detail" => "worker result arrived after placement authority ended",
              "status" => 409
            },
            operation_key: result["operation_key"],
            result_fingerprint: fingerprint,
            status: :uncertain
          })
          |> check_constraint(:status, name: :coop_worker_command_result_valid)
          |> Repo.update()
          |> unwrap_write()

        true ->
          attributes = %{
            completed_at: now,
            error: result["error"],
            operation_key: result["operation_key"],
            result: result["resource"],
            result_fingerprint: fingerprint,
            status: String.to_existing_atom(result["state"])
          }

          command
          |> change(attributes)
          |> check_constraint(:status, name: :coop_worker_command_result_valid)
          |> Repo.update()
          |> unwrap_write()
      end

      command.id
    end)
  end

  defp command_result_authorized?(placement, now) do
    placement.state == :active and DateTime.compare(placement.lease_expires_at, now) == :gt
  end

  defp apply_event_batches(worker_id, batches, now) do
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
      ) || rollback({:coop_session_placement_not_found, batch["session_ref"]})

    after_sequence = batch["after_sequence"]
    events = batch["events"]
    last_sequence = if events == [], do: after_sequence, else: List.last(events)["sequence"]
    session_events? = session_event_batch?(events)
    cursor = event_cursor(placement, session_events?)

    case event_batch_disposition(placement, after_sequence, last_sequence, events, cursor, now) do
      :unauthorized ->
        rollback({:coop_worker_event_placement_not_authorized, placement.id})

      :terminal_cleanup ->
        apply_terminal_cleanup_event_batch(
          placement,
          events,
          cursor,
          last_sequence,
          session_events?
        )

      :late_session_activity ->
        apply_fresh_event_batch(placement, events, cursor, last_sequence, session_events?)

      :fresh ->
        apply_fresh_event_batch(placement, events, cursor, last_sequence, session_events?)

      :replay ->
        apply_replayed_event_batch(placement, events, cursor, session_events?)

      :conflict ->
        rollback({:coop_worker_event_cursor_conflict, cursor, after_sequence})
    end

    %{
      "placement_generation" => placement.generation,
      "sequence" => max(last_sequence, cursor),
      "session_ref" => placement.session_id
    }
  end

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
      true -> :unauthorized
    end
  end

  defp event_batch_disposition(placement, cursor, _last_sequence, _events, cursor, now) do
    if command_result_authorized?(placement, now), do: :fresh, else: :unauthorized
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
        expected_cursor = List.last(values)["sequence"]

        case Repo.get(Session, placement.session_id) do
          %Session{coop_session_id: nil} ->
            if prebinding_session_created?(values),
              do: :ok,
              else: rollback({:coop_activity_session_conflict, remote_id})

          %Session{} ->
            case Activity.ingest_fleet(placement.session_id, remote_id, cursor, values) do
              {:ok, %{cursor: ^expected_cursor}} -> :ok
              {:error, reason} -> rollback(reason)
              _invalid -> rollback({:invalid_coop_activity, :cursor})
            end

          nil ->
            rollback(:work_session_not_found)
        end
    end
  end

  defp prebinding_session_created?([
         %{"sequence" => 1, "session_id" => remote_id, "type" => "session.created"}
       ])
       when is_binary(remote_id),
       do: true

  defp prebinding_session_created?(_events), do: false

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
    |> unwrap_write()
  end

  defp verify_replayed_event!(placement, event) do
    stored = replayed_event(placement.id, event)

    if stored == nil or stored.kind != event["kind"] or
         stored.payload_fingerprint != event_fingerprint(event) do
      rollback({:coop_worker_event_replay_conflict, event["sequence"]})
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

  defp deliver_commands(worker_id, now, state_tools_secret) do
    commands =
      Repo.all(
        from(command in Command,
          join: placement in Placement,
          on: placement.id == command.placement_id,
          where:
            command.worker_id == ^worker_id and
              command.status in [:queued, :delivered, :acknowledged] and
              placement.state == :active and placement.lease_expires_at > ^now,
          order_by: [asc: command.inserted_at, asc: command.id],
          limit: 100,
          lock: "FOR UPDATE SKIP LOCKED",
          select: {command, placement}
        )
      )

    Enum.map(commands, fn {command, placement} ->
      if command.status == :queued do
        command
        |> change(%{delivered_at: now, status: :delivered})
        |> Repo.update!()
      end

      placement
      |> change(%{last_command_id: command.id})
      |> Repo.update!()

      %{
        "command_id" => command.id,
        "command_version" => command.command_version,
        "idempotency_key" => command.idempotency_key,
        "kind" => command.kind,
        "lease_expires_at" => DateTime.to_iso8601(placement.lease_expires_at),
        "lease_ref" => placement.lease_ref,
        "payload" => materialize_command_payload!(command, placement, state_tools_secret),
        "placement_generation" => placement.generation,
        "session_ref" => placement.session_id,
        "worker_id" => placement.worker_id
      }
    end)
  end

  defp materialize_command_payload!(command, placement, state_tools_secret) do
    command.payload
    |> materialize_binding_at!(command, placement, state_tools_secret, ["responder_binding"])
    |> materialize_binding_at!(
      command,
      placement,
      state_tools_secret,
      ["request", "responder_binding"]
    )
  end

  defp materialize_binding_at!(payload, command, placement, state_tools_secret, path) do
    case get_in(payload, path) do
      nil ->
        payload

      descriptor ->
        put_in(
          payload,
          path,
          materialize_binding!(command, placement, descriptor, state_tools_secret)
        )
    end
  end

  defp materialize_binding!(
         command,
         placement,
         %{"endpoint" => endpoint, "token_sha256" => token_sha256} = descriptor,
         state_tools_secret
       )
       when map_size(descriptor) == 2 and is_binary(state_tools_secret) do
    session = Repo.get(Session, command.session_id)

    turn =
      Repo.one(
        from(turn in Turn,
          where:
            turn.session_id == ^command.session_id and
              turn.state_tools_endpoint == ^endpoint and
              turn.state_tools_token_sha256 == ^token_sha256,
          limit: 1,
          lock: "FOR UPDATE"
        )
      )

    with %Session{} <- session,
         %Turn{} <- turn,
         {:ok, binding} <-
           StateBinding.derive(
             session,
             turn,
             StateBinding.placement_scope(placement),
             endpoint,
             state_tools_secret
           ),
         true <- binding.token_sha256 == token_sha256,
         {:ok, _current} <- Binding.resolve(binding.token) do
      StateBinding.document(binding)
    else
      _invalid -> rollback({:coop_worker_state_binding_not_current, command.id})
    end
  end

  defp materialize_binding!(command, _placement, _descriptor, _state_tools_secret),
    do: rollback({:coop_worker_state_binding_not_current, command.id})

  defp choose_worker!(session, requirements, now) do
    cutoff = DateTime.add(now, -@heartbeat_stale_seconds, :second)

    choose_worker_candidate(session, requirements, now, cutoff, []) ||
      rollback({:coop_worker_capacity_unavailable, session.id})
  end

  defp choose_worker_candidate(session, requirements, now, cutoff, excluded_ids) do
    worker = worker_candidate(requirements, cutoff, excluded_ids)

    cond do
      is_nil(worker) ->
        nil

      worker_eligible?(worker, session, requirements, now) and worker_has_capacity?(worker) ->
        worker

      true ->
        choose_worker_candidate(
          session,
          requirements,
          now,
          cutoff,
          [worker.id | excluded_ids]
        )
    end
  end

  defp worker_candidate(requirements, cutoff, excluded_ids) do
    Repo.one(
      from(worker in Worker,
        where:
          worker.workspace_ref == ^requirements.workspace_ref and worker.state == :eligible and
            is_nil(worker.drain_requested_at) and is_nil(worker.revoked_at) and
            worker.last_seen_at >= ^cutoff and worker.id not in ^excluded_ids,
        order_by: [
          asc:
            fragment(
              "(SELECT count(*) FROM coop_session_placements AS placement WHERE placement.worker_id = ? AND placement.state IN ('assigning', 'active', 'draining', 'revoking'))",
              worker.id
            ),
          desc:
            fragment(
              "COALESCE((?::jsonb ->> 'turn_slots_free')::integer, 0)",
              worker.capacity
            ),
          desc:
            fragment(
              "COALESCE((?::jsonb ->> 'session_slots_free')::integer, 0)",
              worker.capacity
            ),
          asc: worker.id
        ],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  defp worker_has_capacity?(worker) do
    reserved_slots = reserved_placement_slots(worker.id)

    Enum.all?(~w(session turn workspace), fn kind ->
      capacity_slot(worker, "#{kind}_slots_free") > 0 and
        capacity_slot(worker, "#{kind}_slots_total") > reserved_slots
    end)
  end

  defp reserved_placement_slots(worker_id) do
    closed =
      from(command in Command,
        where:
          command.placement_id == parent_as(:placement).id and
            command.kind == "close_session" and command.status == :succeeded,
        select: 1
      )

    Repo.aggregate(
      from(placement in Placement,
        as: :placement,
        where:
          placement.worker_id == ^worker_id and
            placement.state in ^@current_placement_states and
            not exists(subquery(closed))
      ),
      :count
    )
  end

  defp worker_eligible?(worker, session, requirements, now) do
    worker.policy_digests[session.policy] == session.policy_digest and
      worker_authority_matches?(worker, session.policy, session.authority_digest) and
      repository_available?(worker.repositories, requirements.repository_ref) and
      capabilities_available?(
        worker.capabilities,
        requirements.capability_names,
        requirements.capability_versions
      ) and
      worker.capacity["state"] == "eligible" and
      DateTime.diff(now, worker.clock_at, :second) |> abs() <= @maximum_clock_skew_seconds
  end

  defp repository_available?(_repositories, nil), do: true

  defp repository_available?(repositories, repository_ref) do
    Enum.any?(repositories, &(&1["ref"] == repository_ref))
  end

  defp capabilities_available?(capabilities, required_names, required_versions) do
    available = Map.new(capabilities, &{&1["name"], &1["version"]})

    Enum.all?(required_names, &Map.has_key?(available, &1)) and
      Enum.all?(required_versions, fn {name, version} -> available[name] == version end)
  end

  defp placement_requirements(session, worker, requirements) do
    %{
      "capability_names" => requirements.capability_names,
      "capability_versions" => requirements.capability_versions,
      "authority_digest" => session.authority_digest,
      "policy" => session.policy,
      "policy_digest" => session.policy_digest,
      "repository_ref" => requirements.repository_ref,
      "sandbox_digest" => worker.sandbox_digest,
      "workspace_ref" => requirements.workspace_ref
    }
  end

  defp placement_authority_current?(requirements, worker) do
    worker.workspace_ref == requirements["workspace_ref"] and
      worker.sandbox_digest == requirements["sandbox_digest"] and
      worker.policy_digests[requirements["policy"]] == requirements["policy_digest"] and
      worker_authority_matches?(
        worker,
        requirements["policy"],
        requirements["authority_digest"]
      ) and
      repository_available?(worker.repositories, requirements["repository_ref"]) and
      capabilities_available?(
        worker.capabilities,
        requirements["capability_names"],
        Map.get(requirements, "capability_versions", %{})
      )
  end

  defp capacity_slot(worker, name), do: Map.get(worker.capacity, name, 0)

  defp worker_authority_matches?(_worker, _policy, nil), do: true

  defp worker_authority_matches?(worker, policy, authority_digest),
    do: worker.policy_authority_digests[policy] == authority_digest

  defp next_placement_generation(session_id) do
    Repo.one(
      from(placement in Placement,
        where: placement.session_id == ^session_id,
        select: coalesce(max(placement.generation), 0)
      )
    ) + 1
  end

  defp current_placement(session_id) do
    Repo.one(
      from(placement in Placement,
        where:
          placement.session_id == ^session_id and
            placement.state in ^@current_placement_states,
        lock: "FOR UPDATE"
      )
    )
  end

  defp latest_placement(session_id) do
    Repo.one(
      from(placement in Placement,
        where: placement.session_id == ^session_id,
        order_by: [desc: placement.generation],
        limit: 1,
        lock: "FOR UPDATE"
      )
    )
  end

  defp locked_worker(worker_id) do
    Repo.one(from(worker in Worker, where: worker.id == ^worker_id, lock: "FOR UPDATE"))
  end

  defp locked_command!(command_id, worker_id) do
    Repo.one(
      from(command in Command,
        where: command.id == ^command_id and command.worker_id == ^worker_id,
        lock: "FOR UPDATE"
      )
    ) || rollback({:coop_worker_command_not_found, command_id})
  end

  defp locked_command_placement!(command) do
    Repo.one(
      from(placement in Placement,
        where:
          placement.id == ^command.placement_id and
            placement.worker_id == ^command.worker_id and
            placement.session_id == ^command.session_id and
            placement.generation == ^command.placement_generation,
        lock: "FOR UPDATE"
      )
    ) || rollback({:coop_session_placement_not_found, command.session_id})
  end

  defp event_fingerprint(event) do
    CanonicalJSON.digest(%{"kind" => event["kind"], "payload" => event["payload"]})
  end

  defp poll_identity(authenticated_worker_id, poll) do
    reported_worker_id = poll["worker"]["id"]

    if authenticated_worker_id == reported_worker_id,
      do: :ok,
      else:
        {:error, {:coop_worker_identity_mismatch, authenticated_worker_id, reported_worker_id}}
  end

  defp requirements(%{} = requirements) do
    workspace_ref = Map.get(requirements, :workspace_ref)
    repository_ref = Map.get(requirements, :repository_ref)
    capability_names = Map.get(requirements, :capability_names, [])
    capability_versions = Map.get(requirements, :capability_versions, %{})

    with :ok <- reference(workspace_ref, 256, :workspace_ref),
         :ok <- optional_reference(repository_ref, 256, :repository_ref),
         :ok <- references(capability_names, :capability_names),
         :ok <- capability_versions(capability_versions) do
      {:ok,
       %{
         capability_names: capability_names,
         capability_versions: capability_versions,
         repository_ref: repository_ref,
         workspace_ref: workspace_ref
       }}
    end
  end

  defp requirements(_requirements),
    do: {:error, {:invalid_coop_session_placement, :requirements}}

  defp references(values, field) when is_list(values) and length(values) <= 100 do
    if Enum.uniq(values) == values and Enum.all?(values, &(reference(&1, 256, field) == :ok)),
      do: :ok,
      else: {:error, {:invalid_coop_session_placement, field}}
  end

  defp references(_values, field), do: {:error, {:invalid_coop_session_placement, field}}

  defp capability_versions(versions) when is_map(versions) and map_size(versions) <= 100 do
    if Enum.all?(versions, fn {name, version} ->
         reference(name, 256, :capability_versions) == :ok and
           reference(version, 128, :capability_versions) == :ok
       end),
       do: :ok,
       else: {:error, {:invalid_coop_session_placement, :capability_versions}}
  end

  defp capability_versions(_versions),
    do: {:error, {:invalid_coop_session_placement, :capability_versions}}

  defp lease_seconds(value)
       when is_integer(value) and value > 0 and value <= @maximum_lease_seconds,
       do: :ok

  defp lease_seconds(_value), do: {:error, {:invalid_coop_session_placement, :lease_seconds}}

  defp reference(value, maximum, field)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum do
    if String.valid?(value) and Regex.match?(@reference, value),
      do: :ok,
      else: {:error, {:invalid_coop_worker_control_plane, field}}
  end

  defp reference(_value, _maximum, field),
    do: {:error, {:invalid_coop_worker_control_plane, field}}

  defp digest(value, _field) when is_binary(value) and byte_size(value) == 64 do
    if value == String.downcase(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/),
      do: :ok,
      else: {:error, {:invalid_coop_worker_control_plane, :digest}}
  end

  defp digest(_value, field),
    do: {:error, {:invalid_coop_worker_control_plane, field}}

  defp optional_reference(nil, _maximum, _field), do: :ok
  defp optional_reference(value, maximum, field), do: reference(value, maximum, field)

  defp enum(value, allowed, field) do
    if value in allowed,
      do: :ok,
      else: {:error, {:invalid_coop_worker_control_plane, field}}
  end

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, {:invalid_coop_worker_control_plane, field}}
    end
  end

  defp parse_timestamp!(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> normalize_microseconds(datetime)
      _invalid -> rollback({:invalid_coop_worker_poll, :timestamp})
    end
  end

  defp normalize_microseconds(%DateTime{microsecond: {value, _precision}} = datetime) do
    %{datetime | microsecond: {value, 6}}
  end

  defp ensure_clock_skew!(worker_id, clock_at, now) do
    if abs(DateTime.diff(now, clock_at, :second)) > @maximum_clock_skew_seconds do
      rollback({:coop_worker_clock_skew, worker_id})
    end
  end

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp active_certificate_worker(certificate_sha256) do
    Repo.one(
      from(certificate in Certificate,
        join: worker in Worker,
        on: worker.id == certificate.worker_id,
        where:
          certificate.sha256 == ^certificate_sha256 and is_nil(certificate.revoked_at) and
            certificate.not_before <= fragment("clock_timestamp()") and
            certificate.expires_at > fragment("clock_timestamp()") and
            worker.state != :revoked,
        select: worker.id
      )
    )
  end

  defp active_certificate_for_worker?(certificate_sha256, worker_id) do
    Repo.exists?(
      from(certificate in Certificate,
        where:
          certificate.sha256 == ^certificate_sha256 and certificate.worker_id == ^worker_id and
            is_nil(certificate.revoked_at) and
            certificate.not_before <= fragment("clock_timestamp()") and
            certificate.expires_at > fragment("clock_timestamp()")
      )
    )
  end

  defp ensure_manual_certificate!(worker_id, certificate_sha256) do
    now = database_now!()

    %Certificate{}
    |> cast(
      %{
        expires_at: DateTime.add(now, 10 * 365 * 24 * 60 * 60, :second),
        issued_by: "legacy-bootstrap",
        not_before: now,
        serial_number: "manual-#{String.slice(certificate_sha256, 0, 16)}",
        sha256: certificate_sha256,
        source: :manual,
        worker_id: worker_id
      },
      [:expires_at, :issued_by, :not_before, :serial_number, :sha256, :source, :worker_id]
    )
    |> validate_required([
      :expires_at,
      :issued_by,
      :not_before,
      :serial_number,
      :sha256,
      :source,
      :worker_id
    ])
    |> foreign_key_constraint(:worker_id)
    |> check_constraint(:sha256, name: :coop_worker_certificate_valid)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :sha256)
    |> unwrap_write()
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap_write({:ok, value}), do: value
  defp unwrap_write({:error, changeset}), do: rollback({:coop_worker_store_error, changeset})
  defp rollback(reason), do: Repo.rollback(reason)
end
