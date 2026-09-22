defmodule Ryker.ControlPlane.WorkerEvidenceCard do
  @moduledoc """
  Renders the approved worker-evidence cards for one episode.

  Three cards from one capture: Network access (what the session was admitted
  to reach), Network (what its newest run was observed doing) and the bound Coop
  task. Each renders only what its own section actually said, and each names its
  own absence rather than borrowing a zero from a neighbour.

  They render together under one Worker evidence heading because the Work setup
  and Work activity cards the approved design seats the first two in are not
  built yet. The section reads the episode identity the page snapshot carries,
  so a page whose snapshot lost that identity shows no evidence at all -- which
  is why the page-level render is tested, not only the component.
  """

  use Phoenix.Component

  import Ryker.ControlPlane.Components,
    only: [card_heading: 1, disclosure: 1, fact_list: 1, identifier: 1]

  alias Ryker.ControlPlane.WorkerEvidence

  @doc """
  The cards for one episode; renders nothing when nothing was captured.

  `episode_id` may be nil: a projection that carries only a reference has no
  episode to read evidence for, and a page must not fail to render because of
  a card that had nothing to show anyway.
  """
  attr(:episode_id, :string, default: nil)

  def render(assigns) do
    assigns = assign(assigns, :cards, cards(assigns.episode_id) |> Enum.reject(&empty?/1))

    ~H"""
    <section
      :if={@cards != []}
      class="worker-evidence"
      aria-labelledby="worker-evidence-heading"
    >
      <h2 id="worker-evidence-heading">Worker evidence</h2>
      <article :for={card <- @cards} class="worker-evidence-card" data-state={card.state}>
        <p :if={card.state == :unreadable} class="evidence-unavailable">
          {card.availability.label}: recorded evidence from {card.worker} could not be read.
        </p>
        <.access :if={card.state == :recorded && !quiet?(card)} card={card} />
        <.network :if={card.state == :recorded && !quiet?(card)} card={card} />
        <.coop_task :if={card.state == :recorded && card.task.state != :unbound} card={card} />
      </article>
    </section>
    """
  end

  defp empty?(%{state: :recorded, task: %{state: :unbound}} = card), do: quiet?(card)
  defp empty?(_card), do: false

  defp quiet?(card) do
    card.access.availability.state != :recorded and
      card.network.availability.state != :recorded and
      is_nil(card.access.reason) and is_nil(card.network.reason)
  end

  defp cards(episode_id) when is_binary(episode_id), do: WorkerEvidence.for_episode(episode_id)
  defp cards(_episode_id), do: []

  # Network access: the posture the session was admitted under, before the call
  # that used it. This is Work setup content, wherever it ends up sitting.
  defp access(assigns) do
    ~H"""
    <div class="case-event-content network-access" data-mode={@card.access.mode}>
      <.card_heading title="Network access">
        <:meta><span class="event-state">{@card.access.headline}</span></:meta>
      </.card_heading>
      <p :if={@card.access.reason} class="case-event-summary">{@card.access.reason}</p>
      <p
        :if={!@card.access.reason && @card.access.availability.state == :not_applicable}
        class="case-event-summary"
      >
        {@card.access.availability.detail}
      </p>
      <.fact_list
        :if={@card.access.availability.state == :recorded}
        facts={access_facts(@card.access)}
      />
      <.disclosure
        :if={@card.access.destinations_disclosed? && @card.access.effective != []}
        id={"network-access-#{@card.id}"}
        label="Allowed destinations and rules"
        class="case-event-details"
      >
        <ul>
          <li :for={rule <- @card.access.effective}>
            {rule}<span :if={rule not in @card.access.requested}> · derived grant</span>
          </li>
        </ul>
      </.disclosure>
    </div>
    """
  end

  # A captured policy says what a session MAY reach. Only the enforcer layer's
  # own observation says it was enforced, and an unobserved run has none.
  defp enforcement(%{state: :observed, status: status, reason: nil}),
    do: "Enforcer reported #{status}"

  defp enforcement(%{state: :observed, status: status, reason: reason}),
    do: "Enforcer reported #{status} (#{reason})"

  defp enforcement(_enforcement), do: "Not recorded — configured is not enforced"

  defp access_facts(access) do
    [
      %{label: "Enforcement", value: enforcement(access.enforcement)},
      if(!access.destinations_disclosed?,
        do: %{label: "Allowed destinations", value: "Withheld by this session's policy"}
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp network(assigns) do
    ~H"""
    <div
      class="case-event-content network-summary"
      data-availability={@card.network.availability.state}
    >
      <.card_heading title="Network">
        <:meta :if={@card.network.scope || @card.network.availability.state != :recorded}>
          <span :if={@card.network.scope} class="event-state">{@card.network.scope}</span>
          <span :if={@card.network.availability.state != :recorded} class="event-state">
            {@card.network.availability.label}
          </span>
        </:meta>
      </.card_heading>
      <p :if={@card.network.reason} class="case-event-summary">{@card.network.reason}</p>
      <p
        :if={@card.network.availability.state in [:not_applicable, :not_reached]}
        class="case-event-summary"
      >
        {@card.network.availability.detail}
      </p>
      <.fact_list
        :if={@card.network.availability.state == :recorded}
        facts={network_facts(@card.network)}
      />
      <.disclosure
        :if={disclosable?(@card.network)}
        id={"network-activity-#{@card.id}"}
        label="Connections and activity"
        class="case-event-details"
      >
        <ul class="network-denials">
          <li :for={denial <- @card.network.denials}>
            {denial.at} · Network blocked · {destination(denial.destination)} · {denial.reason}
          </li>
        </ul>
        <ul class="network-connections">
          <li :for={connection <- @card.network.connections}>
            {destination(connection.destination)} · {connection.transport} · {connection.state}
            <span :if={connection.partial?}> · Partial</span>
          </li>
        </ul>
        <p :if={@card.network.omitted_denials.value not in [nil, 0]}>
          {@card.network.omitted_denials.value} more refusals were omitted by the worker's export bound.
        </p>
        <p :if={@card.network.omitted_connections.value not in [nil, 0]}>
          {@card.network.omitted_connections.value} more connections were omitted by the worker's export bound.
        </p>
        <ul :if={@card.network.alerts != []} class="network-alerts">
          <li :for={alert <- @card.network.alerts}>
            {alert.last_seen} · {alert.category} · {alert.severity} · {alert.state}<span :if={
              alert.reason
            }> · {alert.reason}</span>
          </li>
        </ul>
        <p :if={@card.network.omitted_alerts.value not in [nil, 0]}>
          {@card.network.omitted_alerts.value} more alerts were omitted by the worker's export bound.
        </p>
        <.fact_list
          :if={@card.network.availability.state == :recorded}
          facts={network_detail_facts(@card.network)}
        />
        <.receipt receipt={@card.network.receipt} />
      </.disclosure>
    </div>
    """
  end

  # A filtered session that has not run still has a receipt -- provisional, with
  # no runs in it. Hiding the disclosure because the observation is empty would
  # turn "nothing has run yet" back into the silence the export exists to end.
  defp disclosable?(network),
    do:
      network.availability.state == :recorded or
        network.receipt.availability.state == :recorded

  defp network_facts(network) do
    [
      %{label: "Traffic", value: traffic(network.counters)},
      %{label: "Refusals", value: refusals(network)},
      if(network.freshness, do: %{label: "Observation", value: freshness(network)}),
      if(coverage_caveat(network), do: %{label: "Coverage", value: coverage_caveat(network)})
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp network_detail_facts(network) do
    [
      %{label: "Measured", value: network.measured || "Not recorded"},
      if(network.run_id,
        do: %{label: "Run ID", value: network.run_id, identifier: true}
      ),
      if(network.gateway_epoch,
        do: %{label: "Gateway epoch", value: network.gateway_epoch, identifier: true}
      ),
      if(network.as_of, do: %{label: "Observed at", value: network.as_of}),
      %{label: "Layers", value: layers(network.health)},
      %{label: "Coverage", value: coverage_detail(network.coverage)},
      %{label: "Records lost", value: loss_detail(network.loss)}
    ]
    |> Enum.reject(&is_nil/1)
  end

  # The session receipt is the aggregate the runs roll into; the run references
  # are what it aggregated. Final and complete are independent, so both words
  # are shown: a closed session's receipt can be final and honestly partial.
  defp receipt(assigns) do
    ~H"""
    <div class="network-receipt">
      <h4>Session receipt</h4>
      <p :if={@receipt.availability.state != :recorded}>
        {@receipt.availability.label}<span :if={@receipt[:reason]}>: {@receipt.reason}</span>
      </p>
      <.fact_list
        :if={@receipt.availability.state == :recorded}
        facts={receipt_facts(@receipt)}
      />
      <ul :if={@receipt.runs != []} class="network-receipt-runs">
        <li :for={run <- @receipt.runs}>
          <.identifier value={run.run_id} label="Run ID" />
          <span> · {run.gateway_epoch} · {run.finality} · {run.completeness} · {run.as_of}</span>
        </li>
      </ul>
    </div>
    """
  end

  defp receipt_facts(receipt) do
    omitted = receipt.omitted_run_references.value

    runs =
      receipt.run_count.label <>
        if(omitted in [nil, 0], do: "", else: " · #{omitted} references omitted")

    [
      %{
        label: "Standing",
        value:
          "#{String.capitalize(receipt.finality)} · #{receipt.completeness} · #{receipt.scope}"
      },
      %{label: "Window", value: "#{receipt.started_at} → #{receipt.closed_at || "still open"}"},
      %{label: "Runs", value: runs},
      %{label: "Coverage", value: coverage_detail(receipt.coverage)},
      %{label: "Records lost", value: loss_detail(receipt.loss)}
    ]
  end

  defp layers(%{availability: %{state: :recorded}, layers: layers}) do
    Enum.map_join(layers, " · ", fn layer ->
      case layer.reason do
        nil -> "#{layer.layer} #{layer.status}"
        reason -> "#{layer.layer} #{layer.status} (#{reason})"
      end
    end)
  end

  defp layers(_health), do: "Not recorded"

  # Per metric, never one blanket green status: a lower-bound proxy count and an
  # unavailable socket inventory are different problems with the same totals.
  defp coverage_detail(%{availability: %{state: :recorded}, metrics: metrics}) do
    case Enum.reject(metrics, & &1.exact?) do
      [] -> "All #{length(metrics)} measurements exact"
      inexact -> Enum.map_join(inexact, " · ", &"#{&1.metric} #{&1.status}")
    end
  end

  defp coverage_detail(_coverage), do: "Not recorded"

  defp loss_detail(%{availability: %{state: :recorded}} = loss) do
    [
      loss.records.label,
      if(loss.unknown?, do: "unattributed loss — totals are lower bounds"),
      if(loss.detail_truncated?, do: "detail truncated"),
      if(loss.suppressed_alerts.value not in [nil, 0],
        do: "#{loss.suppressed_alerts.value} alerts suppressed"
      )
      | loss.reasons
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp loss_detail(_loss), do: "Not recorded"

  # Unknown is not zero. A counter nobody measured says so; it never renders 0 B.
  defp traffic(%{availability: %{state: :recorded}, values: values}) do
    sent = values["sent_bytes"]
    received = values["received_bytes"]

    cond do
      sent.known? and received.known? -> "↓ #{bytes(received.value)} · ↑ #{bytes(sent.value)}"
      received.known? -> "↓ #{bytes(received.value)} · ↑ not recorded"
      sent.known? -> "↓ not recorded · ↑ #{bytes(sent.value)}"
      true -> "Not recorded"
    end
  end

  defp traffic(_counters), do: "Not recorded"

  defp refusals(%{counters: %{availability: %{state: :recorded}, values: values}} = network) do
    measured =
      [{values["denied_tls_connections"], "TLS"}, {values["denied_dns_queries"], "DNS"}]
      |> Enum.filter(fn {count, _label} -> count.known? end)

    refused = Enum.filter(measured, fn {count, _label} -> count.value > 0 end)

    case {refused, measured, length(network.denials)} do
      # Nobody counted and no refusal was exported either. "None" here would be
      # the same lie as a 0 B traffic reading, on the number an operator uses to
      # decide whether the policy did anything at all.
      {[], [], 0} ->
        "Not recorded"

      {[], _measured, 0} ->
        "None"

      {[], _measured, observed} ->
        "#{observed} recorded"

      {refused, _measured, _observed} ->
        Enum.map_join(refused, " · ", &"#{elem(&1, 0).value} #{elem(&1, 1)}")
    end
  end

  defp refusals(_network), do: "Not recorded"

  defp freshness(%{freshness: freshness, as_of: as_of, sealed?: sealed?}) do
    label =
      case freshness do
        "terminal" -> "Final"
        "fresh" -> "Current"
        "stale" -> "Stale sample"
        "not-observed" -> "Nothing observed"
      end

    sealed = if sealed?, do: " · sealed", else: ""
    "#{label} as of #{as_of}#{sealed}"
  end

  # A lower-bound metric means the totals beside it are floors, which is a
  # different claim from a measured total.
  defp coverage_caveat(
         %{coverage: %{availability: %{state: :recorded}, metrics: metrics}} = network
       ) do
    inexact = Enum.reject(metrics, & &1.exact?)

    cond do
      network.loss[:unknown?] -> "Some records were lost; totals are lower bounds"
      inexact == [] -> nil
      true -> "#{length(inexact)} of #{length(metrics)} measurements are not exact"
    end
  end

  defp coverage_caveat(_network), do: nil

  defp destination(%{state: :disclosed, name: name}), do: name
  defp destination(%{state: :withheld}), do: "Destination withheld"
  defp destination(_destination), do: "Destination not recorded"

  defp coop_task(assigns) do
    ~H"""
    <div class="case-event-content coop-task" data-state={@card.task.state}>
      <.card_heading title="Coop task">
        <:detail :if={@card.task.snapshot}>{@card.task.snapshot.title}</:detail>
        <:meta>
          <span :if={@card.task.snapshot} class="event-state">{@card.task.snapshot.state_label}</span>
          <span :if={!@card.task.snapshot} class="event-state">{@card.task.availability.label}</span>
        </:meta>
      </.card_heading>
      <p :if={@card.task.reason} class="case-event-summary">{@card.task.reason}</p>
      <p :if={@card.task.snapshot} class="case-event-summary">
        Checklist {@card.task.snapshot.checked.value}/{@card.task.snapshot.total.value} recorded ·
        as of {@card.observed_at}
      </p>
      <.disclosure
        :if={@card.task.snapshot}
        id={"coop-task-#{@card.id}"}
        label="Task details"
        class="case-event-details"
      >
        <ul class="task-checklist">
          <li :for={item <- @card.task.snapshot.checklist} data-checked={item.checked?}>
            {if item.checked?, do: "✓", else: "○"} {item.label}
          </li>
        </ul>
        <p :if={@card.task.snapshot.state_note.availability.state == :recorded}>
          {@card.task.snapshot.state_note.text}<span :if={@card.task.snapshot.state_note.truncated?}> …</span>
        </p>
        <p
          :if={@card.task.snapshot.state_note.availability.state == :redacted}
          class="evidence-redacted"
        >
          The task's state note was withheld: {@card.task.snapshot.state_note.reason}
        </p>
        <.fact_list facts={task_facts(@card)} />
      </.disclosure>
    </div>
    """
  end

  defp task_facts(card) do
    [
      %{label: "Task", value: card.task.id, identifier: true},
      %{label: "Offer", value: card.task.offer_ref, identifier: true},
      %{label: "Worker", value: card.worker, identifier: true}
    ]
  end

  defp bytes(nil), do: "Not recorded"
  defp bytes(count) when count < 1_024, do: "#{count} B"
  defp bytes(count) when count < 1_024 * 1_024, do: "#{div(count, 1_024)} KB"

  defp bytes(count) when count < 1_024 * 1_024 * 1_024,
    do: "#{Float.round(count / 1_048_576, 1)} MB"

  defp bytes(count), do: "#{Float.round(count / 1_073_741_824, 1)} GB"
end
