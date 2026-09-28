defmodule Ryker.ControlPlane.RequestContextHTML do
  alias Ryker.ControlPlane.CallRun
  alias Ryker.ControlPlane.Components
  alias Ryker.ControlPlane.ConversationMemory
  alias Ryker.ControlPlane.Kit
  alias Ryker.ControlPlane.MemoryFormat
  alias Ryker.ControlPlane.PromptDocument
  alias Ryker.ControlPlane.RepositoryProjection
  alias Ryker.ControlPlane.SlackMarkdown
  alias Ryker.ControlPlane.SourceText
  alias Ryker.Slack.Names
  @moduledoc "Readable context derived only from an already sanitized inspection artifact."

  @sources %{
    "custom_instructions" =>
      {"Custom instructions", "policy", nil,
       "The global and channel text, scopes and revisions saved with this request, not today's settings. Empty text means no instruction at that scope."},
    "input" => {"Current message", "conversation", nil, nil},
    "slack_addressing" => {"How the message reached Ryker", "conversation", nil, nil},
    "inputs" => {"Conversation messages", "conversation", nil, nil},
    "current_inputs" =>
      {"New messages in this run", "conversation", nil,
       "Earlier runs remain in the session and are not sent again here."},
    "continuity" =>
      {"Conversation continuity", "memory", "Earlier accepted work",
       "The saved first input, previous delivery and host continuation request. Historical context does not prove current state."},
    "operator_context" =>
      {"Remembered context · potentially stale", "memory", "Scoped operator context",
       "Behavior guidance, retained memories and conversation summaries selected for this request. These do not grant authority."},
    "memory" =>
      {"Facts", "memory", "Scoped memory records",
       "Remembered facts and guidance supplied with this request; potentially stale, not current observations."},
    "records" =>
      {"Records from this work", "memory", "Request records",
       "Records selected from this request, with their saved source and identity fields."},
    "related_outcomes" =>
      {"Related outcomes", "memory", "Outcome recall",
       "Past outcomes selected as related history, not evidence of the current situation."},
    "prior_outcome" =>
      {"Previous accepted answer", "memory", "Earlier accepted work",
       "The delivery and submission reference from the previous run."},
    "candidates" =>
      {"Candidate selection", "memory", nil,
       "How Ryker filtered earlier work for this routing decision."},
    "controller_tools" =>
      {"Ryker state tools", "tools", "Host tool catalog",
       "Tools Ryker could use for this request. Listed here does not mean it used them."},
    "source_and_action_tools" =>
      {"Source and action tools", "tools", "Platform adapter",
       "Source access and platform actions offered for this request. Ryker still enforces what the request may do."},
    "workspace" =>
      {"Workspace access", "tools", "Bound worker workspace",
       "Workspace scope supplied to this request, not an inventory of tools the model actually used."},
    "repository_ref" =>
      {"Repository scope", "runtime", "Pinned work session",
       "The repository selected by the host for this session. Incoming text cannot widen it."},
    "destination" =>
      {"Reply destination", "runtime", "Authenticated conversation binding",
       "The transport, conversation and thread bound by the host, not a destination selected by the model."},
    "allowed_actions" =>
      {"Allowed admission actions", "runtime", "Ingress authority",
       "The admission choices allowed for this input. This is permission scope, not the model's decision."},
    "execution_mode" =>
      {"Live or shadow execution", "runtime", "Host execution mode",
       "The retained execution mode; shadow suppresses externally visible effects."},
    "mode" =>
      {"Context assembly mode", "runtime", "Work context compiler",
       "Full context or continuation into an existing session, as recorded when the request was built."},
    "offer_confirmation_supported" =>
      {"Offer confirmation", "runtime", "Platform capabilities",
       "Whether the bound platform supports host-confirmed task offers."},
    "linked_history_ref" =>
      {"Linked request history", "memory", "Request relationship",
       "An earlier request this one refers to. It does not reuse that request's permissions or destination."},
    "parent_submission_ref" =>
      {"Previous submission", "memory", "Work continuation",
       "The retained parent submission reference for this continuing run."},
    "conversation_observations" =>
      {"Conversation notes", "memory", nil,
       "Notes Ryker kept about earlier messages in this conversation. They are excerpts, not proof of current state."},
    "conversation_knowledge" =>
      {"Learned topics", "memory", nil,
       "Topics Ryker maintained from this conversation. Derived understanding that may be stale."},
    "conversation_feedback" =>
      {"Reactions to replies", "conversation", nil,
       "Emoji reactions people left on Ryker's earlier replies in this work."},
    "retained_cases" =>
      {"Similar past cases", "memory", nil, "Earlier cases recalled as worked examples."},
    "repository_knowledge" =>
      {"Repository knowledge", "memory", nil,
       "The saved knowledge document for the pinned repository."},
    "connected" =>
      {"Connected services", "tools", nil,
       "What this work was told is connected, and the repositories it can reach."},
    "repository_choices" =>
      {"Repositories to choose from", "tools", nil,
       "The repositories this request could be routed to work in."}
  }
  # Historical inspection keeps the label of the saved tool catalog; no execution
  # producer emits the old key.
  @sources Map.put(@sources, "responder_state_tools", @sources["controller_tools"])
  @order ~w(custom_instructions input slack_addressing inputs current_inputs conversation_feedback continuity operator_context conversation_observations conversation_knowledge records related_outcomes prior_outcome retained_cases repository_knowledge candidates controller_tools responder_state_tools source_and_action_tools workspace connected repository_choices repository_ref destination allowed_actions execution_mode mode offer_confirmation_supported linked_history_ref parent_submission_ref)
  @instruction_not_recorded :instruction_not_recorded
  # The evidence a self-analysis was given, under its prompt's `context`: what
  # the request was, what was said, what routing and Work did, what people
  # said about it, and what was left out (`Ryker.Improvement.Evidence`).
  @analysis_parts %{
    "request" =>
      {"The request", "conversation", "What kind of request it was, where, and how it ended."},
    "conversation" =>
      {"What was said", "conversation",
       "The person's messages and Ryker's answers, in order, as Ryker kept them."},
    "routing" =>
      {"Routing decisions", "memory",
       "What routing decided about each message. Each exact routing prompt is in the submitted prompt below."},
    "work" =>
      {"Work turns", "memory",
       "Each Work turn: how it ended, the tools it called and its answer."},
    "feedback" => {"Feedback", "conversation", "Everything people said or did about the answer."},
    "omitted" => {"Left out", "runtime", "Evidence the analysis did not get, and why."}
  }
  # What each tool a request could use is for, in a line an on-call engineer
  # reads without the tool's contract. The name stays beside it: the
  # timeline's tool steps show that name.
  @tool_descriptions %{
    "get_work_state" =>
      "Reads what this request has recorded so far, such as findings, goals and waits.",
    "cite_source" => "Saves where a piece of evidence came from, so the answer can point to it.",
    "record_finding" => "Records a conclusion of the investigation and the evidence behind it.",
    "request_input" => "Asks a person a question and waits for the answer.",
    "wait_for" => "Pauses the work until an event arrives or a deadline passes.",
    "list_automations" => "Lists the automations Ryker runs, such as scheduled checks.",
    "get_automation" => "Reads one automation and its recent runs.",
    "propose_automation" =>
      "Suggests a new or changed automation for a person to confirm before it runs.",
    "plan_goal" => "Adds a goal to the plan for this work, such as a change to make or a check.",
    "update_goal" => "Marks a planned goal as started, done or given up, with its evidence.",
    "request_task" =>
      "Proposes a task, such as a code change, for a person to approve before it starts.",
    "search_memory" =>
      "Searches what Ryker remembers: facts, guidance, earlier conversations and past cases.",
    "propose_memory" =>
      "Suggests a fact or piece of guidance to remember, for a person to confirm.",
    "propose_preference" => "Suggests a setting for how Ryker works, for a person to confirm.",
    "remember_answer" => "Saves a person's answer to a question so Ryker does not ask it again.",
    "update_conversation_summary" =>
      "Updates the saved summary of this conversation once the answer is accepted.",
    "record_feedback" =>
      "Notes a suggestion to improve Ryker itself, without changing the reply.",
    "validate_final" => "Checks the answer against Ryker's rules before it is sent.",
    "record_emisar_approval" =>
      "Notes that an Emisar action is waiting for approval, so the work resumes once it is decided.",
    "list_slack_channels" => "Lists the Slack channels Ryker can see.",
    "search_slack" => "Searches Slack messages Ryker is allowed to read.",
    "read_slack_source" => "Reads a Slack message, thread, channel, file or canvas in full.",
    "set_slack_reaction" => "Adds or removes an emoji reaction on a Slack message.",
    "post_slack_message" =>
      "Drafts an extra Slack message that a person confirms before it is posted.",
    "post_slack_update" =>
      "Posts a short update in this conversation right away, before the answer.",
    "read_github_conversation" => "Reads the GitHub issue or pull request this work is about.",
    "search_github" => "Searches issues and pull requests in a repository of this environment.",
    "read_github_pull_request" => "Reads one pull request in a repository of this environment.",
    "read_github_ci" => "Reads a GitHub Actions run and its jobs, with links to logs.",
    "rerun_github_ci" => "Reruns the failed jobs of a GitHub Actions run, when allowed.",
    "cancel_github_ci" => "Cancels a GitHub Actions run that is still going, when allowed.",
    "submit_github_review" => "Submits a review on a pull request, with inline comments.",
    "set_github_reaction" => "Adds an emoji reaction to a GitHub issue or comment."
  }
  @unapplied_instructions ["Not configured", "Not applicable", "Not recorded"]

  # Host-bound facts about the run. Each is one line of Run details rather than a
  # section of its own: a reader wants them together, and rarely.
  @run_details [
    {"destination", "Replies go to"},
    {"origins", "Conversations"},
    {"mode", "Context"},
    {"execution_mode", "Execution"},
    {"repository_ref", "Repository"},
    {"linked_history_ref", "Linked history"},
    {"parent_submission_ref", "Previous submission"},
    {"signals", "Alert signals"},
    {"offer_confirmation_supported", "Offer confirmation"},
    {"episode_title", "Request title"},
    {"now", "Routing time"},
    {"continuation_window_minutes", "Continuation window"}
  ]
  @run_keys Enum.map(@run_details, &elem(&1, 0))
  @permission_keys ~w(allowed_actions repository_source_kinds)
  @conversation_keys ~w(conversation_context context_manifest)
  @manifest_keys ~w(bytes cutoff included kind range requested root source_read)

  # The briefing's sections, in reading order. The prompt view names the same
  # sections, so a highlighted chunk always leads back to one briefing row.
  @briefing_groups [
    {"policy", "Custom instructions", "Settings captured for this model call."},
    {"conversation", "Messages", nil},
    {"summaries", "Summaries", "Saved summaries of this conversation."},
    {"history", "Related history", nil},
    {"memory", "Selected knowledge",
     "Earlier work, decisions and instructions recalled for this request."},
    {"tools", "Tools and workspace",
     "The capabilities and project context available to the model."},
    {"runtime", "Scope and permissions",
     "Where this run was bound and what the model was allowed to do."}
  ]
  @group_labels Map.new([{"instructions", "Instructions"} | @briefing_groups], fn
                  {group, label} -> {group, label}
                  {group, label, _description} -> {group, label}
                end)
  @group_order ~w(instructions policy conversation summaries history memory tools runtime)
  @part_order [
    "System prompt",
    "Global instructions",
    "Channel instructions",
    "Custom instructions",
    "Current message",
    "Conversation messages",
    "New messages in this run",
    "Source messages",
    "How the message reached Ryker",
    "Earlier messages",
    "Channel summary",
    "Thread summary",
    "Reactions to replies",
    "Continuation candidates",
    "Background matches",
    "Candidates",
    "Conversation continuity",
    "Conversation notes",
    "Learned topics",
    "Prior knowledge",
    "Guidance",
    "Facts",
    "Preferences",
    "Rules",
    "Records from this work",
    "Related outcomes",
    "Previous accepted answer",
    "Similar past cases",
    "Repository knowledge",
    "Connected services",
    "Repositories to choose from",
    "Ryker state tools",
    "Source and action tools",
    "Workspace access",
    "Permitted actions",
    "Run details",
    "Previous attempt error",
    "Topic being relearned",
    "Other fields"
  ]
  # Titles a dedicated row renders whether or not they carry anything; an empty
  # part with one of these titles is never given a second, generic row.
  @dedicated_rows [
    "Candidates",
    "Continuation candidates",
    "Background matches",
    "Current message",
    "Earlier messages",
    "Channel summary",
    "Thread summary",
    "Global instructions",
    "Channel instructions",
    "Permitted actions",
    "Run details",
    "Other fields"
  ]
  # Why a candidate row is empty. The search covers the message's own
  # conversation, or every public Slack channel Ryker joined in the workspace.
  @no_continuation "The search found no earlier work that was still active or had finished " <>
                     "within the continuation window."
  @no_background "The search found no earlier work that could only be linked as background: " <>
                   "nothing that finished earlier, was cancelled, or is tied to another repository."
  # Routing reads the same memory rows on every call, sent or not.
  @routing_memory [
    {"conversation_observations", "Conversation notes",
     "Ryker had no notes about earlier messages in this conversation."},
    {"conversation_knowledge", "Learned topics",
     "Ryker had not maintained any topics for this conversation."}
  ]
  # Rows the briefing shows even when their value is empty, because the empty
  # value is itself the finding: no channel instructions, no summary saved.
  @always_shown [
    "System prompt",
    "Global instructions",
    "Channel instructions",
    "Current message",
    "Earlier messages",
    "Channel summary",
    "Thread summary",
    "Permitted actions",
    "Run details",
    "Other fields"
  ]

  @doc "In-page links to the candidates from this exact retained routing briefing."
  def candidate_links(sections, prefix) do
    with %{artifact: %{state: :retained, truncated: false, text: text}} <-
           Enum.find(sections, &(&1.id == "context")),
         {:ok, %{"candidates" => candidates}} when is_list(candidates) <- Jason.decode(text) do
      for %{"episode_ref" => ref, "state" => state} = item <- candidates,
          is_binary(ref) and is_binary(state),
          into: %{},
          do:
            {ref,
             %{
               label: "Selected work",
               value: candidate_link_title(item),
               href: "#" <> candidate_anchor(prefix, ref),
               allowed_relations:
                 if(is_list(item["allowed_relations"]), do: item["allowed_relations"], else: [])
             }}
    else
      _ -> %{}
    end
  end

  defp candidate_link_title(%{"title" => title}) when is_binary(title) and title != "",
    do: title

  defp candidate_link_title(%{"first_message" => %{"text" => text}})
       when is_binary(text) and text != "",
       do: text |> String.split("\n", parts: 2) |> hd()

  defp candidate_link_title(_item), do: "Earlier work"

  defp candidate_anchor(prefix, ref) when is_binary(prefix) and is_binary(ref),
    do: prefix <> "-candidate-" <> Base.url_encode64(ref, padding: false)

  defp candidate_anchor(_prefix, _ref), do: nil

  @doc "The complete submitted components, grouped for reading without hiding source labels."
  def briefing(sections, kind, prefix, counts \\ %{}) do
    instructions = Enum.find(sections, &(&1.id == "instructions"))
    context = Enum.find(sections, &(&1.id == "context"))
    root = briefing_root(kind)

    [
      if(instructions,
        do:
          group(
            "Instructions",
            "How Ryker asked the model to work.",
            [
              assembly_instructions(instructions.artifact, prefix),
              if(kind == :learning and context,
                do: learning_instructions(context.artifact, prefix),
                else: []
              )
            ]
          ),
        else: []
      ),
      cond do
        is_nil(context) -> []
        kind == :improvement -> analysis_assembly(context.artifact, prefix, counts)
        true -> assembly(context.artifact, root, prefix, counts)
      end,
      # The output contract is shown once, under the retained submission it was
      # sent beside; repeating it above the prompt said the same thing twice.
      []
    ]
  end

  # Routing and work nest what they sent under one key; a learning pass sends
  # its parts at the top of the document.
  defp briefing_root(:admission), do: "$.context"
  defp briefing_root(:learning), do: "$"
  defp briefing_root(:improvement), do: "$.context"
  defp briefing_root(_work), do: "$.work"

  # What a retry was told about the attempt before it, and the topic a
  # relearning pass rebuilds: instructions Ryker added for this attempt.
  defp learning_instructions(%{state: :retained, truncated: false, text: text}, prefix) do
    case Jason.decode(text) do
      {:ok, %{} = context} ->
        [
          learning_part(
            "previous_attempt_error",
            context["previous_attempt_error"],
            {"Previous attempt error", "policy", nil,
             "What went wrong with the attempt before this one, as Ryker told the model."},
            prefix
          ),
          learning_part(
            "rebuild_target",
            context["rebuild_target"],
            {"Topic being relearned", "policy", nil,
             "The topic a person asked Ryker to relearn from messages they chose."},
            prefix
          )
        ]

      _unreadable ->
        []
    end
  end

  defp learning_instructions(_artifact, _prefix), do: []

  defp learning_part(_key, value, _metadata, _prefix) when value in [nil, %{}], do: []

  defp learning_part(key, value, metadata, prefix),
    do: source(key, "$." <> key, value, metadata, learning_part_body(key, value), prefix)

  defp learning_part_body("previous_attempt_error", %{"instruction" => instruction})
       when is_binary(instruction),
       do: ["<pre class=\"model-document-text\">", escape(instruction), "</pre>"]

  defp learning_part_body("rebuild_target", %{"topic_id" => id} = value) when is_binary(id) do
    [
      "<dl class=\"context-rows\">",
      context_row("Version", value["version"]),
      "</dl>",
      "<p><a href=\"",
      escape(ConversationMemory.topic_path(id)),
      "\">Open the topic →</a></p>"
    ]
  end

  defp learning_part_body(_key, value), do: fields(value, 0)

  @doc "The retained prompt and separately supplied output format, without rebuilding either."
  def submitted(sections, prefix, artifact_id \\ nil) do
    [
      "<p class=\"prompt-legend\">Provider-owned instructions and wrappers are not part of this record.</p>",
      Enum.map(
        [
          {"request", "Prompt text", "$.prompt"},
          {"contract", "Response format", "$.output_schema"}
        ],
        fn {id, title, path} ->
          case Enum.find(sections, &(&1.id == id)) do
            nil ->
              []

            section ->
              submitted_source(section.artifact, id, title, path, prefix, artifact_id)
          end
        end
      )
    ]
  end

  defp submitted_source(artifact, id, title, path, prefix, artifact_id) do
    state = artifact_availability(artifact)

    source(
      id,
      path,
      artifact.text,
      {title, "policy", nil, nil},
      case artifact.state do
        :retained when id == "request" -> PromptDocument.render(artifact, prefix <> "-document")
        :retained -> PromptDocument.formatted(artifact)
        :collapsed -> loading()
        _absent -> ["<p>", state, ". No reconstructed substitute is shown.</p>"]
      end,
      prefix,
      state: state,
      # Measured from the stored size, so the row shows the same figure before
      # its text loads and after, and the prompt is not loaded just to count it.
      estimate: if(is_integer(artifact.bytes), do: {:bytes, artifact.bytes}),
      loading: artifact.state == :collapsed,
      artifact: if(artifact.state == :collapsed, do: artifact_id),
      revoked: artifact.state in [:expired, :not_recorded]
    )
  end

  defp artifact_availability(%{state: :expired}), do: "Expired"
  defp artifact_availability(%{state: :not_recorded}), do: "Not recorded"
  defp artifact_availability(%{truncated: true}), do: "Partial display"
  defp artifact_availability(_), do: nil

  defp group(title, description, content, options \\ []),
    do: [
      "<section class=\"prompt-group\"",
      if(group_name = Keyword.get(options, :group),
        do: [" data-group=\"", escape(group_name), "\""],
        else: []
      ),
      "><header><h4>",
      title,
      "</h4>",
      if(description, do: ["<p>", description, "</p>"], else: []),
      "</header>",
      content,
      "</section>"
    ]

  @doc "A flat source inventory for the timeline, without a parent disclosure."
  def assembly(artifact, root, prefix, counts \\ %{})

  def assembly(%{state: :retained, truncated: false, text: text}, root, prefix, counts) do
    case Jason.decode(text) do
      {:ok, context} when is_map(context) -> assemble_context(context, root, prefix, counts)
      _ -> []
    end
  end

  def assembly(_, _, _, _), do: []

  # Every submitted value has one home: a row of its own, a line of Run details,
  # or Other fields. A part the model got nothing for keeps its row and says
  # why, so two briefings read the same way and nothing is hidden by absence.
  defp assemble_context(context, root, prefix, counts) do
    rows =
      context
      |> context_parts(root)
      |> Enum.filter(&row?/1)
      |> Enum.group_by(fn {key, _value, parent} -> row_group(key, parent) end)

    parts = root_parts(context, root)
    conversation = conversation_context(context, root)

    Enum.map(@briefing_groups, fn {group, title, description} ->
      entries = Map.get(rows, group, [])
      extra = group_extra(group, context, conversation, parts, root, prefix)
      absent = absent_rows(group, context, parts, root, prefix)

      if entries == [] and extra == [] and absent == [] do
        []
      else
        {title, description} =
          group_presentation(group, title, description, entries, conversation, counts)

        group(
          title,
          description,
          [Enum.map(entries, &assembled_source(&1, prefix, counts, context)), extra, absent],
          group: group
        )
      end
    end)
  end

  defp routing?(root), do: root == "$.context"

  # A self-analysis is sent the evidence about one request and none of the
  # parts routing and Work are briefed with, so its briefing has one group,
  # its parts in reading order. Routing's rows for parts it sends only when
  # full ("Not configured", "None") read here as missing (2026-09-28).
  @analysis_order ~w(request conversation routing work feedback omitted)

  defp analysis_assembly(%{state: :retained, truncated: false, text: text}, prefix, counts) do
    case Jason.decode(text) do
      {:ok, %{} = context} ->
        entries =
          for key <- @analysis_order,
              Map.has_key?(context, key),
              do: {key, context[key], "$.context"}

        group(
          "The evidence",
          "What the analysis was given about the request, as Ryker kept it.",
          [Enum.map(entries, &assembled_source(&1, prefix, counts, context))],
          group: "memory"
        )

      _unreadable ->
        []
    end
  end

  defp analysis_assembly(_artifact, _prefix, _counts), do: []

  defp absent_rows(group, context, parts, root, prefix) do
    dedicated =
      if routing?(root),
        do: @dedicated_rows ++ Enum.map(@routing_memory, &elem(&1, 1)),
        else: @dedicated_rows

    empty =
      parts
      |> Enum.filter(&(&1.group == group and &1.sent_empty? and &1.title not in dedicated))
      |> Enum.uniq_by(& &1.title)
      |> Enum.sort_by(& &1.rank)
      |> Enum.map(fn part ->
        absent_source(
          "empty",
          part.path,
          {part.title, part.origin},
          "None",
          "Sent to the model empty.",
          prefix
        )
      end)

    if(routing?(root), do: routing_absent(group, context, root, prefix), else: []) ++ empty
  end

  # Routing sends a part only when it has something in it. These rows keep the
  # briefing's shape and say what the model had instead.
  defp routing_absent("policy", context, root, prefix) do
    if Map.has_key?(context, "custom_instructions") do
      []
    else
      channel =
        if get_in(context, ["input", "source", "kind"]) == "slack",
          do: {"Not configured", instruction_hint("channel", "Not configured")},
          else: {"Not applicable", instruction_hint("channel", "Not applicable")}

      [
        {"global", {"Not configured", instruction_hint("global", "Not configured")}},
        {"channel", channel}
      ]
      |> Enum.map(fn {key, {status, hint}} ->
        absent_source(
          key,
          root <> ".custom_instructions." <> key,
          {instruction_title(key), "policy"},
          status,
          hint,
          prefix
        )
      end)
    end
  end

  defp routing_absent("history", context, root, prefix) do
    if blank?(context["candidates"]) do
      [
        {"continuation", "Continuation candidates", @no_continuation},
        {"context", "Background matches", @no_background}
      ]
      |> Enum.map(fn {kind, title, hint} ->
        absent_source(
          "candidates",
          root <> ".candidates." <> kind,
          {title, "memory"},
          "None",
          hint,
          prefix,
          "Candidates"
        )
      end)
    else
      []
    end
  end

  defp routing_absent("memory", context, root, prefix) do
    for {key, title, hint} <- @routing_memory, blank?(context[key]) do
      absent_source(key, root <> "." <> key, {title, "memory"}, "None", hint, prefix)
    end
  end

  defp routing_absent(_group, _context, _root, _prefix), do: []

  # A part with nothing to open is a row, not a disclosure: its status says
  # what the model had instead, and hovering the row says why.
  defp absent_source(key, path, {title, origin}, status, hint, prefix, part \\ nil) do
    [
      "<div class=\"ui-disclosure ui-disclosure-source prompt-source prompt-source-static prompt-source-absent\" id=\"",
      escape(prefix <> "-source-" <> Base.url_encode64(path, padding: false)),
      "\" data-source=\"",
      escape(key),
      "\" data-origin=\"",
      escape(origin),
      "\"",
      if(part, do: [" data-part=\"", escape(part), "\""], else: []),
      "><div class=\"prompt-source-row\" title=\"",
      escape(hint),
      "\"><span class=\"prompt-source-main\"><span class=\"prompt-source-title\">",
      escape(title),
      "</span></span><span class=\"ui-disclosure-meta\"><span class=\"prompt-source-status\">",
      escape(status),
      "</span></span></div></div>"
    ]
  end

  defp row?({key, value, parent}) do
    row_group(key, parent) in ~w(policy conversation history memory tools) and
      (instruction_parent?(parent) or not blank?(value))
  end

  defp row_group(_key, parent)
       when parent in [
              "$.work.custom_instructions",
              "$.context.custom_instructions",
              "$.custom_instructions"
            ],
       do: "policy"

  defp row_group(key, _parent)
       when key in @run_keys or key in @permission_keys or key in @conversation_keys,
       do: "runtime"

  defp row_group("candidates", _parent), do: "history"
  defp row_group(key, parent), do: key |> metadata(parent) |> elem(1)

  defp group_extra("conversation", context, conversation, parts, root, prefix),
    do: conversation_sources(context, conversation, parts, routing?(root), prefix)

  defp group_extra("summaries", _context, conversation, _parts, root, prefix),
    do: summary_sources(conversation, routing?(root), prefix)

  defp group_extra("runtime", context, _conversation, parts, root, prefix),
    do:
      [
        permitted_actions_source(context, allowed_rows(context), root, prefix),
        run_details_source(context, root, prefix),
        other_fields_source(Enum.filter(parts, &(&1.title == "Other fields")), root, prefix)
      ]
      |> Enum.reject(&(&1 == []))

  defp group_extra(_group, _context, _conversation, _parts, _root, _prefix), do: []

  @doc """
  Every part of a submitted prompt, attributed to the briefing row that shows it.

  Parts never nest and together hold every submitted value, so the prompt view
  can highlight one section at a time without leaving text unaccounted for.
  """
  def prompt_parts(document) when is_map(document) do
    document
    |> Enum.flat_map(fn
      {"instructions", value} ->
        [prompt_part("$.instructions", {"System prompt", "instructions", "policy"}, value)]

      {key, value} when key in ["context", "work"] and is_map(value) ->
        context_prompt_parts(value, "$." <> key)

      {key, value} ->
        member_parts(key, value, "$")
    end)
    |> finalize_parts()
  end

  defp context_prompt_parts(context, root),
    do: Enum.flat_map(context, fn {key, value} -> member_parts(key, value, root) end)

  defp root_parts(context, root), do: context |> context_prompt_parts(root) |> finalize_parts()

  # A section is "sent empty" only when all of its parts are empty; the current
  # message copy inside the conversation bundle can be null beside a real input.
  defp finalize_parts(parts) do
    empty =
      parts
      |> Enum.group_by(& &1.title, &blank?(&1.value))
      |> Map.new(fn {title, blanks} ->
        {title, title not in @always_shown and Enum.all?(blanks)}
      end)

    Enum.map(parts, &Map.put(&1, :sent_empty?, empty[&1.title]))
  end

  defp member_parts("custom_instructions", value, parent) when is_map(value) do
    path = field_path(parent, "custom_instructions")

    Enum.map(value, fn {scope, nested} ->
      prompt_part(field_path(path, scope), {instruction_title(scope), "policy", "policy"}, nested)
    end)
  end

  defp member_parts("operator_context", value, parent) when is_map(value) and value != %{} do
    path = field_path(parent, "operator_context")
    Enum.map(value, fn {key, nested} -> member_part(key, nested, path) end)
  end

  defp member_parts("conversation_context", %{"bundle" => bundle} = value, parent)
       when is_map(bundle) do
    path = field_path(parent, "conversation_context")

    Enum.flat_map(value, fn
      {"bundle", bundle} ->
        conversation_parts(bundle, field_path(path, "bundle"), parent)

      {"manifest", manifest} when is_map(manifest) ->
        manifest_parts(manifest, field_path(path, "manifest"))

      {"manifest", manifest} ->
        [earlier_part(field_path(path, "manifest"), manifest)]

      {key, nested} ->
        [other_part(field_path(path, key), nested)]
    end)
  end

  defp member_parts("conversation_context", value, parent) when is_map(value),
    do: conversation_parts(value, field_path(parent, "conversation_context"), parent)

  defp member_parts("context_manifest", value, parent) when is_map(value),
    do: manifest_parts(value, field_path(parent, "context_manifest"))

  defp member_parts(key, value, parent) when key in @conversation_keys,
    do: [earlier_part(field_path(parent, key), value)]

  defp member_parts("candidates", items, parent) when is_list(items) and items != [] do
    path = field_path(parent, "candidates")

    items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      title =
        if continuation_candidate?(item),
          do: "Continuation candidates",
          else: "Background matches"

      prompt_part("#{path}[#{index}]", {title, "history", "memory"}, item)
    end)
  end

  defp member_parts(key, value, parent), do: [member_part(key, value, parent)]

  defp member_part(key, value, parent),
    do: prompt_part(field_path(parent, key), part_section(key, parent), value)

  defp part_section(key, "$.custom_instructions"),
    do: {instruction_title(key), "policy", "policy"}

  defp part_section(key, _parent) when key in @permission_keys,
    do: {"Permitted actions", "runtime", "runtime"}

  defp part_section(key, _parent) when key in @run_keys,
    do: {"Run details", "runtime", "runtime"}

  defp part_section("candidates", _parent), do: {"Candidates", "history", "memory"}

  # Learning passes put their parts at the top of the document.
  defp part_section("inputs", "$"), do: {"Source messages", "conversation", "conversation"}
  defp part_section("knowledge", "$"), do: {"Prior knowledge", "memory", "memory"}

  defp part_section("previous_attempt_error", "$"),
    do: {"Previous attempt error", "instructions", "policy"}

  defp part_section("rebuild_target", "$"),
    do: {"Topic being relearned", "instructions", "policy"}

  # A self-analysis sends its evidence under `context` (`Ryker.Improvement.Prompt`).
  defp part_section(key, "$.context") when is_map_key(@analysis_parts, key) do
    {title, origin, _description} = @analysis_parts[key]
    {title, origin, origin}
  end

  defp part_section(key, parent) do
    case metadata(key, parent) do
      {title, origin, _owner, _description} when origin in ~w(policy conversation memory tools) ->
        {title, origin, origin}

      _unknown ->
        {"Other fields", "runtime", "runtime"}
    end
  end

  # The bundle's copy of the current message belongs with the message itself.
  defp conversation_parts(bundle, path, parent) do
    current = if parent == "$.context", do: "Current message", else: "Conversation messages"

    Enum.map(bundle, fn {key, value} ->
      case key do
        "current" ->
          prompt_part(field_path(path, key), {current, "conversation", "conversation"}, value)

        summary when summary in ~w(channel_summary thread_summary) ->
          summary_part(path, key, value)

        history when history in ~w(messages root) ->
          earlier_part(field_path(path, key), value)

        _unknown ->
          other_part(field_path(path, key), value)
      end
    end)
  end

  # How the earlier messages were selected belongs with them; a manifest key
  # this view does not know is not silently called an earlier message.
  defp manifest_parts(manifest, path) do
    Enum.map(manifest, fn {key, value} ->
      cond do
        key in ~w(channel_summary thread_summary) -> summary_part(path, key, value)
        key in @manifest_keys -> earlier_part(field_path(path, key), value)
        true -> other_part(field_path(path, key), value)
      end
    end)
  end

  defp other_part(path, value),
    do: prompt_part(path, {"Other fields", "runtime", "runtime"}, value)

  defp summary_part(path, key, value) do
    title = if key == "channel_summary", do: "Channel summary", else: "Thread summary"
    prompt_part(field_path(path, key), {title, "summaries", "conversation"}, value)
  end

  defp earlier_part(path, value),
    do: prompt_part(path, {"Earlier messages", "conversation", "conversation"}, value)

  defp prompt_part(path, {title, group, origin}, value) do
    %{
      path: path,
      title: title,
      group: group,
      group_label: @group_labels[group],
      origin: origin,
      value: value,
      bytes: value |> Jason.encode!() |> byte_size(),
      rank:
        {Enum.find_index(@group_order, &(&1 == group)) || 99,
         Enum.find_index(@part_order, &(&1 == title)) || 99}
    }
  end

  defp instruction_title("global"), do: "Global instructions"
  defp instruction_title("channel"), do: "Channel instructions"
  defp instruction_title(other), do: human(other) <> " instructions"

  defp continuation_candidate?(%{"allowed_relations" => relations}) when is_list(relations),
    do: "same_work" in relations

  defp continuation_candidate?(_item), do: false

  # Empty in substance: a map of empty lists says as little as an empty map.
  defp blank?(value) when value in [nil, "", [], %{}], do: true

  defp blank?(value) when is_map(value),
    do: Enum.all?(value, fn {_key, nested} -> blank?(nested) end)

  defp blank?(_value), do: false

  defp context_parts(context, root) do
    context
    |> Enum.sort_by(fn {key, _} -> {Enum.find_index(@order, &(&1 == key)) || 100, key} end)
    |> Enum.flat_map(&context_part(&1, root))
  end

  defp context_part({"operator_context", value}, root)
       when is_map(value) and map_size(value) > 0 do
    Enum.map(Enum.sort(value), fn {key, nested} ->
      {key, nested, root <> ".operator_context"}
    end)
  end

  # One collapsible per scope. A single "Custom instructions" block made a
  # reader open it to find out whether the channel had said anything.
  defp context_part({"custom_instructions", value}, root) when is_map(value),
    do: instruction_parts(value, root <> ".custom_instructions")

  defp context_part({key, value}, root), do: [{key, value, root}]

  defp assembled_source({key, value, parent}, prefix, counts, context) do
    path = field_path(parent, key)

    options =
      [count: row_count(key, value, counts)]
      |> instruction_options(key, parent, value)
      |> source_count_option(key, parent)

    cond do
      key == "candidates" and is_list(value) ->
        candidate_sources(value, path, prefix, counts)

      instruction_parent?(parent) and options[:state] in @unapplied_instructions ->
        absent_source(
          key,
          path,
          {instruction_title(key), "policy"},
          options[:state],
          instruction_hint(key, options[:state]),
          prefix
        )

      true ->
        source(
          key,
          path,
          value,
          source_metadata(key, parent, value),
          source_body(key, value, path, prefix, context),
          prefix,
          options
        )
    end
  end

  # A row of messages counts the messages it holds; the selection ledger behind
  # them stays in the request inspector.
  defp row_count(key, value, _counts) when key in ~w(inputs current_inputs),
    do: default_count(key, value)

  defp row_count(key, value, counts), do: Map.get(counts, key) || default_count(key, value)

  defp default_count("conversation_observations", items) when is_list(items),
    do: %{label: count(length(items), "source note"), known?: true}

  defp default_count("conversation_knowledge", items) when is_list(items),
    do: %{label: count(length(items), "topic"), known?: true}

  defp default_count("knowledge", items) when is_list(items),
    do: %{label: count(length(items), "topic"), known?: true}

  defp default_count(key, %{"items" => items}) when key in ~w(inputs current_inputs),
    do: default_count(key, items)

  defp default_count(key, items) when key in ~w(inputs current_inputs) and is_list(items),
    do: %{label: count(length(items), "message"), known?: true}

  defp default_count(_key, _value), do: nil

  # The current message is one message; a row of several says how many.
  defp source_count_option(options, "input", _parent), do: Keyword.delete(options, :count)

  defp source_count_option(options, "continuity", parent)
       when parent not in ["$.work.operator_context", "$.context.operator_context"],
       do: Keyword.delete(options, :count)

  defp source_count_option(options, _key, _parent), do: options

  # Counts belong to the rows they count: Earlier messages says how many, and a
  # section heading does not total them again.
  defp group_presentation("conversation", title, _description, _entries, _conversation, _counts),
    do: {title, nil}

  defp group_presentation("history", title, _description, _entries, _conversation, _counts),
    do: {title, "Earlier work this message may belong to."}

  defp group_presentation(_group, title, description, _entries, _conversation, _counts),
    do: {title, description}

  defp candidate_sources(items, path, prefix, counts) do
    {continuations, context_only} =
      Enum.split_with(items, fn
        %{"allowed_relations" => relations} when is_list(relations) -> "same_work" in relations
        _ -> false
      end)

    links = Map.get(counts, "candidate_episodes", %{})

    [
      candidate_group_source(
        "continuation_candidates",
        "Continuation candidates",
        "Still active, or finished within the continuation window.",
        continuations,
        links,
        path <> ".continuation",
        prefix
      ),
      candidate_group_source(
        "context_matches",
        "Background matches",
        "Finished earlier, cancelled, or tied to another repository.",
        context_only,
        links,
        path <> ".context",
        prefix
      )
    ]
  end

  defp candidate_group_source(key, title, _description, [], _links, path, prefix),
    do:
      absent_source(
        key,
        path,
        {title, "memory"},
        "None",
        if(key == "continuation_candidates", do: @no_continuation, else: @no_background),
        prefix
      )

  defp candidate_group_source(key, title, description, items, links, path, prefix) do
    source(
      key,
      path,
      items,
      {title, "memory", nil, nil},
      candidates(items, links, prefix),
      prefix,
      count: %{label: count(length(items), "candidate"), known?: true},
      doc: description,
      estimate: items
    )
  end

  defp instruction_parts(value, parent) do
    Enum.map(["global", "channel"], fn key ->
      {key, Map.get(value, key, @instruction_not_recorded), parent}
    end)
  end

  defp instruction_parent?(parent),
    do:
      parent in [
        "$.work.custom_instructions",
        "$.context.custom_instructions",
        "$.custom_instructions"
      ]

  defp conversation_sources(context, {bundle, manifest, bundle_path}, parts, routing?, prefix) do
    shown? = routing? or Enum.any?(parts, &(&1.title == "Earlier messages"))

    [
      if(shown?,
        do:
          earlier_messages_source(
            earlier_messages(context, bundle),
            manifest,
            bundle_path,
            prefix
          ),
        else: []
      )
    ]
    |> Enum.reject(&(&1 == []))
  end

  # Summaries are saved documents about the conversation, not its messages.
  # Until 2026-09-28 routing also captured a summary of the whole channel,
  # which nothing ever saved. A record that carries that slot shows what it
  # recorded; a newer record has no channel row at all.
  defp summary_sources({bundle, manifest, bundle_path}, routing?, prefix) do
    in_thread? = Map.has_key?(bundle, "root") or manifest["root"] not in [nil, "not_applicable"]

    [
      summary_source("channel", {bundle, manifest, bundle_path}, false, true, prefix),
      summary_source("thread", {bundle, manifest, bundle_path}, routing?, in_thread?, prefix)
    ]
    |> Enum.reject(&(&1 == []))
  end

  # A null context says no earlier messages were supplied; a manifest without
  # a bundle says they were counted but their bodies were not retained.
  defp earlier_messages(context, bundle) do
    cond do
      is_list(bundle["messages"]) ->
        bundle["messages"]

      Map.has_key?(context, "conversation_context") and blank?(context["conversation_context"]) ->
        []

      true ->
        nil
    end
  end

  defp earlier_messages_source([], manifest, bundle_path, prefix) do
    absent_source(
      "earlier_messages",
      bundle_path <> ".messages",
      {"Earlier messages", "conversation"},
      "None",
      earlier_messages_hint(manifest),
      prefix
    )
  end

  defp earlier_messages_source(messages, manifest, bundle_path, prefix) do
    source(
      "earlier_messages",
      bundle_path <> ".messages",
      messages,
      {"Earlier messages", "conversation", nil, nil},
      earlier_messages_body(messages, manifest),
      prefix,
      count: earlier_messages_count(messages, manifest),
      state: if(is_nil(messages), do: "Bodies not retained"),
      estimate: messages
    )
  end

  defp earlier_messages_hint(%{"requested" => requested}) when is_integer(requested),
    do: "Up to #{requested} earlier messages could be sent; this conversation had none before it."

  defp earlier_messages_hint(_manifest), do: "No earlier messages were sent."

  defp run_details_source(context, root, prefix) do
    present = Enum.filter(@run_details, fn {key, _label} -> Map.has_key?(context, key) end)

    if present == [] do
      []
    else
      exact = Map.new(present, fn {key, _label} -> {key, context[key]} end)

      summary =
        [run_value("mode", context["mode"]), run_value("destination", context["destination"])]
        |> Enum.reject(&(&1 in [nil, "None"]))
        |> Enum.join(" · ")

      source(
        "run_details",
        root <> ".run_details",
        exact,
        {"Run details", "runtime", nil, nil},
        [
          "<dl class=\"context-rows\">",
          Enum.map(present, fn {key, label} ->
            context_row(label, run_value(key, context[key]))
          end),
          "</dl>"
        ],
        prefix,
        doc: if(summary != "", do: summary),
        estimate: exact
      )
    end
  end

  defp run_value("destination", %{} = destination),
    do: place(destination["thread_ref"] || destination["conversation_ref"])

  defp run_value("origins", %{"conversations" => refs}) when is_list(refs) do
    case refs |> Enum.filter(&is_binary/1) |> Enum.map(&place/1) |> Enum.uniq() do
      [] -> "None"
      places -> Enum.join(places, ", ")
    end
  end

  defp run_value("mode", "full"), do: "Full context"
  defp run_value("mode", "continuation"), do: "Continues the previous run"

  defp run_value("signals", %{"active" => active, "terminal" => terminal} = signals)
       when is_integer(active) and is_integer(terminal) do
    cond do
      active == 0 and terminal == 0 -> "None"
      signals["all_terminal"] == true -> "#{terminal} resolved, none active"
      true -> "#{active} active · #{terminal} resolved"
    end
  end

  defp run_value("now", at) when is_binary(at), do: readable_candidate_time(at)

  defp run_value("continuation_window_minutes", minutes) when is_integer(minutes),
    do: "#{minutes} minutes"

  defp run_value("offer_confirmation_supported", true), do: "Supported"
  defp run_value("offer_confirmation_supported", false), do: "Not supported"
  defp run_value(_key, nil), do: "None"
  defp run_value(_key, value) when is_binary(value), do: human_value(value)
  defp run_value(_key, value), do: Jason.encode!(value)

  defp human_value(value) do
    if Regex.match?(~r/^[a-z]+(_[a-z]+)*$/, value), do: human(value), else: value
  end

  defp place(ref) when is_binary(ref), do: Names.destination(ref)
  defp place(_ref), do: "None"

  defp other_fields_source([], _root, _prefix), do: []

  defp other_fields_source(parts, root, prefix) do
    exact = Map.new(parts, &{&1.path, &1.value})

    source(
      "other_fields",
      root <> ".other_fields",
      exact,
      {"Other fields", "runtime", nil,
       "Sent to the model, but this view has no section for them yet."},
      [
        "<dl class=\"context-rows\">",
        Enum.map(parts, fn part ->
          [
            "<div><dt>",
            escape(part.path),
            "</dt><dd><pre>",
            escape(Jason.encode!(part.value, pretty: true)),
            "</pre></dd></div>"
          ]
        end),
        "</dl>"
      ],
      prefix,
      count: %{label: count(length(parts), "field"), known?: true},
      estimate: exact
    )
  end

  # Work keeps the bundle and its selection manifest together; routing submits
  # them as peers. Read the actual source shape without rewriting the raw view.
  defp conversation_context(
         %{"conversation_context" => %{"bundle" => bundle} = envelope},
         root
       )
       when is_map(bundle),
       do: {bundle, context_map(envelope["manifest"]), root <> ".conversation_context.bundle"}

  defp conversation_context(values, root),
    do:
      {context_map(values["conversation_context"]), context_map(values["context_manifest"]),
       root <> ".conversation_context"}

  defp context_map(value) when is_map(value), do: value
  defp context_map(_value), do: %{}

  defp earlier_messages_count(messages, _manifest) when is_list(messages),
    do: %{label: count(length(messages), "message"), known?: true}

  defp earlier_messages_count(nil, %{"included" => included}) when is_integer(included),
    do: %{label: "#{included} reported", known?: true}

  defp earlier_messages_count(nil, _manifest), do: nil

  defp earlier_messages_body(nil, manifest),
    do: [
      context_limit(manifest),
      "<p class=\"context-absent\">Message bodies were not retained in this context.</p>"
    ]

  defp earlier_messages_body(messages, manifest) do
    [context_limit(manifest), messages(%{"inputs" => messages}, :history)]
  end

  defp context_limit(manifest) do
    case manifest["requested"] do
      requested when is_integer(requested) and requested > 0 ->
        cutoff = readable_candidate_time(manifest["cutoff"])

        [
          "<p class=\"context-note\">Up to ",
          escape(requested),
          " earlier messages",
          if(cutoff, do: [" before ", escape(cutoff)], else: []),
          ".</p>"
        ]

      _ ->
        []
    end
  end

  # A saved summary opens; one that was missing or does not apply is a flat row
  # saying so. Routing leaves a missing summary out of the prompt entirely.
  defp summary_source(kind, {bundle, manifest, bundle_path}, routing?, applies?, prefix) do
    key = kind <> "_summary"
    title = human(kind) <> " summary"
    path = bundle_path <> "." <> key

    cond do
      bundle[key] not in [nil, %{}, ""] ->
        source(
          key,
          path,
          bundle[key],
          {title, "conversation", nil, nil},
          fields(bundle[key], 0),
          prefix,
          count: summary_coverage(bundle[key])
        )

      Map.has_key?(bundle, key) or Map.has_key?(manifest, key) ->
        absent_source(
          key,
          path,
          {title, "conversation"},
          summary_status(manifest[key]),
          summary_hint(manifest[key]),
          prefix
        )

      routing? and not applies? ->
        absent_source(
          key,
          path,
          {title, "conversation"},
          "Not applicable",
          "This message was not in a thread.",
          prefix
        )

      routing? ->
        absent_source(
          key,
          path,
          {title, "conversation"},
          "None saved",
          summary_reason("absent"),
          prefix
        )

      true ->
        []
    end
  end

  # A summary has no message count; how fresh it was and how far it reached are
  # what a reader weighs it by.
  defp summary_coverage(%{} = summary) do
    parts =
      [summary["freshness"], readable_candidate_time(summary["covered_through"])]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> nil
      [freshness, through] -> %{label: "#{freshness} · through #{through}", known?: true}
      [only] -> %{label: only, known?: true}
    end
  end

  defp summary_coverage(_summary), do: nil

  # The same situation reads the same whether the record kept its reason or
  # routing left the summary out.
  defp summary_status(%{"reason" => "absent"}), do: "None saved"
  defp summary_status(%{"reason" => "not_applicable"}), do: "Not applicable"
  defp summary_status(_recorded), do: "Not available"

  defp summary_hint(%{"reason" => reason}) when is_binary(reason), do: summary_reason(reason)
  defp summary_hint(_recorded), do: "No summary was available for this request."

  defp summary_reason("not_applicable"), do: "This summary did not apply to the conversation."
  defp summary_reason("after_cutoff"), do: "The summary was created after this request."
  defp summary_reason("absent"), do: "No summary had been saved for this conversation."
  defp summary_reason(reason), do: human(reason) <> "."

  defp permission_values(values), do: Map.take(values, @permission_keys)

  defp context_row(_label, nil), do: []
  defp context_row(_label, ""), do: []

  defp context_row(label, value),
    do: ["<div><dt>", escape(label), "</dt><dd>", escape(to_string(value)), "</dd></div>"]

  # One line per tool: its name, then what it is for. A tool this view has no
  # words for, such as one an older request listed, keeps its bare name
  # rather than an invented description.
  defp tools(tools) do
    [
      "<dl class=\"context-rows context-tools\">",
      Enum.map(tools, fn tool ->
        name = tool_name(tool)

        [
          "<div><dt><code>",
          escape(name),
          "</code></dt><dd>",
          escape(Map.get(@tool_descriptions, name, "")),
          "</dd></div>"
        ]
      end),
      "</dl>"
    ]
  end

  defp tool_name(%{"name" => name}) when is_binary(name), do: name
  defp tool_name(name) when is_binary(name), do: name
  defp tool_name(tool), do: Jason.encode!(tool)

  # The generic field dumper turned this into an alphabetised tree — Companions,
  # Freshness, Owner, Repositories, Fetched at, Name, Remote identity, Requested
  # revision, Resolved revision, Stale base revision, Stale base status,
  # Version, Workspace base revision — thirteen labels before the reader learns
  # which repository the model could see or whether it could write to it. Then
  # "Repository: primary" and "Companions: none" (Andrew, 2026-09-26): an
  # environment can hold several repositories, so each is a row of its own,
  # named, with whether the run could change it and how fresh it was.
  defp workspace(value, repository_ref) do
    primary = map_value(value["primary"])
    receipts = freshness_receipts(value)

    companions =
      for %{"name" => name} = companion when is_binary(name) <- List.wrap(value["companions"]),
          do: repository_row(name, [access(companion), freshness(receipts[name])])

    rows =
      [
        primary_row(primary, repository_ref, map_value(value["source"]), receipts["primary"])
        | companions
      ] ++ [context_row("Status", value["status"])]

    ["<dl class=\"context-rows\">", rows, "</dl>"]
  end

  # A session without a repository gets Coop's empty scratch folder, which
  # it names "primary"; that is not a repository a reader would recognise.
  # A request that recorded no repository reference is read by that name.
  defp primary_row(primary, repository_ref, source, receipt) do
    cond do
      primary == %{} ->
        []

      is_nil(repository_ref) or (repository_ref == :not_sent and primary["name"] == "primary") ->
        context_row("No repository", join_words(["An empty working folder", access(primary)]))

      true ->
        repository_row(primary["name"], [access(primary), revision(source), freshness(receipt)])
    end
  end

  defp repository_row(name, words) when is_binary(name) do
    case join_words(words) do
      nil -> []
      text -> context_row(name, capitalize_first(text))
    end
  end

  defp repository_row(_name, _words), do: []

  defp join_words(words) do
    case Enum.filter(words, &is_binary/1) do
      [] -> nil
      words -> Enum.join(words, " · ")
    end
  end

  defp capitalize_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp access(%{"read_only" => true}), do: "read only"
  defp access(%{"read_only" => false}), do: "can change"
  defp access(_repository), do: nil

  # "main at 92c952f7": the reader is checking which commit, not reading the
  # hash, and a branch reads by its name.
  defp revision(%{"selected_ref" => ref, "selected_commit" => commit})
       when is_binary(ref) and is_binary(commit),
       do: "#{branch(ref)} at #{String.slice(commit, 0, 8)}"

  defp revision(%{"selected_commit" => commit}) when is_binary(commit),
    do: String.slice(commit, 0, 8)

  defp revision(%{"default_ref" => ref, "default_commit" => commit})
       when is_binary(ref) and is_binary(commit),
       do: "#{branch(ref)} at #{String.slice(commit, 0, 8)}"

  defp revision(_source), do: nil

  defp branch("refs/heads/" <> name), do: name
  defp branch(ref), do: ref

  defp freshness_receipts(value) do
    for %{"name" => name} = receipt when is_binary(name) <-
          List.wrap(get_in(value, ["freshness", "repositories"])),
        into: %{},
        do: {name, receipt}
  end

  defp freshness(%{"stale_base_status" => "current", "fetched_at" => at}),
    do: "up to date as of #{readable_candidate_time(at)}"

  defp freshness(%{"stale_base_status" => "stale", "fetched_at" => at}),
    do: "behind its remote as of #{readable_candidate_time(at)}"

  defp freshness(%{"stale_base_status" => "unknown"}), do: "not checked against its remote"
  defp freshness(%{"stale_base_status" => "not_applicable"}), do: "a local copy with no remote"
  defp freshness(_receipt), do: nil

  defp map_value(value) when is_map(value), do: value
  defp map_value(_value), do: %{}

  # The routing choices ride on the row itself: all six, with the ones this
  # input did not allow marked, because a restriction explains a decision the
  # model could not make. The row opens only when it has more to say.
  defp permitted_actions_source(values, rows, root, prefix) do
    chips = action_chips(values["allowed_actions"])
    path = root <> ".allowed_actions"

    cond do
      chips == [] and rows == [] ->
        []

      rows == [] ->
        [
          "<div class=\"ui-disclosure ui-disclosure-source prompt-source prompt-source-static\" id=\"",
          escape(prefix <> "-source-" <> Base.url_encode64(path, padding: false)),
          "\" data-source=\"permitted_actions\" data-origin=\"runtime\"><div class=\"prompt-source-row\">",
          "<span class=\"prompt-source-main\"><span class=\"prompt-source-title\">Permitted actions</span>",
          chips,
          "</span></div></div>"
        ]

      true ->
        source(
          "permitted_actions",
          path,
          permission_values(values),
          {"Permitted actions", "runtime", nil, nil},
          ["<dl class=\"context-rows\">", rows, "</dl>"],
          prefix,
          inline: chips,
          estimate: nil
        )
    end
  end

  @routing_actions ~w(start_episode continue_episode reply quick_reply react ignore)

  defp action_chips(allowed) when is_list(allowed) and allowed != [] do
    choices =
      if Enum.all?(allowed, &(&1 in @routing_actions)), do: @routing_actions, else: allowed

    [
      "<span class=\"permitted-actions\">",
      Enum.map(choices, fn action ->
        permitted = action in allowed

        [
          "<span class=\"permitted-action\" data-permitted=\"",
          to_string(permitted),
          "\" title=\"",
          escape(action_hint(action, permitted)),
          "\">",
          escape(action_label(action)),
          if(permitted, do: [], else: "<span class=\"sr-only\"> (not permitted)</span>"),
          "</span>"
        ]
      end),
      "</span>"
    ]
  end

  defp action_chips(_allowed), do: []

  defp action_hint(action, permitted) do
    hint =
      case action do
        "start_episode" -> "Start new work for this message"
        "continue_episode" -> "Add this message to earlier work that is still open"
        "reply" -> "Answer in the conversation without starting work"
        "quick_reply" -> "Answer briefly itself, without starting work"
        "react" -> "Only add an emoji reaction"
        "ignore" -> "Do nothing"
        other -> human(other)
      end

    if permitted, do: hint, else: hint <> " (not permitted for this message)"
  end

  defp allowed_rows(values),
    do:
      Enum.reject(
        [context_row("Repository sources", word_list(values["repository_source_kinds"]))],
        &(&1 == [])
      )

  defp word_list(values) when is_list(values) and values != [],
    do: Enum.map_join(values, " · ", &human/1)

  defp word_list(_values), do: nil

  defp action_label("start_episode"), do: "Start work"
  defp action_label("continue_episode"), do: "Continue work"
  defp action_label("reply"), do: "Reply"
  defp action_label("quick_reply"), do: "Quick reply"
  defp action_label("react"), do: "React"
  defp action_label("ignore"), do: "Ignore"
  defp action_label(value), do: human(value)

  def assembly_instructions(%{state: :retained, text: text} = artifact, prefix) do
    source(
      "instructions",
      "$.instructions",
      text,
      {"System prompt", "policy", nil,
       if(artifact.truncated,
         do: "Partial display of the retained instruction field.",
         else: nil
       )},
      ["<pre class=\"model-document-text\">", escape(text), "</pre>"],
      prefix,
      state: if(artifact.truncated, do: "Partial display")
    )
  end

  def assembly_instructions(_, _), do: []

  defp context(context, root, prefix) do
    [
      "<div class=\"request-context-readable\">",
      context
      |> Enum.sort_by(fn {key, _} -> {Enum.find_index(@order, &(&1 == key)) || 100, key} end)
      |> Enum.map(fn {key, value} ->
        path = field_path(root, key)

        source(
          key,
          path,
          value,
          metadata(key, root),
          source_body(key, value, path, prefix, context),
          prefix
        )
      end),
      "</div>"
    ]
  end

  defp metadata(key, root)
       when root in [
              "$.work.custom_instructions",
              "$.context.custom_instructions",
              "$.custom_instructions"
            ] do
    case key do
      "global" ->
        {"Global instructions", "policy", "Configured in Settings", nil}

      "channel" ->
        {"Channel instructions", "policy",
         "Adds channel guidance; wins only when the two conflict", nil}

      other ->
        {human(other) <> " instructions", "policy", "Text at send time", nil}
    end
  end

  defp metadata(key, root)
       when root in ["$.work.operator_context", "$.context.operator_context"] do
    case key do
      "continuity" ->
        {"Conversation notes", "memory", "Selected notes, topics and earlier work",
         "Source notes, maintained topics and conversation summaries selected for this request. These describe what was known then, not verified current state."}

      "preferences" ->
        {"Preferences", "memory", "Confirmed behavior settings",
         "The effective preferences retained for this operator and conversation."}

      "guidance" ->
        {"Guidance", "memory", "Scoped guidance records",
         "Operator-confirmed guidance selected for the bound scope; it cannot widen tool authority."}

      "standing_assignments" ->
        {"Rules", "memory", "Confirmed assignment records",
         "The standing assignment context selected for this request, not a new authorization."}

      _ ->
        metadata(key, nil)
    end
  end

  # A learning pass's parts, at the top of its prompt.
  defp metadata("inputs", "$"),
    do:
      {"Source messages", "conversation", nil,
       "The messages this learning pass read, in the order they were sent."}

  defp metadata("knowledge", "$"),
    do:
      {"Prior knowledge", "memory", nil,
       "Topics Ryker already kept that these messages might change, as they stood then."}

  # Shown with the instructions, never as a row of what the model was given.
  defp metadata(key, "$") when key in ~w(previous_attempt_error rebuild_target),
    do: {human(key), "instructions", nil, nil}

  defp metadata(key, "$.context") when is_map_key(@analysis_parts, key) do
    {title, origin, description} = @analysis_parts[key]
    {title, origin, nil, description}
  end

  defp metadata(key, _root),
    do:
      Map.get(
        @sources,
        key,
        {field_label(key), "other", "Additional retained field",
         "This field was present in the retained request. More specific provenance was not recorded by this viewer."}
      )

  defp source_metadata(key, parent, value) when key in ["global", "channel"] do
    if instruction_parent?(parent),
      do: instruction_metadata(key, value),
      else: metadata(key, parent)
  end

  defp source_metadata(key, parent, _value), do: metadata(key, parent)

  defp instruction_metadata("global", @instruction_not_recorded),
    do: {"Global instructions", "policy", nil, nil}

  defp instruction_metadata("global", _value),
    do: {"Global instructions", "policy", nil, nil}

  defp instruction_metadata("channel", @instruction_not_recorded),
    do: {"Channel instructions", "policy", nil, nil}

  defp instruction_metadata("channel", nil),
    do: {"Channel instructions", "policy", nil, nil}

  defp instruction_metadata("channel", _value),
    do: {"Channel instructions", "policy", nil, nil}

  # One instruction scope: its identity on a line, then the text itself.
  defp instruction_scope(%{} = layer, key) do
    text = layer["text"]

    identity = instruction_identity(key, layer["revision"], text)

    [
      if(identity == "",
        do: [],
        else: ["<p class=\"instruction-identity\">", escape(identity), "</p>"]
      ),
      instruction_text(text, key)
    ]
  end

  defp instruction_identity(_key, _revision, text) when text in [nil, ""], do: ""

  defp instruction_identity(key, revision, _text) do
    source = if key == "global", do: "From Settings", else: "From Slack channel"
    revision = if revision in [nil, ""], do: nil, else: "Revision #{revision}"

    [source, revision]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp instruction_text(text, _key) when is_binary(text) and text != "",
    do: ["<pre class=\"model-document-text\">", escape(text), "</pre>"]

  defp instruction_text(_text, "channel"),
    do: [
      "<p class=\"context-absent\">No channel instructions were saved for this Slack channel when this request ran.</p>"
    ]

  defp instruction_text(_text, _key),
    do: [
      "<p class=\"context-absent\">No global instructions were saved in Settings when this request ran.</p>"
    ]

  def instruction_layers(value) when is_map(value) do
    Enum.map([{"global", "Global instructions"}, {"channel", "Channel instructions"}], fn {key,
                                                                                           label} ->
      [
        "<section class=\"instruction-layer\"><h4>",
        label,
        "</h4>",
        fields(value[key], 0),
        "</section>"
      ]
    end)
  end

  # The workspace names the session's repository as its working copy, so it
  # is read beside the repository the request was bound to.
  defp source_body("workspace", value, _path, _prefix, context)
       when is_map(value) and map_size(value) > 0,
       do: workspace(value, Map.get(context, "repository_ref", :not_sent))

  defp source_body(key, value, path, prefix, _context), do: body(key, value, path, prefix)

  defp body("request", value, "$.context.request", _prefix) when is_map(value),
    do: analysis_request(value)

  defp body(key, items, "$.context." <> key, _prefix)
       when key in ~w(conversation routing work feedback) and is_list(items),
       do: analysis_items(key, Enum.filter(items, &is_map/1))

  defp body("omitted", items, "$.context.omitted", _prefix) when is_list(items),
    do: analysis_omitted(Enum.filter(items, &is_binary/1))

  defp body("inputs", value, "$.inputs", _prefix) when is_list(value),
    do: messages(%{"inputs" => value}, :learning)

  defp body("knowledge", items, "$.knowledge", _prefix) when is_list(items),
    do: topics(items)

  defp body(key, value, _path, _prefix)
       when key in ~w(input inputs current_inputs) and (is_map(value) or is_list(value)),
       do: messages(%{key => value})

  defp body("conversation_observations", items, _path, _prefix) when is_list(items),
    do: recall(%{"observations" => items})

  defp body("conversation_knowledge", items, _path, _prefix) when is_list(items),
    do: recall(%{"knowledge" => items})

  defp body("candidates", value, _path, prefix) when is_list(value) and value != [],
    do: candidates(value, %{}, prefix)

  defp body(key, tools, _path, _prefix)
       when key in ~w(controller_tools responder_state_tools source_and_action_tools) and
              is_list(tools) and
              tools != [],
       do: tools(tools)

  defp body(key, value, path, _prefix)
       when key in ~w(global channel) and is_map(value) do
    if String.contains?(path, ".custom_instructions."),
      do: instruction_scope(value, key),
      else: fields(value, 0)
  end

  defp body("channel", nil, path, _prefix) do
    if String.contains?(path, ".custom_instructions."),
      do: [
        "<p class=\"context-absent\">This request did not come through Slack, so channel instructions did not apply.</p>"
      ],
      else: fields(nil, 0)
  end

  defp body(key, @instruction_not_recorded, path, _prefix) when key in ~w(global channel) do
    if String.contains?(path, ".custom_instructions."),
      do: [
        "<p class=\"context-absent\">Instruction availability was not recorded for this older request.</p>"
      ],
      else: fields(@instruction_not_recorded, 0)
  end

  defp body("custom_instructions", value, _path, _prefix) when is_map(value),
    do: instruction_layers(value)

  defp body("operator_context", value, path, prefix) when is_map(value) and map_size(value) > 0,
    do: context(value, path, prefix)

  defp body("continuity", value, path, _prefix) when is_map(value) do
    if String.contains?(path, ".operator_context."),
      do: [
        recall(value),
        Components.disclosure_html(
          "Exact component",
          ["<pre>", escape(Jason.encode!(value, pretty: true)), "</pre>"],
          class: "context-inline-disclosure"
        )
      ],
      else: fields(value, 0)
  end

  # Ryker's own Slack ID rides along so the model knows its mention; it is the
  # same on every message and tells a reader nothing, so the card says only how
  # the message reached Ryker.
  defp body("slack_addressing", %{"audience" => audience}, _path, _prefix)
       when audience in ~w(direct mention ambient),
       do: ["<p>", escape(reached_ryker(audience)), "</p>"]

  defp body("related_outcomes", items, _path, _prefix) when is_list(items),
    do: outcomes(items)

  defp body("connected", value, _path, _prefix) when is_map(value), do: connected(value)

  defp body("repository_choices", items, _path, _prefix) when is_list(items),
    do: repository_choices(items)

  defp body(_key, value, _path, _prefix), do: fields(value, 0)

  # Each earlier outcome as what it was: what was asked, by whom and when,
  # what Ryker answered, and how it ended. Andrew, 2026-09-28: the row dumped
  # every stored field, "Not supplied", refs, Slack's block JSON and raw
  # timestamps, six outcomes some 19,000 pixels tall. The exact values stay in
  # the prompt text below the briefing.
  defp outcomes(items) do
    case Enum.filter(items, &is_map/1) do
      [] ->
        []

      items ->
        ["<section class=\"context-candidates\">", Enum.map(items, &outcome/1), "</section>"]
    end
  end

  defp outcome(item) do
    trigger = if is_map(item["trigger"]), do: item["trigger"], else: %{}
    asked = trigger |> get_in(["content", "text"]) |> present()
    answer = answer_text(item["result"])

    workspace = slack_workspace(trigger) || Names.workspace()

    [
      "<article class=\"context-candidate context-record context-outcome\"><header class=\"candidate-heading\"><h4>",
      if(asked,
        do: SlackMarkdown.mentions(first_line(asked), workspace),
        else: "Earlier request"
      ),
      "</h4>",
      finished(item["finished_at"]),
      "</header><div class=\"candidate-readable\">",
      candidate_outcome(ended(item)),
      "<dl class=\"candidate-messages\">",
      if(asked,
        do: [
          "<div><dt>Asked</dt><dd><div class=\"markdown-preview\">",
          SlackMarkdown.preview(asked, workspace),
          "</div><span class=\"candidate-message-meta\">",
          byline(who(trigger), readable_candidate_time(trigger["occurred_at"])),
          "</span></dd></div>"
        ],
        else: []
      ),
      if(answer,
        do: [
          "<div><dt>Ryker answered</dt><dd class=\"markdown-preview\">",
          SlackMarkdown.preview(answer, workspace),
          "</dd></div>"
        ],
        else: []
      ),
      "</dl></div></article>"
    ]
  end

  defp answer_text(%{"message" => message}), do: present(message)
  defp answer_text(_result), do: nil

  defp finished(at) do
    case readable_candidate_time(at) do
      nil -> []
      at -> ["<time>finished ", escape(at), "</time>"]
    end
  end

  defp ended(%{"state" => "blocked", "blocker" => blocker}) when is_binary(blocker),
    do: "Stopped: " <> blocker

  defp ended(%{"state" => "blocked"}), do: "Stopped before it finished"
  defp ended(%{"verified" => true}), do: "Finished, with its result checked"
  defp ended(_outcome), do: "Finished"

  # What the work was told is connected, in words, with each repository by the
  # name people know it by rather than its ref.
  defp connected(value) do
    services =
      for {key, label} <- [{"slack", "Slack"}, {"github", "GitHub"}, {"emisar", "Emisar"}],
          value[key] == true,
          do: label

    repositories = value["repositories"] |> List.wrap() |> Enum.filter(&is_binary/1)
    names = if repositories == [], do: %{}, else: repository_names()

    [
      "<p>",
      if(services == [],
        do: "Slack, GitHub and Emisar were not connected.",
        else:
          escape(sentence(services)) <>
            " " <> if(length(services) == 1, do: "was", else: "were") <> " connected."
      ),
      "</p>",
      if(repositories == [],
        do: [],
        else: [
          "<p>Repositories it can reach: ",
          repositories |> Enum.map(&Map.get(names, &1, &1)) |> Enum.map_join(", ", &escape/1),
          "</p>"
        ]
      )
    ]
  end

  # Without the database the briefing still reads, naming repositories by ref.
  defp repository_names do
    RepositoryProjection.names()
  rescue
    _error in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] -> %{}
  end

  defp repository_choices(items) do
    names =
      for item <- items,
          is_map(item),
          name = present(item["description"]) || present(item["ref"]),
          do: name

    ["<ul class=\"context-list\">", Enum.map(names, &["<li>", escape(&1), "</li>"]), "</ul>"]
  end

  # The request a self-analysis looked at, in words.
  defp analysis_request(value) do
    [
      "<dl class=\"context-rows\">",
      context_row("Kind", analysis_kind(value["kind"])),
      context_row("Where", present(value["channel"])),
      context_row("How it ended", value["state"] |> present() |> human_or_nil()),
      context_row(
        "Why it was analyzed",
        value["negative_feedback"]
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&human/1)
        |> word_list()
      ),
      "</dl>"
    ]
  end

  defp analysis_kind("work"), do: "A request Ryker worked on"
  defp analysis_kind("quick_reply"), do: "A message routing answered itself"
  defp analysis_kind(_kind), do: nil

  defp human_or_nil(nil), do: nil
  defp human_or_nil(value), do: human(value)

  defp analysis_items(_key, []), do: ["<p>None.</p>"]

  defp analysis_items(key, items) do
    workspace = Names.workspace()

    [
      "<section class=\"context-candidates\">",
      Enum.map(items, &analysis_item(key, &1, workspace)),
      "</section>"
    ]
  end

  defp analysis_item("conversation", item, workspace) do
    text = present(item["text"])

    analysis_card(
      analysis_from(item["from"]),
      item["at"],
      [
        if(text,
          do: [
            "<div class=\"markdown-preview\">",
            SlackMarkdown.preview(text, workspace),
            "</div>"
          ],
          else: ["<p>", escape(analysis_note(item["note"])), "</p>"]
        )
      ]
    )
  end

  defp analysis_item("routing", item, workspace) do
    analysis_card(
      "Routing: " <> (item["decision"] |> present() |> human_or_nil() || "no decision kept"),
      item["message_at"],
      [
        "<dl class=\"context-rows\">",
        context_row("Model", present(item["model"])),
        context_row("Prompt", analysis_prompt(item)),
        "</dl>",
        analysis_answer("Answer", item["answer"], workspace)
      ]
    )
  end

  defp analysis_item("work", item, workspace) do
    tools =
      for %{"tool" => tool} = call <- List.wrap(item["tools"]), is_binary(tool) do
        tool <> if(is_binary(call["status"]), do: " · " <> call["status"], else: "")
      end

    analysis_card(
      "Work: " <> ((present(item["outcome"]) || present(item["status"]) || "unknown") |> human()),
      item["started_at"],
      [
        "<dl class=\"context-rows\">",
        context_row("Model", present(item["model"])),
        context_row("Error", item["error"] |> present() |> human_or_nil()),
        context_row("Tools", if(tools != [], do: Enum.join(tools, ", "))),
        "</dl>",
        analysis_answer("Answer", item["answer"], workspace)
      ]
    )
  end

  defp analysis_item("feedback", item, workspace) do
    heading =
      [present(item["kind"]) && human(item["kind"]), present(item["value"])]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    analysis_card(
      if(heading == "", do: "Feedback", else: heading),
      item["at"],
      [
        "<dl class=\"context-rows\">",
        context_row("By", present(item["by"])),
        context_row("Why", present(item["note"])),
        "</dl>",
        analysis_answer("Their words", item["message"], workspace)
      ]
    )
  end

  # Why a message's words or a routing prompt were not in the evidence, in
  # words; the values are the ones `Ryker.Improvement.Evidence` records.
  defp analysis_note("deleted by the person"),
    do: "Deleted by the person; its words are not kept."

  defp analysis_note("edited by the person"),
    do: "Changed by the person; the words it had first are not kept."

  defp analysis_note("expired"), do: "Its words expired under retention."
  defp analysis_note(note), do: present(note) || "No words kept."

  defp analysis_prompt(%{"prompt" => prompt}) when is_binary(prompt), do: "Sent in full"

  defp analysis_prompt(%{"kept" => "forgotten"}),
    do: "Not sent: it quoted words that were later changed, deleted or forgotten"

  defp analysis_prompt(%{"kept" => "expired"}), do: "Not sent: retention removed it"
  defp analysis_prompt(%{"kept" => "left out for length"}), do: "Left out for length"
  defp analysis_prompt(_item), do: "Not sent"

  defp analysis_card(title, at, body) do
    [
      "<article class=\"context-candidate context-record\"><header class=\"candidate-heading\"><h4>",
      escape(title),
      "</h4>",
      case readable_candidate_time(at) do
        nil -> []
        time -> ["<time>", escape(time), "</time>"]
      end,
      "</header><div class=\"candidate-readable\">",
      body,
      "</div></article>"
    ]
  end

  defp analysis_answer(label, text, workspace) when is_binary(text) and text != "",
    do: [
      "<dl class=\"candidate-messages\"><div><dt>",
      escape(label),
      "</dt><dd class=\"markdown-preview\">",
      SlackMarkdown.preview(text, workspace),
      "</dd></div></dl>"
    ]

  defp analysis_answer(_label, _text, _workspace), do: []

  defp analysis_from("person"), do: "The person"
  defp analysis_from("ryker"), do: "Ryker"
  defp analysis_from("app"), do: "An app"
  defp analysis_from("bot"), do: "A bot"
  defp analysis_from("system"), do: "The system"
  defp analysis_from(_from), do: "Someone"

  defp analysis_omitted([]), do: ["<p>Nothing was left out.</p>"]

  defp analysis_omitted(items),
    do: ["<ul class=\"context-list\">", Enum.map(items, &["<li>", escape(&1), "</li>"]), "</ul>"]

  defp sentence([only]), do: only
  defp sentence([first, second]), do: first <> " and " <> second

  defp sentence(items),
    do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)

  defp reached_ryker("direct"), do: "A direct message to Ryker."
  defp reached_ryker("mention"), do: "The message mentions @Ryker."

  defp reached_ryker("ambient"),
    do: "Ryker read it in the channel. It was not a direct message or an @Ryker mention."

  defp recall(value) do
    Enum.map(~w(current related rollups observations knowledge), fn
      "observations" ->
        value["observations"] |> List.wrap() |> Enum.filter(&is_map/1) |> notes()

      group ->
        value[group]
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.map(fn item ->
          [
            "<section class=\"conversation-recall\" data-memory-kind=\"",
            group,
            "\"><h4 title=\"",
            escape(item["source_ref"]),
            "\">",
            escape(recall_title(group)),
            "</h4>",
            recall_fields(Map.get(item, "state", item)),
            "</section>"
          ]
        end)
    end)
  end

  # The topics a learning pass was offered: what each said then, its version,
  # and where it is kept now.
  defp topics([]), do: []

  defp topics(items) do
    [
      "<ol class=\"context-notes\">",
      items
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn item ->
        path = topic_path(item["source_ref"])

        [
          "<li class=\"context-note\" data-memory-kind=\"knowledge\" title=\"",
          escape(item["source_ref"]),
          "\"><p class=\"context-note-text\"><strong>",
          escape(present(item["title"]) || present(item["topic_key"]) || "Topic"),
          "</strong></p><p class=\"context-note-text\">",
          escape(present(item["summary"]) || "No summary was recorded."),
          "</p><p class=\"context-note-meta\">",
          if(is_integer(item["version"]),
            do: ["Version ", escape(item["version"])],
            else: []
          ),
          if(path,
            do: [
              if(is_integer(item["version"]), do: " · ", else: []),
              "<a href=\"",
              escape(path),
              "\">Open the topic →</a>"
            ],
            else: []
          ),
          "</p></li>"
        ]
      end),
      "</ol>"
    ]
  end

  defp topic_path("knowledge:" <> id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> ConversationMemory.topic_path(id)
      :error -> nil
    end
  end

  defp topic_path(_ref), do: nil

  # One entry per note: what was noted, then who and when. The row already says
  # these are source notes; a heading and a "Summary" label on each repeated it
  # five times for five one-line notes.
  defp notes([]), do: []
  defp notes(items), do: ["<ol class=\"context-notes\">", Enum.map(items, &note/1), "</ol>"]

  defp note(item) do
    meta = byline(who(item), readable_candidate_time(item["occurred_at"] || item["at"]))

    topics = item["topics"] |> List.wrap() |> Enum.filter(&is_binary/1)

    [
      "<li class=\"context-note\" data-memory-kind=\"observation\" title=\"",
      escape(item["source_ref"]),
      "\"><p class=\"context-note-text\">",
      note_text(item),
      "</p>",
      if(meta != [], do: ["<p class=\"context-note-meta\">", meta, "</p>"], else: []),
      if(topics != [],
        do: [
          "<ul class=\"context-note-topics\" aria-label=\"Topics\">",
          Enum.map(topics, &["<li>", escape(&1), "</li>"]),
          "</ul>"
        ],
        else: []
      ),
      "</li>"
    ]
  end

  # A person mentioned in a note reads as their name (Andrew, 2026-09-28:
  # "always render usernames and channel names, not Slack ids").
  defp note_text(item) do
    case present(item["summary"]) do
      nil -> "No summary was recorded."
      summary -> SlackMarkdown.mentions(summary, slack_workspace(item) || Names.workspace())
    end
  end

  defp recall_title("current"), do: "This conversation"
  defp recall_title("knowledge"), do: "Maintained topic"
  defp recall_title(group), do: human(group)

  defp recall_fields(state) when is_map(state) do
    Enum.map(
      [
        {"title", "Subject"},
        {"summary", "Summary"},
        {"goal", "Goal"},
        {"situation", "Last known situation"},
        {"open_loops", "Still open"},
        {"decisions", "Decisions"},
        {"unresolved_questions", "Questions"},
        {"active_topics", "Topics"},
        {"topics", "Topics"},
        {"topology", "Systems"},
        {"participants", "People"}
      ],
      fn {key, title} ->
        if state[key] in [nil, "", [], %{}],
          do: [],
          else: ["<div><h5>", title, "</h5>", recall_field(key, state[key]), "</div>"]
      end
    )
  end

  defp recall_fields(_),
    do:
      "<p>Saved summary is not structured. Its retained value is in the exact component below.</p>"

  # The people a conversation involved, as the model wrote them down: a Slack
  # ID or a mention there is the person, by name and linked to their profile.
  defp recall_field("participants", people) when is_list(people) do
    [
      "<ul>",
      Enum.map(people, fn
        person when is_binary(person) ->
          {:safe, html} = MemoryFormat.inline(person, Names.workspace())
          ["<li><p>", html, "</p></li>"]

        other ->
          ["<li>", fields(other, 1), "</li>"]
      end),
      "</ul>"
    ]
  end

  defp recall_field(_key, value), do: fields(value, 0)

  defp source(key, path, value, metadata, body, prefix, options \\ []) do
    {title, origin, _owner, description} = metadata
    settings = source_settings(value, options)
    count = Keyword.get(options, :count)

    Components.disclosure_html(title, [source_description(description), body],
      id: prefix <> "-source-" <> Base.url_encode64(path, padding: false),
      kind: :source,
      class: ["prompt-source", settings.state_override && "prompt-source-partial"],
      body_class: "prompt-source-body",
      open: settings.open,
      rest: %{
        "data-source" => key,
        "data-origin" => origin,
        "data-artifact" => settings.artifact,
        "data-revoked" => if(settings.revoked, do: "true")
      },
      label_content: [
        "<span class=\"prompt-source-main\"><span class=\"prompt-source-title\">",
        escape(title),
        "</span>",
        source_count(count),
        source_doc(Keyword.get(options, :doc)),
        Keyword.get(options, :inline, []),
        "</span>"
      ],
      meta: [
        # A body still loading has no value to judge as empty.
        if(Keyword.get(options, :loading, false),
          do: [],
          else: source_status(value, settings.state, settings.state_override)
        ),
        source_estimate(value, settings.state_override, settings.estimate)
      ]
    )
  end

  # A lazy body says it is loading with motion while it loads, not with a
  # standing disclaimer on the collapsed row.
  defp loading, do: "<p class=\"artifact-loading\" role=\"status\">Loading…</p>"

  defp source_settings(value, options) do
    state_override = Keyword.get(options, :state)

    %{
      artifact: Keyword.get(options, :artifact),
      estimate: if(Keyword.has_key?(options, :estimate), do: options[:estimate], else: value),
      open: Keyword.get(options, :open, false),
      revoked: Keyword.get(options, :revoked, false),
      state:
        state_override ||
          if(value in [nil, [], %{}, ""], do: "Empty in request", else: "Retained input"),
      state_override: state_override
    }
  end

  defp source_description(nil), do: []
  defp source_description(description), do: ["<p>", escape(description), "</p>"]

  # The counted summary a reader reads before opening anything. A count nobody
  # recorded says so; it never renders as a zero.
  defp source_count(%{label: label, known?: known?}) do
    [
      "<span class=\"prompt-source-count",
      if(known?, do: "", else: " prompt-source-count-unknown"),
      "\">",
      escape(label),
      "</span>"
    ]
  end

  defp source_count(_count), do: []

  # A one-line description a reader needs before deciding to open the source.
  defp source_doc(nil), do: []
  defp source_doc(doc), do: ["<span class=\"prompt-source-doc\">", escape(doc), "</span>"]

  defp source_status(value, state, override) do
    label =
      cond do
        is_binary(override) -> state
        value in [nil, [], %{}, ""] -> state
        true -> nil
      end

    if label, do: ["<span class=\"prompt-source-status\">", escape(label), "</span>"], else: []
  end

  defp source_estimate(_value, unavailable, _estimate)
       when unavailable in [
              "Expired",
              "Not recorded"
            ],
       do: []

  defp source_estimate(_value, _override, estimate) when estimate in [nil, ""], do: []

  defp source_estimate(_value, _override, estimate),
    do: [
      "<span class=\"prompt-source-estimate\" title=\"Estimated from the length of the text\">",
      estimated_tokens(estimate),
      "</span>"
    ]

  defp instruction_options(options, key, parent, value) when key in ["global", "channel"] do
    if instruction_parent?(parent) do
      case {key, value} do
        {_key, @instruction_not_recorded} ->
          options |> Keyword.put(:state, "Not recorded") |> Keyword.put(:estimate, nil)

        {"channel", nil} ->
          options |> Keyword.put(:state, "Not applicable") |> Keyword.put(:estimate, nil)

        {_key, %{"text" => text}} when is_binary(text) and text != "" ->
          options |> Keyword.put(:state, "Applied") |> Keyword.put(:estimate, text)

        _empty ->
          options |> Keyword.put(:state, "Not configured") |> Keyword.put(:estimate, nil)
      end
    else
      options
    end
  end

  defp instruction_options(options, _key, _parent, _value), do: options

  defp instruction_hint("channel", "Not applicable"),
    do: "This request did not come through Slack, so channel instructions did not apply."

  defp instruction_hint("channel", "Not configured"),
    do: "No channel instructions were saved for this Slack channel when this request ran."

  defp instruction_hint(_key, "Not recorded"),
    do: "Instruction availability was not recorded for this older request."

  defp instruction_hint(_key, _state),
    do: "No global instructions were saved in Settings when this request ran."

  # Provider totals are measured separately. Component counts are estimates over
  # the displayed, sanitized text, not fabricated provider tokenizer receipts.
  defp estimated_tokens({:bytes, bytes}) do
    count = ceil(bytes / 4)
    "≈ #{CallRun.delimit(count)} #{if count == 1, do: "token", else: "tokens"}"
  end

  defp estimated_tokens(value) do
    text = if is_binary(value), do: value, else: Jason.encode!(value)
    estimated_tokens({:bytes, byte_size(text)})
  end

  defp field_path(root, key) do
    if Regex.match?(~r/^[a-zA-Z_][a-zA-Z_0-9]*$/, key),
      do: root <> "." <> key,
      else: root <> "[" <> Jason.encode!(key) <> "]"
  end

  defp messages(context, kind \\ :current) do
    documents =
      [context["input"], context["inputs"], context["current_inputs"]] |> Enum.reject(&is_nil/1)

    Enum.map(documents, fn document ->
      {items, omitted} =
        case document do
          %{"items" => items} when is_list(items) ->
            {items, Map.get(document, "omitted_count", 0)}

          items when is_list(items) ->
            {items, 0}

          input when is_map(input) ->
            {[input], 0}

          _invalid ->
            {[], 0}
        end

      [
        if(kind == :history,
          do: "<section class=\"context-messages context-messages-history\">",
          else: "<section class=\"context-messages\">"
        ),
        Enum.map(items, &message(&1, length(items), kind)),
        if(is_integer(omitted) and omitted > 0,
          do: [
            "<p class=\"context-omission\">",
            escape(omitted),
            " earlier inputs were omitted by the submitted context budget.</p>"
          ],
          else: ""
        ),
        "</section>"
      ]
    end)
  end

  defp message(input, total, kind) when is_map(input) do
    actor = actor_label(input)
    body = message_text(input["content"] || input)
    context = message_context(input, kind)
    raw = Jason.encode!(input, pretty: true)
    title = if(total > 1 and kind not in [:history, :learning], do: context)

    Components.message_block_html(
      actor,
      if(body,
        do: message_body(body, input),
        else: "<p class=\"context-absent\">This source event has no text body.</p>"
      ),
      person: slack_person(input),
      class: "context-message",
      rest: %{"data-message-context" => context},
      title: title,
      meta:
        case message_at(input) do
          nil ->
            []

          at ->
            [
              "<time datetime=\"",
              escape(at),
              "\">",
              escape(readable_candidate_time(at)),
              "</time>"
            ]
        end,
      footer:
        Components.disclosure_html(
          "Details",
          [
            "<dl class=\"context-rows\">",
            message_detail("Source", message_source(input)),
            message_detail("Sender ID", message_sender(input)),
            message_detail("Attachments", attachments(input)),
            "</dl>",
            Components.disclosure_html(
              "Raw event (JSON)",
              ["<pre>", escape(raw), "</pre>"],
              class: "context-message-raw"
            )
          ],
          class: "context-message-details"
        )
    )
  end

  defp message(_input, _total, _kind), do: []

  # Routing reads each message as actor, at and text; Work keeps the full
  # document with its provenance. Both render as the same message.
  defp message_at(input), do: input["occurred_at"] || input["at"]

  defp message_context(_input, :history), do: "Earlier context"
  defp message_context(_input, :learning), do: "Source message"
  defp message_context(%{"current" => false}, _kind), do: "Earlier context"
  defp message_context(_input, _kind), do: "Current message"

  defp message_detail(_label, nil), do: []
  defp message_detail(_label, ""), do: []

  defp message_detail(label, value),
    do: ["<div><dt>", escape(label), "</dt><dd>", escape(value), "</dd></div>"]

  defp message_source(%{"source" => %{"kind" => "control_plane"}}), do: "Chat"
  defp message_source(%{"source" => %{"kind" => "slack"}}), do: "Slack"
  defp message_source(%{"source" => %{"kind" => "github"}}), do: "GitHub"
  defp message_source(%{"source" => %{"kind" => kind}}) when is_binary(kind), do: human(kind)
  defp message_source(_input), do: nil

  defp message_sender(%{"actor" => actor}) when is_binary(actor), do: actor

  defp message_sender(input) do
    actor = if is_map(input["actor"]), do: input["actor"], else: %{}
    actor["display_name"] || actor["name"] || actor["ref"] || input["actor_ref"]
  end

  # The files a message carried by name, so the card says which log or
  # screenshot it was and that one was refused (manual testing, 2026-09-26:
  # "1 attachment"); a platform's rich attachments have no name to give.
  defp attachments(input) do
    content = if is_map(input["content"]), do: input["content"], else: %{}
    files = content["files"] |> List.wrap() |> Enum.map(&file_label/1)
    rich = content["attachments"] |> List.wrap() |> length()
    parts = files ++ if(rich > 0, do: [count(rich, "attachment")], else: [])

    if parts != [], do: Enum.join(parts, ", ")
  end

  defp file_label(%{"transcript_unavailable" => note}) when is_binary(note), do: note

  defp file_label(%{"status" => "available", "name" => name, "transcript" => words})
       when is_binary(name) and is_binary(words),
       do: "#{name}, transcribed"

  defp file_label(%{"status" => "available", "name" => name}) when is_binary(name), do: name
  defp file_label(%{"status" => "unavailable"}), do: "a file Ryker could not read"
  defp file_label(_file), do: "a file"

  # A Slack person the one way every page shows one: their name, linked to
  # their Slack profile, never a raw ID (Andrew, 2026-09-26). A name kept with
  # the message stays that name. The message's source names the workspace; an
  # earlier message or a note kept without one is from the workspace Ryker
  # serves.
  defp slack_person(input) do
    actor = actor_map(input)
    ref = actor_ref(input, actor)

    if actor["kind"] in [nil, "user"] and Names.person_ref?(ref),
      do: kept_name(Names.person(slack_workspace(input) || Names.workspace(), ref), actor)
  end

  defp actor_map(%{"actor" => actor}) when is_map(actor), do: actor
  defp actor_map(_input), do: %{}

  defp actor_ref(%{"actor" => ref}, _actor) when is_binary(ref), do: ref
  defp actor_ref(input, actor), do: input["actor_ref"] || actor["ref"]

  defp kept_name(person, %{"display_name" => name}) when is_binary(name) and name != "",
    do: %{person | name: name}

  defp kept_name(person, %{"name" => name}) when is_binary(name) and name != "",
    do: %{person | name: name}

  defp kept_name(person, _actor), do: person

  # Who wrote a note or a message: a Slack person as above, anyone else as
  # their label says.
  defp who(input) do
    case slack_person(input) do
      nil ->
        escape(actor_label(input))

      person ->
        Kit.person_html(person)
    end
  end

  # "who · when", leaving out whichever is not known.
  defp byline(who, at) do
    [who, at && escape(at)]
    |> Enum.reject(&(&1 in [nil, "", []]))
    |> Enum.intersperse(" · ")
  end

  defp actor_label(%{"actor" => actor} = input) when is_binary(actor),
    do: input |> Map.delete("actor") |> Map.put("actor_ref", actor) |> actor_label()

  defp actor_label(input) do
    actor = if is_map(input["actor"]), do: input["actor"], else: %{}

    name = actor["display_name"] || actor["name"]
    actor_reference(input, actor, name)
  end

  defp actor_reference(_input, _actor, name) when is_binary(name) and name != "", do: name

  defp actor_reference(input, actor, _name) do
    ref = input["actor_ref"] || actor["ref"]

    case {slack_workspace(input), ref} do
      {workspace, ref} when is_binary(workspace) and is_binary(ref) ->
        Names.name(
          workspace,
          String.replace_prefix(ref, "slack:user:", "")
        )

      _ ->
        actor_name(ref, actor)
    end
  end

  defp slack_workspace(%{"source" => %{"kind" => "slack", "ref" => workspace}}), do: workspace

  defp slack_workspace(%{"content" => %{"source" => %{"kind" => "slack", "ref" => workspace}}}),
    do: workspace

  defp slack_workspace(_), do: nil

  defp message_body(body, input) do
    case slack_workspace(input) || compact_slack_workspace(input, body) do
      workspace when is_binary(workspace) ->
        SlackMarkdown.render(body, workspace)

      _ ->
        escape(body)
    end
  end

  # Routing reads earlier messages as actor, at and text alone. One that names
  # a person or a channel the way Slack writes them is from Slack, so it reads
  # in the installation's workspace: "@Ryker check health of our infra", never
  # "<@U0C1LCVNF52> check health…" (Andrew, 2026-09-28).
  defp compact_slack_workspace(%{"source" => _source}, _body), do: nil

  defp compact_slack_workspace(_input, body) do
    if Regex.match?(~r/<[@#][UWCGD][A-Z0-9]+(?:\|[^>]*)?>/, body), do: Names.workspace()
  end

  defp actor_name("slack:user:" <> _, _actor), do: "Slack user"
  defp actor_name("github:user:" <> _, _actor), do: "GitHub user"
  defp actor_name("ryker", _actor), do: "Ryker"
  defp actor_name("control_plane:user:" <> ref, actor), do: actor_name(ref, actor)
  defp actor_name("local-operator", _actor), do: "You"
  defp actor_name(name, _actor) when is_binary(name), do: name
  defp actor_name(_name, actor), do: human(actor["kind"] || "Source")

  defp message_text(%{"body" => text}) when is_binary(text), do: text

  defp message_text(%{} = value) do
    SourceText.from_content(value) ||
      Enum.find_value(~w(content comment review payload), fn key -> message_text(value[key]) end)
  end

  defp message_text(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> message_text(map)
      _text -> value
    end
  end

  defp message_text(_value), do: nil

  defp fields(value, depth) when is_map(value) and depth < 5 do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, nested} ->
      [
        "<div class=\"context-field\"><h4>",
        escape(field_label(key)),
        "</h4>",
        fields(nested, depth + 1),
        "</div>"
      ]
    end)
  end

  defp fields(value, depth) when is_list(value) and depth < 5 do
    [
      "<ul>",
      Enum.map(value, &["<li>", fields(&1, depth + 1), "</li>"]),
      "</ul>"
    ]
  end

  defp fields(value, _depth) when is_map(value) or is_list(value),
    do: ["<pre>", escape(Jason.encode!(value, pretty: true)), "</pre>"]

  defp fields(nil, _depth), do: "<p class=\"context-absent\">Not supplied</p>"
  defp fields(value, _depth), do: ["<p>", escape(value), "</p>"]

  defp candidates(items, links, prefix) when is_list(items) and items != [] do
    [
      "<section class=\"context-candidates\">",
      Enum.map(items, fn item ->
        href = if is_map(item), do: Map.get(links, item["episode_ref"])
        anchor = if is_map(item), do: candidate_anchor(prefix, item["episode_ref"])
        candidate(item, href, anchor)
      end),
      "</section>"
    ]
  end

  # The card shows exactly what the router read, in the order that helps:
  # the work's name, its last exchange, the opening message when it was sent,
  # and why it was offered.
  defp candidate(%{"state" => state} = item, href, anchor) when is_binary(state) do
    first = candidate_message(item["first_message"])
    latest = candidate_message(item["latest_message"])
    title = present(item["title"])
    heading = title || (first && first_line(first.text)) || "Untitled work"

    [
      "<article class=\"context-candidate context-record\"",
      if(anchor, do: [" id=\"", escape(anchor), "\" tabindex=\"-1\""], else: []),
      "><header class=\"candidate-heading\"><h4>",
      escape(heading),
      "</h4>",
      candidate_time(latest || first, item["idle_minutes"]),
      "</header><div class=\"candidate-readable\">",
      candidate_state_warning(state),
      candidate_outcome(item["outcome"]),
      candidate_messages(
        latest,
        # An opening message already shown whole as the heading is not repeated.
        if(first && first.text != heading, do: first),
        item["message_count"]
      ),
      candidate_evidence(item["evidence"]),
      episode_link(href),
      "</div></article>"
    ]
  end

  defp candidate(item, _history, _anchor) do
    [
      "<article class=\"context-candidate context-record context-candidate-malformed\"><p class=\"context-absent\">",
      "Historical candidate · retained shape unavailable",
      "</p>",
      retained_raw_candidate(item),
      "</article>"
    ]
  end

  defp candidate_message(%{"text" => text} = message) when is_binary(text),
    do: %{
      actor: message["actor"],
      at: message["at"],
      text: text,
      truncated: message["truncated"] == true
    }

  defp candidate_message(_message), do: nil

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd() |> bounded(160)

  # The router read the opening and latest messages shown on this card. The
  # rest of that episode is its own timeline, one link away, rather than
  # messages reproduced here that the model never read.
  defp episode_link(href) when is_binary(href),
    do: [
      "<a class=\"candidate-episode-link\" href=\"",
      escape(href),
      "\">Open request →</a>"
    ]

  defp episode_link(_href), do: []

  defp candidate_time(nil, _idle), do: []

  defp candidate_time(message, idle) do
    case readable_candidate_time(message.at) do
      nil ->
        []

      at ->
        ["<time>", escape(at), idle_label(idle), "</time>"]
    end
  end

  defp idle_label(minutes) when is_integer(minutes) and minutes >= 60 * 24,
    do: " · idle #{div(minutes, 60 * 24)} d"

  defp idle_label(minutes) when is_integer(minutes) and minutes >= 60,
    do: " · idle #{div(minutes, 60)} h"

  defp idle_label(minutes) when is_integer(minutes), do: " · idle #{minutes} min"
  defp idle_label(_minutes), do: []

  defp candidate_state_warning("cancelled"),
    do: "<p class=\"candidate-warning\">This work was cancelled.</p>"

  defp candidate_state_warning(_state), do: []

  defp candidate_outcome(outcome) when is_binary(outcome) and outcome != "",
    do: ["<p class=\"candidate-outcome\">", escape(outcome), "</p>"]

  defp candidate_outcome(_outcome), do: []

  defp candidate_evidence(labels) when is_list(labels) and labels != [],
    do: [
      "<p class=\"candidate-rationale\"><strong>Matched on</strong> ",
      labels |> Enum.filter(&is_binary/1) |> Enum.map_join(" · ", &escape/1),
      "</p>"
    ]

  defp candidate_evidence(_labels), do: []

  defp candidate_messages(nil, nil, _count), do: []

  defp candidate_messages(latest, opening, count) do
    [
      "<dl class=\"candidate-messages\">",
      candidate_message_row(latest_label(count), latest),
      candidate_message_row("Opening message", opening),
      "</dl>"
    ]
  end

  defp latest_label(count) when is_integer(count) and count > 1,
    do: "Latest of #{count} messages"

  defp latest_label(_count), do: "Latest message"

  defp candidate_message_row(_label, nil), do: []

  defp candidate_message_row(label, message) do
    [
      "<div><dt>",
      escape(label),
      "</dt><dd><p>",
      escape(message.text),
      if(message.truncated, do: " <span>(truncated)</span>", else: []),
      "</p><span class=\"candidate-message-meta\">",
      byline(
        if(is_binary(message.actor), do: who(%{"actor" => message.actor})),
        readable_candidate_time(message.at)
      ),
      "</span></dd></div>"
    ]
  end

  defp count(value, noun) when is_integer(value) and value >= 0,
    do: "#{value} #{noun}#{if value == 1, do: "", else: "s"}"

  defp count(_value, _noun), do: nil

  defp readable_candidate_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%d %b, %H:%M:%S UTC")
      _invalid -> bounded(value, 120)
    end
  end

  defp readable_candidate_time(_value), do: nil

  defp retained_raw_candidate(item) do
    encoded = if is_binary(item), do: item, else: Jason.encode!(item, pretty: true)
    encoded = bounded(encoded, 500)

    Components.disclosure_html("Retained raw candidate", ["<pre>", escape(encoded), "</pre>"],
      class: "context-candidate-raw context-inline-disclosure"
    )
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp bounded(value, limit) when is_binary(value), do: String.slice(value, 0, limit)

  # A retained field's name as a heading. The contract names a Work turn, an
  # episode and a receipt's owner; the reader knows a run, a request and who
  # recorded it.
  defp field_label("owner"), do: "Recorded by"
  defp field_label("host_continuation"), do: "Continuation"

  defp field_label(key) do
    key
    |> human()
    |> String.replace(~r/\bturn(s?)\b/, "run\\1")
    |> String.replace(~r/\bTurn(s?)\b/, "Run\\1")
    |> String.replace(~r/\bepisode(s?)\b/, "request\\1")
    |> String.replace(~r/\bEpisode(s?)\b/, "Request\\1")
    |> abbreviations()
  end

  # Capitalizing a key wrote "Sha256", "Json preview" and "Source url"; people
  # write these abbreviations one way.
  @abbreviations %{
    "api" => "API",
    "id" => "ID",
    "ids" => "IDs",
    "json" => "JSON",
    "pr" => "PR",
    "sha256" => "SHA-256",
    "url" => "URL",
    "urls" => "URLs"
  }

  defp abbreviations(label) do
    Regex.replace(~r/\b[A-Za-z0-9]+\b/, label, fn word ->
      Map.get(@abbreviations, String.downcase(word), word)
    end)
  end

  defp human(value) when is_map(value) or is_list(value), do: "Structured value"
  defp human(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp escape(value) when is_map(value) or is_list(value), do: escape(Jason.encode!(value))

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
