defmodule Ryker.ControlPlane.ToolCard do
  @moduledoc """
  Readable actions, derived only from retained, sanitized tool evidence: one
  tool call as a card (`render/1`), or as one line of a run of calls
  (`line/1`), which says whose tool it was, what it did, the one fact that
  tells it apart from its neighbours, and how long it took.
  """
  use Phoenix.Component
  alias Ryker.ControlPlane.Components
  alias Ryker.ControlPlane.EpisodeTrace.ToolActivity
  alias Ryker.ControlPlane.SlackMarkdown
  alias Ryker.ControlPlane.Units
  alias Ryker.Wording
  alias Ryker.Work

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
       "Ryker checks the question, then includes it in the answer."},
    "wait_for" =>
      {"Prepare an event wait", "Event wait prepared",
       "Sets the event or deadline that resumes this work."},
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
       "Keeps the pending infrastructure approval so work can resume after a decision."},
    # Emisar's own tools, which Ryker's server has offered since 2026-09-27.
    # Their lines carry Emisar's mark (`@emisar_tools`).
    "find_actions" =>
      {"Look up Emisar actions", "Emisar actions looked up",
       "Searches the actions Emisar can run with this environment's account."},
    "get_action" =>
      {"Read an Emisar action", "Emisar action read",
       "Reads one action's arguments, risk and runners."},
    "run_action" =>
      {"Ask Emisar to run an action", "Emisar run requested",
       "Emisar's policy decides whether it runs now or waits for a person's approval."},
    "wait_for_run" =>
      {"Wait for an Emisar run", "Emisar run checked",
       "Reads a run's state and output as Emisar reports it."},
    "list_runners" =>
      {"List Emisar runners", "Emisar runners listed",
       "Reads the runners this environment's Emisar account can use."},
    "list_packs" =>
      {"List Emisar packs", "Emisar packs listed", "Reads the action packs Emisar trusts."},
    "list_runbooks" =>
      {"List Emisar runbooks", "Emisar runbooks listed", "Reads the runbooks saved in Emisar."},
    "get_runbook" =>
      {"Read an Emisar runbook", "Emisar runbook read", "Reads one runbook's steps."},
    "recent_runs" =>
      {"Read recent Emisar runs", "Recent Emisar runs read",
       "Reads the runs Emisar carried out recently."},
    "get_operation" =>
      {"Look up an Emisar request", "Emisar request looked up",
       "Reads what became of a request whose answer was lost."},
    "cancel_run" =>
      {"Ask Emisar to stop a run", "Emisar stop requested",
       "Asks Emisar to cancel a run that has not finished."},
    "execute_runbook" =>
      {"Ask Emisar to run a runbook", "Emisar runbook requested",
       "Emisar's policy decides whether it runs now or waits for a person's approval."},
    "create_runbook_draft" =>
      {"Draft an Emisar runbook", "Emisar runbook drafted",
       "Saves a draft runbook in Emisar for a person to review."},
    "update_runbook_draft" =>
      {"Update an Emisar runbook draft", "Emisar runbook draft updated",
       "Changes a draft runbook in Emisar for a person to review."}
  }

  @emisar_tools ~w(find_actions get_action run_action wait_for_run list_runners list_packs list_runbooks get_runbook recent_runs get_operation cancel_run execute_runbook create_runbook_draft update_runbook_draft)
  @slack_tools ~w(list_slack_channels search_slack read_slack_source set_slack_reaction post_slack_message post_slack_update)
  @github_tools ~w(read_github_conversation search_github read_github_pull_request read_github_ci rerun_github_ci cancel_github_ci submit_github_review set_github_reaction)

  @doc """
  One step of a run of tool calls or status updates as one line: whose it
  was (`:emisar`, `:ryker`, `:slack`, `:github` or the `:workspace` the work
  runs in), its title, the fact that sets it apart (the search, the action,
  the command, the file), and its duration.
  """
  @spec line(map()) :: %{
          service: atom(),
          title: String.t(),
          detail: String.t() | nil,
          duration: String.t() | nil,
          failed: boolean()
        }
  def line(%{stage: "Status"} = step) do
    %{
      service: :slack,
      title: if(step.summary, do: "Status", else: step.title),
      detail: step.summary,
      duration: nil,
      failed: step.state == "failed"
    }
  end

  def line(step) do
    action = project(step)

    %{
      service: service(action),
      title: if(step.state == "started", do: "Started: " <> action.title, else: action.title),
      detail: line_detail(action),
      duration: step.duration_ms && Units.duration(step.duration_ms),
      failed: step.state in ["failed", "cancelled"]
    }
  end

  defp service(%{tool: tool}) when tool in @emisar_tools, do: :emisar
  defp service(%{tool: tool}) when tool in @slack_tools, do: :slack
  defp service(%{tool: tool}) when tool in @github_tools, do: :github
  defp service(%{kind: "ryker"}), do: :ryker
  defp service(_action), do: :workspace

  # A run request says which action ran where: cloud-init.log_tail ·
  # emisar-3hgr. Its reason is the opened card's to show (Andrew, 2026-09-28:
  # "should have not reason but runner name after it").
  defp line_detail(%{tool: "run_action", facts: facts}) do
    facts = Map.new(facts)

    [facts["Action"], facts["Runner"] || facts["Runners"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> String.slice(0, 160)
    |> case do
      "" -> nil
      detail -> detail
    end
  end

  # The one fact that tells a step from the ones around it, on one line. A
  # command's exit code is on its card; its line names the command.
  defp line_detail(action) do
    [
      for({label, value} <- action.facts, label != "Exit code", do: value),
      action.paths,
      action.description_detail,
      action.text
    ]
    |> List.flatten()
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> case do
      nil -> nil
      text -> text |> first_line() |> String.slice(0, 160)
    end
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

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
          <span :if={@step.duration_ms} class="action-duration">{Units.duration(@step.duration_ms)}</span>
        </:meta>
      </Components.card_heading>
      <pre :if={@action.kind == "command" && @action.description} class="action-command-line"><code>{@action.description}</code></pre>
      <p
        :if={@action.kind != "command" && @action.description && @step.state != "started"}
        class="action-description"
      >
        {@action.description}
      </p>
      <p
        :if={
          @action.kind == "command" && is_nil(@action.description) && is_nil(@action.withheld) &&
            @step.state != "started"
        }
        class="action-description"
      >
        The worker reported that a command ran, not which one.
      </p>
      <p :for={note <- @action.withheld || []} class="action-warning">{note}</p>
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
        {SlackMarkdown.html(@action.text)}
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
      <Components.disclosure
        :for={{artifact, index} <- Enum.with_index(@step.artifacts)}
        id={"tool-#{@step.id}-artifact-#{index}"}
        label={if artifact.label == "Arguments", do: "Raw arguments", else: artifact.label}
        class="action-raw"
        data-artifact={
          if artifact.artifact.state in [:collapsed, :retained], do: artifact[:artifact_id]
        }
        data-revoked={if artifact.artifact.state in [:expired, :not_recorded], do: "true"}
      >
        <:meta :if={artifact.artifact.truncated || artifact.artifact.state == :collapsed}>
          <span :if={artifact.artifact.truncated}>Partial display</span>
          <span :if={artifact.artifact.state == :collapsed}>{bytes(artifact.artifact.bytes)}</span>
        </:meta>
        <p :if={artifact.artifact.state == :collapsed} class="artifact-loading" role="status">
          Loading…
        </p>
        <p :if={artifact.artifact.state in [:expired, :not_recorded]} class="artifact-unavailable">
          This body is no longer retained.
        </p>
        <Components.copy_block :if={artifact.artifact.state == :retained}>
          <pre>{artifact.artifact.text}</pre>
        </Components.copy_block>
      </Components.disclosure>
    </div>
    """
  end

  def project(step) do
    input = artifact(step, "Arguments")
    args = if is_map(input["arguments"]), do: input["arguments"], else: input
    tool = input["tool"] || input["operation"]
    metadata = if input["server"] in ["controller-tools", "responder-state"], do: @tools[tool]

    {title, description, kind, symbol} = naming(metadata, step, args, tool)

    file = file_path(args, step.title)
    {paths, warning} = display_paths(step[:path_context], file)

    %{
      tool: tool,
      title: title,
      description: description,
      # A command or a search names itself in its description; that is the
      # detail its line shows.
      description_detail: if(kind in ~w(command search), do: description),
      kind: kind,
      symbol: symbol,
      paths: paths,
      warning: warning,
      text: readable_text(tool, args),
      facts: facts(tool, args) ++ exit_facts(step[:exit_code]),
      withheld: withheld_notes(step[:withheld], kind),
      groups: groups(tool, args),
      diff: string(args["diff"] || args["patch"])
    }
  end

  # A command that failed says how; one that succeeded needs no line for it.
  defp exit_facts(code) when is_integer(code) and code != 0, do: [{"Exit code", "#{code}"}]
  defp exit_facts(_code), do: []

  # What the worker withheld from this call, and why, one sentence a field.
  defp withheld_notes(%{} = withheld, kind) when map_size(withheld) > 0 do
    for {field, reason} <- Enum.sort(withheld) do
      "#{withheld_field(field, kind)} withheld: #{ToolActivity.reason_words(reason)}."
    end
  end

  defp withheld_notes(_withheld, _kind), do: nil

  defp withheld_field("input", "command"), do: "The command was"
  defp withheld_field("input", _kind), do: "Its arguments were"
  defp withheld_field("output", "command"), do: "What it printed was"
  defp withheld_field("output", _kind), do: "Its result was"
  defp withheld_field("title", _kind), do: "Its title was"
  defp withheld_field("content", _kind), do: "Its output was"
  defp withheld_field("locations", _kind), do: "The files it touched were"
  defp withheld_field(field, _kind), do: "Its #{String.replace(field, "_", " ")} was"

  defp naming({verb, completed, description}, step, _args, _tool),
    do: {if(step.state == "completed", do: completed, else: verb), description, "ryker", "◇"}

  # A shell step is a command whatever else the worker said about it: its
  # command, or why the worker withheld it.
  defp naming(nil, %{tool_kind: "execute"}, args, nil) do
    case args["command"] || args["cmd"] do
      command when is_binary(command) -> {"Run command", command, "command", ">_"}
      _withheld_or_unreported -> {"Run command", nil, "command", ">_"}
    end
  end

  # A tool this view has no words for is named by its own name, not "Tool call".
  defp naming(nil, step, args, tool) do
    case common_action(step, args) do
      {"Tool call", description, kind, symbol} when is_binary(tool) and tool != "" ->
        {tool |> String.replace(~r/[_.]+/, " ") |> String.capitalize(), description, kind, symbol}

      {"Tool call", description, _kind, _symbol} ->
        by_kind(step[:tool_kind], description)

      named ->
        named
    end
  end

  # The worker reports a code step's kind without its command or file, so a
  # step with nothing else to go on is named by its kind. The emisar task's
  # timeline had 55 lines reading only "Tool call".
  defp by_kind("execute", _description), do: {"Run command", nil, "command", ">_"}
  defp by_kind("think", _description), do: {"Think it through", nil, "tool", "◇"}
  defp by_kind("fetch", _description), do: {"Fetch a web page", nil, "tool", "◇"}
  defp by_kind("delete", _description), do: {"Delete files", nil, "edit", "±"}
  defp by_kind("move", _description), do: {"Move files", nil, "edit", "±"}
  defp by_kind(_kind, description), do: {"Tool call", description, "tool", "◇"}

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

  defp edit?(title, args) do
    String.starts_with?(title, ["Edit file", "Write file", "Apply patch"]) ||
      is_binary(args["diff"] || args["patch"])
  end

  defp readable_text("cite_source", args), do: string(args["observation"])
  defp readable_text("run_action", _args), do: nil

  defp readable_text("record_finding", args) do
    [string(args["what"]), string(args["reason"])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp readable_text("update_conversation_summary", %{"state" => state}) when is_map(state),
    do: string(state["situation"])

  defp readable_text(_, args) do
    string(
      args["reason"] || args["description"] || args["summary"] || args["context"] ||
        args["detail"]
    )
  end

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

  # The facts each tool's card lists, by argument and label; a tool without
  # its own list shows the ones most tools share.
  @fact_keys %{
    "cite_source" => [{"subject", "Subject"}, {"relation", "Relation"}, {"source_ref", "Source"}],
    "record_finding" => [{"status", "Conclusion"}, {"scope", "Scope"}],
    "plan_goal" => [
      {"requested_outcome", "Goal"},
      {"completion_contract", "Done when"},
      {"authority", "Allowed work"},
      {"writable_repository", "Writable project"}
    ],
    "update_conversation_summary" => [],
    "search_memory" => [{"query", "Search"}, {"kind", "Knowledge type"}],
    "update_goal" => [{"goal_id", "Goal"}, {"state", "Progress"}],
    "wait_for" => [
      {"deadline", "Wait until"},
      {"verification", "What to verify"},
      {"on_timeout", "If time runs out"}
    ],
    "get_action" => [{"action_id", "Action"}, {"pack_ref", "Pack"}],
    "find_actions" => [{"query", "Search"}]
  }
  @shared_fact_keys [
    {"title", "Title"},
    {"objective", "Objective"},
    {"query", "Search"},
    {"pattern", "Pattern"}
  ]

  defp fact_keys(tool), do: Map.get(@fact_keys, tool, @shared_fact_keys)

  # Andrew, 2026-09-28, of an Emisar run's card: it needs "Action, Pack,
  # Runner(s), Reason, Project and Expected outcome, evidence". The action's
  # own arguments, such as its project, read between where it ran and why.
  defp facts("run_action", args) do
    runners =
      for ref <- List.wrap(args["runner_refs"]), is_binary(ref), do: runner_name(ref)

    ([
       {"Action", string(args["action_id"])},
       {"Pack", args["pack_ref"] |> string() |> then(&(&1 && fact_value("pack_ref", &1)))},
       {Wording.word(length(runners), "Runner"), present_join(runners)}
     ] ++
       action_arguments(args["args"]) ++
       [
         {"Reason", string(args["reason"])},
         {"Expected outcome", string(args["expected"])},
         {"Evidence", string(args["evidence"])}
       ])
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
  end

  defp facts(tool, args) do
    for {key, label} <- fact_keys(tool),
        value = args[key],
        is_binary(value) && value != "",
        do: {label, fact_value(key, value)}
  end

  # A runner as Emisar names it to people: emisar-3hgr, without the key
  # fingerprint its ref carries after "~".
  defp runner_name(ref), do: ref |> String.split("~", parts: 2) |> hd()

  defp present_join([]), do: nil
  defp present_join(values), do: Enum.join(values, ", ")

  defp action_arguments(args) when is_map(args) do
    args
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, value} ->
      case argument_value(value) do
        nil -> []
        text -> [{argument_label(key), String.slice(text, 0, 300)}]
      end
    end)
  end

  defp action_arguments(_args), do: []

  defp argument_label(key),
    do: key |> to_string() |> String.replace(~r/[_.-]+/, " ") |> String.capitalize()

  defp argument_value(value) when is_binary(value) and value != "", do: value
  defp argument_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp argument_value(value) when value in [nil, "", [], %{}], do: nil
  defp argument_value(value), do: Jason.encode!(value)

  # A pack by its name and version, as Emisar lists it: cloud-init@0.1.19,
  # without the content digest it was pinned by.
  defp fact_value("pack_ref", value), do: value |> String.split("/sha256:", parts: 2) |> hd()
  defp fact_value(_key, value), do: value

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
    case Work.activity_paths(context) do
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
  defp bytes(count), do: Units.bytes(count)

  defp string(value) when is_binary(value), do: value
  defp string(_), do: nil
end
