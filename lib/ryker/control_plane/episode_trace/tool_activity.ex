defmodule Ryker.ControlPlane.EpisodeTrace.ToolActivity do
  @moduledoc """
  The worker's narrated activity inside "The work": tool calls folded with
  their completions, plans, permission decisions, provider back-off and
  keep-alive frames, with every payload sanitized, bounded and loaded only
  once its disclosure is opened.
  """
  import Ryker.ControlPlane.EpisodeTrace.Step
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.EpisodeCausality
  alias Ryker.{InspectionRedactor, Repo}
  alias Ryker.StateTools
  alias Ryker.Wording
  alias Ryker.Work

  @state_servers ["controller-tools", "responder-state"]
  # Ryker receives a state-tool call between the worker's start and completion
  # frames. One host shares one clock; the margin covers a remote worker's
  # drift and stays well under the time a model takes to make its next call.
  @call_margin_ms 5_000

  @doc """
  The worker's narration of Ryker's own state tools, joined with what Ryker
  recorded when it answered each call.

  Coop's narration of a state-tool call names only the server and the tool,
  and of a failure only its status. Each narrated call takes the first
  unclaimed recording of the same tool in the same Work turn that Ryker
  received inside the call's window, so a call whose narration was dropped
  cannot hand its recording to the next one. A failed call without a
  recording says Ryker has no record of receiving it.
  """
  @spec with_state_tool_calls(
          [Work.ActivityEvent.t()],
          [StateTools.CallRecord.t()],
          EpisodeCausality.t()
        ) ::
          [Work.ActivityEvent.t()]
  def with_state_tool_calls(events, calls, causality) do
    completions =
      for %Work.ActivityEvent{kind: "tool.completed"} = event <- events,
          into: %{},
          do: {activity_tool_key(event), event}

    {joined, _unclaimed} =
      Enum.reduce(events, {%{}, Enum.group_by(calls, &{&1.turn_id, &1.tool})}, fn event, acc ->
        join_state_call(event, acc, completions, causality)
      end)

    Enum.map(events, &join_call(&1, joined[&1.id]))
  end

  defp join_state_call(
         %Work.ActivityEvent{
           kind: "tool.started",
           payload: %{"input" => %{"server" => server, "tool" => tool}}
         } = started,
         {joined, pending},
         completions,
         causality
       )
       when server in @state_servers and is_binary(tool) do
    case EpisodeCausality.activity_owner(causality, started.id) do
      {:turn, turn_id} ->
        completed = completions[activity_tool_key(started)]
        {call, unclaimed} = claim_call(Map.get(pending, {turn_id, tool}, []), started, completed)
        evidence = %{call: call}
        joined = Map.put(joined, started.id, evidence)
        joined = if completed, do: Map.put(joined, completed.id, evidence), else: joined
        {joined, Map.put(pending, {turn_id, tool}, unclaimed)}

      _not_a_turn ->
        {joined, pending}
    end
  end

  defp join_state_call(_event, acc, _completions, _causality), do: acc

  # A recording older than the call's window belongs to a call whose narration
  # Coop dropped; it is passed over rather than handed to this one.
  defp claim_call(recordings, started, completed) do
    opens = DateTime.add(started.occurred_at, -@call_margin_ms, :millisecond)
    closes = DateTime.add((completed || started).occurred_at, @call_margin_ms, :millisecond)

    case Enum.drop_while(recordings, &(DateTime.compare(&1.called_at, opens) == :lt)) do
      [call | rest] = remaining ->
        if DateTime.compare(call.called_at, closes) == :gt,
          do: {nil, remaining},
          else: {call, rest}

      [] ->
        {nil, []}
    end
  end

  defp join_call(%Work.ActivityEvent{kind: "tool.started"} = event, %{
         call: %StateTools.CallRecord{} = call
       })
       when not is_nil(call.arguments),
       do: update_in(event.payload["input"], &Map.put_new(&1, "arguments", call.arguments))

  defp join_call(
         %Work.ActivityEvent{kind: "tool.completed", payload: %{"status" => "failed"} = payload} =
           event,
         evidence
       )
       when is_map(evidence),
       do: %{event | payload: failed_call(payload, evidence)}

  defp join_call(event, _evidence), do: event

  defp failed_call(payload, %{call: %StateTools.CallRecord{status: "failed", error: error}}) do
    payload
    |> Map.put_new("error", error)
    |> Map.put("ryker_summary", StateTools.ErrorCode.explain(error))
  end

  defp failed_call(payload, %{call: %StateTools.CallRecord{}}) do
    Map.put(
      payload,
      "ryker_summary",
      "Ryker answered the call, but the worker reported it as failed."
    )
  end

  # The sentence said "not recorded for this older call" whenever the turn had
  # no recording at all, which a new turn whose only call never reached Ryker
  # has too (2026-10-05).
  defp failed_call(payload, _no_recording) do
    if payload["error"] || payload["output"] || payload["content"],
      do: payload,
      else:
        Map.put(
          payload,
          "ryker_summary",
          "The tool failed, and Ryker has no record of receiving the call, so there is no error response to show."
        )
  end

  @doc """
  The narrated activity as steps, each owned by the Work turn that produced it.

  A tool start remains visible while it is running. Once its completion is
  retained, the pair becomes one completed step with the start's request and
  the completion's outcome.
  """
  def steps(activity_events, causality, disclosed) do
    routing_ids =
      activity_events
      |> Enum.filter(&(not is_nil(&1.admission_input_id)))
      |> Enum.map(&("activity-" <> &1.id))
      |> MapSet.new()

    {steps, _open, replaced} =
      activity_events
      |> Enum.reject(&hidden_activity?/1)
      |> Enum.reduce({[], %{}, MapSet.new()}, &fold_activity(&1, &2, disclosed))

    steps
    |> Enum.reject(&MapSet.member?(replaced, &1.id))
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
  # until its completion arrives, and `replaced` the starts a completion took
  # the place of, which leave once the run is folded. Removing each start as
  # its completion arrived searched every step so far, so folding took time in
  # the square of a run's tool calls (2026-10-04 review).
  defp fold_activity(
         %Work.ActivityEvent{kind: "tool.started"} = event,
         {steps, open, replaced},
         disclosed
       ) do
    started = tool_started_step(event, disclosed)
    {[started | steps], Map.put(open, activity_tool_key(event), started), replaced}
  end

  defp fold_activity(
         %Work.ActivityEvent{kind: "tool.completed"} = event,
         {steps, open, replaced},
         disclosed
       ) do
    case Map.pop(open, activity_tool_key(event)) do
      {nil, open} ->
        {[tool_completed_step(event, disclosed) | steps], open, replaced}

      {started, open} ->
        {[complete_tool(started, event, disclosed) | steps], open,
         MapSet.put(replaced, started.id)}
    end
  end

  defp fold_activity(event, {steps, open, replaced}, disclosed),
    do: {[activity_step(event, disclosed) | steps], open, replaced}

  # A worker older than 2026-09-29 sent a thought's time and no words.
  defp hidden_activity?(%Work.ActivityEvent{kind: "model.thought", payload: payload}),
    do: blank?(payload["text"]) and not is_map(payload["withheld"])

  defp hidden_activity?(%Work.ActivityEvent{kind: "model.progress", payload: payload}) do
    case payload["text"] do
      text when is_binary(text) -> String.trim(text) == ""
      _other -> true
    end
  end

  defp hidden_activity?(_event), do: false

  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_text), do: true

  defp tool_started_step(event, disclosed) do
    input = event.payload["input"]
    diagnostic? = setup_diagnostic?(event.payload)

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
              {"Tool call", event.payload["tool_call_id"], identifier: true}
            ] ++ activity_tool_details(input)
          ),
        stage: if(diagnostic?, do: "Setup diagnostic", else: "Tool call"),
        tool_kind: event.payload["kind"],
        path_context: safe_path_context(event.payload["path_context"]),
        withheld: withheld(event.payload),
        state: "started",
        summary: activity_tool_summary(input),
        title:
          if(diagnostic?,
            do: setup_diagnostic_title(event.payload),
            else: activity_tool_title(event.payload)
          ),
        tone: nil
      }
    )
  end

  defp tool_completed_step(event, disclosed) do
    status = event.payload["status"] || "completed"
    diagnostic? = setup_diagnostic?(event.payload)

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
            {"Tool call", event.payload["tool_call_id"], identifier: true},
            {"Status", status}
          ]),
        stage: if(diagnostic?, do: "Setup diagnostic", else: "Tool call"),
        tool_kind: event.payload["kind"],
        path_context: safe_path_context(event.payload["path_context"]),
        exit_code: exit_code(event.payload),
        withheld: withheld(event.payload),
        state: status,
        summary: activity_outcome(event.payload, status, diagnostic?),
        title:
          if(diagnostic?,
            do: setup_diagnostic_title(event.payload),
            else: event.payload["title"] || "Tool completion recorded"
          ),
        tone: activity_status_tone(status)
      }
    )
  end

  defp complete_tool(step, event, disclosed) do
    status = event.payload["status"] || "completed"
    duration_ms = nonnegative_diff(event.occurred_at, step.at)
    diagnostic? = setup_diagnostic?(event.payload) || step.stage == "Setup diagnostic"

    %{
      step
      | id: "activity-#{event.id}",
        at: event.occurred_at,
        artifacts: merge_artifacts(step[:artifacts] || [], tool_artifacts(event, disclosed)),
        tool_kind: event.payload["kind"] || step.tool_kind,
        path_context: safe_path_context(event.payload["path_context"] || step.path_context),
        exit_code: exit_code(event.payload),
        withheld: merge_withheld(step[:withheld], withheld(event.payload)),
        stage: if(diagnostic?, do: "Setup diagnostic", else: "Tool call"),
        summary: activity_outcome(event.payload, status, diagnostic?),
        title: if(diagnostic?, do: setup_diagnostic_title(event.payload), else: step.title),
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

  # The exit code a command's output reports.
  defp exit_code(%{"output" => %{"exit_code" => code}}) when is_integer(code), do: code
  defp exit_code(_payload), do: nil

  # Which narrated fields the worker withheld, and why: field names and short
  # reasons only.
  defp withheld(%{"withheld" => %{} = withheld}) do
    reasons =
      for {field, reason} <- withheld, is_binary(field) and is_binary(reason), into: %{} do
        {field, String.slice(reason, 0, 120)}
      end

    if reasons == %{}, do: nil, else: reasons
  end

  defp withheld(_payload), do: nil

  defp merge_withheld(nil, withheld), do: withheld
  defp merge_withheld(withheld, nil), do: withheld
  defp merge_withheld(first, second), do: Map.merge(first, second)

  defp safe_path_context(value) do
    with %{} = paths <- Work.ActivityPaths.sanitize(value),
         %{text: text, truncated: false} <- InspectionRedactor.artifact(paths, max_bytes: 16_384),
         {:ok, redacted} <- Jason.decode(text) do
      Work.ActivityPaths.sanitize(redacted)
    else
      _ -> nil
    end
  end

  defp activity_step(%Work.ActivityEvent{kind: "model.progress"} = event, _disclosed) do
    step("activity-#{event.id}", :work, event.occurred_at, %{
      actor: "Model",
      details: [],
      stage: "Progress",
      state: "",
      summary: event.payload["text"],
      title: "Progress update"
    })
  end

  # A thought as the model summarized it: Codex writes a bold heading, then
  # at times a paragraph under it. A heading alone, "Selecting the reply
  # button", read as a step Ryker took (Andrew, 2026-10-01: "what does this
  # card mean in simple english, in practice?"); it is the model's own note.
  defp activity_step(%Work.ActivityEvent{kind: "model.thought"} = event, _disclosed) do
    {title, summary} =
      case event.payload["text"] do
        text when is_binary(text) -> thought_parts(text)
        _withheld -> {"Model's note", withheld_thought(event.payload)}
      end

    step("activity-#{event.id}", :work, event.occurred_at, %{
      actor: "Model",
      details: [],
      stage: "Thinking",
      state: "",
      summary: summary,
      title: title
    })
  end

  defp activity_step(%Work.ActivityEvent{kind: "model.plan"} = event, disclosed) do
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
        summary: plan_summary(count),
        title: "Model plan updated",
        tone: nil
      }
    )
  end

  defp activity_step(%Work.ActivityEvent{kind: "permission.decided"} = event, _disclosed) do
    outcome = event.payload["outcome"] || "recorded"

    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop policy",
        details:
          compact_details([
            {"Tool call", event.payload["tool_call_id"], identifier: true},
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

  defp activity_step(%Work.ActivityEvent{kind: "activity.elided"} = event, _disclosed) do
    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        details: compact_details([{"Updates left out", event.payload["dropped"]}]),
        stage: "Recorder",
        state: nil,
        summary:
          "This run sent more updates than Ryker keeps for one run, so some were left out.",
        title: "Some activity was left out",
        tone: :warn
      }
    )
  end

  defp activity_step(%Work.ActivityEvent{kind: "provider.backoff"} = event, _disclosed) do
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

  defp activity_step(%Work.ActivityEvent{kind: "provider.alive"} = event, _disclosed) do
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
        state: nil,
        summary: "The worker reported activity Ryker has no card for.",
        title: capitalize(human(event.kind)),
        tone: nil
      }
    )
  end

  # A stored count is read as stored: one a worker wrote as anything but a
  # number names no count.
  defp plan_summary(count) when is_integer(count) and count >= 0,
    do: Wording.count(count, "plan step")

  defp plan_summary(_unreadable), do: "Plan updated"

  defp thought_parts(text) do
    case Regex.run(~r/\A\s*\*\*([^*\n]{1,200})\*\*\s*(.*)\z/s, text) do
      [_whole, heading, rest] ->
        {"Model's note: " <> String.trim(heading), present(String.trim(rest))}

      nil ->
        {"Model's note", text}
    end
  end

  defp withheld_thought(payload) do
    case withheld(payload) do
      %{"text" => reason} -> "The worker withheld this thought: #{reason_words(reason)}."
      _none -> nil
    end
  end

  @doc """
  Why the worker withheld a field, in words: "likely GitHub token" reads as
  "it looked like it held a GitHub token".
  """
  @spec reason_words(String.t()) :: String.t()
  def reason_words("likely " <> kind), do: "it looked like it held a #{kind}"
  def reason_words("too large"), do: "it was too large to send"
  def reason_words(reason), do: reason

  # Tool evidence is the heaviest thing on a long timeline: a tool-heavy run has
  # hundreds of calls, and each one sanitized and re-encoded up to 20 KiB per
  # result field on every refresh, for text that is almost always closed. The
  # result bodies now carry a durable id and load when their disclosure opens.
  #
  # Arguments stay prepared. The compact card face is derived from them -- the
  # command it ran, the file it read, the observation it recorded -- so making
  # them lazy would empty the row a reader scans instead of the body they open.
  @lazy_tool_fields ~w(output error content locations)

  @doc """
  The text behind one opened tool fold, read from its own row: what `steps/3` shows for it once
  disclosed. `:error` for anything that is not a tool body of `episode_id`, which the page then
  answers by projecting itself again, as for every other body.
  """
  @spec disclosed_body(String.t(), Ecto.UUID.t()) :: {:ok, String.t()} | :error
  def disclosed_body("activity-" <> rest, episode_id) when is_binary(episode_id) do
    with <<event_id::binary-size(36), "-", key::binary>> <- rest,
         true <- key in @lazy_tool_fields,
         {:ok, event_id} <- Ecto.UUID.cast(event_id),
         %Work.ActivityEvent{episode_id: ^episode_id, kind: kind, payload: %{} = payload}
         when kind in ["tool.started", "tool.completed"] <-
           Repo.one(Work.ActivityEvent.Query.by_id(event_id)),
         {_label, value} when not is_nil(value) <- shown_artifact(payload, key, key),
         %{state: :retained, text: text} when is_binary(text) <-
           InspectionRedactor.artifact(value, max_bytes: 20_000, disclosed: true) do
      {:ok, text}
    else
      _not_a_tool_body -> :error
    end
  end

  def disclosed_body(_artifact_id, _episode_id), do: :error

  defp tool_artifacts(%Work.ActivityEvent{payload: payload, id: event_id}, disclosed) do
    for {key, label} <- [
          {"input", "Arguments"},
          {"output", "Response"},
          {"error", "Error"},
          {"content", "Output and changes"},
          {"locations", "Files"}
        ],
        {label, value} = shown_artifact(payload, key, label),
        value != nil do
      artifact_id = "activity-#{event_id}-#{key}"
      lazy? = key in @lazy_tool_fields

      %{
        label: label,
        artifact_id: if(lazy?, do: artifact_id),
        artifact:
          InspectionRedactor.artifact(value,
            max_bytes: 20_000,
            disclosed: not lazy? or MapSet.member?(disclosed, artifact_id)
          )
      }
    end
  end

  # A command's result is what it printed; its exit code is on the card. Its
  # content names only the terminal the worker ran it in, which says nothing.
  defp shown_artifact(
         %{"kind" => "execute", "output" => %{"formatted_output" => printed}},
         "output",
         _label
       )
       when is_binary(printed),
       do: {"Output", printed}

  defp shown_artifact(%{"kind" => "execute", "content" => content}, "content", label)
       when is_list(content) do
    if Enum.all?(content, &(&1["type"] == "terminal")),
      do: {label, nil},
      else: {label, content}
  end

  defp shown_artifact(payload, key, label), do: {label, payload[key]}

  defp plan_artifacts(%Work.ActivityEvent{payload: %{"entries" => entries}, id: id}, disclosed)
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

  defp merge_artifacts(start, finish) do
    Enum.reject(start, fn artifact -> Enum.any?(finish, &(&1.label == artifact.label)) end) ++
      finish
  end

  defp tool_outcome(%{"ryker_summary" => summary}, "failed"), do: summary

  # Coop keeps a tool's error output on the worker, so a failure it narrates
  # without a body has none to show, however recent it is.
  defp tool_outcome(payload, "failed") do
    case payload["error"] || payload["output"] || payload["content"] do
      nil -> "The tool failed. The worker does not send tool error details to Ryker."
      value -> value |> InspectionRedactor.artifact(max_bytes: 300) |> Map.fetch!(:text)
    end
  end

  defp tool_outcome(_payload, "cancelled"), do: "The tool call was cancelled."
  defp tool_outcome(_payload, _status), do: nil

  defp activity_outcome(payload, "failed", true) do
    case payload["error"] || payload["output"] || payload["content"] do
      nil -> "Setup failed. Its error detail was not retained."
      value -> value |> InspectionRedactor.artifact(max_bytes: 300) |> Map.fetch!(:text)
    end
  end

  defp activity_outcome(payload, status, _diagnostic?), do: tool_outcome(payload, status)

  defp setup_diagnostic?(payload) do
    title = payload["title"] || ""
    input = if is_map(payload["input"]), do: payload["input"], else: %{}
    operation = input["operation"] || input["tool"] || ""

    String.starts_with?(title, "mcp_startup.") ||
      String.starts_with?(operation, "mcp_startup.")
  end

  defp setup_diagnostic_title(payload) do
    input = if is_map(payload["input"]), do: payload["input"], else: %{}

    name =
      (payload["title"] || input["operation"] || "MCP")
      |> String.replace_prefix("mcp_startup.", "")
      |> String.trim()

    if name == "",
      do: "Tool connection setup",
      else: "#{String.capitalize(name)} connection setup"
  end

  defp activity_tool_key(event) do
    {event.session_id, event.coop_turn_id, event.payload["tool_call_id"] || event.remote_event_id}
  end

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

  defp sensitive_key?(key) when is_atom(key) or is_binary(key) do
    Regex.match?(~r/(?:authorization|cookie|credential|password|secret|token)/i, to_string(key))
  end

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
      "" -> "The worker paused this run at the provider's rate limit."
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
