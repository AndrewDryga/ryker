defmodule Ryker.RepositoryKnowledge.Dispatcher do
  @moduledoc """
  One pass of the knowledge queue (`Ryker.RepositoryKnowledge.Custody`):
  lease the next repository due for a step, take that step, and give the
  lease back with what happened.

  The steps are the daily check (the default branch head, and the rules in
  `Ryker.RepositoryKnowledge.Refresh`) and the write: a model turn through
  `Ryker.RepositoryKnowledge.Executor`, or the outline once no model could
  finish a repository none ever wrote. Only a repository that is added, set
  up and still granted is checked or written, and a run already out at Coop
  is followed to its stop whatever became of its repository.

  GitHub is only read. The document is Ryker's own, and the repository's
  knowledge the moment it is written; a RYKER.md the repository holds is one
  more file the model may read.
  """

  require Logger

  alias Ryker.CoopFleet.JobTemplates

  alias Ryker.RepositoryKnowledge.{
    Custody,
    Document,
    Executor,
    FleetSession,
    Prompt,
    Refresh,
    Run
  }

  alias Ryker.Settings

  @no_policy_hold_seconds 300
  @worker_hold_seconds 60
  @permanent [
    {:github_onboarding, :permission},
    {:github_onboarding, :not_found},
    :repository_empty,
    :repository_too_large
  ]

  # How a run ended, as the atom its release records. Never turn a code read
  # back from the database into an atom it names.
  @codes %{
    "output_contract_failed" => :output_contract_failed,
    "invalid_repository_knowledge" => :invalid_repository_knowledge,
    "invalid_repository_knowledge_candidate" => :invalid_repository_knowledge_candidate,
    "repository_knowledge_unusable" => :repository_knowledge_unusable,
    "repository_knowledge_provider_failed" => :repository_knowledge_provider_failed,
    "repository_knowledge_execution_timeout" => :repository_knowledge_execution_timeout,
    "repository_knowledge_session_not_isolated" => :repository_knowledge_session_not_isolated,
    "repository_knowledge_session_unaddressable" => :repository_knowledge_session_unaddressable,
    "repository_knowledge_attempt_expired" => :repository_knowledge_attempt_expired,
    "repository_knowledge_removed" => :repository_knowledge_removed,
    "repository_knowledge_validation_unconfirmed" => :repository_knowledge_validation_unconfirmed
  }

  @spec run_once(map()) :: {:ok, atom() | term()} | {:error, term()}
  def run_once(settings) do
    case Settings.fetch() do
      {:ok, snapshot} -> run_once(snapshot, settings)
      {:error, :settings_not_initialized} -> {:ok, :idle}
    end
  end

  defp run_once(snapshot, settings) do
    targets = targets(snapshot)
    refs = Map.keys(targets)
    :ok = Custody.ensure(refs)

    case Custody.claim(settings.worker_ref, settings, refs) do
      {:ok, :idle} ->
        {:ok, :idle}

      {:ok, claim} ->
        step(claim, snapshot, Map.get(targets, claim.entry.repository_ref), settings)

      error ->
        error
    end
  end

  @doc """
  The earliest moment after `since` a repository's step falls due by the
  clock alone, for the worker to sleep until (`Custody.next_due_at/2`).
  """
  @spec next_due_at(DateTime.t()) :: DateTime.t() | nil
  def next_due_at(since) do
    case Settings.fetch() do
      {:ok, snapshot} -> Custody.next_due_at(since, Map.keys(targets(snapshot)))
      {:error, :settings_not_initialized} -> nil
    end
  end

  # Every repository the lane may check and write: added from GitHub, set up,
  # and still granted, with its binding.
  defp targets(snapshot) do
    bindings = Map.new(snapshot.github_bindings, &{&1.repository_ref, &1})

    for repository <- snapshot.repositories,
        repository.github_access == :available and repository.onboarding_state == :ready and
          is_binary(repository.github_repository) and Map.has_key?(bindings, repository.ref),
        into: %{},
        do: {repository.ref, {repository, Map.fetch!(bindings, repository.ref)}}
  end

  defp step(claim, snapshot, target, settings) do
    case Custody.outstanding(claim.entry.repository_ref) do
      %Run{} = run ->
        execute(claim, run, target, settings)

      nil when is_nil(target) ->
        # A lease run out on a repository that is no longer set up: given
        # back, and never claimed again while it stays that way.
        Custody.yield(claim, 0)

      nil ->
        case claim.entry.phase do
          :idle -> check(claim, target, settings)
          :write -> write(claim, snapshot, target, settings)
        end
    end
  end

  # -- The daily check ---------------------------------------------------------------

  defp check(claim, {repository, binding}, settings) do
    remote = settings.remote
    entry = claim.entry

    decision =
      with {:ok, head} <- remote.head(binding, repository),
           do:
             Refresh.decide(
               written(entry),
               head,
               fn -> remote.changes(binding, repository, entry.document_commit, head) end,
               DateTime.utc_now()
             )

    case decision do
      {:error, reason} -> failed(claim, reason, settings, &check_failed/2)
      decision -> Custody.checked(claim, decision)
    end
  end

  defp check_failed(claim, reason), do: Custody.checked(claim, {:failed, reason})

  defp written(entry),
    do: %{commit: entry.document_commit, at: entry.document_at, by: entry.document_by}

  # -- Writing -----------------------------------------------------------------------

  defp write(
         %{entry: %{start_count: count, start_limit: limit}} = claim,
         _snapshot,
         target,
         settings
       )
       when count >= limit,
       do: exhausted(claim, target, settings)

  defp write(claim, snapshot, {repository, _binding} = target, settings),
    do: start(claim, policy(snapshot, repository.ref), target, settings)

  # No read-only policy yet (the source is not pinned), or no worker would
  # take the session: the write waits, and no start is spent.
  defp start(claim, nil, _target, _settings), do: Custody.yield(claim, @no_policy_hold_seconds)

  defp start(claim, policy, {repository, _binding} = target, settings) do
    if FleetSession.placeable?(settings, repository.ref, policy),
      do: begin(claim, target, policy, settings),
      else: Custody.yield(claim, @worker_hold_seconds)
  end

  # The repository's own read-only policy: the standard models Work uses for
  # an ordinary task there (`Ryker.CoopFleet.JobTemplates`). Reading a whole
  # repository with tools is exactly that kind of task, and the policy mounts
  # the repository read-only already, so no new policy is needed.
  defp policy(snapshot, ref) do
    Enum.find_value(JobTemplates.from_settings(snapshot), fn binding ->
      if binding.purpose == :standard and binding.scope_kind == :repository and
           binding.scope_ref == ref,
         do: %{name: binding.policy_name, digest: binding.policy_digest}
    end)
  end

  defp begin(claim, {repository, binding} = target, policy, settings) do
    remote = settings.remote

    result =
      with {:ok, head} <- remote.head(binding, repository),
           {:ok, entries} <- remote.tree(binding, repository, head),
           {:ok, run} <-
             Custody.prepare(
               claim,
               attempt(claim.entry, repository, binding, policy, head, entries)
             ),
           do: Custody.begin_execution(claim, run.id)

    case result do
      {:ok, run} -> execute(claim, run, target, settings)
      {:error, :repository_knowledge_lease_lost} = error -> error
      {:error, reason} -> failed(claim, reason, settings, &Custody.give_up_write/2)
    end
  end

  defp attempt(entry, repository, binding, policy, head, entries) do
    tree = Document.tree(entries)
    facts = Document.outline_facts(tree)

    # What Ryker wrote last is worth keeping in the words it has only when a
    # model wrote it; the outline would only teach the model its gaps.
    kept = if entry.document_by == :model, do: entry.document

    request =
      Prompt.build(
        %{
          name: repository.github_repository,
          default_branch: repository.base_branch,
          commit: head,
          top_level: facts.top_level,
          key_files: facts.key_files,
          more: facts.more,
          current_document: kept
        },
        Custody.retry?(entry)
      )

    prompt = Prompt.render(request)

    %{
      commit: head,
      policy: policy.name,
      policy_digest: policy.digest,
      transport: "github",
      conversation_ref: "github:#{binding.name}:repository:#{binding.repository_id}",
      prompt: prompt,
      output_schema: Prompt.output_schema(),
      manifest: %{
        "bytes" => byte_size(prompt),
        "tree_entries" => map_size(tree),
        "top_level" => length(request["context"]["top_level"]),
        "key_files" => length(request["context"]["key_files"]),
        "current_document" => is_binary(request["context"]["current_document"]),
        "omitted" => request["context"]["omitted"],
        "reason" => entry.reason
      }
    }
  end

  defp execute(claim, run, target, settings) do
    result =
      with {:ok, _session} <- Custody.with_lease(claim, fn -> FleetSession.ensure(run) end),
           do: Executor.step(claim, run, target, settings)

    case result do
      # The document is the repository's knowledge, and the lease is given
      # back with it.
      {:ok, {:applied, _entry}} ->
        {:ok, :written}

      {:ok, :waiting} ->
        Custody.yield(claim, settings.step_delay_seconds)

      {:ok, :stopped} ->
        stopped = Custody.current(run.id)

        Custody.release(
          claim,
          Map.get(@codes, stopped.error_code, :repository_knowledge_execution_failed),
          settings.retry_delay_seconds
        )

      {:error, :repository_knowledge_lease_lost} = error ->
        error

      {:error, reason} ->
        unresolved(claim, run, reason)
    end
  end

  # Coop or GitHub could not be asked, or its answer did not settle the step:
  # nothing is replaced; the same run is asked again, less often each time.
  defp unresolved(claim, run, reason) do
    with {:ok, run} <- Custody.reconciliation_failed(claim, run.id) do
      log_unresolved(run, reason)
      Custody.yield(claim, min(Integer.pow(2, min(run.reconcile_attempt_count, 6)), 60))
    end
  end

  # The first tries and then every tenth, about every ten minutes once the
  # wait is a minute: tenant's tenantcorp/tenant-core retried 456 times on
  # 2026-10-03 and nothing said why.
  defp log_unresolved(run, reason) do
    count = run.reconcile_attempt_count

    if count <= 3 or rem(count, 10) == 0 do
      Logger.warning(
        "repository knowledge for #{run.repository_ref} could not take its next step " <>
          "(try #{count}): " <> inspect(reason, limit: 8, printable_limit: 300)
      )
    end
  end

  # Every start of this write is spent. A document a model wrote stays, and
  # the entry says why it was not updated; the outline stands in only where
  # there is nothing better, no document or an earlier outline.
  defp exhausted(claim, {repository, binding}, settings) do
    entry = claim.entry
    reason = last_failure(entry.repository_ref)

    if entry.document_by == :model do
      Custody.give_up_write(claim, reason)
    else
      case outline(settings.remote, binding, repository) do
        {:ok, {document, head}} -> Custody.store_outline(claim, document, head, reason)
        {:error, failure} -> failed(claim, failure, settings, &Custody.give_up_write/2)
      end
    end
  end

  defp outline(remote, binding, repository) do
    with {:ok, head} <- remote.head(binding, repository),
         {:ok, entries} <- remote.tree(binding, repository, head),
         tree = Document.tree(entries),
         {:ok, readme} <- readme(remote, binding, repository, tree, head),
         do: {:ok, {Document.outline(tree, readme, head, Date.utc_today()), head}}
  end

  defp last_failure(ref) do
    case Custody.last_run(ref) do
      %Run{error_code: code} -> Map.get(@codes, code, :repository_knowledge_retry_exhausted)
      nil -> :repository_knowledge_retry_exhausted
    end
  end

  # A README Ryker cannot read gives the outline no words, as none would.
  defp readme(remote, binding, repository, tree, head) do
    case Enum.find(["README.md", "README.rst", "README.txt", "README"], &(tree[&1] == :blob)) do
      nil ->
        {:ok, nil}

      path ->
        case remote.read(binding, repository, path, head) do
          {:ok, text} -> {:ok, text(text)}
          {:error, :source_unavailable} -> {:ok, nil}
          {:error, _reason} = error -> error
        end
    end
  end

  # -- Shared ------------------------------------------------------------------------

  # A reason another try would meet again (a permission, the repository or
  # its default branch gone, no commit yet, too many files) ends the step with
  # a sentence and waits for the next check. Anything else, a 5xx, a rate
  # limit, a reply Ryker did not expect or none at all, is tried again
  # shortly.
  defp failed(claim, reason, settings, record) do
    if reason in @permanent,
      do: record.(claim, reason),
      else: Custody.yield(claim, settings.retry_delay_seconds)
  end

  defp text(:not_found), do: nil
  defp text(text) when is_binary(text), do: text
end
