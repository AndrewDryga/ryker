defmodule Responder.ControlPlane.WorkerEvidence do
  @moduledoc """
  Projects one worker-exported session capture into the approved cards.

  Three cards come out of one capture: Network access, a compact Network summary
  and a conditional Coop task card. Each one renders only what the export
  actually said.

  The approved design seats Network access inside Work setup and the Network
  summary inside Work activity. Those two cards do not exist yet, so all three
  render together in one Worker evidence section; moving them is a placement
  change, and nothing here depends on where they sit.

  The distinctions the page must never lose:

    * configured is not enforced -- a captured policy says what the session may
      reach, and only the enforcer layer's own health says it was enforced
    * unknown is not zero -- an unmeasured counter renders as Not recorded, and
      an unreadable registry renders as its reason, never as no traffic
    * withheld is not absent -- a refusal whose destination the policy did not
      export says "Destination withheld", not that it saw no destination
    * a snapshot is not a history -- the task card is as of its capture, and a
      later capture never rewrites an earlier one
  """

  alias Responder.ControlPlane.Evidence
  alias Responder.CoopFleet.SessionEvidence

  @doc """
  Builds the cards for one episode, newest capture per session.

  An episode with no capture returns `[]`: the caller shows no card at all
  rather than an empty network, because nothing was ever asked or answered.
  """
  @spec for_episode(Ecto.UUID.t()) :: [map()]
  def for_episode(episode_id) when is_binary(episode_id) do
    episode_id
    |> SessionEvidence.latest_for_episode()
    |> Enum.flat_map(fn row ->
      case SessionEvidence.document(row) do
        {:ok, document} -> [project(row, document)]
        # A stored row that no longer decodes is a real absence with a cause,
        # not a session without evidence.
        {:error, reason} -> [unreadable(row, reason)]
      end
    end)
  end

  def for_episode(_episode_id), do: []

  @doc "Projects one already-decoded capture."
  @spec project(SessionEvidence.t(), map()) :: map()
  def project(row, %{} = document) do
    %{
      id: row.id,
      session_id: row.session_id,
      coop_session_id: row.coop_session_id,
      worker: row.worker_id,
      placement_generation: row.placement_generation,
      state: :recorded,
      captured_at: row.first_captured_at,
      observed_at: row.last_captured_at,
      capture_count: row.capture_count,
      session_revision: document["revision"],
      session_state: document["state"],
      snapshot: Evidence.snapshot(:current, observed_at: row.last_captured_at),
      access: access(document["network"]),
      network: network(document["network"]),
      task: task(document["task"])
    }
  end

  defp unreadable(row, reason) do
    %{
      id: row.id,
      session_id: row.session_id,
      coop_session_id: row.coop_session_id,
      worker: row.worker_id,
      placement_generation: row.placement_generation,
      state: :unreadable,
      captured_at: row.first_captured_at,
      observed_at: row.last_captured_at,
      capture_count: row.capture_count,
      reason: reason,
      availability:
        Evidence.availability(:unavailable, detail: "Recorded evidence is unreadable.")
    }
  end

  # Network access: the frozen posture and what it admitted. This is the Work
  # setup content -- what the session may reach, before the call that used it.
  defp access(%{"mode" => mode, "access" => access} = network) do
    %{
      mode: mode,
      headline: posture_headline(mode),
      fingerprint: network["fingerprint"],
      qualification: access["qualification"],
      availability: access_availability(access["status"]),
      reason: access["reason"],
      projection: access["projection"],
      destinations_disclosed?: access["projection"] == "destinations-included",
      requested: access["requested"],
      effective: access["effective"],
      # A captured policy is what the session was admitted under. Whether it was
      # enforced is the enforcer layer's own observation, and an unobserved run
      # can never supply it.
      enforcement: enforcement(network["observation"])
    }
  end

  defp posture_headline("filtered"), do: "Filtered"
  defp posture_headline("none"), do: "No network"
  defp posture_headline("open"), do: "Open"

  defp access_availability("captured"), do: Evidence.availability(:recorded)

  defp access_availability("not_filtered"),
    do:
      Evidence.applicability(:not_applicable,
        detail: "This session did not run under restricted networking, so no policy was captured."
      )

  defp access_availability("unavailable"), do: Evidence.availability(:unavailable)

  defp enforcement(%{"status" => "observed", "health" => %{"enforcer" => enforcer}})
       when is_map(enforcer),
       do: %{state: :observed, status: enforcer["status"], reason: enforcer["reason"]}

  defp enforcement(%{"status" => "observed"}),
    do: %{state: :not_recorded, status: nil, reason: nil}

  defp enforcement(_observation), do: %{state: :not_recorded, status: nil, reason: nil}

  # Network summary: the newest run's observation. This is the Work activity
  # content -- what that run was seen doing, not what it was allowed to do.
  defp network(%{"observation" => observation, "receipt" => receipt}) do
    %{
      availability: observation_availability(observation["status"]),
      reason: observation["reason"],
      freshness: observation["freshness"],
      run_id: observation["run_id"],
      attempt_id: observation["attempt_id"],
      gateway_epoch: observation["gateway_epoch"],
      scope: run_scope(observation),
      measured: observation["scope"],
      as_of: observation["as_of"],
      sealed?: observation["sealed"] == true,
      cleanup: observation["cleanup_outcome"],
      destinations_disclosed?: observation["projection"] == "destinations-included",
      counters: counters(observation["counters"]),
      health: health(observation["health"]),
      coverage: coverage(observation["coverage"]),
      loss: loss(observation["loss"]),
      denials: denials(observation["denials"]),
      omitted_denials: Evidence.count(observation["omitted_denials"], scope: :export_bound),
      connections: connections(observation["connections"]),
      omitted_connections:
        Evidence.count(observation["omitted_connections"], scope: :export_bound),
      alerts: alerts(observation["alerts"]),
      omitted_alerts: Evidence.count(observation["omitted_alerts"], scope: :export_bound),
      receipt: receipt(receipt)
    }
  end

  defp observation_availability("observed"), do: Evidence.availability(:recorded)

  defp observation_availability("no_run"),
    do:
      Evidence.applicability(:not_reached,
        detail: "This session has not run under its captured policy yet."
      )

  defp observation_availability("not_filtered"),
    do: Evidence.applicability(:not_applicable, detail: "This session did not run filtered.")

  defp observation_availability("unavailable"), do: Evidence.availability(:unavailable)

  # Attribution belongs to the run the collector recorded, never to a Work turn
  # the page happens to be rendering: one session can own several runs.
  defp run_scope(%{"run_id" => run, "attempt_id" => attempt})
       when is_binary(run) and is_binary(attempt),
       do: "Run #{short(run)} · attempt #{short(attempt)}"

  defp run_scope(%{"run_id" => run}) when is_binary(run), do: "Run #{short(run)}"
  defp run_scope(_observation), do: nil

  defp short(value) when byte_size(value) <= 12, do: value
  defp short(value), do: binary_part(value, 0, 12) <> "…"

  # Counters are unsigned decimal strings on the wire so a value above 2^53
  # survives a browser. They become integers here and only here; a null stays
  # unknown, which renders as Not recorded rather than 0.
  defp counters(nil), do: %{availability: Evidence.availability(:not_recorded), values: %{}}

  defp counters(%{} = counters) do
    values =
      Map.new(counters, fn {name, value} ->
        {name, Evidence.count(counter(value), scope: :run)}
      end)

    %{availability: Evidence.availability(:recorded), values: values}
  end

  defp counter(nil), do: nil
  defp counter(value) when is_binary(value), do: String.to_integer(value)

  defp health(nil), do: %{availability: Evidence.availability(:not_recorded), layers: []}

  defp health(%{} = health) do
    layers =
      Enum.map(~w(enforcer gateway resolver collector), fn layer ->
        %{layer: layer, status: health[layer]["status"], reason: health[layer]["reason"]}
      end)

    %{availability: Evidence.availability(:recorded), layers: layers}
  end

  defp coverage(nil), do: %{availability: Evidence.availability(:not_recorded), metrics: []}

  defp coverage(%{} = coverage) do
    metrics =
      Enum.map(coverage, fn {metric, value} ->
        %{
          metric: metric,
          status: value["status"],
          reason: value["reason"],
          exact?: value["status"] == "exact"
        }
      end)

    %{availability: Evidence.availability(:recorded), metrics: Enum.sort_by(metrics, & &1.metric)}
  end

  defp loss(nil), do: %{availability: Evidence.availability(:not_recorded)}

  defp loss(%{} = loss) do
    %{
      availability: Evidence.availability(:recorded),
      records: Evidence.count(counter(loss["records"]), scope: :run),
      # An unknown loss means the totals beside it are lower bounds, which is a
      # different claim from a measured zero.
      unknown?: loss["unknown"] == true,
      reasons: loss["reasons"],
      detail_truncated?: loss["detail_truncated"] == true,
      omitted_details: Evidence.count(counter(loss["omitted_details"]), scope: :run),
      suppressed_alerts: Evidence.count(counter(loss["suppressed_alerts"]), scope: :run)
    }
  end

  # A raised alert is the collector's own account of why a number may be wrong.
  # It is kept as a row rather than folded into a status word, because
  # "degraded" and the reason it degraded lead to different actions.
  defp alerts(alerts) do
    Enum.map(alerts, fn alert ->
      %{
        id: alert["id"],
        category: alert["category"],
        severity: alert["severity"],
        state: alert["state"],
        terminal?: alert["terminal"] == true,
        first_seen: alert["first_seen"],
        last_seen: alert["last_seen"],
        reason: alert["reason"],
        health_status: alert["health_status"]
      }
    end)
  end

  defp denials(denials) do
    Enum.map(denials, fn denial ->
      %{
        id: denial["id"],
        at: denial["at"],
        basis: denial["basis"],
        reason: denial["reason"],
        destination: destination(denial),
        port: denial["port"]
      }
    end)
  end

  defp connections(connections) do
    Enum.map(connections, fn connection ->
      %{
        id: connection["id"],
        state: connection["state"],
        transport: connection["transport"],
        destination: destination(connection),
        started_at: connection["started_at"],
        observed_at: connection["observed_at"],
        sent_bytes: Evidence.count(counter(connection["sent_bytes"]), scope: :connection),
        received_bytes: Evidence.count(counter(connection["received_bytes"]), scope: :connection),
        partial?: connection["partial"] == true
      }
    end)
  end

  # Withheld is a disclosure decision the session policy made, and it is not the
  # same fact as a refusal that observed no name at all.
  defp destination(%{"destination" => name}) when is_binary(name),
    do: %{state: :disclosed, name: name}

  defp destination(%{"destination_withheld" => true}), do: %{state: :withheld, name: nil}
  defp destination(_row), do: %{state: :not_recorded, name: nil}

  defp receipt(%{"status" => "available"} = receipt) do
    %{
      availability: Evidence.availability(:recorded),
      finality: receipt["finality"],
      # Final and complete are independent: a closed session's receipt can be
      # final and still honestly partial.
      final?: receipt["finality"] == "final",
      completeness: receipt["completeness"],
      complete?: receipt["completeness"] == "complete",
      scope: receipt["scope"],
      started_at: receipt["started_at"],
      closed_at: receipt["closed_at"],
      run_count: Evidence.count(counter(receipt["run_count"]), scope: :session),
      omitted_run_references:
        Evidence.count(counter(receipt["omitted_run_references"]), scope: :export_bound),
      runs: run_references(receipt["runs"]),
      counters: counters(receipt["counters"]),
      coverage: coverage(receipt["coverage"]),
      loss: loss(receipt["loss"]),
      digest: receipt["receipt_digest"]
    }
  end

  defp receipt(%{"status" => status} = receipt) do
    %{availability: observation_availability(status), reason: receipt["reason"], runs: []}
  end

  # The runs the session receipt aggregated. A worker keeps no transition
  # ledger, so this is the session's own list of run receipts, not a history
  # the controller can ask for.
  defp run_references(runs) do
    Enum.map(runs, fn run ->
      %{
        run_id: run["run_id"],
        gateway_epoch: run["gateway_epoch"],
        as_of: run["as_of"],
        finality: run["finality"],
        completeness: run["completeness"],
        digest: run["receipt_digest"]
      }
    end)
  end

  # The Coop task card: conditional, and only for a task actually bound to this
  # session. Checklist state is what the folder recorded, never a gate result.
  defp task(%{"status" => "unbound"}), do: %{state: :unbound}

  defp task(%{"status" => status} = task) do
    %{
      state: if(status == "bound", do: :bound, else: :unavailable),
      availability:
        if(status == "bound",
          do: Evidence.availability(:recorded),
          else: Evidence.availability(:unavailable)
        ),
      reason: task["reason"],
      queue_id: task["queue_id"],
      task_id: task["task_id"],
      id: task["id"],
      offer_ref: task["offer_ref"],
      draft_sha256: task["draft_sha256"],
      snapshot: task_snapshot(task["snapshot"])
    }
  end

  defp task_snapshot(nil), do: nil

  defp task_snapshot(%{} = snapshot) do
    checklist = snapshot["checklist"]
    checked = Enum.count(checklist, & &1["checked"])

    %{
      state: snapshot["state"],
      state_label: task_state_label(snapshot["state"]),
      state_sha256: snapshot["state_sha256"],
      title: snapshot["title"],
      checklist: Enum.map(checklist, &%{label: &1["label"], checked?: &1["checked"]}),
      # Three of four recorded checkboxes, not three independently verified
      # tests: the folder's own state, and nothing about a gate.
      checked: Evidence.count(checked, scope: :checklist),
      total: Evidence.count(length(checklist), scope: :checklist),
      has_decision?: snapshot["has_decision"] == true,
      files:
        Enum.map(
          snapshot["files"],
          &%{path: &1["path"], byte_size: &1["byte_size"], sha256: &1["sha256"]}
        ),
      state_note: state_note(snapshot["state_note"])
    }
  end

  defp task_state_label("todo"), do: "To do"
  defp task_state_label("in_progress"), do: "In progress"
  defp task_state_label("blocked"), do: "Blocked"
  defp task_state_label("done"), do: "Done"

  defp state_note(%{"status" => "captured"} = note),
    do: %{
      availability: Evidence.availability(:recorded),
      text: note["text"],
      truncated?: note["truncated"] == true
    }

  defp state_note(%{"status" => "withheld"} = note),
    do: %{availability: Evidence.availability(:redacted), text: nil, reason: note["reason"]}

  defp state_note(_note),
    do: %{availability: Evidence.availability(:not_recorded), text: nil}
end
