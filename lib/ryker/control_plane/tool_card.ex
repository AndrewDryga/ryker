defmodule Ryker.ControlPlane.ToolCard do
  @moduledoc "Readable actions, derived only from retained, sanitized tool evidence."
  use Phoenix.Component
  alias Ryker.ControlPlane.Components
  alias Ryker.ControlPlane.SlackMarkdown
  alias Ryker.Work.ActivityPaths

  @tools %{
    "cite_source" =>
      {"Record evidence", "Evidence recorded", "Keeps a source-linked observation for this work."},
    "record_finding" =>
      {"Record a finding", "Finding recorded",
       "Saves a conclusion and its supporting evidence without sending a message or opening an incident."},
    "plan_goal" =>
      {"Create a plan", "Plan recorded", "Defines the goals Ryker will track while working."},
    "update_goal" =>
      {"Update a goal", "Goal updated", "Records progress or a blocker against an existing goal."},
    "update_conversation_summary" =>
      {"Draft conversation context", "Conversation summary drafted",
       "Prepares the situation, decisions and open questions. Ryker saves this draft when it accepts the result."},
    "request_input" =>
      {"Prepare a question", "Question prepared",
       "The question can be included in the response after validation."},
    "wait_for" =>
      {"Prepare an event wait", "Event wait prepared",
       "Defines which event or deadline can resume this work."},
    "search_memory" =>
      {"Search saved knowledge", "Saved knowledge searched",
       "Looks up relevant memories, guidance and conversation context."},
    "propose_memory" =>
      {"Propose a memory", "Memory proposed",
       "Prepares a remembered fact or instruction for confirmation."},
    "propose_preference" =>
      {"Propose a preference", "Preference proposed",
       "Prepares a response preference for confirmation."},
    "request_task" =>
      {"Prepare a task", "Task proposed", "Prepares follow-up work for confirmation."},
    "record_feedback" =>
      {"Record feedback", "Feedback recorded", "Keeps a correction for future behavior."},
    "validate_final" =>
      {"Check the response", "Response check completed",
       "Checks the proposed response and its referenced evidence."},
    "get_work_state" =>
      {"Read work state", "Work state read",
       "Reads the current goals, evidence and pending work."},
    "list_automations" =>
      {"List automations", "Automations listed",
       "Reads saved recurring work and event subscriptions."},
    "get_automation" =>
      {"Read an automation", "Automation read", "Inspects a saved trigger and its instruction."},
    "propose_automation" =>
      {"Propose an automation", "Automation proposed",
       "Prepares a recurring or event-triggered instruction for confirmation."},
    "record_emisar_approval" =>
      {"Record approval request", "Approval request recorded",
       "Keeps the pending infrastructure approval so work can resume after a decision."}
  }

  def render(assigns) do
    assigns = assign(assigns, :action, project(assigns.step))

    ~H"""
    <div class={"action-card action-#{@action.kind} action-event-#{@step.state}"}>
      <Components.card_heading title={
        if @step.state == "started", do: "Started: #{@action.title}", else: @action.title
      }>
        <:leading><span class="action-symbol" aria-hidden="true">{@action.symbol}</span></:leading>
        <:meta :if={@step.state in ["failed", "cancelled", "running"] || @step.duration_ms}>
          <span
            :if={@step.state in ["failed", "cancelled", "running"]}
            class={"action-state action-#{@step.state}"}
          >{@step.state}</span>
          <span :if={@step.duration_ms} class="action-duration">{duration(@step.duration_ms)}</span>
        </:meta>
      </Components.card_heading>
      <p :if={@action.description && @step.state != "started"} class="action-description">
        {@action.description}
      </p>
      <p :if={@action.saved_evidence} class="action-evidence-link">
        <a href={@action.saved_evidence}>View recorded evidence ↑</a>
      </p>
      <p :if={@action.warning} class="action-warning">⚠ {@action.warning}</p>
      <code :for={path <- @action.paths} class="action-path">{path}</code>
      <p :if={@step.summary && @step.state in ["failed", "cancelled"]} class="action-error">
        {@step.summary}
      </p>
      <dl :if={@action.facts != [] && @step.state != "started"} class="action-facts">
        <div :for={{label, value} <- @action.facts}>
          <dt>{label}</dt><dd>{value}</dd>
        </div>
      </dl>
      <div :if={@action.text && @step.state != "started"} class="action-observation markdown-preview">
        {Phoenix.HTML.raw(SlackMarkdown.preview(@action.text))}
      </div>
      <section
        :for={{label, items} <- @action.groups}
        :if={@step.state != "started"}
        class="action-result-group"
      >
        <h4>{label}</h4><ul>
          <li :for={item <- items}>{item}</li>
        </ul>
      </section>
      <pre :if={@action.diff && @step.state != "started"} class="action-diff">{@action.diff}</pre>
      <details
        :for={artifact <- @step.artifacts}
        class="action-raw"
        data-artifact={
          if artifact.artifact.state in [:collapsed, :retained], do: artifact[:artifact_id]
        }
        data-revoked={if artifact.artifact.state in [:expired, :not_recorded], do: "true"}
      >
        <summary>
          {if artifact.label == "Arguments", do: "Raw arguments", else: artifact.label}{if artifact.artifact.truncated,
            do: " · partial record"}{if artifact.artifact.state == :collapsed,
            do: " · #{bytes(artifact.artifact.bytes)}"}
        </summary>
        <p :if={artifact.artifact.state == :collapsed} class="artifact-loading" role="status">
          Loading…
        </p>
        <p :if={artifact.artifact.state in [:expired, :not_recorded]} class="artifact-unavailable">
          This body is no longer retained.
        </p>
        <pre :if={artifact.artifact.state == :retained}>{artifact.artifact.text}</pre>
      </details>
    </div>
    """
  end

  def project(step) do
    input = artifact(step, "Arguments")
    args = if is_map(input["arguments"]), do: input["arguments"], else: input
    tool = input["tool"] || input["operation"]
    metadata = if input["server"] == "responder-state", do: @tools[tool]

    {title, description, kind, symbol} =
      case metadata do
        {verb, completed, description} ->
          {if(step.state == "completed", do: completed, else: verb), description, "ryker", "◇"}

        nil ->
          common_action(step, args)
      end

    file = file_path(args, step.title)
    {paths, warning} = display_paths(step[:path_context], file)

    action = %{
      title: title,
      description: description,
      kind: kind,
      symbol: symbol,
      paths: paths,
      warning: warning,
      text: readable_text(tool, args),
      facts: facts(tool, args),
      groups: groups(tool, args),
      diff: string(args["diff"] || args["patch"]),
      saved_evidence: nil
    }

    citation_result(action, step, tool)
  end

  defp citation_result(
         %{kind: "ryker"} = action,
         %{state: "completed", saved_evidence: link},
         "cite_source"
       )
       when is_binary(link) do
    %{
      action
      | title: "Citation saved",
        description: nil,
        text: nil,
        facts: [],
        saved_evidence: link
    }
  end

  defp citation_result(action, _step, _tool), do: action

  defp common_action(%{tool_kind: "edit"}, _), do: {"Edit files", nil, "edit", "±"}
  defp common_action(%{tool_kind: "read"}, _), do: {"Read file", nil, "read", "↳"}

  defp common_action(%{tool_kind: "search"} = step, _),
    do: {"Search project", step.title, "search", "⌕"}

  defp common_action(step, args) do
    command = args["command"] || args["cmd"]

    cond do
      String.starts_with?(step.title, "Read file ") ->
        {"Read file", nil, "read", "↳"}

      String.starts_with?(step.title, "Search for ") ->
        {"Search project", step.title, "search", "⌕"}

      edit?(step.title, args) ->
        {"Edit files", nil, "edit", "±"}

      is_binary(command) ->
        {"Run command", command, "command", ">_"}

      true ->
        {if(String.trim(step.title) == "", do: "Tool call", else: step.title), nil, "tool", "◇"}
    end
  end

  defp edit?(title, args),
    do:
      String.starts_with?(title, ["Edit file", "Write file", "Apply patch"]) ||
        is_binary(args["diff"] || args["patch"])

  defp readable_text("cite_source", args), do: string(args["observation"])

  defp readable_text("record_finding", args),
    do:
      [string(args["what"]), string(args["reason"])]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

  defp readable_text("update_conversation_summary", %{"state" => state}) when is_map(state),
    do: string(state["situation"])

  defp readable_text(_, args),
    do:
      string(
        args["reason"] || args["description"] || args["summary"] || args["context"] ||
          args["detail"]
      )

  defp groups("request_input", args) do
    args["questions"]
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn question ->
      {string(question["text"]) || "Question",
       Enum.filter(List.wrap(question["choices"]), &is_binary/1)}
    end)
  end

  defp groups("update_conversation_summary", %{"state" => state}) when is_map(state) do
    for {key, label} <- [
          {"decisions", "Decisions"},
          {"open_loops", "Open work"},
          {"unresolved_questions", "Open questions"}
        ],
        items = Enum.filter(List.wrap(state[key]), &is_binary/1),
        items != [],
        do: {label, items}
  end

  defp groups(_, _), do: []

  defp fact_keys(tool) do
    case tool do
      "cite_source" ->
        [{"subject", "Subject"}, {"relation", "Relation"}, {"source_ref", "Source"}]

      "record_finding" ->
        [{"status", "Conclusion"}, {"scope", "Scope"}]

      "plan_goal" ->
        [
          {"requested_outcome", "Goal"},
          {"completion_contract", "Done when"},
          {"authority", "Allowed work"},
          {"writable_repository", "Writable project"}
        ]

      "update_conversation_summary" ->
        []

      "search_memory" ->
        [{"query", "Search"}, {"kind", "Knowledge type"}]

      "update_goal" ->
        [{"goal_id", "Goal"}, {"state", "Progress"}]

      "wait_for" ->
        [
          {"deadline", "Wait until"},
          {"verification", "What to verify"},
          {"on_timeout", "If time runs out"}
        ]

      _ ->
        [
          {"title", "Title"},
          {"objective", "Objective"},
          {"query", "Search"},
          {"pattern", "Pattern"}
        ]
    end
  end

  defp facts(tool, args) do
    for {key, label} <- fact_keys(tool),
        value = args[key],
        is_binary(value) && value != "",
        do: {label, value}
  end

  defp file_path(args, title) do
    cond do
      is_binary(args["path"]) ->
        args["path"]

      is_binary(args["file_path"]) ->
        args["file_path"]

      true ->
        case Regex.run(~r/\ARead file '(.+)'\z/s, title) do
          [_, path] -> path
          _ -> nil
        end
    end
  end

  defp display_paths(context, file) do
    case ActivityPaths.sanitize(context) do
      %{"paths" => paths} = context ->
        files = for %{"scope" => "project", "path" => path} <- paths, do: path
        {Enum.uniq(files), path_warnings(context)}

      nil ->
        {List.wrap(file),
         if(file && Path.type(file) == :absolute, do: "Project boundary not recorded")}
    end
  end

  defp path_warnings(%{"paths" => paths} = context) do
    warnings =
      [
        if(Enum.any?(paths, &(&1["scope"] == "outside")), do: "Outside project"),
        if(Enum.any?(paths, &(&1["scope"] == "unknown")), do: "Project boundary not recorded"),
        if(context["partial"], do: "Some paths were not retained")
      ]
      |> Enum.reject(&is_nil/1)

    if warnings != [], do: Enum.join(warnings, " · ")
  end

  defp artifact(step, label) do
    with %{artifact: %{state: :retained, text: text, truncated: false}} <-
           Enum.find(step.artifacts, &(&1.label == label)),
         {:ok, value} when is_map(value) <- Jason.decode(text),
         do: value,
         else: (_ -> %{})
  end

  defp bytes(nil), do: "size not recorded"
  defp bytes(count) when count < 1_024, do: "#{count} bytes"
  defp bytes(count) when count < 1_024 * 1_024, do: "#{div(count, 1_024)} KiB"
  defp bytes(count), do: "#{Float.round(count / (1_024 * 1_024), 1)} MiB"

  defp string(value) when is_binary(value), do: value
  defp string(_), do: nil
  defp duration(ms) when ms < 1_000, do: "#{ms} ms"
  defp duration(ms), do: "#{Float.round(ms / 1_000, 1)} s"
end
