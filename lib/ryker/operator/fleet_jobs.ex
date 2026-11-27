defmodule Ryker.Operator.FleetJobs do
  @moduledoc """
  Jobs submitted by the controller's local operator. Each request owns its own
  ordinary Work episode, so queueing, model and source access, placements and
  recovery use the same controller authority as other Ryker work.
  """
  alias Ryker.{AdvisoryLock, CanonicalJSON, ControlPlane, CoopFleet}
  alias Ryker.{Episodes, InspectionRedactor, Repo, Work}
  alias Ryker.Operator.FleetJob

  @max_prompt 12_000

  def submit(id, %{environment: environment, repository: repository} = placement, prompt, resolve) do
    with {:ok, id} <- identifier(id),
         {:ok, source} <- source(Map.get(placement, :commit)),
         {:ok, resources} <- resource_request(placement),
         {:ok, purpose} <- job_purpose(placement),
         true <- valid_ref?(environment) and valid_ref?(repository),
         true <- valid_prompt?(prompt),
         {:ok, reference} <- input_reference(placement) do
      digest =
        CanonicalJSON.digest(
          %{
            "environment" => environment,
            "repository" => repository,
            "prompt" => prompt,
            "source" => source
          }
          |> Ryker.Maps.put_present("purpose", purpose)
          |> Ryker.Maps.put_present("resources", resources)
          |> Ryker.Maps.put_present("workspace_input", reference)
        )

      placement = Map.merge(placement, %{source: source, resources: resources, purpose: purpose})
      Repo.transaction(fn -> submit_locked(id, placement, prompt, digest, resolve) end)
    else
      _invalid -> {:error, :invalid_fleet_job}
    end
  end

  defp submit_locked(id, placement, prompt, digest, resolve) do
    :ok = AdvisoryLock.hold("operator-fleet-job:" <> id)

    case Repo.peek(FleetJob.Query.by_id(id)) do
      %FleetJob{request_digest: ^digest} = job -> receipt(job)
      %FleetJob{} -> Repo.rollback(:fleet_job_idempotency_conflict)
      nil -> start(id, placement, prompt, digest, resolve)
    end
  end

  defp source(nil), do: {:ok, Work.RepositorySource.default()}
  defp source(commit), do: Work.RepositorySource.parse(%{"kind" => "commit", "sha" => commit})

  defp input_reference(%{
         workspace_input: %Ryker.Operator.WorkspaceInputs{reference: ref},
         commit: commit
       })
       when is_binary(commit), do: {:ok, ref}

  defp input_reference(%{workspace_input: _}), do: :error
  defp input_reference(_placement), do: {:ok, nil}

  # The original implementation-only request omitted purpose from its digest.
  defp job_purpose(placement) do
    case Map.get(placement, :purpose) do
      purpose when purpose in [nil, "implementation"] -> {:ok, nil}
      "verification" -> {:ok, "verification"}
      _unknown -> :error
    end
  end

  defp resource_request(placement) do
    case {Map.get(placement, :cpu_millis), Map.get(placement, :memory_mib)} do
      {nil, nil} ->
        {:ok, nil}

      {cpu, mib}
      when (is_integer(cpu) or is_binary(cpu)) and (is_integer(mib) or is_binary(mib)) ->
        with {cpu, ""} <- Integer.parse(to_string(cpu)),
             {mib, ""} <- Integer.parse(to_string(mib)),
             true <- cpu in 10..4_000 and mib in 6..8_192 do
          {:ok, %{"cpu_millis" => cpu, "memory_bytes" => mib * 1_048_576}}
        else
          _invalid -> {:error, :invalid_fleet_resources}
        end

      _invalid ->
        {:error, :invalid_fleet_resources}
    end
  end

  defp start(
         id,
         %{environment: environment, repository: repository, source: source, resources: resources} =
           placement,
         prompt,
         digest,
         resolve
       ) do
    with {:ok, %{environment_ref: ^environment, repository_ref: ^repository} = policy} <-
           resolve.(environment, repository),
         {:ok, [transition]} <- Episodes.apply_batch_in_transaction([command(id, prompt)]),
         {:ok, _session} <-
           Work.Custody.pin_task_episode_in_transaction(
             transition.episode.id,
             policy.name,
             policy.digest,
             repository,
             workspace_task(id, prompt, placement),
             Keyword.put(
               Map.to_list(Map.take(policy, [:environment_ref, :repository_context])),
               :repository_source,
               source
             )
           ) do
      id
      |> FleetJob.Changeset.insert(transition.episode.id, digest, placement, resources)
      |> Repo.insert!()
      |> receipt()
    else
      {:error, reason} -> Repo.rollback(reason)
      _missing -> Repo.rollback(:fleet_job_policy_unavailable)
    end
  end

  defp workspace_task(id, prompt, placement) do
    %{
      "offer_ref" => "operator-fleet-job:" <> id,
      "title" => "Fleet job " <> id,
      "prompt" => prompt,
      "authority_limits" => [],
      "source_refs" => ["operator-fleet-job:" <> id],
      "success_checks" => ["Complete the operator's request and verify the result."]
    }
    |> Ryker.Maps.put_present("purpose", placement.purpose)
    |> Ryker.Maps.put_present(
      "verification_input_sha256",
      placement[:workspace_input] && placement.workspace_input.verification_digest
    )
  end

  # A direct operator instruction owns its own immutable episode input, like a
  # confirmed task. Only authenticated adapter messages have Inbox provenance.
  defp command(id, prompt) do
    ref = "operator-fleet-job:" <> id
    destination = "control-plane:lab:" <> id

    %Episodes.Command.AdmitInput{
      actor_ref: "control-plane:local",
      destination: %{
        conversation_ref: destination,
        thread_ref: destination,
        transport: "control_plane"
      },
      episode_id: Repo.generate_id(),
      episode_key: ref,
      native_input_id: ref,
      occurred_at: Repo.now!(),
      payload: %{"operator_fleet_job_ref" => ref, "text" => prompt},
      revision: 1,
      turn_ref: turn_ref(id)
    }
  end

  def list(page \\ 1) do
    jobs =
      ControlPlane.PagedRelation.read(
        FleetJob.Query.all(),
        [desc: :inserted_at, desc: :id],
        "jobs",
        page
      )

    {:ok, %{jobs | items: Enum.map(jobs.items, &receipt/1)}}
  end

  def events(id, page) do
    with {:ok, job_id} <- identifier(id),
         {:ok, job} <- Repo.fetch(FleetJob.Query.by_id(job_id)) do
      query = CoopFleet.Event.Query.by_job_episode(job.episode_id)

      events =
        ControlPlane.PagedRelation.read(query, [asc: :inserted_at, asc: :id], "events", page)

      secrets = InspectionRedactor.current_secrets()

      items =
        Enum.map(events.items, fn event ->
          event
          |> Map.take([
            :id,
            :placement_id,
            :worker_id,
            :session_id,
            :placement_generation,
            :sequence,
            :kind,
            :payload,
            :inserted_at
          ])
          |> Map.update!(:payload, &InspectionRedactor.redact(&1, secrets))
        end)

      {:ok, events |> Map.put(:items, items) |> Map.put(:history_expired, is_nil(job.episode_id))}
    else
      _missing -> {:error, :fleet_job_not_found}
    end
  end

  def workers(page) do
    now = Repo.now!()

    workers =
      ControlPlane.PagedRelation.read(CoopFleet.Worker.Query.all(), [asc: :id], "workers", page)

    items = Enum.map(workers.items, &worker_status(&1, now))
    {:ok, %{workers | items: items}}
  end

  defp worker_status(worker, now) do
    worker
    |> Map.take([
      :id,
      :workspace_ref,
      :state,
      :last_seen_at,
      :drain_requested_at,
      :admission_stopped_at,
      :revoked_at,
      :capacity,
      :storage
    ])
    |> Map.put(
      :heartbeat_current,
      not is_nil(worker.last_seen_at) and
        DateTime.diff(now, worker.last_seen_at, :second) <= CoopFleet.Worker.heartbeat_seconds()
    )
  end

  def fetch(id) do
    with {:ok, id} <- identifier(id),
         {:ok, job} <- Repo.fetch(FleetJob.Query.by_id(id)) do
      {:ok, details(job)}
    else
      _missing -> {:error, :fleet_job_not_found}
    end
  end

  def export(id, options, consume) do
    with {:ok, id} <- identifier(id),
         {:ok, %{episode_id: episode}} when not is_nil(episode) <-
           Repo.fetch(FleetJob.Query.by_id(id)),
         {:ok, session} <- fetch_latest_session(episode) do
      Ryker.CoopFleet.Checkpoints.export(session, options, consume)
    else
      _missing -> {:error, :fleet_job_not_found}
    end
  end

  def services(id, options) do
    read_service(id, "", options, fn
      %{"services" => services} when is_list(services) ->
        {:ok,
         %{services: InspectionRedactor.redact(services, InspectionRedactor.current_secrets())}}

      _invalid ->
        :error
    end)
  end

  def service_logs(id, name, container, cursor, options) do
    if is_binary(name) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/, name) and
         is_binary(container) and Regex.match?(~r/\A[0-9a-f]{64}\z/, container) and
         is_binary(cursor) and byte_size(cursor) <= 512 and
         Regex.match?(~r/\A[A-Za-z0-9_-]*\z/, cursor) do
      query = URI.encode_query(%{"container" => container, "cursor" => cursor})
      read_service(id, "/" <> name <> "/logs?" <> query, options, &log_page/1)
    else
      {:error, :invalid_fleet_log_request}
    end
  end

  defp log_page(%{"records" => records, "at_end" => at_end} = page)
       when is_list(records) and is_boolean(at_end) do
    secrets = InspectionRedactor.current_secrets()

    {:ok,
     %{
       records: InspectionRedactor.redact(records, secrets),
       cursor: page["cursor"],
       at_end: at_end
     }}
  end

  defp log_page(_invalid), do: :error

  defp read_service(id, suffix, options, project) do
    with {:ok, job_id} <- identifier(id),
         {:ok, %{episode_id: episode}} when not is_nil(episode) <-
           Repo.fetch(FleetJob.Query.by_id(job_id)),
         {:ok, session} <- fetch_latest_session(episode),
         %{coop_session_id: remote} when is_binary(remote) <- session,
         {:ok, placement} <- service_placement(session.id),
         {:ok, worker} <-
           Repo.fetch(
             CoopFleet.Worker.Query.enrolled(CoopFleet.Worker.Query.by_id(placement.worker_id))
           ) do
      path =
        "/v1/sessions/" <> URI.encode(remote, &URI.char_unreserved?/1) <> "/services" <> suffix

      request = %{"method" => "GET", "path" => path}
      key = CoopFleet.Command.read_key("services")

      options =
        Keyword.merge(options,
          workspace_ref: worker.workspace_ref,
          max_waits: 100,
          poll_interval_ms: 150
        )

      with {:ok, command} <-
             CoopFleet.ControlPlane.enqueue_command(placement.id, "api_request", request, key),
           {:ok, body} <-
             CoopFleet.Bridge.await_command(command.id, options),
           :ok <- CoopFleet.Bridge.current_command_placement(command),
           {:ok, %{enrollment_epoch: epoch}} when epoch == worker.enrollment_epoch <-
             Repo.fetch(CoopFleet.Worker.Query.enrolled(CoopFleet.Worker.Query.by_id(worker.id))),
           {:ok, result} <- project.(body) do
        {:ok,
         Map.merge(result, %{
           job_id: job_id,
           worker_id: worker.id,
           placement_generation: placement.generation
         })}
      else
        _unavailable -> {:error, :fleet_services_unavailable}
      end
    else
      _unavailable -> {:error, :fleet_services_unavailable}
    end
  end

  defp service_placement(session_id) do
    query =
      session_id
      |> CoopFleet.Placement.Query.by_session_id()
      |> CoopFleet.Placement.Query.active()

    case Repo.fetch(query) do
      {:ok, placement} ->
        if DateTime.compare(placement.lease_expires_at, Repo.now!()) == :gt,
          do: {:ok, placement},
          else: :error

      _missing ->
        :error
    end
  end

  def cancel(id) do
    case identifier(id) do
      {:ok, id} -> Repo.transaction(fn -> cancel_locked(id) end)
      _invalid -> {:error, :fleet_job_not_found}
    end
  end

  defp cancel_locked(id) do
    :ok = AdvisoryLock.hold("operator-fleet-job:" <> id)

    with {:ok, %{episode_id: episode_id}} when not is_nil(episode_id) <-
           Repo.fetch(FleetJob.Query.by_id(id)),
         {:ok, %{id: ^episode_id} = episode} <-
           Episodes.fetch_and_lock_current_in_transaction("operator-fleet-job:" <> id),
         {:ok, result} <-
           Work.Custody.cancel_current(
             episode,
             "fleet-cancel:" <> id,
             "Cancelled by the local fleet operator."
           ) do
      %{job_id: id, cancellation: result.status}
    else
      {:error, :not_found} -> Repo.rollback(:fleet_job_not_found)
      {:error, reason} -> Repo.rollback(reason)
      _expired -> Repo.rollback(:fleet_job_not_found)
    end
  end

  defp details(%FleetJob{episode_id: nil} = job), do: Map.put(receipt(job), :state, :expired)

  defp details(job) do
    case Repo.fetch(Episodes.Episode.Query.by_id(job.episode_id)) do
      {:ok, episode} -> progress(job, episode)
      {:error, :not_found} -> Map.put(receipt(job), :state, :expired)
    end
  end

  defp progress(job, episode) do
    turn = Repo.peek(Work.Turn.Query.current(episode))
    outcome = [episode.id] |> Work.Turn.Query.latest_accepted_outcomes() |> Repo.peek()

    session = fetch_latest_session(episode.id)

    Map.merge(receipt(job), %{
      state: episode.state,
      last_saved_checkpoint: recovery_point(session),
      placement: current_placement(session),
      next_attempt_at: turn && turn.next_attempt_at,
      error_detail:
        turn && turn.last_error_detail &&
          InspectionRedactor.redact(turn.last_error_detail, InspectionRedactor.current_secrets()),
      turn_status: turn && turn.status,
      error_code: turn && turn.last_error_code,
      result: accepted_message(outcome),
      history_pruned: not is_nil(episode.history_pruned_at)
    })
  end

  defp fetch_latest_session(episode) do
    episode
    |> Work.Session.Query.latest_of_episode()
    |> Work.Session.Query.for_work()
    |> Repo.fetch()
  end

  defp recovery_point({:ok, session}), do: CoopFleet.Checkpoints.last_saved(session)
  defp recovery_point(_missing), do: nil

  defp current_placement({:ok, session}) do
    query =
      session.id
      |> CoopFleet.Placement.Query.by_session_id()
      |> CoopFleet.Placement.Query.ordered_by_generation_desc()
      |> CoopFleet.Placement.Query.limit_to(1)

    case Repo.peek(query) do
      nil ->
        nil

      placement ->
        placement
        |> Map.take([:worker_id, :generation, :state, :lease_expires_at])
        |> Map.put(:session_generation, session.generation)
    end
  end

  defp current_placement(_missing), do: nil

  defp accepted_message({_id, %{"message" => message}, _sent, _intent}), do: message
  defp accepted_message(_outcome), do: nil

  defp receipt(job),
    do: %{
      job_id: job.id,
      episode_id: job.episode_id,
      environment: job.environment_ref,
      repository: job.repository_ref,
      requested_resources: job.resources
    }

  defp turn_ref(id), do: "turn:operator-fleet-job:" <> id
  defp identifier(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp identifier(_invalid), do: :error

  defp valid_ref?(ref) do
    is_binary(ref) and byte_size(ref) in 1..256 and String.valid?(ref) and
      not String.contains?(ref, <<0>>)
  end

  defp valid_prompt?(prompt) do
    is_binary(prompt) and byte_size(prompt) in 1..@max_prompt and String.valid?(prompt) and
      String.trim(prompt) != "" and not String.contains?(prompt, <<0>>)
  end
end
