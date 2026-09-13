defmodule Ryker.ControlPlane.EpisodeTrace.ToolActivity do
  @moduledoc """
  The worker's narrated activity inside "The work": tool calls folded with
  their completions, plans, permission decisions, provider back-off and
  keep-alive frames, with every payload sanitized, bounded and loaded only
  once its disclosure is opened.
  """

  import Ryker.ControlPlane.EpisodeTrace.Step

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{EpisodeCausality, InspectionRedactor}
  alias Ryker.Work.{ActivityEvent, ActivityPaths}

  @doc """
  The narrated activity as steps, each owned by the Work turn that produced it.

  A tool completion is appended as its own step beside the start it answers,
  rather than rewriting the earlier card the reader may already have open.
  """
  def steps(activity_events, causality, disclosed) do
    routing_ids =
      activity_events
      |> Enum.filter(&(not is_nil(&1.admission_input_id)))
      |> Enum.map(&("activity-" <> &1.id))
      |> MapSet.new()

    activity_events
    |> Enum.reject(&(&1.kind == "model.thought"))
    |> Enum.reduce({[], %{}}, &fold_activity(&1, &2, disclosed))
    |> elem(0)
    |> Enum.reverse()
    |> Enum.map(fn step ->
      step = %{step | owner: activity_step_owner(step.id, causality)}
      if MapSet.member?(routing_ids, step.id), do: %{step | band: :routing}, else: step
    end)
  end

  # The remote turn id on the event is the durable link back to this episode's
  # Work turn; a tool result is owned by the turn that called it, not by
  # whatever message happens to precede it in the reader's scroll.
  defp activity_step_owner("activity-" <> event_id, causality),
    do: EpisodeCausality.activity_owner(causality, event_id)

  defp activity_step_owner(_id, _causality), do: :episode

  # Steps accumulate newest first; `open` holds each started tool call's step
  # until its completion arrives, so a tool-heavy run folds in one pass.
  defp fold_activity(%ActivityEvent{kind: "tool.started"} = event, {steps, open}, disclosed) do
    started = tool_started_step(event, disclosed)
    {[started | steps], Map.put(open, activity_tool_key(event), started)}
  end

  defp fold_activity(%ActivityEvent{kind: "tool.completed"} = event, {steps, open}, disclosed) do
    case Map.pop(open, activity_tool_key(event)) do
      {nil, open} -> {[tool_completed_step(event, disclosed) | steps], open}
      {started, open} -> {[complete_tool(started, event, disclosed) | steps], open}
    end
  end

  defp fold_activity(event, {steps, open}, disclosed),
    do: {[activity_step(event, disclosed) | steps], open}

  defp tool_started_step(event, disclosed) do
    input = event.payload["input"]

    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        artifacts: tool_artifacts(event, disclosed),
        details:
          compact_details(
            [
              {"Kind", event.payload["kind"]},
              {"Tool call", event.payload["tool_call_id"]}
            ] ++ activity_tool_details(input)
          ),
        stage: "Tool call",
        tool_kind: event.payload["kind"],
        path_context: safe_path_context(event.payload["path_context"]),
        state: "started",
        summary: activity_tool_summary(input),
        title: activity_tool_title(event.payload),
        tone: nil
      }
    )
  end

  defp tool_completed_step(event, disclosed) do
    status = event.payload["status"] || "completed"

    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        artifacts: tool_artifacts(event, disclosed),
        details:
          compact_details([
            {"Kind", event.payload["kind"]},
            {"Tool call", event.payload["tool_call_id"]},
            {"Status", status}
          ]),
        stage: "Tool call",
        tool_kind: event.payload["kind"],
        path_context: safe_path_context(event.payload["path_context"]),
        state: status,
        summary: tool_outcome(event.payload, status),
        title: event.payload["title"] || "Tool completion recorded",
        tone: activity_status_tone(status)
      }
    )
  end

  defp complete_tool(step, event, disclosed) do
    status = event.payload["status"] || "completed"
    duration_ms = nonnegative_diff(event.occurred_at, step.at)

    %{
      step
      | id: "activity-#{event.id}",
        at: event.occurred_at,
        artifacts: merge_artifacts(step[:artifacts] || [], tool_artifacts(event, disclosed)),
        tool_kind: event.payload["kind"] || step.tool_kind,
        path_context: safe_path_context(event.payload["path_context"] || step.path_context),
        summary: tool_outcome(event.payload, status),
        details:
          step.details ++
            compact_details([
              {"Status", status},
              {"Finished", event.occurred_at}
            ]),
        duration_ms: duration_ms,
        state: human(status),
        tone: activity_status_tone(status)
    }
  end

  defp safe_path_context(value) do
    with %{} = paths <- ActivityPaths.sanitize(value),
         %{text: text, truncated: false} <- InspectionRedactor.artifact(paths, max_bytes: 16_384),
         {:ok, redacted} <- Jason.decode(text) do
      ActivityPaths.sanitize(redacted)
    else
      _ -> nil
    end
  end

  defp activity_step(%ActivityEvent{kind: "model.progress"} = event, _disclosed) do
    step("activity-#{event.id}", :work, event.occurred_at, %{
      actor: "Model",
      details: [],
      stage: "Progress",
      state: "",
      summary: event.payload["text"],
      title: "Progress update"
    })
  end

  defp activity_step(%ActivityEvent{kind: "model.plan"} = event, disclosed) do
    count = event.payload["step_count"] || 0

    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Model",
        artifacts: plan_artifacts(event, disclosed),
        details: compact_details([{"Plan steps", count}]),
        stage: "Plan",
        state: "updated",
        summary: plural(count, "plan step"),
        title: "Model plan updated",
        tone: nil
      }
    )
  end

  defp activity_step(%ActivityEvent{kind: "permission.decided"} = event, _disclosed) do
    outcome = event.payload["outcome"] || "recorded"

    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop policy",
        details:
          compact_details([
            {"Tool call", event.payload["tool_call_id"]},
            {"Option", event.payload["option_kind"]}
          ]),
        stage: "Permission",
        state: outcome,
        summary: permission_summary(event.payload),
        title: "Tool permission decided",
        tone: activity_status_tone(outcome)
      }
    )
  end

  defp activity_step(%ActivityEvent{kind: "activity.elided"} = event, _disclosed) do
    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        details: compact_details([{"Dropped events", event.payload["dropped"]}]),
        stage: "Recorder",
        state: "bounded",
        summary: "The turn exceeded its bounded narration budget.",
        title: "Some activity was elided",
        tone: :warn
      }
    )
  end

  defp activity_step(%ActivityEvent{kind: "provider.backoff"} = event, _disclosed) do
    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        details: safe_payload_details(event.payload),
        stage: "Provider",
        summary: provider_backoff_summary(event.payload),
        title: "Provider rate limit",
        tone: :warn
      }
    )
  end

  defp activity_step(%ActivityEvent{kind: "provider.alive"} = event, _disclosed) do
    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        details: safe_payload_details(event.payload),
        stage: "Provider",
        summary: provider_alive_summary(event.payload),
        title: "Provider is still responding",
        tone: nil
      }
    )
  end

  defp activity_step(event, _disclosed) do
    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        details: [],
        stage: "Worker activity",
        state: "recorded",
        summary: "Bounded activity event recorded.",
        title: capitalize(human(event.kind)),
        tone: nil
      }
    )
  end

  # Tool evidence is the heaviest thing on a long timeline: a tool-heavy run has
  # hundreds of calls, and each one sanitized and re-encoded up to 20 KiB per
  # result field on every refresh, for text that is almost always closed. The
  # result bodies now carry a durable id and load when their disclosure opens.
  #
  # Arguments stay prepared. The compact card face is derived from them -- the
  # command it ran, the file it read, the observation it recorded -- so making
  # them lazy would empty the row a reader scans instead of the body they open.
  @lazy_tool_fields ~w(output error content locations)

  defp tool_artifacts(%ActivityEvent{payload: payload, id: event_id}, disclosed) do
    for {key, label} <- [
          {"input", "Arguments"},
          {"output", "Response"},
          {"error", "Error"},
          {"content", "Output and changes"},
          {"locations", "Files"}
        ],
        Map.has_key?(payload, key),
        payload[key] != nil do
      artifact_id = "activity-#{event_id}-#{key}"
      lazy? = key in @lazy_tool_fields

      %{
        label: label,
        artifact_id: if(lazy?, do: artifact_id),
        artifact:
          InspectionRedactor.artifact(payload[key],
            max_bytes: 20_000,
            disclosed: not lazy? or MapSet.member?(disclosed, artifact_id)
          )
      }
    end
  end

  defp plan_artifacts(%ActivityEvent{payload: %{"entries" => entries}, id: id}, disclosed)
       when entries not in [nil, []] do
    artifact_id = "activity-#{id}-plan"

    [
      %{
        label: "Plan",
        artifact_id: artifact_id,
        artifact:
          InspectionRedactor.artifact(entries,
            max_bytes: 20_000,
            disclosed: MapSet.member?(disclosed, artifact_id)
          )
      }
    ]
  end

  defp plan_artifacts(_event, _disclosed), do: []

  defp merge_artifacts(start, finish),
    do:
      Enum.reject(start, fn artifact -> Enum.any?(finish, &(&1.label == artifact.label)) end) ++
        finish

  defp tool_outcome(payload, "failed") do
    case payload["error"] || payload["output"] || payload["content"] do
      nil -> "The tool failed. Its error response was not recorded for this older call."
      value -> value |> InspectionRedactor.artifact(max_bytes: 300) |> Map.fetch!(:text)
    end
  end

  defp tool_outcome(_payload, "cancelled"), do: "The tool call was cancelled."
  defp tool_outcome(_payload, _status), do: nil

  defp activity_tool_key(event),
    do:
      {event.session_id, event.coop_turn_id,
       event.payload["tool_call_id"] || event.remote_event_id}

  defp activity_tool_title(%{
         "input" => %{"operation" => action, "server" => server}
       })
       when is_binary(server) and is_binary(action),
       do: "#{server} · #{action}"

  defp activity_tool_title(%{"title" => title}) when is_binary(title),
    do: InspectionRedactor.artifact(title, max_bytes: 200).text

  defp activity_tool_title(_payload), do: "Tool call"

  defp activity_tool_summary(%{} = input) do
    [input["server"], input["operation"] || input["tool"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> present()
  end

  defp activity_tool_summary(_input), do: "Tool execution recorded."

  defp activity_tool_details(input) when is_map(input) do
    [
      {"Server", input["server"]},
      {"Tool", input["tool"]},
      {"Operation", input["operation"]}
    ]
  end

  defp activity_tool_details(_input), do: []

  defp safe_payload_details(payload), do: payload |> safe_fields() |> compact_details()

  defp safe_fields(%{} = fields) do
    fields
    |> Enum.reject(fn {key, _value} -> sensitive_key?(key) end)
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.flat_map(fn {key, value} ->
      case safe_activity_value(value) do
        nil -> []
        safe -> [{capitalize(human(key)), safe}]
      end
    end)
    |> Enum.take(20)
  end

  defp safe_fields(_fields), do: []

  defp safe_activity_value(value) when is_binary(value), do: value |> scrub_url() |> bounded(512)

  defp safe_activity_value(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp safe_activity_value(value) when is_map(value) or is_list(value) do
    value
    |> redact_activity_value()
    |> CanonicalJSON.encode!()
    |> bounded(512)
  rescue
    ArgumentError -> nil
  end

  defp safe_activity_value(_value), do: nil

  defp redact_activity_value(%{} = value) do
    value
    |> Enum.reject(fn {key, _nested} -> sensitive_key?(key) end)
    |> Map.new(fn {key, nested} -> {to_string(key), redact_activity_value(nested)} end)
  end

  defp redact_activity_value(value) when is_list(value),
    do: value |> Enum.take(32) |> Enum.map(&redact_activity_value/1)

  defp redact_activity_value(value) when is_binary(value), do: scrub_url(value)
  defp redact_activity_value(value), do: value

  defp sensitive_key?(key) when is_atom(key) or is_binary(key),
    do:
      Regex.match?(~r/(?:authorization|cookie|credential|password|secret|token)/i, to_string(key))

  defp sensitive_key?(_key), do: false

  defp scrub_url(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        uri |> Map.merge(%{fragment: nil, query: nil, userinfo: nil}) |> URI.to_string()

      _not_url ->
        value
    end
  end

  defp permission_summary(payload) do
    case payload["outcome"] do
      "cancelled" -> "Coop policy refused this unattended permission request."
      outcome when is_binary(outcome) -> "Coop policy recorded #{human(outcome)}."
      _missing -> "Coop policy recorded a permission decision."
    end
  end

  # The step used to say only which provider was limited, over a badge that
  # repeated the title. What a reader needs is where the work goes instead.
  defp provider_backoff_summary(payload) do
    target = payload["target"] || payload["provider"]
    next_target = payload["next_target"]
    reset = payload["reset_at"] || payload["retry_after"] || retry_in(payload)

    [limited(target), replacement(next_target), fallback_retry(next_target, reset)]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
    |> case do
      "" -> "Coop paused this turn at the provider's rate limit."
      summary -> summary <> "."
    end
  end

  defp limited(nil), do: nil
  defp limited(target), do: "#{target} is rate limited"

  defp replacement(nil), do: nil
  defp replacement(next_target), do: "#{next_target} will be used instead"

  defp fallback_retry(nil, reset) when is_binary(reset), do: "retrying #{reset}"
  defp fallback_retry(_next_target, _reset), do: nil

  defp retry_in(%{"retry_after_seconds" => seconds}) when is_integer(seconds),
    do: "in #{seconds}s"

  defp retry_in(_payload), do: nil

  defp provider_alive_summary(payload) do
    frames = payload["frames"]
    bytes = payload["bytes"]

    [frames && "#{frames} frames", bytes && "#{bytes} bytes observed"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "Provider frames are still arriving although no higher-level activity was narrated."
      summary -> summary
    end
  end

  defp activity_status_tone(status) when status in ["failed", "denied"], do: :bad
  defp activity_status_tone(status) when status in ["cancelled", "backing off"], do: :warn
  defp activity_status_tone(status) when status in ["completed", "selected", "allowed"], do: :good
  defp activity_status_tone(_status), do: nil
end
