defmodule Ryker.ControlPlane.ConfigurationHelp do
  @moduledoc """
  Operator explanations for the explicitly exposed runtime settings, not a
  config parser.

  Each setting has a title and a line under it in plain words, which is all a
  reader sees until they open its Details; the behaviour and the default
  there keep the precise terms support needs. A retention limit carries the
  name the Data retention page gives it.
  """

  # Defaults describe the shipped operational defaults, not a configuration file.
  # Retention horizons are required inputs and deliberately have no default.
  @required_retention "Required when retention is configured; there is no implicit default."
  @settings %{
    "admission" => {
      "Routing",
      "Decides whether an incoming message needs a reply, a reaction, more work or nothing.",
      "Runs before Work. It uses a pinned classifier policy and durable queue; enabling it does not mean a classifier worker is currently available.",
      "Required by the v1 configuration."
    },
    "work" => {
      "Running work",
      "Runs the conversations and tasks routing accepted, with their models, repositories and tools.",
      "Product mode assigns work to enrolled Coop workers. Each request keeps its host-selected policy and authority; an input cannot choose broader access.",
      "Required by the v1 configuration; product mode uses fleet execution."
    },
    "control_plane" => {
      "This console and Chat",
      "Serves this console, Chat and the actions you take here.",
      "The listener accepts loopback connections only. Conversation messages use the configured Work profile; repository and Emisar tools retain their real authority.",
      "Not configured unless the control_plane section is present."
    },
    "coop_worker_gateway" => {
      "Worker connections",
      "Lets workers connect to Ryker to receive work and report progress.",
      "Workers authenticate with mutual TLS to receive work and report progress. A configured gateway is not proof that any worker is connected or eligible for a policy.",
      "Required in product mode; not configured when omitted in component mode."
    },
    "delivery" => {
      "Replies and actions",
      "Delivers accepted replies, reactions and actions to where they belong.",
      "Separate queues retry delivery and reconcile uncertain outcomes. This is distinct from generating a model answer; a finished model run may still be waiting for delivery.",
      "Required whenever a local, Slack or GitHub delivery adapter is enabled."
    },
    "publication" => {
      "Pull requests",
      "Checks code changes, opens pull requests for approved ones and follows them on GitHub.",
      "Uses configured repository bindings and the recorded candidate. Enabling the worker does not authorize arbitrary pushes or merges; the publication checks and operator action boundaries still apply.",
      "Readiness reviews run whenever a delivery adapter is configured. Publishing requires GitHub and an explicitly configured repository binding."
    },
    "retention" => {
      "Cleanup and retention",
      "Cleans up finished work and deletes old data once it is past its limit.",
      "Dirty or unpublished work and unresolved custody can prevent cleanup. Data is pruned in ordered stages, not just because it is old. Shorter horizons reduce the evidence available for later inspection.",
      "Required in product mode; all retention durations must be specified."
    },
    "state_tools" => {
      "Ryker's tools",
      "Gives the model Ryker's own tools, such as waiting for an event or offering a task.",
      "Tools can record progress, request input and use enabled workflow capabilities. Calls still require the session's authority; this is not unrestricted access to the database or every external MCP tool.",
      "Required in product mode and for the Emisar approval handoff."
    },
    "event_waits" => {
      "Waiting for events",
      "Resumes work that is waiting for an outside event or a deadline.",
      "Processes durable subscriptions instead of keeping a model turn running while it waits. Only matching events or the wait's own timeout may resolve that wait.",
      "Not configured unless the event_waits section is present."
    },
    "schedules" => {
      "Scheduled work",
      "Starts the work for reminders and schedules when they are due.",
      "Each occurrence uses its configured destination and policy. Read-only, governed-operation and repository-write policies remain separate; enabling schedules does not widen their authority.",
      "Not configured unless schedules and its required policy bindings are present."
    },
    "emisar" => {
      "Emisar approvals",
      "Watches Emisar for approval decisions and resumes the work waiting on them.",
      "Ryker monitors the exact recorded action; it does not approve or repeat it. This setting is not the catalog of Emisar tools available to a Work policy.",
      "Not configured unless the emisar section is present; requires state_tools."
    },
    "slack" => {
      "Slack",
      "Receives Slack messages and clicks, and keeps Ryker's replies and cards up to date.",
      "Workspace identity, channel participation, repository bindings and operator rules restrict what it processes.",
      "Not configured unless the slack section is present."
    },
    "github" => {
      "GitHub",
      "Handles GitHub comments, reviews and repository events.",
      "Signed webhook events are matched to configured app-installation and repository bindings. App permissions and those bindings continue to limit reads, replies and publication.",
      "Not configured unless the github section is present."
    },
    "webhooks" => {
      "Webhooks",
      "Accepts events from the senders you set up, such as alerting and deployment tools.",
      "Each source has its own verification, mapping and destination scope. This is separate from GitHub's native webhook listener; it is not an unauthenticated generic command endpoint.",
      "Not configured unless the webhooks section is present."
    },
    "runtime.mode" => {
      "Installation mode",
      "Whether this is a full installation or a partial one for development and tests.",
      "Product mode requires fleet execution, the worker gateway, state tools and retention. Component mode relaxes those assembly requirements for development; it is not the production topology.",
      "Required YAML field mode: product or component."
    },
    "admission.policy" => {
      "Routing policy",
      "The worker policy routing runs under. It is a policy name, not a model name.",
      "The policy selects execution settings and permitted capabilities. Its policy digest pins the exact reviewed content. Configure admission.policy.name and admission.policy.digest together; changing a name alone does not safely change the model.",
      "Required; choose an existing reviewed Coop policy and its exact digest."
    },
    "admission.decision_timeout_ms" => {
      "Routing time limit",
      "How long routing waits for one decision.",
      "A longer timeout can avoid premature admission failures, but does not make the model think faster. This is not the Work execution timeout or the end-to-end reply deadline.",
      "30 seconds (30000 ms). The v1 loader accepts 1000–300000 ms."
    },
    "work.concurrency" => {
      "Work at the same time",
      "How many pieces of work Ryker moves forward at the same time.",
      "More slots can reduce queueing when independent work and eligible workers are available. They do not create worker capacity or speed up a single model call, and may increase simultaneous provider usage.",
      "4 slots. The v1 loader accepts 1–32."
    },
    "work.poll_interval_ms" => {
      "Work check interval",
      "How often Ryker looks for work that is ready and for progress on running work.",
      "A shorter interval reduces polling delay but increases database and worker traffic. It does not make the model think faster and is not the browser's live-update interval.",
      "250 milliseconds. The v1 loader accepts 1–60000 ms."
    },
    "retention.operational_data_seconds" => {
      "Prompts, replies and tool activity",
      "How long the full text of messages, model calls and tool calls is kept.",
      "Episode payload cleanup waits for terminal work and proof that its owned sessions are discarded. It may remove model-request evidence before compact history expires. Must not exceed closed-work or conversation-memory retention.",
      @required_retention
    },
    "retention.closed_work_seconds" => {
      "Finished work",
      "How long closed incident rooms, task cards and their history are kept.",
      "This is not the grace period for closing a Coop session. Cleanup still checks ownership and terminal state. Must be at least operational retention and no longer than episode-history retention.",
      @required_retention
    },
    "retention.episode_history_seconds" => {
      "Request history",
      "How long the step-by-step record of each finished request is kept.",
      "History is removed as a coherent unit, not as isolated events. Compact custody receipts survive until the audit horizon. Must be at least closed-work retention and no longer than audit retention.",
      @required_retention
    },
    "retention.audit_data_seconds" => {
      "Audit trail",
      "How long the short records of what happened are kept, after the rest of a request's history is gone.",
      "This is the final history horizon and must be at least episode-history retention. Increasing it retains more evidence; it cannot recover records already pruned. Backups have a separate lifecycle.",
      @required_retention
    },
    "retention.disposable_bytes_limit" => {
      "Space for unused working copies",
      "How much space one worker may keep for working copies no task is using any more.",
      "Workers measure their own filesystem and report it; Ryker never estimates bytes it did not receive, and a missing report is unknown rather than zero. Age or pressure never authorises discarding protected work. This bounds workspace allocation, not writes a running task makes inside its own fork.",
      @required_retention
    },
    "retention.reclaim_target_seconds" => {
      "Cleanup target",
      "How soon a working copy no task needs any more should be deleted from a worker.",
      "Cleanup ages work from eligibility, not from session creation, and drains it in bounded fair passes. A worker that is offline retries with bounded backoff and is not counted against this target.",
      @required_retention
    },
    "retention.storage_high_watermark_bytes" => {
      "Storage limit for new work",
      "Above this much used space, a worker starts no new work that needs a working copy.",
      "The worker enforces refusal and reports it; Ryker then stops placing new fork-requiring sessions there and names the worker's own reason, while cleanup, control and recovery of existing work continue. Must be above the low watermark and the reserve.",
      @required_retention
    },
    "retention.storage_low_watermark_bytes" => {
      "Storage level to start again",
      "Below this much used space, a worker takes that kind of work again.",
      "Recovery follows the worker's own report, so there is no second threshold in Ryker to oscillate against. Must be below the high watermark.",
      @required_retention
    },
    "retention.storage_reserve_bytes" => {
      "Space kept for cleanup",
      "The free space a worker keeps so that cleanup can always finish.",
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
      "A feature Ryker itself provides, such as waiting for an event or scheduling work. Each use still checks what the request may do."

  def grant("MCP tool"),
    do:
      "A tool from a connected tool server. That server and the worker's policy decide who may use it; being listed here does not grant permission."

  def grant("source/action tool"),
    do:
      "A tool name the model is told about. Being told is not permission; the worker's policy decides what the model may use."

  def grant(_kind),
    do: "Explanation unavailable for this grant type; the name alone does not grant permission."
end
