defmodule Ryker.CoopFleet.JobAuthority do
  @moduledoc "Freezes controller settings and exact sources before a session can be placed."
  alias Ryker.CanonicalJSON
  alias Ryker.Config
  alias Ryker.CoopFleet.{Command, JobCheck, JobSpec, JobTemplates, ManagedSources}
  alias Ryker.CoopFleet.Placement
  alias Ryker.GitHub
  alias Ryker.{Repo, Settings}
  alias Ryker.Settings
  alias Ryker.Work

  @identity ~w(id execution_kind generation create_generation external_ref policy policy_digest authority_digest repository_ref repository_context repository_source environment_ref workspace_task)a

  def ensure_pinned(
        session,
        source_root,
        prepare \\ &ManagedSources.prepare/3,
        reader \\ check_reader()
      )

  def ensure_pinned(
        %Work.Session{worker_job_document: nil, worker_job_digest: nil} = session,
        root,
        prepare,
        reader
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
         {:ok, job} <- with_check(job, snapshot, reader),
         {:ok, digest} <- JobSpec.digest(job) do
      pin(session, snapshot.installation.revision, job, digest)
    end
  end

  # Coop's workers refuse version-1 jobs since job-setup:2. A session pinned
  # with one but never created moves to version 2 with the same grant, and
  # gets its check below; a created one is replaced (`JobSpec.rebind/3`).
  def ensure_pinned(
        %Work.Session{worker_job_document: %{"version" => 1} = job} = session,
        root,
        prepare,
        reader
      ) do
    with :ok <- uncreated(session),
         true <- CanonicalJSON.worker_digest(job) == session.worker_job_digest,
         {:ok, upgraded} <- JobSpec.upgrade(job),
         {:ok, session} <- repin(session, upgraded) do
      ensure_pinned(session, root, prepare, reader)
    else
      false -> {:error, {:coop_fleet_authority_mismatch, :worker_job}}
      {:error, reason} -> {:error, reason}
    end
  end

  def ensure_pinned(%Work.Session{} = session, root, prepare, reader) do
    with {:ok, session} <- validate(session),
         {:ok, session} <- refresh_companions(session, root, prepare),
         do: refresh_check(session, reader)
  end

  defp check_reader, do: Config.get_env(:job_check_reader, GitHub.RepositoryFiles)

  # A working copy's review runs the repository's gate as of the job's base
  # commit: Coop's job-setup:2 runs no other check. A read-only job reviews
  # nothing. GitHub that cannot be read now is a wait, never a job frozen
  # without the check its repository names.
  defp with_check(
         %{"repository_read_only" => false, "source" => %{} = source} = job,
         snapshot,
         reader
       ) do
    ref = source["repository_ref"]
    repository = Enum.find(snapshot.repositories, &(&1.ref == ref))
    binding = Enum.find(snapshot.github_bindings, &(&1.repository_ref == ref))

    with %{} <- repository,
         %{} <- binding,
         {:ok, check} <-
           JobCheck.resolve(binding, repository, source["binding"]["base_commit"], reader) do
      {:ok, Map.put(job, "check", check)}
    else
      _unavailable -> {:error, :coop_worker_source_unavailable}
    end
  end

  defp with_check(job, _snapshot, _reader), do: {:ok, job}

  # A job moved from version 1 has no check yet; it gets its repository's
  # before its session is created, as a fresh pin does. A job that names a
  # check keeps it, and a read-only one reviews nothing.
  defp refresh_check(
         %Work.Session{
           worker_job_document:
             %{"repository_read_only" => false, "source" => %{}, "check" => %{"argv" => []}} = job
         } = session,
         reader
       ) do
    with :ok <- uncreated(session),
         {:ok, snapshot} <- Settings.fetch(),
         {:ok, checked} <- with_check(job, snapshot, reader) do
      if checked == job, do: {:ok, session}, else: repin(session, checked)
    else
      {:error, :coop_worker_job_requires_new_session} -> {:ok, session}
      # Without settings there is no repository to read a gate from.
      {:error, :settings_not_initialized} -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_check(session, _reader), do: {:ok, session}

  # A session's job is pinned once, and a replacement copies its predecessor's,
  # so each companion repository stayed at the commit its default branch had
  # when the task began. The worker proves every source it stages against its
  # branch as it is now and refuses one that moved (Coop's
  # TestSourceStagingRefusesChangedOrUnprovenFrozenObjects): a task woken the
  # next day by review feedback on its pull request failed eight times on
  # companions that had simply advanced (2026-09-28). Companions are read-only
  # context, so before a session is created each is resolved again and a
  # changed one is pinned anew. The task's own source stays as it began.
  defp refresh_companions(
         %Work.Session{worker_job_document: %{"companions" => [_ | _] = pinned} = job} = session,
         root,
         prepare
       ) do
    with :ok <- uncreated(session),
         {:ok, snapshot} <- Settings.fetch(),
         {:ok, current} <- companions(snapshot, Enum.map(pinned, & &1["name"]), root, prepare) do
      if Enum.map(current, &source_commits/1) == Enum.map(pinned, &source_commits/1) do
        {:ok, session}
      else
        repinned = Map.put(job, "companions", current)
        repin(session, repinned)
      end
    else
      # A placed session keeps the job the worker was already asked with.
      {:error, :coop_worker_job_requires_new_session} -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_companions(session, _root, _prepare), do: {:ok, session}

  defp source_commits(%{"source" => %{"binding" => binding}}) do
    Map.take(
      binding,
      ~w(default_ref default_commit selected_ref selected_commit base_commit admitted_tree)
    )
  end

  defp repin(original, job) do
    with {:ok, digest} <- JobSpec.digest(job),
         do: Repo.transaction(fn -> repin_locked(original, job, digest) end)
  end

  defp repin_locked(original, job, digest) do
    session =
      original.id
      |> Work.Session.Query.by_id()
      |> Work.Session.Query.lock_for_update()
      |> Repo.peek()

    cond do
      is_nil(session) or Map.take(session, @identity) != Map.take(original, @identity) or
          session.worker_job_digest != original.worker_job_digest ->
        Repo.rollback(:coop_worker_job_identity_changed)

      uncreated(session) != :ok ->
        session

      true ->
        session |> Work.Session.Changeset.pin_worker_job(job, digest) |> Repo.update!()
    end
  end

  # No worker holds a copy of the job of a session none of whose creates got
  # anywhere: the placements its failed creates took do not bind it. That was
  # the woken task's case, placed eight times and created none.
  defp uncreated(%Work.Session{coop_session_id: nil, cleanup_status: :active} = session) do
    live = Repo.exists?(Command.Query.live_creates(session.id))

    if live, do: {:error, :coop_worker_job_requires_new_session}, else: :ok
  end

  defp uncreated(_session), do: {:error, :coop_worker_job_requires_new_session}

  def validate(%Work.Session{worker_job_document: %{} = job, worker_job_digest: digest} = session) do
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

  @doc """
  The same authority without the companion repositories Ryker no longer has.

  A replacement keeps its predecessor's authority, but a repository removed
  from Ryker since can grant no source any more: every new session for that
  work asked the worker to fetch it and failed (2026-09-28). A replacement
  may narrow its authority this way; it never widens it, and its primary
  repository is never dropped. Settings that cannot be read say nothing about
  which repositories went away, so they are an error, never a reason to drop
  every companion.
  """
  @spec without_removed_repositories(map()) :: {:ok, map()} | {:error, term()}
  def without_removed_repositories(
        %{worker_job_document: %{"companions" => [_ | _] = companions} = job} = authority
      ) do
    with {:ok, available} <- available_repositories() do
      kept = Enum.filter(companions, &MapSet.member?(available, &1["source"]["repository_ref"]))

      if length(kept) == length(companions) do
        {:ok, authority}
      else
        narrowed = Map.put(job, "companions", kept)
        narrow(authority, narrowed, available)
      end
    end
  end

  def without_removed_repositories(authority), do: {:ok, authority}

  defp narrow(authority, job, available) do
    with {:ok, digest} <- JobSpec.digest(job) do
      {:ok,
       %{authority | worker_job_document: job, worker_job_digest: digest}
       |> Map.update(:repository_context, nil, &available_context(&1, available))}
    end
  end

  defp available_context(%{"read_only_repositories" => refs} = context, available),
    do: %{context | "read_only_repositories" => Enum.filter(refs, &MapSet.member?(available, &1))}

  defp available_context(context, _available), do: context

  @doc """
  Whether the session's frozen job names a companion repository Ryker no longer
  has. Settings that cannot be read leave the session as it is.
  """
  @spec removed_repositories?(Work.Session.t()) :: boolean()
  def removed_repositories?(%Work.Session{
        worker_job_document: %{"companions" => [_ | _] = companions}
      }) do
    case available_repositories() do
      {:ok, available} ->
        not Enum.all?(companions, &MapSet.member?(available, &1["source"]["repository_ref"]))

      {:error, _reason} ->
        false
    end
  end

  def removed_repositories?(_session), do: false

  defp available_repositories do
    case Settings.fetch() do
      {:ok, snapshot} ->
        bound = MapSet.new(snapshot.github_bindings, & &1.repository_ref)

        available =
          for repository <- snapshot.repositories,
              repository.github_access == :available and MapSet.member?(bound, repository.ref),
              into: MapSet.new(),
              do: repository.ref

        {:ok, available}

      {:error, reason} ->
        {:error, {:settings_unavailable, reason}}
    end
  end

  @doc """
  The session as its create preparation left it, for the caller that ran the
  preparation: the same execution identity, and the job `ensure_pinned/3`
  may just have pinned anew for its companions. A receipt is checked against
  the job its caller holds (`exact_receipt/2`), so the caller that prepared
  the create adopts the new job first; the woken task's first created session
  was closed as "session_authority" because it had not (2026-09-28).
  """
  @spec prepared(Work.Session.t()) :: {:ok, Work.Session.t()} | {:error, term()}
  def prepared(%Work.Session{id: id} = expected_session) when is_binary(id) do
    case Repo.fetch(Work.Session.Query.by_id(id)) do
      {:ok, %Work.Session{} = saved_session} ->
        cond do
          Map.take(saved_session, @identity) != Map.take(expected_session, @identity) ->
            {:error, {:coop_fleet_authority_mismatch, :worker_job}}

          # A session Coop runs directly holds no worker job, so there is
          # nothing to adopt. Validating one anyway failed every such create
          # before its first turn: each eval world ran no model (2026-09-29).
          is_nil(saved_session.worker_job_document) and
              is_nil(expected_session.worker_job_document) ->
            {:ok, expected_session}

          true ->
            validate(saved_session)
        end

      {:error, :not_found} ->
        {:error, {:coop_fleet_authority_mismatch, :worker_job}}
    end
  end

  # Create preparation pins after callers take their claim snapshot. Reload only the
  # same execution identity; an already-pinned caller may never adopt another job.
  def exact_receipt(%Work.Session{id: id} = expected_session, remote)
      when is_binary(id) and is_map(remote) do
    with {:ok, session} <- stored_session(expected_session),
         {:ok, session} <- validate(session),
         true <- remote["external_ref"] == Work.Session.coop_task_ref(session),
         true <- remote["job_ref"] == session.external_ref,
         true <- remote["job_digest"] == session.worker_job_digest do
      :ok
    else
      _mismatch -> {:error, {:coop_protocol_error, :session_authority}}
    end
  end

  def exact_receipt(_expected, _remote),
    do: {:error, {:coop_protocol_error, :session_authority}}

  # Old bound sessions can be inspected and destroyed, never resumed under new
  # authority. Closing and removing a session run nothing under its grant, so
  # the worker need only hold this session's exact job, whatever version it was
  # frozen in. Checking it as a job Ryker would grant today refused every
  # cleanup of a session created before version 2 (2026-10-04).
  def exact_cleanup_receipt(%Work.Session{id: id} = expected_session, remote)
      when is_binary(id) and is_map(remote) do
    with {:ok, session} <- stored_session(expected_session),
         true <- cleanup_receipt?(session, remote) do
      :ok
    else
      _mismatch -> {:error, {:coop_protocol_error, :session_authority}}
    end
  end

  def exact_cleanup_receipt(_expected, _remote),
    do: {:error, {:coop_protocol_error, :session_authority}}

  defp cleanup_receipt?(
         %Work.Session{worker_job_document: nil, worker_job_digest: nil} = session,
         remote
       ) do
    is_binary(session.coop_session_id) and remote["id"] == session.coop_session_id and
      remote["external_ref"] == Work.Session.coop_task_ref(session)
  end

  defp cleanup_receipt?(%Work.Session{worker_job_document: %{} = job} = session, remote) do
    CanonicalJSON.worker_digest(job) == session.worker_job_digest and
      remote["external_ref"] == Work.Session.coop_task_ref(session) and
      remote["job_ref"] == session.external_ref and
      remote["job_digest"] == session.worker_job_digest
  end

  defp cleanup_receipt?(_session, _remote), do: false

  defp stored_session(expected) do
    case Repo.fetch(Work.Session.Query.by_id(expected.id)) do
      {:ok, %Work.Session{} = saved_session} ->
        if Map.take(saved_session, @identity) == Map.take(expected, @identity) and
             (is_nil(expected.worker_job_digest) or
                expected.worker_job_digest == saved_session.worker_job_digest),
           do: {:ok, saved_session},
           else: {:error, :coop_worker_job_identity_changed}

      {:error, :not_found} ->
        {:error, :coop_worker_job_identity_changed}
    end
  end

  defp source_matches?(nil, %Work.Session{repository_ref: nil, repository_source: nil}), do: true

  defp source_matches?(%{} = source, session) do
    source["repository_ref"] == session.repository_ref and
      source["binding"]["requested"] ==
        (session.repository_source || Work.RepositorySource.default())
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
    case Settings.environment(snapshot, environment_ref) do
      %Settings.Environment{} = environment ->
        refs = Settings.Environment.repository_refs(environment)

        primary in Settings.Environment.writable_refs(environment) and
          if context?,
            do: repositories == [primary | List.delete(refs, primary)],
            else: refs == [primary] and repositories == [primary]

      nil ->
        false
    end
  end

  defp scope_matches?(%{scope_kind: :environment} = binding, session) do
    binding.scope_ref == session.environment_ref and
      binding.repository_ref == session.repository_ref
  end

  defp scope_matches?(%{scope_kind: :repository} = binding, session),
    do: binding.scope_ref == session.repository_ref

  defp scope_matches?(%{scope_kind: :installation}, session), do: is_nil(session.repository_ref)

  defp companion_refs(session) do
    case Work.RepositoryContext.restore(session.repository_context, session.repository_ref) do
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
         true <- source["binding"]["requested"] == (requested || Work.RepositorySource.default()) do
      {:ok, source}
    else
      {:error, {:coop_worker_source_refused, repository, submodule}} ->
        {:error, {:coop_worker_source_refused, repository, submodule}}

      _unavailable ->
        {:error, :coop_worker_source_unavailable}
    end
  end

  defp source(_snapshot, _ref, _requested, _root, _prepare),
    do: {:error, :coop_worker_source_unavailable}

  # A read-only repository is refused in its own words: what to change is the
  # environment that lists it, not the repository the task works on.
  defp companions(snapshot, refs, root, prepare) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, sources} ->
      case source(snapshot, ref, nil, root, prepare) do
        {:ok, source} ->
          {:cont, {:ok, sources ++ [%{"name" => ref, "source" => source}]}}

        {:error, {:coop_worker_source_refused, repository, submodule}} ->
          {:halt, {:error, {:coop_worker_companion_refused, repository, submodule}}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp document(session, work, purpose, source, companions) do
    work
    |> JobTemplates.execution(purpose, not is_nil(source))
    |> Map.merge(%{
      "version" => 2,
      "job_ref" => session.external_ref,
      "source" => source,
      "companions" => companions
    })
  end

  defp pin(original, revision, job, digest) do
    Repo.transaction(fn ->
      # Settings writers update this row in the same transaction as their
      # changes. A shared lock holds the checked revision through the pin.
      installation =
        Settings.Installation.Query.all()
        |> Settings.Installation.Query.lock_for_share()
        |> Repo.peek()

      session =
        original.id
        |> Work.Session.Query.by_id()
        |> Work.Session.Query.lock_for_update()
        |> Repo.peek()

      unless session && Map.take(session, @identity) == Map.take(original, @identity),
        do: Repo.rollback(:coop_worker_job_identity_changed)

      pin_locked(session, installation, revision, job, digest)
    end)
  end

  defp pin_locked(
         %Work.Session{worker_job_document: nil, worker_job_digest: nil} = session,
         installation,
         revision,
         job,
         digest
       ) do
    unless installation && installation.revision == revision,
      do: Repo.rollback(:coop_worker_job_settings_changed)

    case unplaced(session) do
      :ok -> session |> Work.Session.Changeset.pin_worker_job(job, digest) |> Repo.update!()
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp pin_locked(session, _installation, _revision, _job, _digest) do
    case validate(session) do
      {:ok, pinned} -> pinned
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp unplaced(session) do
    if unstarted?(session), do: :ok, else: {:error, :coop_worker_job_requires_new_session}
  end

  @doc """
  Whether no worker ever took the session: it was never placed, so no worker
  holds its job and nothing ran under its authority.
  """
  @spec unstarted?(Work.Session.t()) :: boolean()
  def unstarted?(%Work.Session{coop_session_id: nil, cleanup_status: :active} = session),
    do: not Repo.exists?(Placement.Query.by_session_id(session.id))

  def unstarted?(_session), do: false
end
