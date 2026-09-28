defmodule Ryker.RepositoryKnowledge.Dispatcher do
  @moduledoc """
  One pass of the knowledge queue (`Ryker.RepositoryKnowledge.Custody`):
  lease the next repository due for a step, take that step, and give the
  lease back with what happened.

  The steps are the daily check (what GitHub says now, and the rules in
  `Ryker.RepositoryKnowledge.Refresh`), the write (a model turn through
  `Ryker.RepositoryKnowledge.Executor`, or the outline once no model could
  finish a repository none ever wrote), and the proposal on GitHub. Only a
  repository that is added, set up and still granted is checked, written or
  proposed; one GitHub keeps archived is skipped with a sentence that says
  so, and a run already out at Coop is followed to its stop whatever became
  of its repository. Once a person closes Ryker's pull request, the check
  writes and proposes nothing more until someone asks.
  """

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

  @actor "github:knowledge"
  @file_name "RYKER.md"
  @no_policy_hold_seconds 300
  @worker_hold_seconds 60
  @permanent [
    {:github_onboarding, :archived},
    {:github_onboarding, :permission},
    {:github_onboarding, :not_found},
    :repository_empty,
    :repository_too_large,
    :repository_knowledge_unreadable,
    :repository_knowledge_proposal_edited
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

  # Every repository the lane may check, write and propose: added from
  # GitHub, set up, and still granted, with its binding.
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
          :publish -> publish(claim, target, settings)
        end
    end
  end

  # -- The daily check ---------------------------------------------------------------

  defp check(claim, {repository, binding}, settings) do
    remote = settings.remote
    entry = claim.entry

    result =
      with :ok <- not_archived(remote, binding, repository),
           {:ok, head} <- remote.head(binding, repository),
           {:ok, current} <- knowledge_file(remote, binding, repository, head),
           {:ok, pull_request} <- pull_request_state(remote, binding, repository, entry),
           :ok <- follow_default_branch(repository, head, current, pull_request),
           do:
             {:checked, decide(entry, head, current, pull_request, binding, repository, remote),
              pull_request}

    case result do
      {:checked, {:error, reason}, _pull_request} ->
        failed(claim, reason, settings, &check_failed/2)

      {:checked, decision, pull_request} ->
        Custody.checked(claim, decision, pull_request)

      {:error, reason} ->
        failed(claim, reason, settings, &check_failed/2)
    end
  end

  # A person closed Ryker's pull request, turning it down: nothing is
  # written or proposed again by itself, only when someone asks for it
  # (refresh knowledge). A document written and never proposed is proposed
  # first; otherwise the rules decide (`Ryker.RepositoryKnowledge.Refresh`).
  defp decide(_entry, _head, _current, :closed, _binding, _repository, _remote), do: :current

  defp decide(
         %{document: document, published_at: nil},
         _head,
         _current,
         _pull_request,
         _binding,
         _repository,
         _remote
       )
       when is_binary(document),
       do: :publish

  defp decide(entry, head, current, _pull_request, binding, repository, remote) do
    Refresh.decide(
      written(entry),
      current,
      head,
      fn -> remote.changes(binding, repository, entry.document_commit, head) end,
      DateTime.utc_now()
    )
  end

  defp check_failed(claim, reason), do: Custody.checked(claim, {:failed, reason})

  defp written(entry),
    do: %{commit: entry.document_commit, at: entry.document_at, by: entry.document_by}

  defp not_archived(remote, binding, repository) do
    case remote.repository(binding, repository) do
      {:ok, %{archived: true}} -> {:error, {:github_onboarding, :archived}}
      {:ok, %{archived: false}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # RYKER.md on the default branch, or nil. One Ryker cannot read (over
  # 128,000 bytes, not text, not a file) is not one Ryker wrote: like a
  # person's, it is left as it is, and the entry says why.
  defp knowledge_file(remote, binding, repository, head) do
    case remote.read(binding, repository, @file_name, head) do
      {:ok, current} -> {:ok, text(current)}
      {:error, :source_unavailable} -> {:error, :repository_knowledge_unreadable}
      {:error, _reason} = error -> error
    end
  end

  defp pull_request_state(_remote, _binding, _repository, %{pull_request_number: nil}),
    do: {:ok, nil}

  defp pull_request_state(remote, binding, repository, %{pull_request_number: number}),
    do: remote.pull_request(binding, repository, number)

  # Work reads RYKER.md from the settings (`Ryker.Work.SubmissionBuilder`).
  # While Ryker's proposal is open, that is the proposal; otherwise it is
  # the file on the default branch, as people merged, edited or deleted it.
  defp follow_default_branch(_repository, _head, _current, :open), do: :ok

  defp follow_default_branch(repository, head, current, _pull_request) do
    wanted =
      case current do
        nil ->
          %{
            knowledge_content: nil,
            knowledge_status: nil,
            knowledge_source_commit: nil,
            knowledge_sha256: nil
          }

        text ->
          %{
            knowledge_content: text,
            knowledge_status: :accepted,
            knowledge_source_commit: head,
            knowledge_sha256: sha256(text)
          }
      end

    if repository.knowledge_content == wanted.knowledge_content and
         repository.knowledge_status == wanted.knowledge_status,
       do: :ok,
       else: save_work_copy(repository.ref, wanted)
  end

  # -- Writing -----------------------------------------------------------------------

  defp write(
         %{entry: %{start_count: count, start_limit: limit}} = claim,
         _snapshot,
         target,
         settings
       )
       when count >= limit,
       do: exhausted(claim, target, settings)

  defp write(claim, snapshot, {repository, binding} = target, settings) do
    case not_archived(settings.remote, binding, repository) do
      :ok -> start(claim, policy(snapshot, repository.ref), target, settings)
      {:error, reason} -> failed(claim, reason, settings, &Custody.give_up_write/2)
    end
  end

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
           {:ok, current} <- knowledge_file(remote, binding, repository, head),
           {:ok, run} <-
             Custody.prepare(
               claim,
               attempt(claim.entry, repository, binding, policy, head, entries, current)
             ),
           do: Custody.begin_execution(claim, run.id)

    case result do
      {:ok, run} -> execute(claim, run, target, settings)
      {:error, :repository_knowledge_lease_lost} = error -> error
      {:error, reason} -> failed(claim, reason, settings, &Custody.give_up_write/2)
    end
  end

  defp attempt(entry, repository, binding, policy, head, entries, current) do
    tree = Document.tree(entries)
    facts = Document.outline_facts(tree)

    # The document on the default branch is worth keeping in the words it
    # has only when a model or a person wrote it; the old file-list summary
    # and the outline would only teach the model their gaps.
    kept = if Document.origin(current) in [:model, :person], do: current, else: nil

    request =
      Prompt.build(
        %{
          name: repository.github_repository,
          default_branch: repository.base_branch,
          commit: head,
          top_level: facts.top_level,
          key_files: facts.key_files,
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
      {:ok, {:applied, _entry}} ->
        # The document is ready to propose; the next pass proposes it.
        with {:ok, _released} <- Custody.yield(claim, 0), do: {:ok, :written}

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

      {:error, _reason} ->
        unresolved(claim, run)
    end
  end

  # Coop or GitHub could not be asked, or its answer did not settle the step:
  # nothing is replaced; the same run is asked again, less often each time.
  defp unresolved(claim, run) do
    with {:ok, run} <- Custody.reconciliation_failed(claim, run.id) do
      Custody.yield(claim, min(Integer.pow(2, min(run.reconcile_attempt_count, 6)), 60))
    end
  end

  # Every start of this write is spent. The outline stands in only where
  # there is nothing better: no RYKER.md, or only the old file-list summary
  # or an earlier outline. A document a model or a person wrote stays, and
  # the entry says why it was not updated.
  defp exhausted(claim, {repository, binding}, settings) do
    entry = claim.entry
    reason = last_failure(entry.repository_ref)

    if entry.document_by == :model do
      Custody.give_up_write(claim, reason)
    else
      case outline(settings.remote, binding, repository) do
        {:ok, {document, head}} -> Custody.store_outline(claim, document, head, reason)
        {:ok, :kept} -> Custody.give_up_write(claim, reason)
        {:error, failure} -> failed(claim, failure, settings, &Custody.give_up_write/2)
      end
    end
  end

  defp outline(remote, binding, repository) do
    with {:ok, head} <- remote.head(binding, repository),
         {:ok, current} <- knowledge_file(remote, binding, repository, head) do
      if Document.origin(current) in [:none, :old_scan, :outline],
        do: written_outline(remote, binding, repository, head),
        else: {:ok, :kept}
    end
  end

  defp written_outline(remote, binding, repository, head) do
    with {:ok, entries} <- remote.tree(binding, repository, head),
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

  # -- Proposing ---------------------------------------------------------------------

  defp publish(claim, {repository, binding}, settings) do
    entry = claim.entry

    case settings.remote.publish(binding, repository, %{
           document: entry.document,
           body: pull_request_body(entry),
           proposed: last_proposal(repository)
         }) do
      {:ok, result} ->
        recorded(claim, result, repository, settings)

      # RYKER.md on the default branch became one Ryker cannot read.
      {:error, :source_unavailable} ->
        failed(claim, :repository_knowledge_unreadable, settings, &Custody.publication_failed/2)

      {:error, reason} ->
        failed(claim, reason, settings, &Custody.publication_failed/2)
    end
  end

  # What Ryker last proposed: Work reads that proposal while its pull request
  # is open (`follow_default_branch/4`), so it is what Ryker last wrote there.
  defp last_proposal(%{knowledge_status: :proposed, knowledge_content: content}), do: content
  defp last_proposal(_repository), do: nil

  # GitHub has the proposal; Work's copy of it is saved with the record. A
  # save the settings refused (another saved them a moment before) gives the
  # lease back and proposes again shortly, which finds the same proposal.
  defp recorded(claim, result, repository, settings) do
    case Custody.published(claim, result, &save_published(repository.ref, &1, result)) do
      {:ok, _entry} = recorded -> recorded
      {:error, :repository_knowledge_lease_lost} = error -> error
      {:error, _reason} -> Custody.yield(claim, settings.retry_delay_seconds)
    end
  end

  defp save_published(ref, entry, %{outcome: outcome, url: url})
       when outcome in [:opened, :updated],
       do:
         save_work_copy(ref, %{
           knowledge_content: entry.document,
           knowledge_status: :proposed,
           knowledge_source_commit: entry.document_commit,
           knowledge_sha256: entry.document_sha256,
           knowledge_pull_request_url: url
         })

  defp save_published(ref, _entry, %{outcome: :unchanged} = result),
    do:
      save_work_copy(ref, %{
        knowledge_content: result.base_document,
        knowledge_status: :accepted,
        knowledge_source_commit: result.base_commit,
        knowledge_sha256: sha256(result.base_document)
      })

  @doc false
  def pull_request_body(entry) do
    short = String.slice(entry.document_commit, 0, 7)

    [
      if(entry.document_by == :outline,
        do:
          "Ryker could not finish reading this repository at `#{short}`, so this RYKER.md is " <>
            "an outline from the file list. Ryker replaces it on its next refresh.",
        else:
          "Ryker read this repository at `#{short}` and wrote RYKER.md: what it is for, its " <>
            "parts, how to build, test and run it, how it ships, its conventions and where to " <>
            "look. Every path and command in it was checked against the repository at that commit."
      ),
      entry.reason && "Why now: #{entry.reason}",
      (entry.dropped_count || 0) > 0 &&
        "Ryker left out #{dropped(entry.dropped_count)} the model named that the repository " <>
          "does not have.",
      "Review and edit it before merging; Ryker never merges it. While this pull request is " <>
        "open, Ryker updates it here instead of opening another."
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n\n")
  end

  defp dropped(1), do: "1 path or command"
  defp dropped(count), do: "#{count} paths or commands"

  # -- Shared ------------------------------------------------------------------------

  # A reason another try would meet again (archived, a permission, the
  # repository or its default branch gone, no commit yet, too many files, a
  # RYKER.md Ryker cannot read, a pull request a person edited) ends the step
  # with a sentence and waits for the next check. Anything
  # else, a 5xx, a rate limit, a reply Ryker did not expect or none at all,
  # is tried again shortly.
  defp failed(claim, reason, settings, record) do
    if reason in @permanent,
      do: record.(claim, reason),
      else: Custody.yield(claim, settings.retry_delay_seconds)
  end

  # Work's copy of RYKER.md lives on the repository's settings row. A
  # repository removed meanwhile keeps nothing: the write names the revision
  # it found the repository at, so a removal in between refuses it instead
  # of saving the repository again with nothing but its RYKER.md.
  defp save_work_copy(ref, attributes) do
    snapshot = Settings.fetch!()

    if Enum.any?(snapshot.repositories, &(&1.ref == ref)) do
      case Settings.put_repository(
             Map.put(attributes, :ref, ref),
             snapshot.installation.revision,
             @actor
           ) do
        {:ok, _snapshot} -> :ok
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  defp text(:not_found), do: nil
  defp text(text) when is_binary(text), do: text

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
