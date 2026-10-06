defmodule Ryker.Work.Executor.Sessions do
  @moduledoc """
  Binds the claim to exactly one remote Coop session.

  `ensure_session/2` reuses an open session the host already bound, rotates
  one that is exhausted, closed, discarded, or whose knowledge context went
  stale, replaces one whose placement was lost, and otherwise creates a new
  session under the persisted create key. Creation is keyed and reconciled
  through the operation so a lost response never creates a second session.
  """

  alias Ryker.Coop.API
  alias Ryker.CoopFleet.JobAuthority
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.Work.{Custody, OperationKeys, Session}
  alias Ryker.Work.Executor.Remote

  @doc false
  # Coop's workers refuse every turn on a session created with a version-1 job
  # since job-setup:2; it stays open and readable. A turn not yet started on
  # one moves to the next generation, which carries the same grant as version
  # 2 (`Ryker.CoopFleet.JobSpec.rebind/3`); the old session is never used again.
  def ensure_session(
        %{session: %{coop_session_id: id, worker_job_document: %{"version" => 1}}, turn: turn} =
          claim,
        settings
      )
      when is_binary(id) and is_nil(turn.coop_turn_id),
      do: rotate_session(claim, settings)

  def ensure_session(%{session: %{coop_session_id: id}} = claim, settings)
      when is_binary(id) do
    use_bound_session(claim, id, settings)
  end

  def ensure_session(claim, settings), do: create_or_bind_session(claim, settings)

  defp use_bound_session(claim, id, settings) do
    case Remote.api_call(settings, fn -> settings.api.get_session(settings.client, id) end) do
      {:ok, remote_session} ->
        with :ok <-
               Remote.exact_remote_session_state(claim.session, remote_session) do
          use_or_rotate_session(claim, remote_session, settings)
        end

      {:error, {:coop_session_replacement_required, _session_id, _generation}} ->
        replace_lost_session(claim, settings)

      # The worker holding it does not have it: its state was started afresh
      # (2026-09-28). It is as lost as a session whose placement is gone.
      {:error, {:coop_error, 404, "session_not_found", _detail}} ->
        replace_lost_session(claim, settings)

      {:error, _reason} = error ->
        error
    end
  end

  # A session never created whose frozen job still names a repository Ryker
  # has since removed could only fail "fetch job source" on the worker, on
  # every attempt (2026-09-28). Its replacement gives that repository up.
  defp create_or_bind_session(claim, settings) do
    if JobAuthority.removed_repositories?(claim.session),
      do: replace_lost_session(claim, settings),
      else: create_or_bind_current_session(claim, settings)
  end

  defp create_or_bind_current_session(claim, settings) do
    key = OperationKeys.create(claim.session)

    result =
      with :ok <- new_session_repository_capability(claim, settings) do
        case Remote.operation_by_key(settings, key) do
          :not_found -> create_session(claim, key, settings)
          {:ok, operation} -> bind_session_from_operation(claim, operation, key, settings)
          {:error, _reason} = error -> error
        end
      end

    case result do
      {:error, {:coop_session_replacement_required, _session_id, _generation}} ->
        replace_lost_session(claim, settings)

      other ->
        other
    end
  end

  defp new_session_repository_capability(%{session: %{repository_ref: nil}}, _settings), do: :ok

  defp new_session_repository_capability(
         %{session: %{repository_ref: repository_ref}} = claim,
         settings
       )
       when is_binary(repository_ref),
       do: repository_capabilities(claim, settings)

  defp replace_lost_session(claim, settings) do
    continue_on_next_generation(
      claim,
      settings,
      &Custody.replace_session_after_placement_loss/4
    )
  end

  defp rotate_session(claim, settings),
    do: continue_on_next_generation(claim, settings, &Custody.rotate_session/4)

  # Custody mints the next session generation for this turn, which clears its
  # state tools binding, and the executor starts over from there. The binding
  # is made again only after the new session is placed on a worker: bound
  # before, it named no placement, and the binding made after placement
  # conflicted with it and blocked the turn.
  defp continue_on_next_generation(claim, settings, rotate) do
    with {:ok, rotated} <-
           rotate.(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation
           ) do
      claim
      |> Map.merge(%{session: rotated.session, turn: rotated.turn})
      |> Map.delete(:state_binding)
      |> ensure_session(settings)
    end
  end

  defp use_or_rotate_session(%{turn: %{coop_turn_id: id}} = claim, _remote, _settings)
       when is_binary(id),
       do: {:ok, claim}

  defp use_or_rotate_session(claim, %{"state" => "open"}, settings) do
    case KnowledgeSnapshot.authorize_session(claim.episode, claim.session) do
      :ok -> {:ok, claim}
      {:error, :work_knowledge_context_stale} -> rotate_session(claim, settings)
    end
  end

  defp use_or_rotate_session(claim, %{"state" => state}, settings)
       when state in ~w(exhausted closed discarded) do
    rotate_session(claim, settings)
  end

  defp use_or_rotate_session(_claim, _remote, _settings),
    do: {:error, {:coop_protocol_error, :session_state}}

  # Every bound session must provide version-2 source freshness receipts.
  defp repository_capabilities(claim, settings) do
    with {:ok, capability_call} <- repository_freshness_capability_call(claim, settings) do
      settings
      |> Remote.api_call(capability_call)
      |> validate_repository_freshness_capability()
    end
  end

  defp repository_freshness_capability_call(claim, settings) do
    cond do
      function_exported?(settings.api, :capabilities, 2) ->
        {:ok, fn -> settings.api.capabilities(settings.client, claim.session) end}

      function_exported?(settings.api, :capabilities, 1) ->
        {:ok, fn -> settings.api.capabilities(settings.client) end}

      true ->
        {:error, {:coop_upgrade_required, :repository_freshness_v2}}
    end
  end

  defp validate_repository_freshness_capability(
         {:ok, %{"repository_freshness_receipt_versions" => versions}}
       ) do
    if capability_versions?(versions) and 2 in versions,
      do: :ok,
      else: {:error, {:coop_upgrade_required, :repository_freshness_v2}}
  end

  defp validate_repository_freshness_capability({:ok, _invalid}),
    do: {:error, {:coop_upgrade_required, :repository_freshness_v2}}

  defp validate_repository_freshness_capability({:error, {:coop_error, 404, _code, _detail}}),
    do: {:error, {:coop_upgrade_required, :repository_freshness_v2}}

  defp validate_repository_freshness_capability({:error, _reason} = error), do: error

  defp capability_versions?(versions)
       when is_list(versions) and versions != [] and
              length(versions) <= 16 do
    versions == Enum.sort(Enum.uniq(versions)) and
      Enum.all?(versions, &(is_integer(&1) and &1 > 0 and &1 <= 65_535))
  end

  defp capability_versions?(_versions), do: false

  defp create_session(claim, key, settings) do
    task = Session.coop_task_ref(claim.session)

    # Pinning a repository's source can take minutes, longer than the lease.
    prepare = fn ->
      API.prepare_create_session(
        settings.api,
        settings.client,
        key,
        claim.session.policy,
        task,
        claim.session.repository_source
      )
    end

    # Preparing may pin the session's companions anew; this executor, which
    # prepared it, adopts that job before the worker's receipt is read against
    # it (`JobAuthority.prepared/1`).
    with :ok <- Remote.with_lease_heartbeat(settings, prepare),
         {:ok, session} <- JobAuthority.prepared(claim.session) do
      create_prepared(%{claim | session: session}, key, task, settings)
    else
      error -> created(error, claim, key, settings)
    end
  end

  defp create_prepared(claim, key, task, settings) do
    settings
    |> Remote.mutation_call(:create_session, key, fn ->
      Remote.create_remote_session(settings, claim, key, task)
    end)
    |> created(claim, key, settings)
  end

  defp created(result, claim, key, settings) do
    case result do
      {:ok, %{"session" => remote_session}} when is_map(remote_session) ->
        case bind_session(claim, remote_session) do
          {:ok, _claim} = success -> success
          {:error, reason} -> reconcile_create_response(claim, key, reason, settings)
        end

      {:ok, %{"operation" => operation}} when is_map(operation) ->
        bind_session_from_operation(claim, operation, key, settings)

      {:ok, _response} ->
        reconcile_create_response(claim, key, :create_session_response, settings)

      {:error, _reason} = error ->
        reconcile_unreached_create(claim, key, settings, error)
    end
  end

  # Found live 2026-09-12 — the fleet fails an unbound session whose placement is
  # gone closed before it enqueues anything, so a create was fenced on the turn and
  # then never reached Coop. Nothing resolved the fence, and the session replacement
  # the lost placement forces refused itself with work_remote_operation_in_flight on
  # every operator retry. `:not_found` is the host's proof that no operation exists
  # under this key: the create never crossed the boundary, so the fence must not
  # outlive the attempt. An operation the host cannot resolve keeps it.
  defp reconcile_unreached_create(claim, key, settings, error) do
    case Remote.operation_by_key(settings, key) do
      {:ok, operation} ->
        bind_session_from_operation(claim, operation, key, settings)

      :not_found ->
        case Custody.release_session_create(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               key
             ) do
          {:ok, _turn} -> error
          {:error, _reason} = release_error -> release_error
        end

      {:error, _unresolved} ->
        error
    end
  end

  defp reconcile_create_response(claim, key, reason, settings) do
    Remote.reconcile_after_transport(
      Remote.ambiguous_mutation(:create_session, reason),
      key,
      settings,
      &bind_session_from_operation(claim, &1, key, settings)
    )
  end

  defp bind_session_from_operation(claim, operation, key, settings) do
    case Remote.operation_resource(
           operation,
           "session",
           "CreateRemoteSession",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, session_id} ->
        fetch_and_bind_session(claim, session_id, settings)

      {:confirmed_failed, reason} ->
        with {:ok, _session} <-
               Custody.advance_session_create(
                 claim.episode.id,
                 claim.turn.turn_ref,
                 claim.lease_ref,
                 claim.session.create_generation
               ) do
          {:error, {:work_generation_spent, :session_create, reason}}
        end

      {:uncertain, reason} ->
        {:error, {:work_execution_blocked, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_and_bind_session(claim, session_id, settings) do
    with {:ok, remote_session} <-
           Remote.api_call(settings, fn ->
             settings.api.get_session(settings.client, session_id)
           end) do
      bind_session(claim, remote_session)
    end
  end

  defp bind_session(claim, %{"id" => remote_session_id} = remote_session)
       when is_binary(remote_session_id) do
    with :ok <- Remote.exact_remote_session(claim.session, remote_session),
         {:ok, session} <-
           Custody.bind_session(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation,
             claim.session.create_generation,
             remote_session_id
           ) do
      {:ok, %{claim | session: session}}
    end
  end

  defp bind_session(_claim, _remote_session),
    do: {:error, {:coop_protocol_error, :session_resource}}
end
