defmodule Ryker.GitHubActions.IssueWorkflows do
  @moduledoc "Append-only issue plans and idempotent approvals backed by normal Work ingress."
  alias Ryker.AdvisoryLock
  alias Ryker.CanonicalJSON
  alias Ryker.GitHub
  alias Ryker.GitHubActions.IssueInstructions
  alias Ryker.GitHubActions.IssueMessages
  alias Ryker.GitHubActions.IssuePlan
  alias Ryker.GitHubActions.IssueProgress
  alias Ryker.GitHubActions.IssueRequest
  alias Ryker.GitHubActions.IssueWorkflow
  alias Ryker.GitHubActions.Requests
  alias Ryker.GitObject
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.StateTools

  @doc "Makes the configured quick-action comment due without starting a task."
  def ensure(access, issue) do
    Repo.transaction(fn ->
      fence!(access)

      enabled =
        Enum.any?(
          Settings.fetch!().repositories,
          &(&1.ref == access.repository.ref and &1.github_issue_actions)
        )

      if not enabled, do: Repo.rollback(:issue_actions_disabled)
      workflow = fetch_and_lock_workflow!(access, issue)

      if is_nil(workflow.external_receipt) do
        workflow
        |> IssueWorkflow.Changeset.update(%{next_attempt_at: Repo.now!()})
        |> Repo.update!()
      else
        workflow
      end
    end)
  end

  @doc "An active issue conversation may offer controls without starting a task."
  def offer(binding, access, issue) do
    Repo.transaction(fn ->
      fence!(access)

      case StateTools.Binding.fetch_and_lock_current_with_episode(binding) do
        {:ok, %{episode: %{execution_mode: :live}}} -> :ok
        _stale -> Repo.rollback(:planning_request_required)
      end

      workflow = fetch_and_lock_workflow!(access, issue)

      workflow
      |> IssueWorkflow.Changeset.update(%{next_attempt_at: Repo.now!()})
      |> Repo.update!()
    end)
  end

  @doc "Reads a plan without creating work or storing anything on a link preview."
  def view(access, issue, before_revision \\ nil) do
    workflow =
      case Repo.fetch(IssueWorkflow.Query.by_identity(identity(access, issue["number"]))) do
        {:ok, workflow} -> workflow
        {:error, :not_found} -> %IssueWorkflow{revision: 0}
      end

    plans =
      if workflow.id do
        workflow.id
        |> IssuePlan.Query.by_workflow_id()
        |> IssuePlan.Query.before_revision(before_revision)
        |> IssuePlan.Query.ordered_by_recent()
        |> IssuePlan.Query.limit_to(10)
        |> Repo.all()
      else
        []
      end

    request =
      workflow.current_request_id |> current_request() |> IssueProgress.displayed_request()

    progress = IssueProgress.read(request)

    plan = current_plan(workflow.current_plan_id)

    %{
      issue: issue,
      workflow: workflow,
      plans: plans,
      progress: progress,
      progress_text: IssueMessages.status(progress),
      history_before: if(length(plans) == 10, do: List.last(plans).revision),
      plan: plan,
      implementation: implementation(workflow, plan, request, progress, issue),
      expected: %{
        "revision" => workflow.revision,
        "plan_id" => workflow.current_plan_id,
        "request_id" => workflow.current_request_id,
        "issue_digest" => GitHub.IssueSnapshot.digest(issue)
      }
    }
  end

  defp implementation(%{id: nil}, nil, _request, _progress, _issue), do: nil

  defp implementation(workflow, nil, _request, _progress, issue) do
    workflow.id
    |> IssueRequest.Query.by_workflow_id()
    |> IssueRequest.Query.direct_build(issue)
    |> Repo.peek()
    |> case do
      nil -> nil
      request -> IssueProgress.read(request)
    end
  end

  defp implementation(
         _workflow,
         %{id: id},
         %{kind: :implement_plan, plan_id: id},
         progress,
         _issue
       ),
       do: progress

  defp implementation(workflow, plan, _request, _progress, _issue) do
    case IssueProgress.fetch_implementation(workflow.id, plan.id) do
      {:ok, request} -> IssueProgress.read(request)
      {:error, :not_found} -> nil
    end
  end

  defp current_request(nil), do: nil

  defp current_request(id) do
    case Repo.fetch(IssueRequest.Query.by_id(id)) do
      {:ok, request} -> request
      {:error, :not_found} -> nil
    end
  end

  def current_plan(nil), do: nil
  def current_plan(id), do: id |> IssuePlan.Query.by_id() |> Repo.fetch!()

  @doc "Accepts one exact issue or plan snapshot. Two people clicking it still start only once."
  def start(access, issue, kind, expected)
      when kind in [:make_plan, :build_issue, :implement_plan, :triage_issue] do
    key =
      if kind == :triage_issue,
        do: triage_key(issue),
        else: CanonicalJSON.digest(%{"kind" => Atom.to_string(kind), "expected" => expected})

    Repo.transaction(fn ->
      fence!(access)
      authorize_start!(access, kind)
      workflow = fetch_and_lock_workflow!(access, issue)

      key = manual_key(workflow, kind, key)

      case Repo.fetch(
             IssueRequest.Query.by_workflow_id(workflow.id)
             |> IssueRequest.Query.approved_work(kind, expected, issue, key)
           ) do
        {:ok, request} -> %{request: request, status: :duplicate}
        {:error, :not_found} -> start_new!(access, issue, workflow, kind, expected, key)
      end
    end)
  end

  @doc "Repository opt-in authorizes read-only system triage, never impersonation of the reporter."
  def auto_triage(configured, issue, grant) do
    access = Map.put(configured, :actor, %{"id" => 0, "login" => "ryker-triage", "type" => "Bot"})
    key = triage_key(issue)

    Repo.transaction(fn ->
      fence!(access)
      authorize_start!(access, :triage_issue)

      unless GitHub.IssueTriageGrant.matches?(grant, issue),
        do: Repo.rollback(:triage_request_changed)

      workflow = fetch_and_lock_workflow!(access, issue)

      case Repo.fetch(
             IssueRequest.Query.by_workflow_id(workflow.id)
             |> IssueRequest.Query.by_request_key(key)
           ) do
        {:ok, request} ->
          %{request: request, status: :duplicate}

        {:error, :not_found} ->
          start_new!(
            Map.put(access, :triage_grant, grant),
            issue,
            workflow,
            :triage_issue,
            view(access, issue).expected,
            key
          )
      end
    end)
  end

  # Manual approval of the same report can replace an expired automatic
  # request. Its old outcome and idempotency key remain part of issue history.
  defp manual_key(workflow, :triage_issue, key) do
    case Repo.fetch(
           IssueRequest.Query.by_workflow_id(workflow.id)
           |> IssueRequest.Query.by_request_key(key)
         ) do
      {:ok, %{actor_id: 0, outcome: %{"status" => "authorization_expired"}, id: id}} ->
        CanonicalJSON.digest([key, id])

      _other ->
        key
    end
  end

  defp manual_key(_workflow, _kind, key), do: key

  def expire_automatic(%IssueRequest{kind: :triage_issue, actor_id: 0} = request) do
    Repo.transaction(fn ->
      workflow =
        request.workflow_id
        |> IssueWorkflow.Query.by_id()
        |> IssueWorkflow.Query.lock_for_update()
        |> Repo.fetch!()

      request.id |> IssueRequest.Query.by_id() |> Repo.fetch!() |> expire_locked(workflow)
    end)
  end

  defp expire_locked(%IssueRequest{outcome: nil} = request, workflow) do
    now = Repo.now!()

    request
    |> IssueRequest.Changeset.finish(
      %{"status" => "authorization_expired", "terminal" => true},
      now
    )
    |> Repo.update!()

    if workflow.current_request_id == request.id do
      workflow |> IssueWorkflow.Changeset.update(%{next_attempt_at: now}) |> Repo.update!()
    end
  end

  defp expire_locked(_finished, _workflow), do: :ok

  defp triage_key(issue) do
    CanonicalJSON.digest(%{
      "kind" => "triage_issue",
      "issue" => GitHub.IssueSnapshot.content_digest(issue)
    })
  end

  defp authorize_start!(%{actor: %{"id" => 0}} = access, :triage_issue) do
    enabled =
      Enum.any?(
        Settings.fetch!().repositories,
        &(&1.ref == access.repository.ref and &1.github_issue_triage)
      )

    if not enabled, do: Repo.rollback(:issue_triage_disabled)
  end

  defp authorize_start!(%{actor: %{"id" => id}}, _kind) when is_integer(id) and id > 0, do: :ok
  defp authorize_start!(_access, _kind), do: Repo.rollback(:issue_request_not_authorized)

  @doc "A human edit creates a new revision; it never changes an approved brief."
  def edit(access, issue, expected, body) do
    Repo.transaction(fn ->
      fence!(access)
      workflow = fetch_and_lock_workflow!(access, issue)
      key = "edit:" <> CanonicalJSON.digest(%{"expected" => expected, "body" => body})

      case Repo.fetch(
             IssuePlan.Query.by_workflow_id(workflow.id)
             |> IssuePlan.Query.by_source_key(key)
           ) do
        {:ok, plan} ->
          plan

        {:error, :not_found} ->
          expect_plan!(workflow, issue, expected)
          plan = current_plan!(workflow)

          insert_plan!(
            workflow,
            body,
            plan.source_commit,
            issue,
            key,
            "github-user:#{access.actor["id"]}"
          )
      end
    end)
  end

  @doc "Saves the model's plan only for its current planning input and host-observed commit."
  def save(binding, instruction_ref, body) do
    with {:ok, {entry, _event}} <- Records.TaskInstruction.fetch_source(binding, instruction_ref),
         {:ok, %IssueRequest{kind: :make_plan} = request} <-
           Repo.fetch(IssueRequest.Query.by_entry_id(entry.id)) do
      Repo.transaction(fn -> save_current!(binding, entry, request, body) end)
    else
      _invalid -> {:error, :planning_request_required}
    end
  end

  def save_triage(binding, instruction_ref, result) do
    with {:ok, {entry, _event}} <- Records.TaskInstruction.fetch_source(binding, instruction_ref),
         {:ok, %IssueRequest{kind: :triage_issue} = request} <-
           Repo.fetch(IssueRequest.Query.by_entry_id(entry.id)) do
      Repo.transaction(fn -> save_current!(binding, entry, request, {:triage, result}) end)
    else
      _invalid -> {:error, :triage_request_required}
    end
  end

  defp save_current!(binding, entry, request, body) do
    # Same source/episode order as task start; a superseded turn cannot save a plan.
    :ok = Records.TaskInstruction.lock_source(entry)

    current =
      case StateTools.Binding.fetch_and_lock_current_with_episode(binding) do
        {:ok, current} -> current
        {:error, reason} -> Repo.rollback(reason)
      end

    ensure_saving!(current)

    commit =
      get_in(current.session.worker_job_document || %{}, [
        "source",
        "binding",
        "selected_commit"
      ])

    if not GitObject.id?(commit), do: Repo.rollback(:planning_source_required)

    workflow =
      IssueWorkflow.Query.by_id(request.workflow_id)
      |> IssueWorkflow.Query.lock_for_update()
      |> Repo.fetch!()

    if current.session.repository_ref != workflow.repository_ref,
      do: Repo.rollback(:planning_source_required)

    case body do
      {:triage, result} -> save_triage!(workflow, request, result, commit)
      text -> save_plan!(workflow, request, text, commit)
    end
  end

  defp ensure_saving!(current) do
    if current.episode.execution_mode != :live or
         get_in(current.turn.validation_intent || %{}, ["verdict"]) == "accept",
       do: Repo.rollback(:planning_request_required)
  end

  defp save_triage!(_workflow, %IssueRequest{outcome: %{} = outcome}, result, _commit) do
    if outcome["triage"] == Map.delete(result, "plan"),
      do: outcome,
      else: Repo.rollback(:triage_already_saved)
  end

  defp save_triage!(workflow, request, result, commit) do
    if workflow.revision != request.base_revision or workflow.current_request_id != request.id,
      do: Repo.rollback(:plan_changed)

    plan =
      if result["plan"] do
        insert_plan!(
          workflow,
          result["plan"],
          commit,
          request.source_snapshot["issue"],
          "request:" <> request.id,
          "ryker"
        )
      end

    outcome = %{
      "status" => "triage_ready",
      "triage" => Map.delete(result, "plan"),
      "plan_id" => if(plan, do: plan.id)
    }

    request |> IssueRequest.Changeset.finish(outcome, Repo.now!()) |> Repo.update!()
    workflow |> IssueWorkflow.Changeset.update(%{next_attempt_at: Repo.now!()}) |> Repo.update!()
    outcome
  end

  defp save_plan!(workflow, request, body, commit) do
    key = "request:" <> request.id

    case Repo.fetch(
           IssuePlan.Query.by_workflow_id(workflow.id)
           |> IssuePlan.Query.by_source_key(key)
         ) do
      {:ok, %{body: ^body} = plan} ->
        plan

      {:ok, _different} ->
        Repo.rollback(:plan_already_saved)

      {:error, :not_found} ->
        if workflow.revision != request.base_revision, do: Repo.rollback(:plan_changed)

        plan =
          insert_plan!(workflow, body, commit, request.source_snapshot["issue"], key, "ryker")

        request
        |> IssueRequest.Changeset.finish(
          %{"status" => "plan_ready", "plan_id" => plan.id},
          Repo.now!()
        )
        |> Repo.update!()

        plan
    end
  end

  defp start_new!(access, issue, workflow, kind, expected, key) do
    expect_plan!(workflow, issue, expected)
    if expected["request_id"] != workflow.current_request_id, do: Repo.rollback(:plan_changed)
    available!(workflow)

    snapshot =
      snapshot(workflow, issue, kind)
      |> Ryker.Maps.put_present("triage_grant", Map.get(access, :triage_grant))

    case CanonicalJSON.validate(snapshot, max_bytes: 65_536) do
      :ok -> :ok
      {:error, _reason} -> Repo.rollback(:invalid_plan)
    end

    # Leave room in the existing task record for title, checks and source references.
    if kind == :build_issue and
         byte_size(CanonicalJSON.encode!(IssueInstructions.prompt(kind, snapshot))) > 30_720,
       do: Repo.rollback(:issue_build_too_large)

    evidence =
      snapshot
      |> IssueInstructions.evidence()
      |> Map.delete("triage_grant")
      |> Map.merge(%{"workflow_id" => workflow.id, "request_key" => key})

    with {:ok, receipt} <-
           Requests.record(
             access,
             workflow.number,
             Atom.to_string(kind),
             IssueInstructions.request(kind, snapshot),
             evidence
           ),
         {:ok, request} <- insert_request(workflow, snapshot, access, kind, key, receipt.entry.id) do
      workflow
      |> IssueWorkflow.Changeset.update(%{
        current_request_id: request.id,
        issue_snapshot: issue,
        next_attempt_at: Repo.now!()
      })
      |> Repo.update!()

      %{request: request, status: :recorded}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_request(workflow, snapshot, access, kind, key, entry_id) do
    IssueRequest.Changeset.insert(%{
      workflow_id: workflow.id,
      plan_id: get_in(snapshot, ["plan", "id"]),
      kind: kind,
      request_key: key,
      base_revision: workflow.revision,
      source_snapshot: snapshot,
      actor_id: access.actor["id"],
      entry_id: entry_id,
      inserted_at: Repo.now!()
    })
    |> Repo.insert()
  end

  defp available!(%{current_request_id: nil}), do: :ok

  defp available!(workflow) do
    request =
      workflow.current_request_id
      |> IssueRequest.Query.by_id()
      |> Repo.fetch!()
      |> IssueProgress.refresh()

    if is_nil(request.finished_at), do: Repo.rollback(:issue_work_in_progress)
  end

  defp snapshot(workflow, issue, :implement_plan) do
    plan = current_plan!(workflow)

    if GitHub.IssueSnapshot.content_digest(plan.issue_snapshot) !=
         GitHub.IssueSnapshot.content_digest(issue),
       do: Repo.rollback(:issue_changed)

    %{
      "issue" => issue,
      "plan" => %{
        "id" => plan.id,
        "revision" => plan.revision,
        "body" => plan.body,
        "source_commit" => plan.source_commit
      }
    }
  end

  defp snapshot(_workflow, issue, _kind), do: %{"issue" => issue}

  defp insert_plan!(workflow, body, commit, issue, key, author) do
    changeset =
      IssuePlan.Changeset.insert(%{
        workflow_id: workflow.id,
        revision: workflow.revision + 1,
        parent_plan_id: workflow.current_plan_id,
        source_key: key,
        body: body,
        source_commit: commit,
        issue_snapshot: issue,
        author_ref: author,
        inserted_at: Repo.now!()
      })

    case Repo.insert(changeset) do
      {:ok, plan} ->
        workflow
        |> IssueWorkflow.Changeset.update(%{
          current_plan_id: plan.id,
          revision: plan.revision,
          issue_snapshot: issue,
          next_attempt_at: Repo.now!()
        })
        |> Repo.update!()

        plan

      {:error, _changeset} ->
        Repo.rollback(:invalid_plan)
    end
  end

  defp current_plan!(%{current_plan_id: nil}), do: Repo.rollback(:plan_required)

  defp current_plan!(workflow),
    do: workflow.current_plan_id |> IssuePlan.Query.by_id() |> Repo.fetch!()

  defp expect_plan!(workflow, issue, expected) do
    current = %{
      "revision" => workflow.revision,
      "plan_id" => workflow.current_plan_id,
      "request_id" => workflow.current_request_id,
      "issue_digest" => GitHub.IssueSnapshot.digest(issue)
    }

    if Map.delete(current, "request_id") != Map.delete(expected, "request_id"),
      do: Repo.rollback(:plan_changed)
  end

  defp fetch_and_lock_workflow!(access, issue) do
    identity = identity(access, issue["number"])
    AdvisoryLock.hold!("issue-workflow:" <> identity)

    case Repo.fetch(
           IssueWorkflow.Query.by_identity(identity)
           |> IssueWorkflow.Query.lock_for_update()
         ) do
      {:ok, workflow} ->
        workflow

      {:error, :not_found} ->
        IssueWorkflow.Changeset.insert(%{
          identity: identity,
          binding_ref: access.binding.name,
          repository_ref: access.repository.ref,
          repository_id: access.binding.repository_id,
          installation_id: access.binding.installation_id,
          number: issue["number"],
          issue_snapshot: issue
        })
        |> Repo.insert!()
    end
  end

  defp identity(access, number) do
    CanonicalJSON.digest(%{
      "binding" => access.binding.name,
      "repository" => access.binding.repository_id,
      "installation" => access.binding.installation_id,
      "number" => number
    })
  end

  defp fence!(access) do
    :ok = Settings.synchronize_in_transaction()

    with {:ok, current} <- Settings.fetch(),
         true <-
           GitHub.TaskAccess.authority_configuration(current) ==
             GitHub.TaskAccess.authority_configuration(access.settings),
         do: :ok,
         else: (_changed -> Repo.rollback(:repository_access_changed))
  end
end
