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
      |> assign(:model, model(request.target))
      |> assign(:headline, headline(request))
      |> assign(:explanation, explanation(request))
      |> assign(:timing, request.timing)
      |> assign(:decision, decision_facts(request))
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

    ~H"""
    <div class="episode-request">
      <div class="case-request-heading">
        <h3>{@headline}</h3>
        <div class="request-model" title={@request.target}>
          <strong>{@model.name}</strong><span>{@model.account}</span>
        </div>
      </div>
      <p :if={@explanation} class="request-explanation">{@explanation}</p>
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
            <a :if={fact[:href]} href={fact.href}>{fact.value}</a><span :if={!fact[:href]}>{fact.value}</span>
          </dd>
        </div>
      </dl>
      <dl :if={@timing != []} class="request-timing">
        <div :for={metric <- @timing} :if={metric.value != "Not recorded"}>
          <dt>{timing_label(metric.label)}</dt><dd>{metric.value}</dd>
        </div>
      </dl>
      <details
        :if={@request.phase == :submission && technical_details(@request) != []}
        class="request-technical-details case-event-details"
      >
        <summary>Technical details</summary>
        <dl>
          <div :for={fact <- technical_details(@request)}>
            <dt>{fact.label}</dt><dd>{fact.value}</dd>
          </div>
        </dl>
      </details>
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
          <details
            :if={unavailable_assembly?(section)}
            class="briefing-unavailable"
            id={"#{@request.id}-#{section.id}-unavailable"}
          >
            <summary>
              {section.title} <span>{availability(section.artifact) || "Unstructured record"}</span>
            </summary>
            <.artifact_text section={section} />
          </details>
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
        <div :if={is_binary(@response["message"])} class="markdown-preview">
          {Phoenix.HTML.raw(Ryker.ControlPlane.SlackMarkdown.preview(@response["message"]))}
        </div>
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
      <section
        :if={@result? && !@archived_response}
        class="request-evidence request-result-evidence"
        id={"#{@request.id}-evidence"}
      >
        <h4>{if @request.source_kind == :work, do: "Raw model response", else: "Routing records"}</h4>
        <.artifact_disclosure
          :for={section <- @request.sections}
          :if={@request.source_kind != :work || section.id == "candidate"}
          id={"#{@request.id}-evidence-#{section.id}"}
          section={section}
        />
      </section>
    </div>
    """
  end

  defp unavailable_assembly?(%{id: "instructions", artifact: artifact}),
    do: artifact.state != :retained

  defp unavailable_assembly?(section),
    do:
      section.artifact.state != :retained || section.artifact.truncated ||
        not is_map(document(%{sections: [section]}, "context"))

  # One disclosure per record, not one disclosure over all of them. A routing
  # result carries the evidence, the committed decision, the milestones and the
  # exact response; stacking every one of them inside a single "Routing records"
  # toggle meant opening all of it to read any of it, and the titles that say
  # which is which were only visible after that.
  defp artifact_disclosure(assigns) do
    assigns = assign(assigns, :rows, decided_rows(assigns.section))

    ~H"""
    <details class={"timeline-artifact artifact-#{@section.id}"} id={@id}>
      <summary>
        {@section.title}<span :if={availability(@section.artifact)}>{availability(@section.artifact)}</span>
      </summary>
      <dl :if={@rows != []} class="context-rows">
        <div :for={{label, value} <- @rows}>
          <dt>{label}</dt><dd>{value}</dd>
        </div>
      </dl>
      <pre :if={@section.artifact.state == :retained}>{@section.artifact.text}</pre>
    </details>
    """
  end

  # "What can we extract from routing records to make this informative?" — the
  # committed decision is the record a reader opens this section for, and it was
  # a JSON blob. Its own fields answer the question directly: what the host
  # decided, how it related this to existing work, and why.
  @decision_rows [
    {"action", "Decision"},
    {"work_class", "Work class"},
    {"relation", "Relation to existing work"},
    {"episode_ref", "Related episode"},
    {"reaction", "Reaction"},
    {"reason", "Reason"}
  ]

  defp decided_rows(%{id: "candidate", artifact: %{state: :retained, text: text}})
       when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decision} when is_map(decision) ->
        for {key, label} <- @decision_rows,
            value = decision[key],
            is_binary(value) and value != "",
            do: {label, value}

      _other ->
        []
    end
  end

  defp decided_rows(_section), do: []

  # Identity and artifact-level inspection remain on the linked full request
  # record; this is the body inside a disclosure that already named the record.
  defp artifact_text(assigns) do
    ~H"""
    <section class={"timeline-artifact artifact-#{@section.id}"}>
      <h4>{@section.title}</h4>
      <p :if={availability(@section.artifact)}>{availability(@section.artifact)}</p>
      <pre :if={@section.artifact.state == :retained}>{@section.artifact.text}</pre>
    </section>
    """
  end

  def model(target) when is_binary(target) do
    case Regex.run(~r/\A([^:]+):([^@]+)(?:@(.+))?\z/, target) do
      [_, provider, name, profile] -> %{name: name, account: provider <> " · " <> profile}
      [_, provider, name] -> %{name: name, account: provider}
      _ -> %{name: target, account: nil}
    end
  end

  def model(_), do: %{name: "Model not recorded", account: nil}

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

  defp technical_details(request) do
    [
      technical_detail("Request", request[:request_id]),
      technical_detail("Policy", request[:policy]),
      technical_detail("Fingerprint", request[:fingerprint])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp technical_detail(label, value) when is_binary(value) and value != "",
    do: %{label: label, value: value}

  defp technical_detail(_label, _value), do: nil

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
      {%{}, _} -> "Response to validate"
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
          relation_fact(candidate),
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

  defp run_mode(:live), do: "Live"
  defp run_mode(:shadow), do: "Evaluation"

  defp decision_label("start_episode"), do: "Start new work"
  defp decision_label("continue_episode"), do: "Continue existing work"
  defp decision_label("reply"), do: "Reply in the conversation"
  defp decision_label("react"), do: "React only"
  defp decision_label("ignore"), do: "No response"
  defp decision_label(action) when is_binary(action), do: String.replace(action, "_", " ")

  defp relation_fact(%{"episode_ref" => ref}) when is_binary(ref) and ref != "",
    do: %{label: "Joins", value: ref, href: "/timeline/#{URI.encode_www_form(ref)}"}

  defp relation_fact(%{"relation" => relation}) when is_binary(relation),
    do: %{label: "Relation", value: String.replace(relation, "_", " ")}

  defp relation_fact(_candidate), do: nil

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
