defmodule Ryker.CoopFleet.JobAuthority do
  @moduledoc "Freezes controller settings and exact sources before a session can be placed."

  import Ecto.Query

  alias Ryker.CoopFleet.{JobSpec, JobTemplates, ManagedSources, Placement}
  alias Ryker.{Repo, Settings}
  alias Ryker.Settings.{Environment, Installation}
  alias Ryker.Work.{RepositoryContext, RepositorySource, Session, SessionChangeset}

  @identity ~w(id execution_kind generation create_generation external_ref policy policy_digest authority_digest repository_ref repository_context repository_source environment_ref workspace_task)a

  def ensure_pinned(session, source_root, prepare \\ &ManagedSources.prepare/3)

  def ensure_pinned(
        %Session{worker_job_document: nil, worker_job_digest: nil} = session,
        root,
        prepare
      ) do
    # Ref resolution can take minutes. Neither a session row nor Settings is
    # locked while Git talks to the source host.
    with :ok <- unplaced(session),
         {:ok, snapshot} <- Settings.fetch(),
         {:ok, refs} <- companion_refs(session),
         {:ok, purpose} <- purpose(snapshot, session, refs),
         {:ok, source} <-
           source(snapshot, session.repository_ref, session.repository_source, root, prepare),
         {:ok, companions} <- companions(snapshot, refs, root, prepare),
         job = document(session, snapshot.work, purpose, source, companions),
         {:ok, digest} <- JobSpec.digest(job) do
      pin(session, snapshot.installation.revision, job, digest)
    end
  end

  def ensure_pinned(%Session{} = session, _root, _prepare), do: validate(session)

  def validate(%Session{worker_job_document: %{} = job, worker_job_digest: digest} = session) do
    with {:ok, ^digest} <- JobSpec.digest(job),
         true <- job["job_ref"] == session.external_ref,
         {:ok, refs} <- companion_refs(session),
         true <- Enum.map(job["companions"], & &1["source"]["repository_ref"]) == refs,
         true <- source_matches?(job["source"], session) do
      {:ok, session}
    else
      _invalid -> {:error, {:coop_fleet_authority_mismatch, :worker_job}}
    end
  end

  def validate(_session), do: {:error, {:coop_fleet_authority_mismatch, :worker_job}}

  # Create preparation pins after callers take their claim snapshot. Reload only the
  # same execution identity; an already-pinned caller may never adopt another job.
  def exact_receipt(%Session{id: id} = expected, remote) when is_binary(id) and is_map(remote) do
    with {:ok, session} <- stored_session(expected),
         {:ok, session} <- validate(session),
         true <- remote["external_ref"] == Session.coop_task_ref(session),
         true <- remote["job_ref"] == session.external_ref,
         true <- remote["job_digest"] == session.worker_job_digest do
      :ok
    else
      _mismatch -> {:error, {:coop_protocol_error, :session_authority}}
    end
  end

  def exact_receipt(_expected, _remote),
    do: {:error, {:coop_protocol_error, :session_authority}}

  # Old bound sessions can be inspected and destroyed, never resumed under new authority.
  def exact_cleanup_receipt(%Session{id: id} = expected, remote)
      when is_binary(id) and is_map(remote) do
    case stored_session(expected) do
      {:ok, %Session{worker_job_document: nil, worker_job_digest: nil} = session} ->
        if is_binary(session.coop_session_id) and remote["id"] == session.coop_session_id and
             remote["external_ref"] == Session.coop_task_ref(session),
           do: :ok,
           else: {:error, {:coop_protocol_error, :session_authority}}

      {:ok, session} ->
        exact_receipt(session, remote)

      _mismatch ->
        {:error, {:coop_protocol_error, :session_authority}}
    end
  end

  def exact_cleanup_receipt(_expected, _remote),
    do: {:error, {:coop_protocol_error, :session_authority}}

  defp stored_session(expected) do
    case Repo.get(Session, expected.id) do
      %Session{} = saved ->
        if Map.take(saved, @identity) == Map.take(expected, @identity) and
             (is_nil(expected.worker_job_digest) or
                expected.worker_job_digest == saved.worker_job_digest),
           do: {:ok, saved},
           else: {:error, :coop_worker_job_identity_changed}

      nil ->
        {:error, :coop_worker_job_identity_changed}
    end
  end

  defp source_matches?(nil, %Session{repository_ref: nil, repository_source: nil}), do: true

  defp source_matches?(%{} = source, session) do
    source["repository_ref"] == session.repository_ref and
      source["binding"]["requested"] == (session.repository_source || RepositorySource.default())
  end

  defp source_matches?(_source, _session), do: false

  defp purpose(snapshot, session, companions) do
    repositories = if session.repository_ref, do: [session.repository_ref | companions], else: []

    bindings =
      Enum.filter(JobTemplates.from_settings(snapshot), fn binding ->
        binding.policy_name == session.policy and binding.policy_digest == session.policy_digest and
          (is_nil(session.authority_digest) or
             binding.authority_digest == session.authority_digest) and
          binding_scope_matches?(binding, session, repositories, snapshot)
      end)

    case bindings do
      [%{purpose: purpose}] -> {:ok, purpose}
      _unavailable -> {:error, :coop_worker_job_settings_unavailable}
    end
  end

  defp binding_scope_matches?(binding, session, repositories, snapshot) do
    (scope_matches?(binding, session) and binding.repositories == repositories) or
      incident_repository_scope?(binding, session, repositories, snapshot)
  end

  # Incident policy selects a model ladder, not a repository grant. A room or
  # in-place investigation inherits its source session's repository context;
  # verify that context against current settings before resolving any source.
  defp incident_repository_scope?(
         %{purpose: :incident, scope_kind: :installation},
         %{repository_ref: ref, repository_context: context, environment_ref: environment_ref},
         repositories,
         snapshot
       )
       when is_binary(ref) do
    case {context, environment_ref} do
      {nil, nil} ->
        repositories == [ref]

      {nil, environment_ref} ->
        incident_environment_scope?(snapshot, environment_ref, ref, repositories, false)

      {%{"context_ref" => ^environment_ref}, environment_ref} ->
        incident_environment_scope?(snapshot, environment_ref, ref, repositories, true)

      _other ->
        false
    end
  end

  defp incident_repository_scope?(_binding, _session, _repositories, _snapshot), do: false

  defp incident_environment_scope?(snapshot, environment_ref, primary, repositories, context?) do
    case Environment.find(snapshot, :ref, environment_ref) do
      %Environment{} = environment ->
        refs = Environment.repository_refs(environment)

        primary in Environment.writable_refs(environment) and
          if context?,
            do: repositories == [primary | List.delete(refs, primary)],
            else: refs == [primary] and repositories == [primary]

      nil ->
        false
    end
  end

  defp scope_matches?(%{scope_kind: :environment} = binding, session),
    do:
      binding.scope_ref == session.environment_ref and
        binding.repository_ref == session.repository_ref

  defp scope_matches?(%{scope_kind: :repository} = binding, session),
    do: binding.scope_ref == session.repository_ref

  defp scope_matches?(%{scope_kind: :installation}, session), do: is_nil(session.repository_ref)

  defp companion_refs(session) do
    case RepositoryContext.restore(session.repository_context, session.repository_ref) do
      {:ok, nil} -> {:ok, []}
      {:ok, context} -> {:ok, context.read_only_repositories}
      _invalid -> {:error, :coop_worker_job_settings_unavailable}
    end
  end

  defp source(_snapshot, nil, nil, _root, _prepare), do: {:ok, nil}

  defp source(snapshot, ref, requested, root, prepare) when is_binary(ref) do
    with %{github_repository: repository, github_access: :available} <-
           Enum.find(snapshot.repositories, &(&1.ref == ref)),
         %{repository_id: id} <- Enum.find(snapshot.github_bindings, &(&1.repository_ref == ref)),
         {:ok, %{source: source}} <- prepare.(root, ref, requested),
         true <-
           source["repository_ref"] == ref and source["github_repository"] == repository and
             source["github_repository_id"] == id,
         true <- source["binding"]["requested"] == (requested || RepositorySource.default()) do
      {:ok, source}
    else
      _unavailable -> {:error, :coop_worker_source_unavailable}
    end
  end

  defp source(_snapshot, _ref, _requested, _root, _prepare),
    do: {:error, :coop_worker_source_unavailable}

  defp companions(snapshot, refs, root, prepare) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, sources} ->
      case source(snapshot, ref, nil, root, prepare) do
        {:ok, source} -> {:cont, {:ok, sources ++ [%{"name" => ref, "source" => source}]}}
        error -> {:halt, error}
      end
    end)
  end

  defp document(session, work, purpose, source, companions) do
    work
    |> JobTemplates.execution(purpose, not is_nil(source))
    |> Map.merge(%{
      "version" => 1,
      "job_ref" => session.external_ref,
      "source" => source,
      "companions" => companions
    })
  end

  defp pin(original, revision, job, digest) do
    Repo.transaction(fn ->
      # Settings writers update this row in the same transaction as their
      # changes. A shared lock holds the checked revision through the pin.
      installation = Repo.one(from(installation in Installation, lock: "FOR SHARE"))

      session =
        Repo.one(from(session in Session, where: session.id == ^original.id, lock: "FOR UPDATE"))

      unless session && Map.take(session, @identity) == Map.take(original, @identity),
        do: Repo.rollback(:coop_worker_job_identity_changed)

      pin_locked(session, installation, revision, job, digest)
    end)
  end

  defp pin_locked(
         %Session{worker_job_document: nil, worker_job_digest: nil} = session,
         installation,
         revision,
         job,
         digest
       ) do
    unless installation && installation.revision == revision,
      do: Repo.rollback(:coop_worker_job_settings_changed)

    case unplaced(session) do
      :ok -> session |> SessionChangeset.pin_worker_job(job, digest) |> Repo.update!()
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp pin_locked(session, _installation, _revision, _job, _digest) do
    case validate(session) do
      {:ok, pinned} -> pinned
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp unplaced(%Session{coop_session_id: nil, cleanup_status: :active} = session) do
    if Repo.exists?(from(placement in Placement, where: placement.session_id == ^session.id)),
      do: {:error, :coop_worker_job_requires_new_session},
      else: :ok
  end

  defp unplaced(_session), do: {:error, :coop_worker_job_requires_new_session}
end
