defmodule Ryker.ControlPlane.RequestContextHTML do
  alias Ryker.ControlPlane.PromptDocument
  alias Ryker.ControlPlane.SlackMarkdown
  alias Ryker.ControlPlane.SlackNames
  alias Ryker.ControlPlane.SourceText
  @moduledoc "Readable context derived only from an already sanitized inspection artifact."

  @sources %{
    "custom_instructions" =>
      {"Custom instructions", "policy", "Submitted settings",
       "The global and channel text, scopes and revisions saved with this request, not today's settings. Empty text means no instruction at that scope."},
    "input" =>
      {"Messages supplied to this request", "conversation", "Incoming message",
       "The message that started this routing call."},
    "slack_addressing" =>
      {"Who this Slack message addresses", "conversation", "Slack addressing at receipt",
       "The audience and host-configured Ryker user reference saved on the first receipt. This context does not grant authority."},
    "inputs" =>
      {"Messages supplied to this request", "conversation", "Episode input history",
       "Messages selected for this work turn, in their retained order. Any recorded budget omissions are shown below."},
    "current_inputs" =>
      {"New messages in this turn", "conversation", "Episode input history",
       "Inputs added to the continuing session. Earlier turns are not resubmitted in this field."},
    "continuity" =>
      {"Conversation continuity", "memory", "Earlier accepted work",
       "The saved first input, previous delivery and host continuation request. Historical context does not prove current state."},
    "operator_context" =>
      {"Remembered context · potentially stale", "memory", "Scoped operator context",
       "Behavior guidance, retained memories and conversation summaries selected for this episode. These do not grant authority."},
    "memory" =>
      {"Confirmed memory", "memory", "Scoped memory records",
       "Remembered facts and guidance supplied with this request; potentially stale, not current observations."},
    "records" =>
      {"Evidence and durable records", "memory", "Episode record store",
       "Records selected from this episode, including their retained source and identity fields."},
    "related_outcomes" =>
      {"Related outcomes", "memory", "Outcome recall",
       "Past outcomes selected as related history, not evidence of the current situation."},
    "prior_outcome" =>
      {"Previous accepted answer", "memory", "Earlier accepted work",
       "The delivery and submission reference from the previous work turn."},
    "candidates" =>
      {"Episodes offered to admission", "memory", "Admission candidate selection",
       "These were the allowed candidates and relations at submission time, not a new search of today's state."},
    "responder_state_tools" =>
      {"Ryker state tools", "tools", "Host tool catalog",
       "State operations advertised to this request. Availability is not a receipt that a tool ran."},
    "source_and_action_tools" =>
      {"Source and action tools", "tools", "Platform adapter",
       "Source access and platform actions advertised for this episode. The host still enforces the bound authority."},
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
      {"Linked episode history", "memory", "Episode relationship",
       "A historical episode reference, not reused write authority or destination."},
    "parent_submission_ref" =>
      {"Previous submission", "memory", "Work continuation",
       "The retained parent submission reference for this continuing turn."}
  }
  @order ~w(custom_instructions input slack_addressing inputs current_inputs continuity operator_context records related_outcomes prior_outcome candidates responder_state_tools source_and_action_tools workspace repository_ref destination allowed_actions execution_mode mode offer_confirmation_supported linked_history_ref parent_submission_ref)

  @doc "The complete submitted components, grouped for reading without hiding source labels."
  def briefing(sections, kind, prefix, counts \\ %{}) do
    instructions = Enum.find(sections, &(&1.id == "instructions"))
    context = Enum.find(sections, &(&1.id == "context"))
    root = if kind == :admission, do: "$.context", else: "$.work"

    [
      if(instructions,
        do:
          group(
            "Instructions",
            "How Ryker asked the model to work.",
            assembly_instructions(instructions.artifact, prefix)
          ),
        else: []
      ),
      if(context, do: assembly(context.artifact, root, prefix, counts), else: []),
      # The output contract is shown once, under the retained submission it was
      # sent beside; repeating it above the prompt said the same thing twice.
      []
    ]
  end

  @doc "The retained prompt and separately supplied output format, without rebuilding either."
  def submitted(sections, prefix, artifact_id \\ nil) do
    [
      "<p class=\"prompt-legend\">Ryker's retained submission; provider-owned instructions and wrappers are not recorded here. Point to or focus a highlight to identify its component.</p>",
      Enum.map(
        [
          {"request", "Prompt",
           "The exact retained prompt text, including its messages and context.", "Prompt text",
           "$.prompt"},
          {"contract", "Response format", "Supplied alongside the prompt, not added to its text.",
           "Output contract", "$.output_schema"}
        ],
        fn {id, title, description, component, path} ->
          case Enum.find(sections, &(&1.id == id)) do
            nil ->
              []

            section ->
              group(
                title,
                description,
                submitted_source(section.artifact, id, component, path, prefix, artifact_id)
              )
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
      {title, "policy", "Retained submission", "Sanitized for inspection; secrets are redacted."},
      case artifact.state do
        :retained -> PromptDocument.render(artifact)
        :collapsed -> ["<p>", state, ".</p>"]
        _absent -> ["<p>", state, ". No reconstructed substitute is shown.</p>"]
      end,
      prefix,
      state: state,
      artifact: if(artifact.state == :collapsed, do: artifact_id),
      revoked: artifact.state in [:expired, :not_recorded]
    )
  end

  defp artifact_availability(%{state: :collapsed}),
    do: "The retained prompt loads when this disclosure is opened"

  defp artifact_availability(%{state: :expired}), do: "Expired"
  defp artifact_availability(%{state: :not_recorded}), do: "Not recorded"
  defp artifact_availability(%{truncated: true}), do: "Partial display"
  defp artifact_availability(_), do: nil

  defp group(title, description, content),
    do: [
      "<section class=\"prompt-group\"><header><h4>",
      title,
      "</h4><p>",
      description,
      "</p></header>",
      content,
      "</section>"
    ]

  def render(artifact, root \\ "$.context", prefix \\ "context")

  def render(%{state: :retained, truncated: false, text: text}, root, prefix) do
    case Jason.decode(text) do
      {:ok, context} when is_map(context) -> context(context, root, prefix)
      _not_structured -> []
    end
  end

  def render(_artifact, _root, _prefix), do: []

  @doc "A flat source inventory for the timeline, without a parent disclosure."
  def assembly(artifact, root, prefix, counts \\ %{})

  def assembly(%{state: :retained, truncated: false, text: text}, root, prefix, counts) do
    case Jason.decode(text) do
      {:ok, context} when is_map(context) -> assemble_context(context, root, prefix, counts)
      _ -> []
    end
  end

  def assembly(_, _, _, _), do: []

  defp assemble_context(context, root, prefix, counts) do
    parts =
      context
      |> Enum.sort_by(fn {key, _} -> {Enum.find_index(@order, &(&1 == key)) || 100, key} end)
      |> Enum.flat_map(fn
        {"operator_context", value} when is_map(value) and map_size(value) > 0 ->
          Enum.map(Enum.sort(value), fn {key, value} ->
            {key, value, root <> ".operator_context"}
          end)

        # One collapsible per scope. A single "Custom instructions" block made a
        # reader open it to find out whether the channel had said anything.
        {"custom_instructions", value} when is_map(value) and map_size(value) > 0 ->
          Enum.map(Enum.sort(value), fn {key, value} ->
            {key, value, root <> ".custom_instructions"}
          end)

        {key, value} ->
          [{key, value, root}]
      end)

    # Keep exact runtime fields and empty values, without giving every scalar
    # flag its own prompt component.
    {components, scope} =
      Enum.split_with(parts, fn {key, value, parent} ->
        {_, origin, _, _} = metadata(key, parent)
        origin not in ["runtime", "other"] && value not in [nil, [], %{}, ""]
      end)

    groups = Enum.group_by(components, fn {key, _, parent} -> elem(metadata(key, parent), 1) end)

    [
      Enum.map(
        [
          {"policy", "Custom instructions",
           "Explicit operator settings included in this request."},
          {"conversation", "Messages",
           "The original input and any conversation history supplied to this call."},
          {"memory", "Selected knowledge",
           "Earlier work, decisions and instructions recalled for this request."},
          {"tools", "Tools and workspace",
           "The capabilities and project context available to the model."}
        ],
        fn {origin, title, description} ->
          case Map.get(groups, origin, []) do
            [] ->
              []

            entries ->
              group(
                title,
                description,
                Enum.map(entries, fn {key, value, parent} ->
                  path = field_path(parent, key)

                  options =
                    [count: Map.get(counts, key)]
                    |> maybe_instruction_estimate(parent, value)

                  source(
                    key,
                    path,
                    value,
                    metadata(key, parent),
                    body(key, value, path, prefix),
                    prefix,
                    options
                  )
                end)
              )
          end
        end
      ),
      if(scope != [],
        do:
          group(
            "Request settings",
            "Where the request came from and the limits applied to it.",
            runtime_context(scope, root, prefix)
          ),
        else: []
      )
    ]
  end

  # One collapsible named after a JSON path, holding whatever was left over,
  # answered "what is in the struct" when the reader is asking what the model
  # knew. Three named blocks answer that instead, each readable closed, and the
  # exact bytes keep their own block at the end where the path belongs.
  defp runtime_context(scope, root, prefix) do
    values = Map.new(scope, fn {key, value, _parent} -> {key, value} end)

    # Raw context keeps every retained field, without exposing implementation
    # JSON paths as reader-facing labels.
    exact = Map.new(scope, fn {key, value, _parent} -> {key, value} end)

    [
      context_block(
        "where",
        "Where this ran",
        where_summary(values),
        where_rows(values),
        values,
        root,
        prefix
      ),
      context_block(
        "seen",
        "What it could see",
        seen_summary(values),
        seen_rows(values),
        values,
        root,
        prefix
      ),
      context_block(
        "allowed",
        "What it was allowed to do",
        allowed_summary(values),
        allowed_rows(values),
        values,
        root,
        prefix
      ),
      source(
        "raw",
        root,
        exact,
        {"Raw context", "runtime", "exact retained bytes",
         "The context as submitted, for reading the record rather than the request."},
        ["<pre>", escape(Jason.encode!(exact, pretty: true)), "</pre>"],
        prefix
      )
    ]
  end

  defp context_block(_key, _title, _summary, [], _values, _root, _prefix), do: []

  defp context_block(key, title, summary, rows, values, root, prefix) do
    source(
      key,
      root <> "." <> key,
      values,
      {title, "runtime", summary, nil},
      ["<dl class=\"context-rows\">", rows, "</dl>"],
      prefix
    )
  end

  defp context_row(_label, nil), do: []
  defp context_row(_label, ""), do: []

  defp context_row(label, value),
    do: ["<div><dt>", escape(label), "</dt><dd>", escape(to_string(value)), "</dd></div>"]

  # The generic field dumper turned this into an alphabetised tree — Companions,
  # Freshness, Owner, Repositories, Fetched at, Name, Remote identity, Requested
  # revision, Resolved revision, Stale base revision, Stale base status,
  # Version, Workspace base revision — thirteen labels before the reader learns
  # which repository the model could see or whether it could write to it.
  defp workspace(value) do
    primary = value["primary"] || %{}
    # `source` is a sibling of `primary`, not its child — the alphabetised dump
    # made that unreadable, which is why it was unreadable.
    source = value["source"] || %{}
    companions = value["companions"] || []

    rows =
      Enum.reject(
        [
          context_row("Repository", workspace_repository(primary)),
          context_row("Access", workspace_access(primary)),
          context_row("Checked out", workspace_revision(source)),
          context_row("Freshness", workspace_freshness(value)),
          context_row("Companions", workspace_companions(companions)),
          context_row("Status", value["status"])
        ],
        &(&1 == [])
      )

    ["<dl class=\"context-rows\">", rows, "</dl>"]
  end

  defp workspace_repository(%{"name" => name, "path" => path})
       when is_binary(name) and is_binary(path) and path != "." do
    "#{name} at #{path}"
  end

  defp workspace_repository(%{"name" => name}) when is_binary(name), do: name
  defp workspace_repository(_primary), do: nil

  defp workspace_access(%{"read_only" => true}), do: "read-only"
  defp workspace_access(%{"read_only" => false}), do: "writable"
  defp workspace_access(_primary), do: nil

  # A forty-character object id twice over says less than the ref plus a short
  # id, and the reader is checking "which commit", not reading the hash.
  defp workspace_revision(%{"selected_ref" => ref, "selected_commit" => commit})
       when is_binary(ref) and is_binary(commit),
       do: "#{ref} · #{String.slice(commit, 0, 8)}"

  defp workspace_revision(%{"selected_commit" => commit}) when is_binary(commit),
    do: String.slice(commit, 0, 8)

  # The default selection carries the default ref and commit under their own
  # names; a "default" kind with nothing selected still checked something out.
  defp workspace_revision(%{"default_ref" => ref, "default_commit" => commit})
       when is_binary(ref) and is_binary(commit),
       do: "#{ref} · #{String.slice(commit, 0, 8)} (default)"

  defp workspace_revision(_source), do: nil

  defp workspace_freshness(value) do
    stale = get_in(value, ["freshness", "repositories"]) || []

    status =
      Enum.find_value(stale, fn entry ->
        if is_map(entry), do: entry["stale_base_status"]
      end)

    fetched =
      Enum.find_value(stale, fn entry ->
        if is_map(entry), do: entry["fetched_at"]
      end)

    [status, fetched && "fetched #{compact_time(fetched)}"]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp workspace_companions([]), do: "none"

  defp workspace_companions(companions) when is_list(companions) do
    Enum.map_join(companions, ", ", fn
      %{"name" => name} -> name
      other -> to_string(other)
    end)
  end

  defp workspace_companions(_companions), do: nil

  defp compact_time(value) when is_binary(value) do
    case String.split(value, "T") do
      [date, rest] -> "#{date} #{String.slice(rest, 0, 5)} UTC"
      _other -> value
    end
  end

  defp compact_time(value), do: value

  defp where_rows(values) do
    Enum.reject(
      [
        context_row("Source", source_name(values["input"])),
        context_row("Asked by", actor_name(values["input"])),
        context_row("Execution", values["execution_mode"]),
        context_row("Assembly", values["mode"])
      ],
      &(&1 == [])
    )
  end

  defp where_summary(values) do
    [source_name(values["input"]), actor_name(values["input"]), values["execution_mode"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp source_name(%{"source" => %{"kind" => kind, "ref" => ref}}), do: "#{kind}:#{ref}"
  defp source_name(_input), do: nil

  defp actor_name(%{"actor" => %{"ref" => ref}}), do: ref
  defp actor_name(_input), do: nil

  defp seen_rows(values) do
    manifest = values["context_manifest"] || %{}

    Enum.reject(
      [
        context_row("Earlier messages", messages_seen(manifest)),
        context_row("Channel summary", summary_state(manifest["channel_summary"])),
        context_row("Thread summary", summary_state(manifest["thread_summary"])),
        context_row("Read", manifest["source_read"] && human(manifest["source_read"])),
        context_row("Up to", manifest["cutoff"])
      ],
      &(&1 == [])
    )
  end

  defp seen_summary(values) do
    case values["context_manifest"] do
      %{} = manifest -> messages_seen(manifest) || "no history recorded"
      _absent -> "no history recorded"
    end
  end

  # The number a reader wants is how much of what was asked for actually
  # arrived: "0 of 20" is usually why a decision looks wrong.
  defp messages_seen(%{"included" => included, "requested" => requested})
       when is_integer(included) and is_integer(requested),
       do: "#{included} of #{requested} asked for"

  defp messages_seen(%{"included" => included}) when is_integer(included),
    do: "#{included} included"

  defp messages_seen(_manifest), do: nil

  defp summary_state(%{"status" => "unavailable"}), do: "none saved"
  defp summary_state(%{"status" => status}), do: human(status)
  defp summary_state(_summary), do: nil

  defp allowed_rows(values) do
    Enum.reject(
      [
        context_row("Actions", word_list(values["allowed_actions"])),
        context_row("Repository sources", word_list(values["repository_source_kinds"])),
        context_row("Offer confirmation", values["offer_confirmation_supported"])
      ],
      &(&1 == [])
    )
  end

  defp allowed_summary(values) do
    [
      count_label(values["allowed_actions"], "action"),
      count_label(values["repository_source_kinds"], "source kind")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp count_label(values, noun) when is_list(values) and values != [],
    do: "#{length(values)} #{noun}#{if length(values) == 1, do: "", else: "s"}"

  defp count_label(_values, _noun), do: nil

  defp word_list(values) when is_list(values) and values != [],
    do: Enum.map_join(values, " · ", &human/1)

  defp word_list(_values), do: nil

  def assembly_instructions(%{state: :retained, text: text} = artifact, prefix) do
    source(
      "instructions",
      "$.instructions",
      text,
      {"Ryker instructions", "policy", "Host-authored instructions",
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

  def instructions(artifact, kind, prefix \\ "instructions", open \\ false)

  def instructions(%{state: :retained, text: text}, kind, prefix, open) do
    title = if kind == :admission, do: "Ryker admission policy", else: "Ryker work policy"

    source(
      "instructions",
      "$.instructions",
      text,
      {title, "policy", "Host-authored instructions",
       "The instruction field retained with this exact request. This is not the Coop wrapper or provider system prompt, and it is not loaded from today's source code."},
      ["<pre class=\"model-document-text\">", escape(text), "</pre>"],
      prefix,
      open: open
    )
  end

  def instructions(_artifact, _kind, _prefix, _open), do: []

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
          body(key, value, path, prefix),
          prefix
        )
      end),
      "</div>"
    ]
  end

  defp metadata(key, root)
       when root in ["$.work.custom_instructions", "$.context.custom_instructions"] do
    case key do
      "global" ->
        {"Global instructions", "policy", "Workspace text at send time", nil}

      "channel" ->
        {"Channel instructions", "policy", "Channel text at send time; overrides global", nil}

      other ->
        {human(other) <> " instructions", "policy", "Text at send time", nil}
    end
  end

  defp metadata(key, root)
       when root in ["$.work.operator_context", "$.context.operator_context"] do
    case key do
      "continuity" ->
        {"Conversation memory", "memory", "Selected notes, topics and earlier work",
         "Source notes, maintained topics and conversation summaries selected for this request. These describe what was known then, not verified current state."}

      "preferences" ->
        {"Operator preferences", "memory", "Confirmed behavior settings",
         "The effective preferences retained for this operator and conversation."}

      "guidance" ->
        {"Confirmed guidance", "memory", "Scoped guidance records",
         "Operator-confirmed guidance selected for the bound scope; it cannot widen tool authority."}

      "standing_assignments" ->
        {"Standing assignments", "memory", "Confirmed assignment records",
         "The standing assignment context selected for this episode, not a new authorization."}

      _ ->
        metadata(key, nil)
    end
  end

  defp metadata(key, _root),
    do:
      Map.get(
        @sources,
        key,
        {human(key), "other", "Additional retained field",
         "This field was present in the retained request. More specific provenance was not recorded by this viewer."}
      )

  def source_label("$.inputs"), do: "Source messages · Retained conversation inputs"
  def source_label("$.knowledge"), do: "Prior knowledge · Frozen topic versions"

  def source_label(path) do
    parts = String.split(path, ".")
    key = List.last(parts)
    parent = parts |> Enum.drop(-1) |> Enum.join(".")

    if path == "$.instructions" do
      "Ryker instructions · Host-authored instructions"
    else
      {title, _, owner, _} = metadata(key, parent)
      title <> " · " <> owner
    end
  end

  @doc "One instruction scope: its identity on a line, then the text itself."
  def instruction_scope(%{} = layer) do
    identity =
      [{"Revision", layer["revision"]}, {"Scope", layer["scope"]}]
      |> Enum.filter(fn {_label, value} -> value not in [nil, ""] end)
      |> Enum.map_join(" · ", fn {label, value} -> "#{label} #{value}" end)

    [
      if(identity == "",
        do: [],
        else: ["<p class=\"instruction-identity\">", escape(identity), "</p>"]
      ),
      instruction_text(layer["text"])
    ]
  end

  defp instruction_text(text) when is_binary(text) and text != "",
    do: ["<pre class=\"model-document-text\">", escape(text), "</pre>"]

  defp instruction_text(_text),
    do: ["<p class=\"context-absent\">No instruction saved at this scope.</p>"]

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

  defp body(key, value, _path, _prefix)
       when key in ~w(input inputs current_inputs) and (is_map(value) or is_list(value)),
       do: messages(%{key => value})

  defp body("candidates", value, _path, _prefix) when is_list(value) and value != [],
    do: candidates(value)

  defp body("workspace", value, _path, _prefix) when is_map(value) and map_size(value) > 0,
    do: workspace(value)

  defp body(key, value, path, _prefix)
       when key in ~w(global channel) and is_map(value) do
    if String.contains?(path, ".custom_instructions."),
      do: instruction_scope(value),
      else: fields(value, 0)
  end

  defp body("custom_instructions", value, _path, _prefix) when is_map(value),
    do: instruction_layers(value)

  defp body("operator_context", value, path, prefix) when is_map(value) and map_size(value) > 0,
    do: context(value, path, prefix)

  defp body("continuity", value, path, _prefix) when is_map(value) do
    if String.contains?(path, ".operator_context."),
      do: [
        recall(value),
        "<details><summary>Exact component</summary><pre>",
        escape(Jason.encode!(value, pretty: true)),
        "</pre></details>"
      ],
      else: fields(value, 0)
  end

  defp body(_key, value, _path, _prefix), do: fields(value, 0)

  defp recall(value) do
    Enum.map(~w(current related rollups observations knowledge), fn group ->
      value[group]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn item ->
        [
          "<section class=\"conversation-recall\" data-memory-kind=\"",
          if(group == "observations", do: "observation", else: group),
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

  defp recall_title("current"), do: "This conversation"
  defp recall_title("observations"), do: "Source note"
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
          else: ["<div><h5>", title, "</h5>", fields(state[key], 0), "</div>"]
      end
    )
  end

  defp recall_fields(_),
    do:
      "<p>Saved summary is not structured. Its retained value is in the exact component below.</p>"

  defp source(key, path, value, metadata, body, prefix, options \\ []) do
    {title, origin, owner, description} = metadata
    open = Keyword.get(options, :open, false)
    state_override = Keyword.get(options, :state)
    count = Keyword.get(options, :count)
    artifact = Keyword.get(options, :artifact)
    revoked = Keyword.get(options, :revoked, false)

    estimate =
      if Keyword.has_key?(options, :estimate),
        do: Keyword.get(options, :estimate),
        else: value

    state =
      state_override ||
        if value in [nil, [], %{}, ""], do: "Empty in request", else: "Retained input"

    [
      "<details id=\"",
      escape(prefix <> "-source-" <> Base.url_encode64(path, padding: false)),
      "\" class=\"prompt-source",
      if(state_override, do: " prompt-source-partial", else: ""),
      "\" data-source=\"",
      escape(key),
      "\" data-origin=\"",
      origin,
      "\"",
      # The component carries its own lazy load. The outer disclosure used to,
      # which is why it had to stay a disclosure at all.
      if(artifact, do: [" data-artifact=\"", escape(artifact), "\""], else: ""),
      # An expired body must never be fetched back, and the reader's open copy
      # goes with it: privacy and retention win over preserving their place.
      if(revoked, do: " data-revoked=\"true\"", else: ""),
      if(open, do: " open", else: ""),
      "><summary>",
      "<span class=\"prompt-source-state\">",
      source_state(value, state, state_override, estimate),
      "</span>",
      # The reader wants the name of the thing first, then how much of it there
      # is, then where it came from. Leading with a bare count read as
      # "1 includedMessages supplied to this request".
      "<span class=\"prompt-source-title\">",
      escape(title),
      "</span>",
      source_count(count),
      "<span class=\"prompt-source-location\">",
      escape(owner),
      "</span></summary>",
      "<div class=\"prompt-source-body\">",
      if(description, do: ["<p>", escape(description), "</p>"], else: []),
      body,
      "</div></details>"
    ]
  end

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

  defp source_state(_value, state, unavailable, _estimate)
       when unavailable in ["Expired", "Not recorded"],
       do: state

  # A body that has not loaded yet has no text to estimate from. "≈ 1 estimated
  # tokens" on a prompt that is actually thousands is worse than no number.
  defp source_state(
         _value,
         state,
         "The retained prompt loads when this disclosure is opened",
         _estimate
       ),
       do: state

  defp source_state(_value, state, _override, estimate) when estimate in [nil, ""], do: state

  defp source_state(value, state, override, estimate),
    do: [
      if(override || value in [nil, [], %{}, ""], do: [state, " · "], else: []),
      estimated_tokens(estimate)
    ]

  defp maybe_instruction_estimate(options, parent, value)
       when parent in ["$.work.custom_instructions", "$.context.custom_instructions"] and
              is_map(value),
       do: Keyword.put(options, :estimate, value["text"])

  defp maybe_instruction_estimate(options, _parent, _value), do: options

  # Provider totals are measured separately. Component counts are estimates over
  # the displayed, sanitized text, not fabricated provider tokenizer receipts.
  defp estimated_tokens(value) do
    text = if is_binary(value), do: value, else: Jason.encode!(value)
    "≈ #{ceil(byte_size(text) / 4)} estimated tokens"
  end

  defp field_path(root, key) do
    if Regex.match?(~r/^[a-zA-Z_][a-zA-Z_0-9]*$/, key),
      do: root <> "." <> key,
      else: root <> "[" <> Jason.encode!(key) <> "]"
  end

  defp messages(context) do
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
        "<section>",
        Enum.map(items, &message/1),
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

  defp message(input) when is_map(input) do
    actor = actor_label(input)
    body = message_text(input["content"] || input)

    [
      "<article class=\"context-message\"><header><strong>",
      escape(actor),
      "</strong><span>",
      if(input["current"] == false, do: "Earlier context", else: "Input"),
      " · ",
      escape(input["occurred_at"] || "Time not recorded"),
      "</span></header>",
      if(body,
        do: ["<div class=\"context-message-body\">", message_body(body, input), "</div>"],
        else: "<p>Structured source event · fields below</p>"
      ),
      "<details><summary>Source fields and attachment metadata</summary><pre>",
      escape(Jason.encode!(input, pretty: true)),
      "</pre></details></article>"
    ]
  end

  defp message(_input), do: []

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
        SlackNames.name(
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
    case slack_workspace(input) do
      workspace when is_binary(workspace) ->
        SlackMarkdown.render(body, workspace)

      _ ->
        escape(body)
    end
  end

  defp actor_name("slack:user:" <> _, _actor), do: "Slack user"
  defp actor_name("github:user:" <> _, _actor), do: "GitHub user"
  defp actor_name("local-operator", _actor), do: "You · local operator"
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
        escape(human(key)),
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

  defp candidates(items) when is_list(items) and items != [] do
    [
      "<section><h3>Episodes offered to admission</h3><p>These were the allowed candidates, not a new search of today's state.</p>",
      Enum.map(items, &candidate/1),
      "</section>"
    ]
  end

  defp candidate(%{"state" => state} = item) when is_binary(state) do
    digest = if is_map(item["digest"]), do: item["digest"], else: %{}
    objective = present(digest["objective"])

    [
      "<details class=\"context-candidate\"><summary><span>",
      escape(candidate_lifecycle(state)),
      " - ",
      escape(candidate_use(item["allowed_relations"])),
      "</span></summary><div class=\"candidate-readable\">",
      if(objective,
        do: ["<h4>", escape(objective), "</h4>"],
        else: "<p class=\"context-absent\">Objective was not recorded.</p>"
      ),
      candidate_facts(digest),
      if(present(digest["latest_development"]),
        do: [
          "<p class=\"candidate-development\"><strong>Latest development</strong> ",
          escape(digest["latest_development"]),
          "</p>"
        ],
        else: []
      ),
      candidate_previews(item),
      candidate_rationale(item["match"]),
      "</div>",
      technical_candidate(item, false),
      "</details>"
    ]
  end

  defp candidate(item) do
    [
      "<details class=\"context-candidate context-candidate-malformed\"><summary>",
      "Historical candidate - retained shape unavailable",
      "</summary><p class=\"context-absent\">This older option cannot be summarized safely.</p>",
      technical_candidate(item, true),
      "</details>"
    ]
  end

  defp candidate_lifecycle("active"), do: "Active"
  defp candidate_lifecycle("complete"), do: "Completed"
  defp candidate_lifecycle("cancelled"), do: "Cancelled"
  defp candidate_lifecycle(other), do: human(other)

  defp candidate_use(relations) when is_list(relations) do
    same_work = "same_work" in relations
    history = "history_only" in relations

    cond do
      same_work and history -> "may continue or provide background"
      same_work -> "may continue"
      history -> "background only"
      true -> "permitted use not recorded"
    end
  end

  defp candidate_use(_relations), do: "permitted use not recorded"

  defp candidate_facts(digest) do
    facts =
      [
        candidate_fact("Messages", count(digest["input_count"], "message")),
        candidate_fact("Conversations", count(digest["conversations"], "conversation")),
        candidate_fact("Covered through", readable_candidate_time(digest["covered_through"])),
        candidate_fact("Freshness", present(digest["freshness"]) && human(digest["freshness"]))
      ]
      |> Enum.reject(&(&1 == []))

    if facts == [], do: [], else: ["<dl class=\"candidate-facts\">", facts, "</dl>"]
  end

  defp candidate_fact(_label, nil), do: []

  defp candidate_fact(label, value),
    do: ["<div><dt>", label, "</dt><dd>", escape(value), "</dd></div>"]

  defp count(value, noun) when is_integer(value) and value >= 0,
    do: "#{value} #{noun}#{if value == 1, do: "", else: "s"}"

  defp count(_value, _noun), do: nil

  defp readable_candidate_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%d %b %Y, %H:%M UTC")
      _invalid -> bounded(value, 120)
    end
  end

  defp readable_candidate_time(_value), do: nil

  defp candidate_previews(item) do
    first = candidate_preview(item["first_input"], "First message")
    latest = candidate_preview(item["latest_input"], "Latest message")

    latest =
      if first != nil and latest != nil and first.text == latest.text, do: nil, else: latest

    [first, latest]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn preview ->
      [
        "<article class=\"candidate-preview\"><header><strong>",
        preview.label,
        "</strong>",
        if(preview.at, do: ["<time>", escape(preview.at), "</time>"], else: []),
        "</header><p>",
        escape(preview.text),
        if(preview.truncated, do: " <span>(truncated)</span>", else: []),
        "</p></article>"
      ]
    end)
  end

  defp candidate_preview(%{} = preview, label) do
    case preview_text(preview["content_preview"]) do
      nil ->
        nil

      text ->
        %{
          label: label,
          text: bounded(text, 800),
          at: readable_candidate_time(preview["occurred_at"]),
          truncated: preview["truncated"] == true
        }
    end
  end

  defp candidate_preview(_preview, _label), do: nil

  defp preview_text(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = document} -> message_text(document["content"] || document)
      _invalid -> partial_preview_text(value)
    end
  end

  defp preview_text(_value), do: nil

  defp partial_preview_text(value) do
    case Regex.run(~r/"text"\s*:\s*"((?:\\.|[^"])*)/, value, capture: :all_but_first) do
      [encoded] ->
        case Jason.decode(~s("#{encoded}")) do
          {:ok, text} when is_binary(text) -> text
          _invalid -> bounded(encoded, 800)
        end

      _none ->
        nil
    end
  end

  defp candidate_rationale(match) when is_map(match) do
    reasons =
      []
      |> maybe_reason(match["occurrence_identity"] == true, "same source event")
      |> maybe_reason(positive_integer?(match["direct_references"]), fn ->
        count(match["direct_references"], "direct reference")
      end)
      |> maybe_reason(match["same_thread"] == true, "same thread")
      |> maybe_reason(match["same_conversation"] == true, "same conversation")
      |> maybe_reason(positive_number?(match["topic_fit"]), "related wording")
      |> maybe_reason(match["active"] == true, "active work")
      |> Enum.reverse()

    if reasons == [],
      do: [],
      else: [
        "<p class=\"candidate-rationale\"><strong>Why offered</strong> ",
        Enum.join(reasons, " · "),
        "</p>"
      ]
  end

  defp candidate_rationale(_match), do: []

  defp maybe_reason(reasons, true, reason) when is_function(reason, 0), do: [reason.() | reasons]
  defp maybe_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_reason(reasons, false, _reason), do: reasons

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp positive_number?(value), do: is_number(value) and value > 0

  defp technical_candidate(item, bounded?) do
    encoded = if is_binary(item), do: item, else: Jason.encode!(item, pretty: true)
    encoded = if bounded?, do: bounded(encoded, 500), else: encoded

    [
      "<details class=\"context-candidate-technical\"><summary>Technical details</summary><pre>",
      escape(encoded),
      "</pre></details>"
    ]
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp bounded(value, limit) when is_binary(value), do: String.slice(value, 0, limit)

  defp human(value) when is_map(value) or is_list(value), do: "Structured value"
  defp human(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp escape(value) when is_map(value) or is_list(value), do: escape(Jason.encode!(value))

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
