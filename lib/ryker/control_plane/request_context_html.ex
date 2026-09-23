defmodule Ryker.ControlPlane.RequestContextHTML do
  alias Ryker.ControlPlane.Components
  alias Ryker.ControlPlane.PromptDocument
  alias Ryker.ControlPlane.SlackMarkdown
  alias Ryker.ControlPlane.SlackNames
  alias Ryker.ControlPlane.SourceText
  @moduledoc "Readable context derived only from an already sanitized inspection artifact."

  @sources %{
    "custom_instructions" =>
      {"Custom instructions", "policy", nil,
       "The global and channel text, scopes and revisions saved with this request, not today's settings. Empty text means no instruction at that scope."},
    "input" => {"Current message", "conversation", nil, nil},
    "slack_addressing" =>
      {"Who this Slack message addresses", "conversation", "Slack addressing at receipt",
       "The audience and host-configured Ryker user reference saved on the first receipt. This context does not grant authority."},
    "inputs" => {"Conversation messages", "conversation", nil, nil},
    "current_inputs" =>
      {"New messages in this turn", "conversation", nil,
       "Earlier turns remain in the session and are not resubmitted here."},
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
      {"Candidate selection", "memory", nil,
       "How Ryker filtered earlier work for this routing decision."},
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
  @instruction_not_recorded :instruction_not_recorded

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
               href: "#" <> candidate_anchor(prefix, ref)
             }}
    else
      _ -> %{}
    end
  end

  defp candidate_link_title(%{"digest" => %{"objective" => title}})
       when is_binary(title) and title != "", do: title

  defp candidate_link_title(_item), do: "Earlier work"

  defp candidate_anchor(prefix, ref) when is_binary(prefix) and is_binary(ref),
    do: prefix <> "-candidate-" <> Base.url_encode64(ref, padding: false)

  defp candidate_anchor(_prefix, _ref), do: nil

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
      "<p class=\"prompt-legend\">Provider-owned instructions and wrappers are not part of this record. Point to or focus a highlight to identify its component.</p>",
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
      {title, "policy", nil, submitted_provenance(id, artifact)},
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

  defp submitted_provenance("request", %{redacted: true}),
    do: "Sensitive values are hidden in this view."

  defp submitted_provenance("contract", _artifact),
    do: "Supplied alongside the prompt, not added to its text."

  defp submitted_provenance(_id, _artifact), do: nil

  defp artifact_availability(%{state: :collapsed}),
    do: "Loads on open"

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
    parts = context_parts(context, root)

    # Keep exact runtime fields and empty values, without giving every scalar
    # flag its own prompt component.
    {components, scope} = Enum.split_with(parts, &display_component?/1)

    groups = Enum.group_by(components, fn {key, _, parent} -> elem(metadata(key, parent), 1) end)

    [
      Enum.map(
        [
          {"policy", "Custom instructions", "Settings captured for this model call."},
          {"conversation", "Messages", nil},
          {"memory", "Selected knowledge",
           "Earlier work, decisions and instructions recalled for this request."},
          {"tools", "Tools and workspace",
           "The capabilities and project context available to the model."}
        ],
        &assembled_group(&1, groups, prefix, counts)
      ),
      if(scope != [],
        do:
          group(
            "Context and permissions",
            "What additional context the model received and what it was allowed to do.",
            runtime_context(scope, root, prefix),
            group: "runtime"
          ),
        else: []
      )
    ]
  end

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

  defp display_component?({key, value, parent}) do
    {_, origin, _, _} = metadata(key, parent)

    origin not in ["runtime", "other"] &&
      (instruction_parent?(parent) || value not in [nil, [], %{}, ""])
  end

  defp assembled_group({origin, title, description}, groups, prefix, counts) do
    case Map.get(groups, origin, []) do
      [] ->
        []

      entries ->
        {title, description} = group_presentation(origin, title, description, entries, counts)

        group(
          title,
          description,
          Enum.map(entries, &assembled_source(&1, prefix, counts)),
          group: origin
        )
    end
  end

  defp assembled_source({key, value, parent}, prefix, counts) do
    path = field_path(parent, key)

    options =
      [count: Map.get(counts, key)]
      |> instruction_options(key, parent, value)
      |> source_count_option(key, parent)

    if key == "candidates" and is_list(value) do
      candidate_sources(value, path, prefix, counts)
    else
      source(
        key,
        path,
        value,
        source_metadata(key, parent, value),
        body(key, value, path, prefix),
        prefix,
        options
      )
    end
  end

  defp source_count_option(options, key, _parent) when key in ~w(input inputs current_inputs),
    do: Keyword.delete(options, :count)

  defp source_count_option(options, "continuity", parent)
       when parent not in ["$.work.operator_context", "$.context.operator_context"],
       do: Keyword.delete(options, :count)

  defp source_count_option(options, _key, _parent), do: options

  defp group_presentation("conversation", title, _description, entries, _counts) do
    count =
      Enum.reduce(entries, 0, fn {key, value, _parent}, total ->
        total + message_count(key, value)
      end)

    {title, if(count > 0, do: count(count, "message"), else: nil)}
  end

  defp group_presentation("memory", _title, _description, [{"candidates", _, _}], counts) do
    description =
      case counts["candidates"] do
        %{label: label} when is_binary(label) -> label
        _ -> "How earlier work could be used for this routing decision."
      end

    {"Related history", description}
  end

  defp group_presentation(_origin, title, description, _entries, _counts),
    do: {title, description}

  defp candidate_sources(items, path, prefix, counts) do
    {continuations, context_only} =
      Enum.split_with(items, fn
        %{"allowed_relations" => relations} when is_list(relations) -> "same_work" in relations
        _ -> false
      end)

    histories = Map.get(counts, "candidate_histories", %{})
    candidate_count = Map.get(counts, "candidates", %{})

    [
      candidate_group_source(
        "continuation_candidates",
        "Continuation candidates",
        "Earlier work the router could continue.",
        continuations,
        histories,
        path <> ".continuation",
        prefix
      ),
      candidate_group_source(
        "context_matches",
        "Context matches",
        "Earlier work supplied as background only.",
        context_only,
        histories,
        path <> ".context",
        prefix
      ),
      excluded_candidate_source(candidate_count, path, prefix)
    ]
  end

  defp candidate_group_source(_key, _title, _description, [], _histories, _path, _prefix),
    do: []

  defp candidate_group_source(key, title, description, items, histories, path, prefix) do
    source(
      key,
      path,
      items,
      {title, "memory", nil, description},
      candidates(items, histories, prefix),
      prefix,
      count: %{label: count(length(items), "candidate"), known?: true},
      estimate: items
    )
  end

  defp excluded_candidate_source(%{excluded: excluded} = count, path, prefix)
       when is_integer(excluded) and excluded > 0 do
    reason = count[:reason] || "The routing shortlist limit excluded these candidates."

    source(
      "not_supplied",
      path <> ".excluded",
      %{"excluded" => excluded},
      {"Not supplied", "memory", nil, nil},
      ["<p>", escape(reason), "</p>"],
      prefix,
      count: %{label: count(excluded, "candidate"), known?: true},
      estimate: nil
    )
  end

  defp excluded_candidate_source(_count, _path, _prefix), do: []

  defp message_count(key, value) when key in ~w(input inputs current_inputs) do
    case value do
      %{"items" => items} when is_list(items) -> length(items)
      items when is_list(items) -> length(items)
      value when is_map(value) -> 1
      _ -> 0
    end
  end

  defp message_count(_key, _value), do: 0

  defp instruction_parts(value, parent) do
    Enum.map(["global", "channel"], fn key ->
      {key, Map.get(value, key, @instruction_not_recorded), parent}
    end)
  end

  defp instruction_parent?(parent),
    do: parent in ["$.work.custom_instructions", "$.context.custom_instructions"]

  defp runtime_context(scope, root, prefix) do
    values = Map.new(scope, fn {key, value, _parent} -> {key, value} end)
    exact = Map.new(scope, fn {key, value, _parent} -> {key, value} end)

    {bundle, manifest, bundle_path} = conversation_context(values, root)
    messages = if is_list(bundle["messages"]), do: bundle["messages"]
    permission_rows = allowed_rows(values)

    [
      if(
        conversation_history?(values, manifest),
        do:
          source(
            "earlier_messages",
            bundle_path <> ".messages",
            messages,
            {"Earlier messages", "conversation", nil, nil},
            earlier_messages_body(messages, manifest),
            prefix,
            count: earlier_messages_count(messages, manifest),
            state: if(is_nil(messages), do: "Bodies not retained"),
            estimate: if(messages in [nil, []], do: nil, else: messages)
          ),
        else: []
      ),
      summary_source("channel", bundle, manifest, bundle_path, prefix),
      summary_source("thread", bundle, manifest, bundle_path, prefix),
      if(permission_rows != [],
        do:
          source(
            "permitted_actions",
            root <> ".allowed_actions",
            permission_values(values),
            {"Permitted actions", "runtime", nil, nil},
            ["<dl class=\"context-rows\">", permission_rows, "</dl>"],
            prefix,
            estimate: nil
          ),
        else: []
      ),
      source(
        "raw_context",
        root,
        exact,
        {"Raw context", "runtime", nil, nil},
        ["<pre>", escape(Jason.encode!(exact, pretty: true)), "</pre>"],
        prefix,
        state: "Technical",
        estimate: nil
      )
    ]
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

  defp conversation_history?(values, manifest),
    do:
      Map.has_key?(values, "conversation_context") or is_integer(manifest["included"]) or
        is_integer(manifest["requested"])

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

  defp earlier_messages_body([], manifest) do
    [
      context_limit(manifest),
      "<p class=\"context-absent\">No earlier messages were supplied.</p>"
    ]
  end

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

  defp summary_source(kind, bundle, manifest, bundle_path, prefix) do
    key = kind <> "_summary"

    if Map.has_key?(bundle, key) or Map.has_key?(manifest, key) do
      value = bundle[key]
      recorded = manifest[key]
      available? = value not in [nil, %{}, ""]

      source(
        key,
        bundle_path <> "." <> key,
        if(available?, do: value, else: %{"status" => "unavailable"}),
        {human(kind) <> " summary", "conversation", nil, nil},
        summary_body(value, recorded),
        prefix,
        state: if(available?, do: nil, else: "Not available"),
        estimate: if(available?, do: value, else: nil)
      )
    else
      []
    end
  end

  defp summary_body(value, _recorded) when value not in [nil, %{}, ""], do: fields(value, 0)

  defp summary_body(_value, %{"reason" => reason}) when is_binary(reason) do
    ["<p class=\"context-absent\">", summary_reason(reason), "</p>"]
  end

  defp summary_body(_value, _recorded),
    do: "<p class=\"context-absent\">No summary was available for this request.</p>"

  defp summary_reason("not_applicable"), do: "This summary did not apply to the conversation."
  defp summary_reason("after_cutoff"), do: "The summary was created after this request."
  defp summary_reason("absent"), do: "No summary had been saved for this conversation."
  defp summary_reason(reason), do: human(reason) <> "."

  defp permission_values(values),
    do:
      Map.take(values, [
        "allowed_actions",
        "repository_source_kinds",
        "offer_confirmation_supported"
      ])

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

  defp allowed_rows(values) do
    Enum.reject(
      [
        context_row("Actions", action_list(values["allowed_actions"])),
        context_row("Repository sources", word_list(values["repository_source_kinds"])),
        context_row("Offer confirmation", values["offer_confirmation_supported"])
      ],
      &(&1 == [])
    )
  end

  defp word_list(values) when is_list(values) and values != [],
    do: Enum.map_join(values, " · ", &human/1)

  defp word_list(_values), do: nil

  defp action_list(values) when is_list(values) and values != [],
    do: Enum.map_join(values, " · ", &action_label/1)

  defp action_list(_values), do: nil

  defp action_label("start_episode"), do: "Start work"
  defp action_label("continue_episode"), do: "Continue work"
  defp action_label("reply"), do: "Reply"
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

  def instructions(artifact, kind, prefix \\ "instructions", open \\ false)

  def instructions(%{state: :retained, text: text}, kind, prefix, open) do
    title = if kind == :admission, do: "Admission system prompt", else: "Work system prompt"

    source(
      "instructions",
      "$.instructions",
      text,
      {title, "policy", nil,
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

  def source_label("$.inputs"), do: "Source messages · Retained conversation inputs"
  def source_label("$.knowledge"), do: "Prior knowledge · Frozen topic versions"
  def source_label("$.instructions"), do: "System prompt"
  def source_label("$.context.custom_instructions.global"), do: "Global instructions"
  def source_label("$.work.custom_instructions.global"), do: "Global instructions"
  def source_label("$.context.custom_instructions.channel"), do: "Channel instructions"
  def source_label("$.work.custom_instructions.channel"), do: "Channel instructions"
  def source_label("$.context.conversation_context.messages"), do: "Earlier messages"
  def source_label("$.work.conversation_context.messages"), do: "Earlier messages"
  def source_label("$.work.conversation_context.bundle.messages"), do: "Earlier messages"
  def source_label("$.context.conversation_context.channel_summary"), do: "Channel summary"
  def source_label("$.work.conversation_context.channel_summary"), do: "Channel summary"
  def source_label("$.work.conversation_context.bundle.channel_summary"), do: "Channel summary"
  def source_label("$.context.conversation_context.thread_summary"), do: "Thread summary"
  def source_label("$.work.conversation_context.thread_summary"), do: "Thread summary"
  def source_label("$.work.conversation_context.bundle.thread_summary"), do: "Thread summary"
  def source_label("$.context.allowed_actions"), do: "Permitted actions"
  def source_label("$.work.allowed_actions"), do: "Permitted actions"
  def source_label("$.context.conversation_observations"), do: "Conversation observations"
  def source_label("$.context.conversation_knowledge"), do: "Conversation knowledge"
  def source_label("$.context.slack_addressing"), do: "Slack addressing"
  def source_label("$.context.repository_source_kinds"), do: "Repository sources"

  def source_label(path) do
    parts = String.split(path, ".")
    key = List.last(parts)
    parent = parts |> Enum.drop(-1) |> Enum.join(".")

    {title, _, owner, _} = metadata(key, parent)
    if(owner, do: title <> " · " <> owner, else: title)
  end

  @doc "One instruction scope: its identity on a line, then the text itself."
  def instruction_scope(%{} = layer) do
    instruction_scope(layer, "global")
  end

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

  defp body(key, value, _path, _prefix)
       when key in ~w(input inputs current_inputs) and (is_map(value) or is_list(value)),
       do: messages(%{key => value})

  defp body("candidates", value, _path, prefix) when is_list(value) and value != [],
    do: candidates(value, %{}, prefix)

  defp body("workspace", value, _path, _prefix) when is_map(value) and map_size(value) > 0,
    do: workspace(value)

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
        "</span>"
      ],
      meta: [
        source_status(value, settings.state, settings.state_override),
        source_estimate(value, settings.state_override, settings.estimate)
      ]
    )
  end

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
              "Not recorded",
              "Loads on open"
            ],
       do: []

  defp source_estimate(_value, _override, estimate) when estimate in [nil, ""], do: []

  defp source_estimate(_value, _override, estimate),
    do: ["<span class=\"prompt-source-estimate\">", estimated_tokens(estimate), "</span>"]

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
        "<section class=\"context-messages\">",
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
    title = if(total > 1 and kind != :history, do: context)

    Components.message_block_html(
      actor,
      if(body,
        do: message_body(body, input),
        else: "<p class=\"context-absent\">This source event has no text body.</p>"
      ),
      class: "context-message",
      rest: %{"data-message-context" => context},
      title: title,
      meta:
        if(input["occurred_at"],
          do: [
            "<time datetime=\"",
            escape(input["occurred_at"]),
            "\">",
            escape(readable_candidate_time(input["occurred_at"])),
            "</time>"
          ],
          else: []
        ),
      footer:
        Components.disclosure_html(
          "Details",
          [
            "<dl class=\"context-rows\">",
            message_detail("Source", message_source(input)),
            message_detail("Sender ID", message_sender(input)),
            message_detail("Attachments", attachment_count(input)),
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

  defp message_context(_input, :history), do: "Earlier context"
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

  defp message_sender(input) do
    actor = if is_map(input["actor"]), do: input["actor"], else: %{}
    actor["display_name"] || actor["name"] || actor["ref"] || input["actor_ref"]
  end

  defp attachment_count(input) do
    content = if is_map(input["content"]), do: input["content"], else: %{}

    count =
      [content["attachments"], content["files"]]
      |> Enum.flat_map(&List.wrap/1)
      |> length()

    if count > 0, do: count(count, "attachment")
  end

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
  defp actor_name("local-operator", _actor), do: "Local operator"
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

  defp candidates(items, histories, prefix) when is_list(items) and items != [] do
    [
      "<section class=\"context-candidates\">",
      Enum.map(items, fn item ->
        history = if is_map(item), do: Map.get(histories, item["episode_ref"], []), else: []
        anchor = if is_map(item), do: candidate_anchor(prefix, item["episode_ref"])
        candidate(item, history, anchor)
      end),
      "</section>"
    ]
  end

  defp candidate(%{"state" => state} = item, enriched_history, anchor) when is_binary(state) do
    digest = if is_map(item["digest"]), do: item["digest"], else: %{}
    objective = present(digest["objective"])
    latest_development = present(digest["latest_development"])
    {previews, omitted} = candidate_preview_list(item, enriched_history)
    latest = List.last(previews)

    history_count =
      if is_list(item["message_history"]) and item["message_history"] != [],
        do: length(previews) + omitted,
        else: digest["input_count"] || length(previews) + omitted

    [
      "<article class=\"context-candidate context-record\"",
      if(anchor, do: [" id=\"", escape(anchor), "\" tabindex=\"-1\""], else: []),
      "><header class=\"candidate-heading\"><h4>",
      candidate_title(objective),
      "</h4>",
      candidate_time(digest),
      "</header><div class=\"candidate-readable\">",
      candidate_state_warning(state),
      candidate_excerpt(
        if(history_count > 1, do: nil, else: latest),
        objective,
        latest_development
      ),
      candidate_rationale(item["match"]),
      candidate_history_section(previews, history_count, omitted, enriched_history),
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

  defp candidate_title(nil), do: "Objective was not recorded"
  defp candidate_title(objective), do: escape(objective)

  defp candidate_history_section(
         _previews,
         history_count,
         _omitted,
         %{"artifact_id" => artifact_id, "state" => "collapsed"}
       ) do
    related_candidate_history([], history_count, 0, artifact_id, true)
  end

  defp candidate_history_section(
         previews,
         history_count,
         omitted,
         %{"artifact_id" => artifact_id, "state" => "retained"}
       ) do
    related_candidate_history(previews, history_count, omitted, artifact_id, false)
  end

  defp candidate_history_section(previews, history_count, omitted, _enriched_history)
       when length(previews) > 1 or omitted > 0,
       do: candidate_history(previews, history_count, omitted)

  defp candidate_history_section(previews, history_count, omitted, _enriched_history)
       when is_integer(history_count) and history_count > 1,
       do: candidate_history(previews, history_count, omitted)

  defp candidate_history_section(_previews, _history_count, _omitted, _enriched_history), do: []

  defp candidate_time(digest) do
    case readable_candidate_time(digest["covered_through"]) do
      nil -> []
      value -> ["<time>", escape(value), "</time>"]
    end
  end

  defp candidate_state_warning("cancelled"),
    do: "<p class=\"candidate-warning\">This work was cancelled.</p>"

  defp candidate_state_warning(_state), do: []

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

  defp candidate_preview_list(item, enriched_history) do
    history = candidate_source_history(item, enriched_history)

    if is_list(history) and history != [] do
      {previews, omitted} = bounded_candidate_history(history)
      {previews, candidate_omitted(omitted, enriched_history)}
    else
      fallback_candidate_previews(item)
    end
  end

  defp candidate_source_history(%{"message_history" => history}, _enriched)
       when is_list(history) and history != [],
       do: history

  defp candidate_source_history(_item, %{} = enriched), do: enriched["items"]
  defp candidate_source_history(_item, enriched), do: enriched

  defp candidate_omitted(omitted, %{"omitted" => enriched}) when is_integer(enriched),
    do: max(omitted, enriched)

  defp candidate_omitted(omitted, _enriched), do: omitted

  defp fallback_candidate_previews(item) do
    first = candidate_preview(item["first_input"], "Message 1")
    latest = candidate_preview(item["latest_input"], "Latest message")
    latest = if same_preview?(first, latest), do: nil, else: latest
    {[first, latest] |> Enum.reject(&is_nil/1), 0}
  end

  defp same_preview?(%{text: text}, %{text: text}), do: true
  defp same_preview?(_first, _latest), do: false

  defp bounded_candidate_history(history) do
    total = length(history)

    indexed =
      if total <= 20 do
        Enum.with_index(history, 1)
      else
        [{hd(history), 1} | Enum.with_index(Enum.take(history, -19), total - 18)]
      end

    previews =
      indexed
      |> Enum.map(fn {preview, index} ->
        position = preview["history_position"] || index
        candidate_preview(preview, "Message #{position}")
      end)
      |> Enum.reject(&is_nil/1)

    {previews, max(total - 20, 0)}
  end

  defp candidate_excerpt(nil, _objective, _latest_development), do: []

  defp candidate_excerpt(%{text: text}, objective, _latest_development)
       when text == objective,
       do: []

  defp candidate_excerpt(preview, _objective, _latest_development) do
    [
      "<p class=\"candidate-excerpt\">",
      escape(preview.text),
      if(preview.truncated, do: " <span>(truncated)</span>", else: []),
      "</p>"
    ]
  end

  defp candidate_history(previews, count, omitted) do
    Components.disclosure_html(
      "Message history",
      [
        if(omitted > 0,
          do: [
            "<p class=\"candidate-history-omission\">",
            count(omitted, "earlier message"),
            " omitted</p>"
          ],
          else: []
        ),
        Enum.map(previews, &candidate_preview_card/1)
      ],
      class: "candidate-history",
      meta: if(is_integer(count) and count > 1, do: count(count, "message"))
    )
  end

  defp related_candidate_history(previews, count, omitted, artifact_id, collapsed?) do
    Components.disclosure_html(
      "Related episode history",
      [
        "<p class=\"context-note\">Full history not supplied to routing",
        if(collapsed?, do: " · loads on open", else: []),
        "</p>",
        if(omitted > 0,
          do: [
            "<p class=\"candidate-history-omission\">",
            count(omitted, "message"),
            " not shown</p>"
          ],
          else: []
        ),
        Enum.map(previews, &candidate_preview_card/1)
      ],
      class: "candidate-history candidate-related-history",
      rest: %{"data-artifact" => artifact_id},
      meta: if(is_integer(count) and count > 1, do: count(count, "message"))
    )
  end

  defp candidate_preview_card(preview) do
    Components.message_block_html(
      nil,
      ["<p>", escape(preview.text), "</p>"],
      title: preview.label,
      class: "candidate-preview",
      meta: [
        if(preview.at, do: ["<time>", escape(preview.at), "</time>"], else: []),
        if(preview.truncated, do: "<span>(truncated)</span>", else: [])
      ]
    )
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
      |> maybe_reason(match["same_thread"] == true, "Same thread")
      |> maybe_reason(
        match["same_conversation"] == true and match["same_thread"] != true,
        "Same conversation"
      )
      |> maybe_reason(positive_number?(match["topic_fit"]), "Similar request")
      |> maybe_reason(match["active"] == true, "Active work")
      |> Enum.reverse()

    if reasons == [],
      do: [],
      else: [
        "<p class=\"candidate-rationale\"><strong>Matched on</strong> ",
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

  defp human(value) when is_map(value) or is_list(value), do: "Structured value"
  defp human(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp escape(value) when is_map(value) or is_list(value), do: escape(Jason.encode!(value))

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
