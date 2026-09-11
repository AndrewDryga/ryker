defmodule Responder.ControlPlane.ConfigurationHelp do
  @moduledoc "Operator explanations for the explicitly exposed runtime settings, not a config parser."

  # Defaults describe the shipped operational defaults, not a configuration file.
  # Retention horizons are required inputs and deliberately have no default.
  @required_retention "Required when retention is configured; there is no implicit default."
  @settings %{
    "admission" => {
      "Admission",
      "Decides whether an incoming message needs a reply, a reaction, more work, or no response.",
      "Runs before Work. It uses a pinned classifier policy and durable queue; enabling it does not mean a classifier worker is currently available.",
      "Required by the v1 configuration."
    },
    "work" => {
      "Work execution",
      "Runs admitted conversations and tasks with their configured models, repositories and tools.",
      "Product mode assigns work to enrolled Coop workers. Each request keeps its host-selected policy and authority; an input cannot choose broader access.",
      "Required by the v1 configuration; product mode uses fleet execution."
    },
    "control_plane" => {
      "Control plane and Conversation Lab",
      "Serves this local inspection UI, the Conversation Lab and operator actions.",
      "The listener accepts loopback connections only. Lab messages use the configured Work profile; repository and Emisar tools retain their real authority.",
      "Not configured unless the control_plane section is present."
    },
    "coop_worker_gateway" => {
      "Coop worker gateway",
      "Accepts outbound connections from execution workers.",
      "Workers authenticate with mutual TLS to receive work and report progress. A configured gateway is not proof that any worker is connected or eligible for a policy.",
      "Required in product mode; not configured when omitted in component mode."
    },
    "delivery" => {
      "Reply and action delivery",
      "Delivers accepted replies, reactions and platform actions to their destinations.",
      "Separate queues retry delivery and reconcile uncertain outcomes. This is distinct from generating a model answer; a finished model run may still be waiting for delivery.",
      "Required whenever a local, Slack or GitHub delivery adapter is enabled."
    },
    "publication" => {
      "Readiness and repository publication",
      "Reviews repository candidates, publishes approved drafts and follows their GitHub lifecycle.",
      "Uses configured repository bindings and the recorded candidate. Enabling the worker does not authorize arbitrary pushes or merges; the publication checks and operator action boundaries still apply.",
      "Readiness reviews run whenever a delivery adapter is configured. Publishing requires GitHub and an explicitly configured repository binding."
    },
    "retention" => {
      "Cleanup and retention",
      "Cleans up owned execution sessions and ages out eligible historical data.",
      "Dirty or unpublished work and unresolved custody can prevent cleanup. Data is pruned in ordered stages, not just because it is old. Shorter horizons reduce the evidence available for later inspection.",
      "Required in product mode; all retention durations must be specified."
    },
    "state_tools" => {
      "Responder state tools",
      "Exposes Responder's durable workflow tools to authorized model sessions.",
      "Tools can record progress, request input and use enabled workflow capabilities. Calls still require the session's authority; this is not unrestricted access to the database or every external MCP tool.",
      "Required in product mode and for the Emisar approval handoff."
    },
    "event_waits" => {
      "External-event waits",
      "Resumes work that is waiting for an external event or a recorded deadline.",
      "Processes durable subscriptions instead of keeping a model turn running while it waits. Only matching events or the wait's own timeout may resolve that wait.",
      "Not configured unless the event_waits section is present."
    },
    "schedules" => {
      "Scheduled work",
      "Creates work for due reminders and recurring schedules.",
      "Each occurrence uses its configured destination and policy. Read-only, governed-operation and repository-write policies remain separate; enabling schedules does not widen their authority.",
      "Not configured unless schedules and its required policy bindings are present."
    },
    "emisar" => {
      "Emisar approval monitoring",
      "Tracks governed actions awaiting approval in Emisar and resumes their waiting episodes.",
      "Responder monitors the exact recorded action; it does not approve or repeat it. This setting is not the catalog of Emisar tools available to a Work policy.",
      "Not configured unless the emisar section is present; requires state_tools."
    },
    "slack" => {
      "Slack integration",
      "Receives Slack messages and interactions and maintains Slack replies and cards.",
      "Workspace identity, channel participation, repository bindings and operator rules restrict what it processes. Configured does not prove the Slack connection or token is healthy.",
      "Not configured unless the slack section is present."
    },
    "github" => {
      "GitHub integration",
      "Processes supported GitHub comments, reviews and repository events.",
      "Signed webhook events are matched to configured app-installation and repository bindings. App permissions and those bindings continue to limit reads, replies and publication.",
      "Not configured unless the github section is present."
    },
    "webhooks" => {
      "External webhook inputs",
      "Accepts configured event sources such as alerting and deployment systems.",
      "Each source has its own verification, mapping and destination scope. This is separate from GitHub's native webhook listener; it is not an unauthenticated generic command endpoint.",
      "Not configured unless the webhooks section is present."
    },
    "runtime.mode" => {
      "Runtime mode",
      "Selects a complete product deployment or a component/test topology.",
      "Product mode requires fleet execution, the worker gateway, state tools and retention. Component mode relaxes those assembly requirements for development; it is not the production topology.",
      "Required YAML field mode: product or component."
    },
    "admission.policy" => {
      "Admission execution policy",
      "Names the trusted Coop execution policy used for classification; it is not a model name.",
      "The policy selects execution settings and permitted capabilities. Its policy digest pins the exact reviewed content. Configure admission.policy.name and admission.policy.digest together; changing a name alone does not safely change the model.",
      "Required; choose an existing reviewed Coop policy and its exact digest."
    },
    "admission.decision_timeout_ms" => {
      "Admission decision timeout",
      "Limits how long one admission attempt waits for its classification result.",
      "A longer timeout can avoid premature admission failures, but does not make the model think faster. This is not the Work execution timeout or the end-to-end reply deadline.",
      "30 seconds (30000 ms). The v1 loader accepts 1000–300000 ms."
    },
    "work.concurrency" => {
      "Work concurrency",
      "Sets the number of local Work executor slots that can advance requests concurrently.",
      "More slots can reduce queueing when independent work and eligible workers are available. They do not create worker capacity or speed up a single model call, and may increase simultaneous provider usage.",
      "4 slots. The v1 loader accepts 1–32."
    },
    "work.poll_interval_ms" => {
      "Work polling interval",
      "Sets how often Work workers check for eligible work and updated execution state.",
      "A shorter interval reduces polling delay but increases database and worker traffic. It does not make the model think faster and is not the browser's live-update interval.",
      "250 milliseconds. The v1 loader accepts 1–60000 ms."
    },
    "retention.operational_data_seconds" => {
      "Operational payload retention",
      "Sets the age threshold for pruning eligible input, output and execution payloads.",
      "Episode payload cleanup waits for terminal work and proof that its owned sessions are discarded. It may remove model-request evidence before compact history expires. Must not exceed closed-work or conversation-memory retention.",
      @required_retention
    },
    "retention.closed_work_seconds" => {
      "Closed-work retention",
      "Sets the age threshold for removing eligible closed incident rooms, task cards and their lifecycle records.",
      "This is not the grace period for closing a Coop session. Cleanup still checks ownership and terminal state. Must be at least operational retention and no longer than episode-history retention.",
      @required_retention
    },
    "retention.episode_history_seconds" => {
      "Episode-history retention",
      "Sets the age threshold for pruning an eligible episode's detailed execution history.",
      "History is removed as a coherent unit, not as isolated events. Compact custody receipts survive until the audit horizon. Must be at least closed-work retention and no longer than audit retention.",
      @required_retention
    },
    "retention.audit_data_seconds" => {
      "Audit retention",
      "Sets the age threshold for removing eligible compact audit records and custody receipts.",
      "This is the final history horizon and must be at least episode-history retention. Increasing it retains more evidence; it cannot recover records already pruned. Backups have a separate lifecycle.",
      @required_retention
    },
    "retention.disposable_bytes_limit" => {
      "Disposable workspace budget",
      "Documents how many bytes of inactive disposable forks one worker may hold: eligible or in grace, never dirty, unpublished or running work.",
      "Workers measure their own filesystem and report it; Responder never estimates bytes it did not receive, and a missing report is unknown rather than zero. Age or pressure never authorises discarding protected work. This bounds workspace allocation, not writes a running task makes inside its own fork.",
      @required_retention
    },
    "retention.reclaim_target_seconds" => {
      "Reclamation target",
      "Documents how quickly an eligible disposable fork should disappear from a healthy worker after its grace period ends.",
      "Cleanup ages work from eligibility, not from session creation, and drains it in bounded fair passes. A worker that is offline retries with bounded backoff and is not counted against this target.",
      @required_retention
    },
    "retention.storage_high_watermark_bytes" => {
      "Storage high watermark",
      "Documents the worker storage level above which new fork allocation is refused.",
      "The worker enforces refusal and reports it; Responder then stops placing new fork-requiring sessions there and names the worker's own reason, while cleanup, control and recovery of existing work continue. Must be above the low watermark and the reserve.",
      @required_retention
    },
    "retention.storage_low_watermark_bytes" => {
      "Storage low watermark",
      "Documents the worker storage level below which refused allocation reopens.",
      "Recovery follows the worker's own report, so there is no second threshold in Responder to oscillate against. Must be below the high watermark.",
      @required_retention
    },
    "retention.storage_reserve_bytes" => {
      "Cleanup storage reserve",
      "Documents the free space a worker keeps so that cleanup itself can always finish.",
      "Allocation that would spend the reserve is refused before any fork is created. Must be below the high watermark.",
      @required_retention
    }
  }

  @bytes ~w(retention.disposable_bytes_limit retention.storage_high_watermark_bytes retention.storage_low_watermark_bytes retention.storage_reserve_bytes)

  @durations %{
    "admission.decision_timeout_ms" => 1,
    "work.poll_interval_ms" => 1,
    "retention.operational_data_seconds" => 1_000,
    "retention.closed_work_seconds" => 1_000,
    "retention.episode_history_seconds" => 1_000,
    "retention.audit_data_seconds" => 1_000,
    "retention.reclaim_target_seconds" => 1_000
  }

  def setting(key) do
    case Map.fetch(@settings, key) do
      {:ok, {title, purpose, behavior, default}} ->
        %{title: title, purpose: purpose, behavior: behavior, default: default, documented: true}

      :error ->
        %{
          title: key,
          purpose: "Explanation unavailable for this setting in this release.",
          behavior:
            "Inspect the owning configuration loader before changing it; its behavior is not inferred from its name.",
          default: "Not documented; do not assume the current value is a default.",
          documented: false
        }
    end
  end

  @components ~w(admission work control_plane coop_worker_gateway delivery publication retention state_tools event_waits schedules emisar slack github webhooks)

  def value(key, "enabled") when key in @components, do: "Configured"
  def value(key, "disabled") when key in @components, do: "Not configured"

  def value(key, value) when key in @bytes do
    case Integer.parse(value) do
      {bytes, ""} when bytes > 0 ->
        :erlang.float_to_binary(bytes / 1_073_741_824, decimals: 2) <> " GiB"

      _other ->
        value
    end
  end

  def value(key, value) do
    with multiplier when is_integer(multiplier) <- @durations[key],
         {number, ""} when number > 0 <- Integer.parse(value) do
      milliseconds = number * multiplier

      {unit, divisor} =
        Enum.find(
          [
            {"day", 86_400_000},
            {"hour", 3_600_000},
            {"minute", 60_000},
            {"second", 1_000},
            {"millisecond", 1}
          ],
          fn {_unit, divisor} -> rem(milliseconds, divisor) == 0 end
        )

      count = div(milliseconds, divisor)
      "#{count} #{unit}#{if count == 1, do: "", else: "s"}"
    else
      _ -> value
    end
  end

  def grant("host capability"),
    do:
      "A durable workflow feature exposed by Responder, such as event waits or schedules. Each operation still checks the request's authority."

  def grant("MCP tool"),
    do:
      "A named tool in the configured local MCP catalog. Its server and the session policy enforce access; appearing here does not grant permission."

  def grant("source/action tool"),
    do:
      "A tool name advertised in Work context. This is descriptive context, not an access grant; the pinned Coop policy remains the authority."

  def grant(_kind),
    do: "Explanation unavailable for this grant type; the name alone does not grant permission."
end
