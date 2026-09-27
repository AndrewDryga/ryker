defmodule Ryker.ControlPlane.ConfigurationHelp do
  @moduledoc """
  Operator explanations for the explicitly exposed runtime settings, not a
  config parser.

  Each setting has a title and a line under it in plain words, which is all a
  reader sees until they open its Details. The behaviour and the default
  there are plain words too (QA re-test, 2026-09-26, found "v1 loader" and
  "admission.policy.digest" in them); the setting's name in the file and its
  loaded value are the precise terms support needs. A retention limit
  carries the name the Data retention page gives it.
  """

  # Defaults describe the shipped operational defaults, not a configuration file.
  # Retention horizons are required inputs and deliberately have no default.
  @required_retention "Required when cleanup is set up; there is no default."
  @settings %{
    "admission" => {
      "Routing",
      "Decides whether an incoming message needs a reply, a reaction, more work or nothing.",
      "Runs before any work starts, using the routing model and permissions saved in Ryker. Turning it on does not mean a worker is ready to route right now.",
      "Always on."
    },
    "work" => {
      "Running work",
      "Runs the conversations and tasks routing accepted, with their models, repositories and tools.",
      "A full installation runs work on the workers connected to it. Each request keeps the access Ryker chose for it; a message cannot ask for more.",
      "Always on. A full installation runs work on connected workers."
    },
    "control_plane" => {
      "This console and Chat",
      "Serves this console, Chat and the actions you take here.",
      "It answers only on this computer. Chat messages run like any other request, and repository and Emisar tools keep their own limits.",
      "Off unless the settings file has a control_plane section."
    },
    "coop_worker_gateway" => {
      "Worker connections",
      "Lets workers connect to Ryker to receive work and report progress.",
      "Workers prove who they are with certificates before they receive work. Being set up does not mean a worker is connected now, or that one can run a given kind of work.",
      "Required in a full installation; off in a partial one unless set."
    },
    "delivery" => {
      "Replies and actions",
      "Delivers accepted replies, reactions and actions to where they belong.",
      "Replies wait in their own queue, are retried, and are checked when it is unclear whether one arrived. An answer the model has finished may still be waiting here to be sent.",
      "On whenever Chat, Slack or GitHub is set up."
    },
    "publication" => {
      "Pull requests",
      "Checks code changes, opens pull requests for approved ones and follows them on GitHub.",
      "It works only with repositories you set up and the exact change a task recorded. Turning it on never allows other pushes or merges; each pull request still needs its checks and your approval.",
      "Code reviews run whenever replies can be delivered. Opening pull requests needs GitHub and the repository set up in Ryker."
    },
    "retention" => {
      "Cleanup and retention",
      "Cleans up finished work and deletes old data once it is past its limit.",
      "Work with unsaved or unpublished changes, or still in use, is never cleaned up. Data is removed in stages, not only by age. Shorter limits leave less history to look back at.",
      "Required in a full installation, with every limit set."
    },
    "state_tools" => {
      "Ryker's tools",
      "Gives the model Ryker's own tools, such as waiting for an event or offering a task.",
      "The tools record progress, ask people questions and use the features you turned on. Each call is still limited to what its request may do; they give no general access to Ryker's data or to other tools.",
      "Required in a full installation and for Emisar approvals."
    },
    "event_waits" => {
      "Waiting for events",
      "Resumes work that is waiting for an outside event or a deadline.",
      "Ryker writes down what the work is waiting for instead of keeping a model running. Only the matching event, or the wait's own time limit, ends the wait.",
      "Off unless the settings file has an event_waits section."
    },
    "schedules" => {
      "Scheduled work",
      "Starts the work for reminders and schedules when they are due.",
      "Each run posts where its schedule says and keeps its schedule's access: reading only, running approved operations and changing code stay separate. Turning schedules on gives none of them more.",
      "Off unless the settings file sets up schedules and the policies they run under."
    },
    "emisar" => {
      "Emisar approvals",
      "Watches Emisar for approval decisions and resumes the work waiting on them.",
      "Ryker watches the exact action it recorded; it never approves or repeats it. This is not the list of Emisar tools work may use.",
      "Off unless the settings file has an emisar section; needs Ryker's tools."
    },
    "slack" => {
      "Slack",
      "Receives Slack messages and clicks, and keeps Ryker's replies and cards up to date.",
      "It handles only your workspace, the channels Ryker takes part in, and what your rules allow.",
      "Off unless Slack is set up."
    },
    "github" => {
      "GitHub",
      "Handles GitHub comments, reviews and repository events.",
      "Ryker takes only signed events for the app installation and repositories you set up. The app's permissions and those repositories still limit what it reads, replies to and publishes.",
      "Off unless GitHub is set up."
    },
    "webhooks" => {
      "Webhooks",
      "Accepts events from the senders you set up, such as alerting and deployment tools.",
      "Each sender has its own signature check, its own way of reading events and its own place to post. This is separate from GitHub's events, and it never runs anything for an unsigned request.",
      "Off unless a webhook source is set up."
    },
    "runtime.mode" => {
      "Installation mode",
      "Whether this is a full installation or a partial one for development and tests.",
      "A full installation needs workers, their connections, Ryker's tools and cleanup. A partial one leaves some of them out for development; it is not how Ryker runs for a team.",
      "Required: product (a full installation) or component (a partial one)."
    },
    "admission.decision_timeout_ms" => {
      "Routing time limit",
      "How long routing waits for one decision.",
      "A longer limit avoids giving up on routing too early, but does not make the model think faster. It is not the limit for the work itself or for the whole reply.",
      "30 seconds. Allowed: 1 second to 5 minutes."
    },
    "work.concurrency" => {
      "Work at the same time",
      "How many pieces of work Ryker moves forward at the same time.",
      "More at once shortens queues when there is separate work and free workers. It adds no workers, does not speed up one model call, and may use more of your model provider at once.",
      "4 at a time. Allowed: 1 to 32."
    },
    "work.poll_interval_ms" => {
      "Work check interval",
      "How often Ryker checks running work for progress.",
      "Work that is ready starts as soon as it is recorded, whatever this is. A shorter interval notices a running turn's progress sooner but adds worker traffic. It does not make the model think faster, and it is not how often this console refreshes.",
      "250 milliseconds. Allowed: 1 millisecond to 1 minute."
    },
    "retention.operational_data_seconds" => {
      "Prompts, replies and tool activity",
      "How long the full text of messages, model calls and tool calls is kept.",
      "The text is removed only after its request has finished and its worker sessions are gone, and it can go before the shorter history does. Must not be longer than Finished work or conversation memory.",
      @required_retention
    },
    "retention.closed_work_seconds" => {
      "Finished work",
      "How long closed incident rooms, task cards and their history are kept.",
      "This is not how long a worker session stays open after its work ends. Cleanup still checks that the work is finished and whose it is. Must be at least Prompts, replies and tool activity, and no longer than Request history.",
      @required_retention
    },
    "retention.episode_history_seconds" => {
      "Request history",
      "How long the step-by-step record of each finished request is kept.",
      "A request's history is removed whole, never step by step. Short receipts stay until the Audit trail limit. Must be at least Finished work and no longer than Audit trail.",
      @required_retention
    },
    "retention.audit_data_seconds" => {
      "Audit trail",
      "How long the short records of what happened are kept, after the rest of a request's history is gone.",
      "The last of a request's history to go; it must be at least Request history. A longer limit keeps more from now on; it cannot bring back what is already gone. Backups are kept separately.",
      @required_retention
    },
    "retention.disposable_bytes_limit" => {
      "Space for unused working copies",
      "How much space one worker may keep for working copies no task is using any more.",
      "Workers measure their own disk and report it; Ryker never guesses, and a missing report counts as unknown, not zero. Neither age nor a full disk lets Ryker delete work that must be kept. This limits copies kept for later, not what a running task writes in its own copy.",
      @required_retention
    },
    "retention.reclaim_target_seconds" => {
      "Cleanup target",
      "How soon a working copy no task needs any more should be deleted from a worker.",
      "The time counts from when a copy could first be deleted, not from when it was made, and cleanup takes turns fairly across workers. An offline worker is tried again later and does not count against this target.",
      @required_retention
    },
    "retention.storage_high_watermark_bytes" => {
      "Storage limit for new work",
      "Above this much used space, a worker starts no new work that needs a working copy.",
      "The worker refuses the work and says so; Ryker then sends it no new work that needs a copy and shows the worker's reason, while cleanup and existing work carry on. Must be above Storage level to start again and Space kept for cleanup.",
      @required_retention
    },
    "retention.storage_low_watermark_bytes" => {
      "Storage level to start again",
      "Below this much used space, a worker takes that kind of work again.",
      "Ryker follows the worker's own report, so there is no second limit to flip back and forth against. Must be below Storage limit for new work.",
      @required_retention
    },
    "retention.storage_reserve_bytes" => {
      "Space kept for cleanup",
      "The free space a worker keeps so that cleanup can always finish.",
      "A copy that would use this space is refused before it is made. Must be below Storage limit for new work.",
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
            "Check what reads this setting before changing it; its name alone does not say what it does.",
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
      "A tool from a connected tool server. Ryker's job access and that server's permissions decide who may use it; being listed here does not grant permission."

  def grant("source/action tool"),
    do:
      "A tool name the model is told about. Being told is not permission; Ryker's job access and the tool server decide what the model may use."

  def grant(_kind),
    do: "Explanation unavailable for this grant type; the name alone does not grant permission."
end
