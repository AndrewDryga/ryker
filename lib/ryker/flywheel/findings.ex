defmodule Ryker.Flywheel.Findings do
  @moduledoc "Correlated proposals and explicit ownership transitions; shipping never proves improvement."
  alias Ryker.Flywheel.{Finding, Protocol, Receipt, Run, Runs}
  alias Ryker.{Reference, Repo}

  def observe(%Run{} = run, attributes, identities) do
    if not Protocol.finding?(attributes), do: Repo.rollback(:invalid_flywheel_finding)
    evidence = attributes["evidence"]

    if not Enum.all?(evidence, &known?(&1, identities)),
      do: Repo.rollback(:flywheel_evidence_not_reviewed)

    query = attributes["key"] |> Finding.Query.by_key() |> Finding.Query.lock_for_update()

    case Repo.fetch(query) do
      {:ok, finding} ->
        evidence = Enum.uniq(finding.evidence ++ evidence)
        finding |> Finding.Changeset.observe(evidence) |> Repo.update!()

      {:error, :not_found} ->
        attributes = Map.put(attributes, "run_id", run.id)

        case Repo.insert(Finding.Changeset.insert(attributes)) do
          {:ok, finding} -> finding
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end

  defp known?(identity, identities) do
    identity in identities or
      Repo.exists?(
        Receipt.Query.by_identity(identity["source"], identity["ref"], identity["version"])
      )
  end

  def transition(%Run{} = run, id, operation, request) do
    finding = id |> Finding.Query.by_id() |> Finding.Query.lock_for_update() |> Repo.peek()
    finding = finding || Repo.rollback(:flywheel_finding_not_found)
    note = request["note"]
    if not Reference.valid?(note, 2_000), do: Repo.rollback(:flywheel_decision_note_required)

    if operation == "select" and finding.status in [:ready, :in_progress, :waiting_user] and
         selected_in?(finding, run) do
      finding
    else
      record_transition(run, finding, operation, request)
    end
  end

  defp record_transition(run, finding, operation, request) do
    attributes = change(run, finding, operation, request)

    event = %{
      "action" => operation,
      "at" => DateTime.to_iso8601(Repo.now!()),
      "run_id" => run.id,
      "note" => request["note"],
      "before" =>
        finding
        |> Map.take([
          :status,
          :owner,
          :kind,
          :proposal,
          :task_id,
          :deployed_version,
          :shipped_at,
          :outcome
        ])
        |> Protocol.document(),
      "evidence_versions" =>
        Enum.map(Map.get(attributes, :evidence, finding.evidence), &Protocol.digest/1)
    }

    attributes = Map.put(attributes, :history, finding.history ++ [event])

    result = finding |> Finding.Changeset.transition(attributes) |> Repo.update()

    case result do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Repo.rollback(
          if Keyword.has_key?(changeset.errors, :task_id),
            do: :flywheel_task_link_conflict,
            else: changeset
        )
    end
  end

  defp change(run, finding, "select", request) do
    if finding.status not in [:proposed, :regressed, :ready, :in_progress, :waiting_user],
      do: Repo.rollback(:flywheel_finding_not_selectable)

    authorize_selection(run, finding, request)

    if finding.status in [:ready, :in_progress, :waiting_user] do
      %{status: finding.status}
    else
      status = if finding.owner == :ryker, do: :ready, else: :waiting_user

      %{
        status: status,
        task_id: nil,
        outcome: nil,
        deployed_version: nil,
        shipped_at: nil,
        revisit_at: nil
      }
    end
  end

  defp change(_run, finding, "user_done", _request) do
    if finding.status != :waiting_user, do: Repo.rollback(:flywheel_not_waiting_for_user)
    if finding.owner == :both, do: %{status: :ready}, else: %{status: :verified}
  end

  defp change(run, finding, "link", request) do
    require_selection(run, finding)
    task_id = request["task_id"]

    if finding.status not in [:ready, :in_progress] or finding.owner == :user or
         not is_binary(task_id) or
         not Regex.match?(~r/^\d{4}-\d{2}-\d{2}-[a-z0-9-]{1,160}$/, task_id),
       do: Repo.rollback(:invalid_flywheel_task_link)

    if finding.task_id && finding.task_id != task_id,
      do: Repo.rollback(:flywheel_task_link_conflict)

    %{task_id: task_id}
  end

  defp change(run, finding, "start", _request) do
    require_selection(run, finding)

    if finding.status not in [:ready, :in_progress] or finding.owner == :user,
      do: Repo.rollback(:flywheel_task_not_ready)

    if run.mode == :auto and not Runs.budget_available?(run),
      do: Repo.rollback(:flywheel_budget_exhausted)

    %{status: :in_progress}
  end

  defp change(run, finding, "ship", request) do
    require_selection(run, finding)
    if finding.status != :in_progress, do: Repo.rollback(:flywheel_task_not_started)
    version = request["version"]

    with true <- Reference.valid?(version, 200),
         {:ok, followup_at} <- Protocol.datetime(request["followup_at"]),
         true <- DateTime.compare(followup_at, Repo.now!()) == :gt do
      %{
        status: :shipped,
        deployed_version: version,
        shipped_at: Repo.now!(),
        revisit_at: followup_at
      }
    else
      _invalid -> Repo.rollback(:flywheel_deployment_and_followup_required)
    end
  end

  defp change(_run, finding, "outcome", request) do
    if finding.status not in [:shipped, :verified, :regressed],
      do: Repo.rollback(:flywheel_task_not_shipped)

    outcome = request["outcome"]
    validate_outcome(finding, outcome)

    status =
      case outcome["verdict"] do
        "improved" -> :verified
        "regressed" -> :regressed
        "insufficient" -> :shipped
      end

    followup_at = future_time!(request["followup_at"])
    %{status: status, outcome: outcome, revisit_at: followup_at}
  end

  defp change(_run, finding, "defer", request) do
    require_unstarted(finding)

    at = if request["revisit_at"], do: future_time!(request["revisit_at"]), else: nil
    %{status: :deferred, revisit_at: at}
  end

  defp change(_run, finding, "dismiss", _request) do
    require_unstarted(finding)
    %{status: :dismissed, revisit_at: nil}
  end

  defp change(_run, finding, "revise", request) do
    require_unstarted(finding)
    replacement = request["replacement"]

    if not Protocol.finding?(replacement) or replacement["key"] != finding.key,
      do: Repo.rollback(:invalid_flywheel_finding)

    if not Enum.all?(replacement["evidence"], &known?(&1, [])),
      do: Repo.rollback(:flywheel_evidence_not_reviewed)

    status = if finding.status in [:dismissed, :deferred], do: finding.status, else: :proposed

    %{
      status: status,
      owner: replacement["owner"],
      kind: replacement["kind"],
      proposal: replacement["proposal"],
      evidence: Enum.uniq(finding.evidence ++ replacement["evidence"])
    }
  end

  defp change(_run, finding, "close", request) do
    if finding.status not in [:ready, :in_progress], do: Repo.rollback(:flywheel_task_not_started)

    if finding.task_id && request["task_closed"] != true,
      do: Repo.rollback(:flywheel_task_reconciliation_required)

    evidence = request["evidence"]

    if not is_list(evidence) or evidence == [] or
         not Enum.all?(evidence, &(Protocol.identity?(&1) and known?(&1, []))),
       do: Repo.rollback(:flywheel_evidence_not_reviewed)

    %{
      status: :dismissed,
      revisit_at: nil,
      evidence: Enum.uniq(finding.evidence ++ evidence),
      outcome: %{
        "verdict" => "no_change",
        "comparison" => request["note"],
        "evidence" => evidence
      }
    }
  end

  defp change(_run, finding, "reopen", request) do
    if finding.status not in [:dismissed, :deferred],
      do: Repo.rollback(:flywheel_finding_not_deferred)

    new_evidence = request["new_evidence"]

    reminder_due =
      not is_nil(finding.revisit_at) and DateTime.compare(finding.revisit_at, Repo.now!()) != :gt

    material = request["material_change"] == true and new_evidence?(finding, new_evidence)

    if not reminder_due and not material, do: Repo.rollback(:flywheel_material_change_required)

    %{status: :proposed, revisit_at: nil}
  end

  defp change(_run, _finding, _operation, _request),
    do: Repo.rollback(:invalid_flywheel_transition)

  defp new_evidence?(finding, evidence) do
    decision =
      Enum.find(Enum.reverse(finding.history), &(&1["action"] in ["dismiss", "defer", "close"]))

    prior = if decision, do: decision["evidence_versions"] || [], else: []

    Protocol.identity?(evidence) and evidence in finding.evidence and
      Protocol.digest(evidence) not in prior
  end

  defp require_unstarted(%Finding{status: :ready, task_id: task_id}) when not is_nil(task_id),
    do: Repo.rollback(:flywheel_task_reconciliation_required)

  defp require_unstarted(%Finding{status: status})
       when status in [:proposed, :ready, :waiting_user, :deferred, :dismissed, :regressed],
       do: :ok

  defp require_unstarted(_finding), do: Repo.rollback(:flywheel_task_already_started)

  defp selected_in?(finding, run) do
    decision =
      Enum.find(
        Enum.reverse(finding.history),
        &(&1["action"] in ["select", "revise", "dismiss", "close"])
      )

    not is_nil(decision) and decision["action"] == "select" and decision["run_id"] == run.id
  end

  defp require_selection(run, finding) do
    if not selected_in?(finding, run), do: Repo.rollback(:flywheel_selection_required)
  end

  defp authorize_selection(%Run{mode: :suggest}, _finding, %{"approved" => true}), do: :ok

  defp authorize_selection(%Run{mode: :suggest}, _finding, _request),
    do: Repo.rollback(:flywheel_user_selection_required)

  defp authorize_selection(%Run{} = run, %Finding{} = finding, _request) do
    kinds = run.policy["allowed_kinds"] || []
    if to_string(finding.kind) not in kinds, do: Repo.rollback(:flywheel_kind_not_authorized)
    findings = Repo.all(Finding.Query.all())

    count =
      Enum.reduce(findings, 0, fn item, count ->
        count + Enum.count(item.history, &(&1["action"] == "select" and &1["run_id"] == run.id))
      end)

    if count >= run.policy["max_tasks"] or not Runs.budget_available?(run),
      do: Repo.rollback(:flywheel_budget_exhausted)
  end

  defp validate_outcome(finding, outcome) when is_map(outcome) do
    valid = outcome_fields?(outcome) and outcome["version"] == finding.deployed_version

    if not valid, do: Repo.rollback(:invalid_flywheel_outcome)

    if outcome["requests"] == 0 and outcome["verdict"] != "insufficient",
      do: Repo.rollback(:flywheel_insufficient_traffic)

    from = Protocol.datetime!(outcome["from"])
    until = Protocol.datetime!(outcome["until"])

    if DateTime.compare(from, finding.shipped_at) == :lt or DateTime.compare(until, from) != :gt or
         DateTime.compare(until, Repo.now!()) == :gt or
         not Enum.all?(outcome["evidence"], &known?(&1, [])),
       do: Repo.rollback(:flywheel_outcome_not_observed)
  end

  defp validate_outcome(_finding, _outcome), do: Repo.rollback(:invalid_flywheel_outcome)

  defp outcome_fields?(outcome) do
    outcome["verdict"] in ~w(improved regressed insufficient) and
      Reference.valid?(outcome["comparison"], 4_000) and
      Reference.valid?(outcome["guardrails"], 2_000) and
      is_integer(outcome["requests"]) and outcome["requests"] >= 0 and
      is_list(outcome["evidence"]) and outcome["evidence"] != [] and
      Enum.all?(outcome["evidence"], &Protocol.identity?/1)
  end

  defp future_time!(value) do
    at = Protocol.datetime!(value)

    if DateTime.compare(at, Repo.now!()) != :gt,
      do: Repo.rollback(:flywheel_followup_must_be_future)

    at
  end

  def report do
    findings = Repo.all(Finding.Query.ordered_by_oldest())
    now = Repo.now!()

    %{
      proposals: Enum.filter(findings, &(&1.status in [:proposed, :regressed])),
      for_you: Enum.filter(findings, &(&1.status == :waiting_user)),
      ready: Enum.filter(findings, &(&1.status == :ready)),
      in_progress: Enum.filter(findings, &(&1.status == :in_progress)),
      pending_outcomes: Enum.filter(findings, &(&1.status == :shipped)),
      followups: Enum.filter(findings, &due?(&1, now)),
      deferred: Enum.filter(findings, &(&1.status == :deferred)),
      dismissed: Enum.filter(findings, &(&1.status == :dismissed)),
      verified: Enum.filter(findings, &(&1.status == :verified))
    }
  end

  defp due?(%Finding{status: status, revisit_at: %DateTime{} = at}, now)
       when status in [:shipped, :verified, :regressed, :deferred],
       do: DateTime.compare(at, now) != :gt

  defp due?(_finding, _now), do: false
end
