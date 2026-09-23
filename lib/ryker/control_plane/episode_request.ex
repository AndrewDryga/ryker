defmodule Ryker.ControlPlane.EpisodeRequest do
  @moduledoc "A readable model call, with the retained evidence available inline."
  use Phoenix.Component

  alias Ryker.ControlPlane.Components
  alias Ryker.ControlPlane.RequestContextHTML
  alias Ryker.ControlPlane.RequestPage

  def render(assigns) do
    request = assigns.request
    archived = RequestPage.latest_archived_response(request.sections)

    assigns =
      assigns
      |> assign(:headline, headline(request))
      |> assign(:explanation, explanation(request))
      |> assign(:timing, request.timing)
      |> assign(:decision, decision_facts(request))
      |> assign(:candidate_outcomes, candidate_outcomes(request))
      |> assign(:result?, request.phase == :result)
      |> assign(:archived_response, archived)
      |> assign(
        :response,
        if(request.phase == :result && request.source_kind == :work && !archived,
          do: document(request, "candidate")
        )
      )
      |> assign(:record_links, request[:record_links] || %{})
      |> assign(:contract_section, Enum.find(request.sections, &(&1.id == "contract")))
      |> assign(:applied, applied_context(request))
      |> assign(
        :prompt_section,
        if(request.phase == :submission, do: Enum.find(request.sections, &(&1.id == "request")))
      )
      |> assign(
        :input_sections,
        Enum.filter(request.sections, &(&1.id in ~w(instructions context)))
      )
      |> assign(
        :result_evidence,
        result_evidence(request)
      )

    ~H"""
    <div class="episode-request">
      <Components.card_heading title={@headline} meta_layout={:stack_on_narrow}>
        <:description :if={!@result? && @explanation}>{@explanation}</:description>
        <:meta>
          <div class="request-model"><Components.execution_target target={@request.target} /></div>
        </:meta>
      </Components.card_heading>
      <p :if={@result? && @explanation} class="request-rationale">
        {@explanation}
      </p>
      <section
        :if={@applied != []}
        class="applied-context"
        aria-label="Saved context used by this call"
      >
        <div :for={group <- @applied}>
          <h4>{group.title}</h4>
          <ul>
            <li :for={entry <- group.entries}>
              <strong :if={entry.title}>{entry.title}</strong><span>{entry.text}</span>
            </li>
          </ul>
          <a href={group.href}>Manage {group.manage} →</a>
        </div>
      </section>
      <dl :if={@decision != []} class="request-decision">
        <div :for={fact <- @decision}>
          <dt>{fact.label}</dt>
          <dd>
            <a :if={fact[:href]} href={fact.href}>{fact.value}</a>
            <Components.identifier :if={fact[:identifier]} value={fact.value} label={fact.label} />
            <span :if={!fact[:href] && !fact[:identifier]}>{fact.value}</span>
          </dd>
        </div>
      </dl>
      <Components.disclosure
        :if={@candidate_outcomes != []}
        id={"#{@request.id}-candidate-outcomes"}
        label="Candidate outcomes"
        class="routing-candidate-outcomes"
      >
        <ul>
          <li :for={outcome <- @candidate_outcomes}>
            <a href={outcome.href}>{outcome.title}</a><span> · {outcome.status}</span>
          </li>
        </ul>
      </Components.disclosure>
      <dl :if={@timing != []} class="request-timing">
        <div :for={metric <- @timing} :if={metric.value != "Not recorded"}>
          <dt>{timing_label(metric.label)}</dt><dd>{metric.value}</dd>
        </div>
      </dl>
      <div
        :if={!@result? && (@input_sections != [] || @contract_section)}
        class="prompt-assembly"
        aria-label="Briefing sources"
      >
        <h4 class="sr-only">Briefing sources</h4>
        {Phoenix.HTML.raw(
          RequestContextHTML.briefing(
            @request.sections,
            @request.source_kind,
            @request.id,
            @request[:counts] || %{}
          )
        )}
        <%= for section <- @input_sections do %>
          <Components.disclosure
            :if={unavailable_assembly?(section)}
            class="briefing-unavailable"
            id={"#{@request.id}-#{section.id}-unavailable"}
            label={section.title}
            kind={:source}
          >
            <:meta>{availability(section.artifact) || "Unstructured record"}</:meta>
            <.artifact_text section={section} />
          </Components.disclosure>
        <% end %>
      </div>
      <section :if={@prompt_section} class="final-prompt" id={"#{@request.id}-final-prompt"}>
        <header>
          <h4>
            Full submitted request<span :if={@prompt_section.artifact.redacted}>Secrets redacted</span><span :if={
              @prompt_section.artifact.truncated
            }>Partial display</span>
          </h4>
        </header>
        {Phoenix.HTML.raw(
          RequestContextHTML.submitted(
            @request.sections,
            @request.id <> "-submitted",
            @prompt_section[:artifact_id]
          )
        )}
      </section>
      <section :if={is_map(@response)} class="response-review">
        <Components.message_block :if={is_binary(@response["message"])} sender="Ryker">
          {Phoenix.HTML.raw(Ryker.ControlPlane.SlackMarkdown.preview(@response["message"]))}
        </Components.message_block>
        <p :if={is_binary(@response["decision_reason"])}>{@response["decision_reason"]}</p>
        <div :if={response_records(@response) != []} class="response-records">
          <h4>Supporting records</h4>
          <p>These records were created during the work and selected to support this response.</p>
          <ul>
            <li :for={ref <- response_records(@response)}>
              <a :if={@record_links[ref]} href={@record_links[ref].href}>{@record_links[ref].title}</a>
              <code :if={!@record_links[ref]}>{ref}</code>
            </li>
          </ul>
        </div>
      </section>
      <p :if={@archived_response} class="response-reference">
        <a href={"#turn-#{String.replace_prefix(@request.id, "request-", "") |> String.replace_suffix("-result", "")}-response-#{@archived_response.attempt}-body"}>
          View response with attempt {@archived_response.attempt}'s checks ↑
        </a>
      </p>
      <div
        :if={@result? && !@archived_response && @result_evidence != []}
        class="routing-evidence"
        aria-label="Routing evidence"
      >
        <.artifact_disclosure
          :for={section <- @result_evidence}
          id={"#{@request.id}-evidence-#{section.id}"}
          section={section}
          source_kind={@request.source_kind}
        />
      </div>
    </div>
    """
  end

  defp unavailable_assembly?(%{id: "instructions", artifact: artifact}),
    do: artifact.state != :retained

  defp unavailable_assembly?(section),
    do:
      section.artifact.state != :retained || section.artifact.truncated ||
        not is_map(document(%{sections: [section]}, "context"))

  defp result_evidence(%{source_kind: :work, sections: sections}),
    do: Enum.filter(sections, &(&1.id == "candidate"))

  defp result_evidence(%{source_kind: :admission, sections: sections} = request) do
    ids =
      if decision_artifact_needed?(request),
        do: ~w(routing response candidate),
        else: ~w(routing response)

    Enum.filter(sections, &(&1.id in ids))
  end

  defp result_evidence(_request), do: []

  # The committed decision and timings are already readable above this point.
  # These peer disclosures retain only the records that explain how routing
  # selected its context and the exact model response that proposed the result.
  defp artifact_disclosure(assigns) do
    assigns =
      assigns
      |> assign(:label, evidence_label(assigns.section, assigns.source_kind))
      |> assign(:meta, artifact_meta(assigns.section.artifact))
      |> assign(:selection_facts, selection_facts(assigns.section))

    ~H"""
    <Components.disclosure
      id={@id}
      label={@label}
      kind={:source}
      class={["routing-evidence-item", "artifact-#{@section.id}"]}
    >
      <:meta :if={@meta}>{@meta}</:meta>
      <dl :if={@selection_facts} class="selection-evidence-facts">
        <div :for={fact <- @selection_facts}>
          <dt>{fact.label}</dt><dd>{fact.value}</dd>
        </div>
      </dl>
      <Components.disclosure
        :if={@selection_facts}
        id={@id <> "-technical"}
        label="Technical record"
        class="selection-evidence-technical"
      >
        <pre class="model-document-text" tabindex="0">{@section.artifact.text}</pre>
      </Components.disclosure>
      <pre
        :if={@section.artifact.state == :retained && !@selection_facts}
        class="model-document-text"
        tabindex="0"
      >{@section.artifact.text}</pre>
      <p :if={@section.artifact.state != :retained} class="artifact-unavailable">
        {@meta || "This record was not retained."}
      </p>
    </Components.disclosure>
    """
  end

  defp evidence_label(%{id: "routing"}, _kind), do: "Selection evidence"
  defp evidence_label(%{id: "response"}, _kind), do: "Raw routing response"
  defp evidence_label(%{id: "candidate"}, :work), do: "Raw model response"
  defp evidence_label(section, _kind), do: section.title

  defp artifact_meta(%{state: :retained, text: text, bytes: bytes} = artifact) do
    kind =
      if is_binary(text) && match?({:ok, _value}, Jason.decode(text)), do: "JSON", else: "Text"

    [
      kind,
      artifact_size(bytes),
      artifact[:redacted] && "Secrets redacted",
      artifact[:truncated] && "Partial display"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp artifact_meta(artifact), do: availability(artifact)

  defp artifact_size(nil), do: "Size not recorded"
  defp artifact_size(count) when count < 1_024, do: "#{count} bytes"
  defp artifact_size(count), do: "#{div(count, 1_024)} KiB"

  defp decision_artifact_needed?(request) do
    case Enum.find(request.sections, &(&1.id == "candidate")) do
      %{artifact: %{state: state}} when state != :not_recorded ->
        is_nil(document(request, "candidate"))

      _ ->
        false
    end
  end

  defp selection_facts(%{id: "routing", artifact: artifact}) do
    case artifact_document(artifact) do
      %{} = evidence -> routing_facts(evidence)
      _ -> nil
    end
  end

  defp selection_facts(_section), do: nil

  defp routing_facts(evidence) do
    receipt = if is_map(evidence["routing_receipt"]), do: evidence["routing_receipt"], else: %{}

    manifest =
      if is_map(evidence["context_manifest"]), do: evidence["context_manifest"], else: %{}

    [
      routing_candidate_fact(receipt),
      routing_omission_fact(receipt),
      routing_scope_fact(receipt),
      routing_lanes_fact(receipt),
      routing_context_fact(manifest)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      facts -> facts
    end
  end

  defp routing_candidate_fact(%{"offered" => offered, "examined" => examined})
       when is_integer(offered) and is_integer(examined),
       do: %{label: "Candidates", value: "#{offered} of #{examined} supplied"}

  defp routing_candidate_fact(_receipt), do: nil

  defp routing_omission_fact(%{"omitted" => omitted} = receipt)
       when is_integer(omitted) and omitted > 0 do
    reason = receipt["cutoff_reason"] |> readable_code()
    value = "#{omitted} omitted" <> if(reason, do: " · #{reason}", else: "")
    %{label: "Why some were excluded", value: value}
  end

  defp routing_omission_fact(_receipt), do: nil

  defp routing_scope_fact(%{"scope" => scope} = receipt) when is_binary(scope) do
    conversations = receipt["eligible_conversations"]

    value =
      readable_code(scope) <>
        if(is_integer(conversations), do: " · #{conversations} eligible conversations", else: "")

    %{label: "Search scope", value: value}
  end

  defp routing_scope_fact(_receipt), do: nil

  defp routing_lanes_fact(%{"lanes" => lanes}) when is_map(lanes) and map_size(lanes) > 0 do
    value =
      lanes
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(" · ", fn {lane, facts} ->
        returned = if is_map(facts), do: facts["returned"]
        saturated = is_map(facts) && facts["saturated"] == true

        readable_code(lane) <>
          if(is_integer(returned), do: " #{returned}", else: "") <>
          if(saturated, do: " (limit reached)", else: "")
      end)

    %{label: "Search lanes", value: value}
  end

  defp routing_lanes_fact(_receipt), do: nil

  defp routing_context_fact(%{"included" => included, "requested" => requested})
       when is_integer(included) and is_integer(requested),
       do: %{
         label: "Conversation context",
         value: "#{included} of #{requested} earlier messages included"
       }

  defp routing_context_fact(_manifest), do: nil

  defp artifact_document(%{state: :retained, truncated: false, text: text})
       when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = document} -> document
      _ -> nil
    end
  end

  defp artifact_document(_artifact), do: nil

  defp readable_code(value) when is_binary(value) and value != "" do
    value |> String.replace("_", " ") |> String.capitalize()
  end

  defp readable_code(_value), do: nil

  # Identity and artifact-level inspection remain on the linked full request
  # record; this is the body inside a disclosure that already named the record.
  defp artifact_text(assigns) do
    ~H"""
    <section class={"timeline-artifact artifact-#{@section.id}"}>
      <pre :if={@section.artifact.state == :retained}>{@section.artifact.text}</pre>
      <p :if={@section.artifact.state != :retained}>{availability(@section.artifact)}</p>
    </section>
    """
  end

  defp applied_context(%{phase: :submission} = request) do
    case document(request, "context") do
      %{"operator_context" => context} when is_map(context) ->
        [
          %{
            title: "Standing rules used",
            manage: "rules",
            href: "/rules",
            entries: context_entries(context["standing_assignments"], "title", "task")
          },
          %{
            title: "Preferences used",
            manage: "preferences",
            href: "/preferences",
            entries: preference_entries(context["preferences"])
          },
          %{
            title: "Guidance recalled",
            manage: "guidance",
            href: "/guidance",
            entries: context_entries(context["guidance"], "subject", "summary")
          },
          %{
            title: "Memory recalled",
            manage: "memory",
            href: "/memory",
            entries: context_entries(context["memory"], "subject", "value")
          }
        ]
        |> Enum.reject(&(&1.entries == []))

      _ ->
        []
    end
  end

  defp applied_context(_), do: []

  defp context_entries(entries, title_key, text_key) when is_list(entries) do
    Enum.flat_map(entries, fn
      %{} = entry ->
        case entry[text_key] do
          text when is_binary(text) -> [%{title: safe_title(entry[title_key]), text: text}]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp context_entries(_, _, _), do: []
  defp safe_title(value) when is_binary(value), do: value
  defp safe_title(_), do: nil

  defp preference_entries(entries) when is_map(entries) do
    entries
    |> Enum.sort()
    |> Enum.flat_map(fn
      {key, %{"value" => value}} when is_binary(value) ->
        [
          %{
            title: Components.label(key),
            text: Components.label(value)
          }
        ]

      _ ->
        []
    end)
  end

  defp preference_entries(_), do: []

  defp headline(%{phase: :submission, source_kind: :admission}), do: "Routing briefing"
  defp headline(%{phase: :submission}), do: "Model briefing"

  defp headline(%{source_kind: :admission} = request) do
    case document(request, "candidate") do
      %{"action" => "reply", "work_class" => "conversational"} -> "Conversational reply"
      %{"action" => "reply"} -> "Reply requested"
      %{"action" => "ignore"} -> "No reply needed"
      %{"action" => "react"} -> "Reaction selected"
      %{"action" => "start_episode"} -> "New work requested"
      %{"action" => "continue_episode"} -> "Continue existing work"
      _ -> "Routing result"
    end
  end

  defp headline(request) do
    case {document(request, "candidate"), document(request, "validation")} do
      {%{}, _} -> "Model response"
      {_, %{"verdict" => %{"verdict" => "reject"}}} -> "Answer needs correction"
      {_, %{"verdict" => %{"verdict" => "accept"}}} -> "Answer passed validation"
      _ -> "Model result"
    end
  end

  # The routing card showed a paragraph of reasoning and two timings, while the
  # record behind it held the decision itself. These are the parts a person
  # reads to know what happened: what it chose to do, whether it joined existing
  # work, and what kind of work it asked for.
  defp decision_facts(%{source_kind: :admission} = request) do
    case document(request, "candidate") do
      %{"action" => action} = candidate ->
        [
          %{label: "Decision", value: decision_label(action)},
          (request[:candidate_links] || %{})[candidate["episode_ref"]] || relation_fact(candidate),
          work_fact(candidate),
          source_fact(candidate),
          reaction_fact(candidate)
        ]
        |> Enum.reject(&is_nil/1)

      _other ->
        []
    end
  end

  defp decision_facts(%{source_kind: :work, execution_mode: mode})
       when mode in [:live, :shadow],
       do: [%{label: "Run mode", value: run_mode(mode)}]

  defp decision_facts(_request), do: []

  defp candidate_outcomes(%{source_kind: :admission, phase: :result} = request) do
    case document(request, "candidate") do
      %{} = result ->
        selected_ref = result["episode_ref"]
        relation = result["relation"]

        request
        |> Map.get(:candidate_links, %{})
        |> Enum.map(fn {ref, candidate} ->
          %{
            title: candidate.value,
            href: candidate.href,
            status:
              candidate_outcome(
                ref,
                candidate.allowed_relations,
                selected_ref,
                relation,
                result["action"]
              ),
            selected: ref == selected_ref
          }
        end)
        |> Enum.sort_by(fn outcome -> {not outcome.selected, outcome.title} end)

      _ ->
        []
    end
  end

  defp candidate_outcomes(_request), do: []

  defp candidate_outcome(ref, _allowed, ref, "same_work", _action),
    do: "Selected for continuation"

  defp candidate_outcome(ref, _allowed, ref, _relation, "continue_episode"),
    do: "Selected for continuation"

  defp candidate_outcome(ref, _allowed, ref, "history_only", _action),
    do: "Selected as background"

  defp candidate_outcome(ref, _allowed, ref, _relation, _action), do: "Selected"

  defp candidate_outcome(_ref, allowed, _selected_ref, _relation, _action) do
    if "same_work" in allowed, do: "Not selected for continuation", else: "Background only"
  end

  defp run_mode(:live), do: "Live"
  defp run_mode(:shadow), do: "Evaluation"

  defp decision_label("start_episode"), do: "Start new work"
  defp decision_label("continue_episode"), do: "Continue existing work"
  defp decision_label("reply"), do: "Reply in the conversation"
  defp decision_label("react"), do: "React only"
  defp decision_label("ignore"), do: "No response"
  defp decision_label(action) when is_binary(action), do: String.replace(action, "_", " ")

  defp relation_fact(%{"episode_ref" => "candidate:" <> _ = ref}),
    do: %{label: "Selected work", value: ref, identifier: true}

  defp relation_fact(%{"episode_ref" => ref}) when is_binary(ref) and ref != "",
    do: %{label: "Joins", value: ref, href: "/timeline/#{URI.encode_www_form(ref)}"}

  defp relation_fact(%{"relation" => relation}) when is_binary(relation),
    do: %{label: "Earlier work", value: relation_label(relation)}

  defp relation_fact(_candidate), do: nil

  defp relation_label("unrelated"), do: "Separate request"
  defp relation_label("same_work"), do: "Continuation"
  defp relation_label("history_only"), do: "Background context"
  defp relation_label(relation), do: readable_code(relation)

  defp work_fact(%{"work_class" => class}) when is_binary(class),
    do: %{label: "Work", value: String.replace(class, "_", " ")}

  defp work_fact(_candidate), do: nil

  defp source_fact(%{"repository_source" => %{"kind" => kind, "name" => name}})
       when is_binary(kind) and is_binary(name),
       do: %{label: "Source", value: "#{kind} #{name}"}

  defp source_fact(_candidate), do: nil

  defp reaction_fact(%{"reaction" => %{"emoji_name" => emoji}}) when is_binary(emoji),
    do: %{label: "Reaction", value: ":#{emoji}:"}

  defp reaction_fact(_candidate), do: nil

  defp explanation(%{phase: :submission, source_kind: :admission}),
    do: "Classify this message and choose how to respond."

  defp explanation(%{phase: :submission} = request) do
    case document(request, "context") do
      %{"mode" => "continuation"} ->
        "Continue with the new messages and the saved conversation context."

      _ ->
        nil
    end
  end

  defp explanation(%{source_kind: :admission} = request) do
    case document(request, "candidate") do
      %{"reason" => reason} when is_binary(reason) -> reason
      _ -> nil
    end
  end

  defp explanation(request) do
    case if(is_nil(document(request, "candidate")), do: document(request, "validation")) do
      %{"candidate_attempt" => attempt, "verdict" => %{"verdict" => verdict}}
      when is_integer(attempt) and verdict in ~w(accept reject) ->
        "Candidate #{attempt} " <>
          if(verdict == "accept",
            do: "passed the host's checks.",
            else: "was returned for correction."
          )

      _ ->
        nil
    end
  end

  defp response_records(%{"outcome" => %{"record_refs" => refs}}) when is_list(refs),
    do: Enum.filter(refs, &is_binary/1)

  defp response_records(_), do: []

  # Decode only complete, already-sanitized artifacts. A partial archive must
  # not become a confident routing or validation explanation.
  defp document(request, id) do
    case Enum.find(request.sections, &(&1.id == id)) do
      %{artifact: %{state: :retained, truncated: false, text: text}} ->
        case Jason.decode(text) do
          {:ok, value} when is_map(value) -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Retention, redaction and a withdrawn authorization all remove the body. The
  # reader's open disclosure must not be restored around content that is gone.

  defp availability(%{state: :collapsed}), do: nil
  defp availability(%{state: :expired}), do: "Expired"
  defp availability(%{state: :not_recorded}), do: "Not recorded"
  defp availability(%{truncated: true}), do: "Partial display"
  defp availability(_), do: nil
  defp timing_label("Coop queue"), do: "Queue"
  defp timing_label("Agent execution"), do: "Model execution"
  defp timing_label("Host processing"), do: "Processing"
  defp timing_label(label), do: label
end
