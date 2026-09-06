defmodule Responder.ControlPlane.EpisodeRequest do
  @moduledoc "A readable model call, with the retained evidence available inline."
  use Phoenix.Component

  alias Responder.ControlPlane.Components
  alias Responder.ControlPlane.PromptDocument
  alias Responder.ControlPlane.RequestContextHTML

  def render(assigns) do
    request = assigns.request

    assigns =
      assigns
      |> assign(:model, model(request.target))
      |> assign(:headline, headline(request))
      |> assign(:explanation, explanation(request))
      |> assign(:timing, request.timing)
      |> assign(:result?, request.phase == :result)
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
        :technical_sections,
        Enum.reject(
          request.sections,
          &(&1.id in ~w(instructions context) ||
              (request.phase == :submission && &1.id == "request"))
        )
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
      <dl :if={@timing != []} class="request-timing">
        <div :for={metric <- @timing} :if={metric.value != "Not recorded"}>
          <dt>{timing_label(metric.label)}</dt><dd>{metric.value}</dd>
        </div>
      </dl>
      <div
        :if={!@result? && @input_sections != []}
        class="prompt-assembly"
        aria-label="Briefing sources"
      >
        <h4 class="sr-only">Briefing sources</h4>
        <%= for section <- @input_sections do %>
          {Phoenix.HTML.raw(assembly(section, @request))}
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
      <details :if={@prompt_section} class="final-prompt" id={"#{@request.id}-final-prompt"}>
        <summary>
          Full submitted prompt
          <span :if={@prompt_section.artifact.redacted}>Secrets redacted</span><span :if={
            @prompt_section.artifact.truncated
          }>Partial display</span>
        </summary>
        <p :if={@prompt_section.artifact.state == :retained} class="prompt-legend">
          Highlighted text is linked to its briefing source. Hover or focus a section to see its source path.
        </p>
        <p :if={@prompt_section.artifact.state != :retained}>
          {if @prompt_section.artifact.state == :expired, do: "Expired", else: "Not recorded"}
        </p>
        {Phoenix.HTML.raw(PromptDocument.render(@prompt_section.artifact))}
      </details>
      <details
        :if={@result?}
        class="request-evidence request-result-evidence"
        id={"#{@request.id}-evidence"}
      >
        <summary>Response & validation records</summary>
        <.artifact_text
          :for={section <- @request.sections}
          section={section}
        />
      </details>
      <details class="request-provenance" id={"#{@request.id}-provenance"}>
        <summary>Request record</summary>
        <p>{@request.coverage}</p>
        <a href={@request.href}>Open full request record →</a>
        <.artifact_text
          :for={section <- @technical_sections}
          :if={!@result?}
          section={section}
        />
      </details>
    </div>
    """
  end

  defp assembly(%{id: "instructions", artifact: artifact}, request),
    do: RequestContextHTML.assembly_instructions(artifact, request.id)

  defp assembly(%{id: "context", artifact: artifact}, request),
    do: RequestContextHTML.assembly(artifact, context_root(request), request.id)

  defp context_root(%{source_kind: :admission}), do: "$.context"
  defp context_root(_), do: "$.work"

  defp unavailable_assembly?(%{id: "instructions", artifact: artifact}),
    do: artifact.state != :retained

  defp unavailable_assembly?(section),
    do:
      section.artifact.state != :retained || section.artifact.truncated ||
        not is_map(document(%{sections: [section]}, "context"))

  # The main timeline uses a single disclosure for raw evidence. Identity and
  # artifact-level inspection remain on the linked full request record.
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
    case document(request, "validation") do
      %{"verdict" => %{"verdict" => "reject"}} -> "Answer needs correction"
      %{"verdict" => %{"verdict" => "accept"}} -> "Answer passed validation"
      _ -> "Model result"
    end
  end

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
    case document(request, "validation") do
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

  defp availability(%{state: :expired}), do: "Expired"
  defp availability(%{state: :not_recorded}), do: "Not recorded"
  defp availability(%{truncated: true}), do: "Partial display"
  defp availability(_), do: nil
  defp timing_label("Coop queue"), do: "Queue"
  defp timing_label("Agent execution"), do: "Model execution"
  defp timing_label("Host processing"), do: "Processing"
  defp timing_label(label), do: label
end
