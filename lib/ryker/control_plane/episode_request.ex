defmodule Ryker.ControlPlane.EpisodeRequest do
  @moduledoc "A readable model call, with the retained evidence available inline."
  use Phoenix.Component
  alias Ryker.Admission.Sentiment
  alias Ryker.ControlPlane.CallRun
  alias Ryker.ControlPlane.Components
  alias Ryker.ControlPlane.Paths
  alias Ryker.ControlPlane.RequestContextHTML
  alias Ryker.ControlPlane.RoutingReason
  alias Ryker.ControlPlane.Units
  alias Ryker.Episodes.Words

  # Background calls about a request that send no reply: learning from its
  # messages, and the self-analysis of a request a person was unhappy with.
  # Their cards carry what they decided under `background`.
  @background_kinds [:learning, :improvement]

  def render(assigns) do
    request = assigns.request
    archived = latest_archived_response(request.sections)

    assigns =
      assigns
      |> assign(:headline, headline(request))
      |> assign(:attempt, attempt_label(request))
      |> assign(:explanation, explanation(request))
      |> assign(:decision, decision_facts(request))
      |> assign(:result?, request.phase == :result)
      |> assign(:run, if(request.phase == :result, do: request[:run]))
      |> assign(:retried_after, if(request.phase == :result, do: request[:retried_after]))
      |> assign(:reason_from_model?, reason_from_model?(request))
      |> assign(:archived_response, archived)
      |> assign(
        :response,
        if(request.phase == :result && request.source_kind == :work && !archived,
          do: document(request, "candidate")
        )
      )
      |> assign(:record_links, request[:record_links] || %{})
      |> assign(:model_reason, model_reason(request))
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
      |> assign(:retention_note, request[:retention_note])

    ~H"""
    <div class="episode-request">
      <Components.card_heading title={@headline}>
        <:detail :if={@attempt}>{@attempt}</:detail>
        <:description :if={!@result? && @explanation}>{@explanation}</:description>
        <:meta :if={@run && @run.total_ms}>took {Units.duration(@run.total_ms)}</:meta>
      </Components.card_heading>
      <p :if={@retried_after} class="request-retry">
        Retried after attempt {@retried_after.generation} failed: {lower_first(
          sentence(@retried_after.summary)
        )} <a href={@retried_after.href}>See attempt {@retried_after.generation} ↑</a>
      </p>
      <p :if={@retention_note} class="artifact-unavailable request-retention">{@retention_note}</p>
      <section :if={!@result?} class="request-model-section" aria-label="Model">
        <h4>Model</h4>
        <Components.execution_target target={@request.target} />
        <p class="request-model-reason">
          {@model_reason} <.link navigate="/settings/models">Settings</.link>
        </p>
      </section>
      <p :if={@result? && @explanation} class="request-rationale">
        <small :if={@reason_from_model?}>Model's reason</small>{@explanation}
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
            <span :if={fact[:value] && !fact[:href] && !fact[:identifier]}>{fact.value}</span>
            <span :if={fact[:note]} class="request-decision-note"> · {fact.note}</span>
            <ul :if={fact[:outcomes] not in [nil, []]} class="routing-candidate-outcomes">
              <li :for={outcome <- fact.outcomes} data-selected={to_string(outcome.selected)}>
                <span class="considered-verdict">{outcome.status}</span>
                <a href={outcome.href} title="Where the briefing offered it">
                  {outcome.title} <span aria-hidden="true">↑</span>
                </a>
              </li>
            </ul>
          </dd>
        </div>
      </dl>
      <CallRun.table :if={@run} run={@run} />
      <p :for={wait <- @request[:waits] || []} class="request-wait">{wait_text(wait)}</p>
      <div
        :if={!@result? && !@retention_note && (@input_sections != [] || @contract_section)}
        class="prompt-assembly"
        aria-label="Briefing sources"
      >
        <h4 class="sr-only">Briefing sources</h4>
        {Phoenix.HTML.raw(briefing(@request))}
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
      <section
        :if={@prompt_section && !@retention_note}
        class="final-prompt"
        id={"#{@request.id}-final-prompt"}
      >
        <header>
          <h4>
            Full submitted request<span :if={@prompt_section.artifact.truncated}>Partial display</span>
          </h4>
        </header>
        {Phoenix.HTML.raw(submitted(@request, @prompt_section))}
      </section>
      <section :if={is_map(@response)} class="response-review">
        <Components.message_block :if={is_binary(@response["message"])} sender="Ryker">
          {Phoenix.HTML.raw(Ryker.ControlPlane.SlackMarkdown.preview(@response["message"]))}
        </Components.message_block>
        <p :if={is_binary(@response["decision_reason"])}>{@response["decision_reason"]}</p>
        <Components.title_update :if={@request[:title_update]} title={@request.title_update} />
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
      <Components.disclosure
        :if={@request[:identity]}
        id={"#{@request.id}-identity"}
        label="Details"
        class="request-identity"
      >
        <Components.fact_list facts={@request.identity.facts} />
        <a :if={@request.identity[:link]} href={@request.identity.link.href}>
          {@request.identity.link.label} →
        </a>
        <Components.disclosure
          :if={@request.identity[:record]}
          id={"#{@request.id}-receipts"}
          label={@request.identity.record_label}
          kind={:source}
        >
          <Components.copy_block label="Copy JSON">
            <pre class="model-document-text" tabindex="0">{@request.identity.record}</pre>
          </Components.copy_block>
        </Components.disclosure>
      </Components.disclosure>
    </div>
    """
  end

  # An answer sent exactly as it was checked is read once, in the
  # conversation, so its card keeps only what the conversation does not show
  # (`sent`). A title is shown only where the answer changed the request's
  # title (`title_update`); a title that stayed the same says nothing.
  def candidate_response(assigns) do
    assigns =
      assigns
      |> assign_new(:sent, fn -> false end)
      |> assign_new(:title_update, fn -> nil end)
      |> assign(:document, candidate_document(assigns.response))
      |> assign(:response_meta, candidate_response_meta(assigns.response))

    ~H"""
    <section
      :if={@response.state == :retained}
      class="candidate-response"
      id={"#{@prefix}-response-#{@attempt}"}
    >
      <div id={"#{@prefix}-response-#{@attempt}-body"} class="candidate-response-body" tabindex="-1">
        <Components.message_block
          :if={@document && is_binary(@document["message"]) && !@sent}
          sender="Ryker"
        >
          {Phoenix.HTML.raw(Ryker.ControlPlane.SlackMarkdown.preview(@document["message"]))}
        </Components.message_block>
        <p
          :if={@document && is_binary(@document["decision_reason"])}
          class="candidate-decision-reason"
        >
          {@document["decision_reason"]}
        </p>
        <Components.title_update :if={@title_update} title={@title_update} />
        <Components.disclosure
          id={"#{@prefix}-response-#{@attempt}-raw"}
          label="Raw response"
          kind={:source}
          class="candidate-response-raw"
        >
          <:meta>{@response_meta}</:meta>
          <Components.copy_block label="Copy JSON">
            <pre class="model-document-text" tabindex="0">{@response.text}</pre>
          </Components.copy_block>
        </Components.disclosure>
      </div>
    </section>
    <p :if={@response.state == :expired} class="artifact-unavailable">
      Response body expired for this attempt. Its check receipt is preserved here.
    </p>
    """
  end

  defp candidate_document(%{state: :retained, truncated: false, text: text}) do
    case Jason.decode(text) do
      {:ok, %{} = document} -> document
      _ -> nil
    end
  end

  defp candidate_document(_), do: nil

  defp candidate_response_meta(response) do
    kind = if candidate_document(response), do: "JSON", else: "Text"

    [
      kind,
      artifact_size(response.bytes),
      response.truncated && "Display truncated"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  @doc """
  The recorded response a turn's latest answer is kept as: the check that read
  it, when that check's archived response is exactly the answer's bytes.
  """
  def latest_archived_response(sections) do
    with %{artifact: %{state: :retained, sha256: digest}} <-
           Enum.find(sections, &(&1.id == "candidate")),
         %{artifact: %{state: :retained, truncated: false, text: text}, responses: responses} <-
           Enum.find(sections, &(&1.id == "validation")),
         {:ok, %{"candidate_attempt" => attempt, "history" => history}} when is_list(history) <-
           Jason.decode(text),
         %{"candidate_sha256" => ^digest} <-
           Enum.find(history, &(is_map(&1) && &1["candidate_attempt"] == attempt)),
         %{state: :retained, sha256: ^digest} = artifact <- responses[attempt] do
      %{attempt: attempt, artifact: artifact}
    else
      _ -> nil
    end
  end

  # Drawn from the whole entry rather than its sections alone: the entry
  # carries the names known when it loaded (`Names.revision/0`), so a name
  # Slack gives later draws the briefing again (2026-09-26).
  defp briefing(request) do
    RequestContextHTML.briefing(
      request.sections,
      request.source_kind,
      request.id,
      request[:counts] || %{}
    )
  end

  defp submitted(request, prompt_section) do
    RequestContextHTML.submitted(
      request.sections,
      request.id <> "-submitted",
      prompt_section[:artifact_id]
    )
  end

  defp unavailable_assembly?(%{id: "instructions", artifact: artifact}),
    do: artifact.state != :retained

  defp unavailable_assembly?(section) do
    section.artifact.state != :retained || section.artifact.truncated ||
      not is_map(document(%{sections: [section]}, "context"))
  end

  defp result_evidence(%{source_kind: :work, sections: sections}),
    do: Enum.filter(sections, &(&1.id == "candidate"))

  defp result_evidence(%{source_kind: :admission, sections: sections} = request) do
    # How the search chose the earlier work belongs to the briefing that
    # shows that work; the result keeps the model's exact response.
    ids =
      if decision_artifact_needed?(request),
        do: ~w(response candidate),
        else: ~w(response)

    Enum.filter(sections, &(&1.id in ids))
  end

  defp result_evidence(%{source_kind: kind, sections: sections}) when kind in @background_kinds,
    do: Enum.filter(sections, &(&1.id == "response" and &1.artifact.state == :retained))

  defp result_evidence(_request), do: []

  # The committed decision and timings are already readable above this point.
  # These peer disclosures retain the exact model response that proposed it.
  defp artifact_disclosure(assigns) do
    assigns =
      assigns
      |> assign(:label, evidence_label(assigns.section, assigns.source_kind))
      |> assign(:meta, artifact_meta(assigns.section.artifact))

    ~H"""
    <Components.disclosure
      id={@id}
      label={@label}
      kind={:source}
      class={["routing-evidence-item", "artifact-#{@section.id}"]}
    >
      <:meta :if={@meta}>{@meta}</:meta>
      <Components.copy_block :if={@section.artifact.state == :retained} label="Copy JSON">
        <pre class="model-document-text" tabindex="0">{@section.artifact.text}</pre>
      </Components.copy_block>
      <p :if={@section.artifact.state != :retained} class="artifact-unavailable">
        {@meta || "This record was not retained."}
      </p>
    </Components.disclosure>
    """
  end

  defp evidence_label(%{id: "response"}, kind) when kind in @background_kinds,
    do: "Raw model response"

  defp evidence_label(%{id: "response"}, _kind), do: "Raw routing response"
  defp evidence_label(%{id: "candidate"}, :work), do: "Raw model response"
  defp evidence_label(section, _kind), do: section.title

  defp artifact_meta(%{state: :retained, text: text, bytes: bytes} = artifact) do
    kind =
      if is_binary(text) && match?({:ok, _value}, Jason.decode(text)), do: "JSON", else: "Text"

    [
      kind,
      artifact_size(bytes),
      artifact[:truncated] && "Partial display"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp artifact_meta(artifact), do: availability(artifact)

  defp artifact_size(nil), do: "Size not recorded"
  defp artifact_size(count), do: Units.bytes(count)

  defp decision_artifact_needed?(request) do
    case Enum.find(request.sections, &(&1.id == "candidate")) do
      %{artifact: %{state: state}} when state != :not_recorded ->
        is_nil(document(request, "candidate"))

      _ ->
        false
    end
  end

  defp readable_code(value) when is_binary(value) and value != "" do
    value |> String.replace("_", " ") |> String.capitalize()
  end

  defp readable_code(_value), do: nil

  # Identity and artifact-level inspection remain on the linked full request
  # record; this is the body inside a disclosure that already named the record.
  defp artifact_text(assigns) do
    ~H"""
    <section class={"timeline-artifact artifact-#{@section.id}"}>
      <Components.copy_block :if={@section.artifact.state == :retained}>
        <pre>{@section.artifact.text}</pre>
      </Components.copy_block>
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
            href: "/instructions?show=preferences#saved",
            entries: preference_entries(context["preferences"])
          },
          %{
            title: "Guidance recalled",
            manage: "guidance",
            href: "/instructions?show=guidance#saved",
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
            title: Words.label(key),
            text: Words.label(value)
          }
        ]

      _ ->
        []
    end)
  end

  defp preference_entries(_), do: []

  # A job freezes its model from Ryker's settings when the work starts. A call
  # whose job is exactly one of today's settings says which; one whose job no
  # longer matches them (they changed since, or the job was shaped for its
  # task) says only where models are chosen, since today's settings do not
  # describe it. Either way the card links there (Andrew, 2026-09-29, of a
  # task's briefing with no line at all: "missing link to settings").
  defp model_reason(%{model_choice: %{settings: true} = choice}),
    do: "#{purpose(choice) || "This call"} uses the model set for it in"

  defp model_reason(_request), do: "Chosen when this work started, from the models set in"

  # Ryker's wait for the worker ran out while the call kept running; it picked
  # the same call back up. Part of this call, not a separate retry.
  defp wait_text(%{paused_at: %DateTime{} = paused, resumed_at: %DateTime{} = resumed}) do
    gap = DateTime.diff(resumed, paused, :millisecond)

    "Ryker's wait for the worker ran out at #{Calendar.strftime(paused, "%H:%M:%S")} while the " <>
      "call kept running, and it resumed waiting #{Units.duration(gap)} later."
  end

  defp wait_text(%{paused_at: %DateTime{} = paused}) do
    "Ryker's wait for the worker ran out at #{Calendar.strftime(paused, "%H:%M:%S")} while the call kept running."
  end

  defp failure_explanation(%{summary: summary}, _response) when is_binary(summary),
    do: sentence(summary)

  defp failure_explanation(_failure, %{"error_code" => code}) when is_binary(code),
    do: "The model call failed: #{String.replace(code, "_", " ")}."

  defp failure_explanation(_failure, _response), do: "The model call failed."

  defp sentence(text), do: if(String.ends_with?(text, "."), do: text, else: text <> ".")

  # Routing that ran more than once names each attempt, so a retried input's
  # cards read as the separate calls they were.
  defp attempt_label(%{source_kind: :admission, generation: generation, generations: generations})
       when is_integer(generation) and is_integer(generations) and generations > 1,
       do: "Attempt #{generation}"

  defp attempt_label(%{source_kind: kind, generation: generation, generations: total})
       when kind in @background_kinds and is_integer(generation) and is_integer(total) and
              total > 1,
       do: "Attempt #{generation}"

  defp attempt_label(_request), do: nil

  # What a work call is for, in the words of the work it was routed as.
  defp work_purpose(:conversational), do: "Use an AI model to answer in the conversation."
  defp work_purpose(:standard), do: "Use an AI model to investigate and respond."
  defp work_purpose(:deep), do: "Use an AI model for a deeper investigation."
  defp work_purpose(:contributor), do: "Use an AI model to make changes in a repository."
  defp work_purpose(:incident), do: "Use an AI model to work on the incident."

  defp work_purpose(purpose) when purpose in [:schedule, :schedule_read_only, :schedule_governed],
    do: "Use an AI model to run a scheduled task."

  defp work_purpose(_purpose), do: nil

  defp purpose(%{purpose: nil}), do: nil

  defp purpose(%{purpose: purpose, scope_kind: :repository, scope_name: repository}),
    do: "#{purpose_name(purpose)} in #{repository}"

  defp purpose(%{purpose: purpose}), do: purpose_name(purpose)

  defp purpose_name(:admission), do: "Routing"
  defp purpose_name(:conversational), do: "Conversational work"
  defp purpose_name(:standard), do: "Standard work"
  defp purpose_name(:deep), do: "Deep work"
  defp purpose_name(:contributor), do: "Contributor work"
  defp purpose_name(:schedule), do: "Scheduled work"
  defp purpose_name(:schedule_read_only), do: "Read-only scheduled work"
  defp purpose_name(:schedule_governed), do: "Governed scheduled work"
  defp purpose_name(:incident), do: "Incident work"
  defp purpose_name(:learning), do: "Learning"

  defp headline(%{phase: :submission, source_kind: :admission}), do: "Routing briefing"
  defp headline(%{phase: :submission, source_kind: :learning}), do: "Learning briefing"
  defp headline(%{phase: :submission, source_kind: :improvement}), do: "Self-analysis briefing"
  defp headline(%{phase: :submission}), do: "Work briefing"

  defp headline(%{source_kind: :admission} = request) do
    case {document(request, "candidate"), document(request, "response")} do
      {nil, %{"state" => "failed"}} -> "Routing failed"
      {candidate, _response} -> admission_headline(candidate)
    end
  end

  defp headline(%{source_kind: kind, background: %{headline: headline}})
       when kind in @background_kinds,
       do: headline

  defp headline(request) do
    case {document(request, "candidate"), document(request, "validation")} do
      {%{}, _} -> "Model response"
      {_, %{"verdict" => %{"verdict" => "reject"}}} -> "Answer needs correction"
      {_, %{"verdict" => %{"verdict" => "accept"}}} -> "Answer passed validation"
      _ -> "Model result"
    end
  end

  defp admission_headline(candidate) do
    case candidate do
      %{"action" => "reply", "work_class" => "conversational"} -> "Conversational reply"
      %{"action" => "reply"} -> "Reply requested"
      %{"action" => "ignore"} -> "No reply needed"
      %{"action" => "react"} -> "Reaction selected"
      %{"action" => "quick_reply"} -> "Answered right away"
      %{"action" => "start_episode"} -> "New work requested"
      %{"action" => "continue_episode"} -> "Continue existing work"
      _ -> "Routing result"
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
          %{
            label: "Decision",
            value: decision_label(action),
            note: work_meaning(candidate["work_class"])
          },
          earlier_work_fact(request, candidate),
          source_fact(candidate),
          reaction_fact(candidate),
          sentiment_fact(document(request, "response"))
          | answer_facts(candidate)
        ]
        |> Enum.reject(&is_nil/1)

      _other ->
        []
    end
  end

  # A live run is the normal case and says nothing; an evaluation run is the
  # one a reader must not mistake for a delivered answer.
  defp decision_facts(%{source_kind: :work, execution_mode: :shadow}),
    do: [%{label: "Run", value: "Evaluation", note: "checked, but never delivered"}]

  # What a learning attempt saved, proposed or held back, linked to the topics
  # it wrote, and how many of the messages it read are this page's; what a
  # self-analysis found, and how sure it was.
  defp decision_facts(%{source_kind: kind, phase: :result, background: %{facts: facts}})
       when kind in @background_kinds,
       do: facts

  defp decision_facts(_request), do: []

  # The earlier work the briefing offered, each with what the decision did
  # with it. With nothing offered, how the message relates to earlier work.
  defp earlier_work_fact(request, candidate) do
    case candidate_outcomes(request) do
      [] -> unoffered_work_fact(candidate)
      outcomes -> offered_work_fact(candidate, outcomes)
    end
  end

  defp unoffered_work_fact(candidate) do
    with %{label: "Earlier work"} = fact <- relation_fact(candidate) do
      if candidate["relation"] == "unrelated",
        do: Map.put(fact, :note, "no earlier work matched"),
        else: fact
    end
  end

  defp offered_work_fact(candidate, outcomes) do
    %{
      label: "Earlier work",
      value:
        if(Enum.any?(outcomes, & &1.selected),
          do: nil,
          else: relation_label(candidate["relation"] || "unrelated")
        ),
      outcomes: outcomes
    }
  end

  defp work_meaning("conversational"), do: "a quick answer, no investigation"
  defp work_meaning("standard"), do: "an investigation with tools"
  defp work_meaning("deep"), do: "a deeper investigation"
  # A kind this viewer does not know is still the decision it recorded.
  defp work_meaning(work_class) when is_binary(work_class),
    do: String.replace(work_class, "_", " ")

  defp work_meaning(_work_class), do: nil

  defp reason_from_model?(%{source_kind: :admission, phase: :result} = request),
    do: is_binary((document(request, "candidate") || %{})["reason"])

  defp reason_from_model?(%{source_kind: kind, phase: :result, background: %{reason: reason}})
       when kind in @background_kinds,
       do: is_binary(reason)

  defp reason_from_model?(_request), do: false

  defp lower_first(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest
  defp lower_first(text), do: text

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
            selected: ref == selected_ref,
            continuable: "same_work" in candidate.allowed_relations
          }
        end)
        # The briefing's own order: what could be continued, then background.
        |> Enum.sort_by(fn outcome ->
          {not outcome.selected, not outcome.continuable, outcome.title}
        end)

      _ ->
        []
    end
  end

  defp candidate_outcomes(_request), do: []

  defp candidate_outcome(ref, _allowed, ref, "same_work", _action), do: "Continued"
  defp candidate_outcome(ref, _allowed, ref, _relation, "continue_episode"), do: "Continued"
  defp candidate_outcome(ref, _allowed, ref, "history_only", _action), do: "Used as background"
  defp candidate_outcome(ref, _allowed, ref, _relation, _action), do: "Selected"

  defp candidate_outcome(_ref, allowed, _selected_ref, _relation, _action) do
    if "same_work" in allowed, do: "Not continued", else: "Background only"
  end

  defp decision_label("start_episode"), do: "Start new work"
  defp decision_label("continue_episode"), do: "Continue existing work"
  defp decision_label("reply"), do: "Reply in the conversation"
  defp decision_label("react"), do: "React only"
  defp decision_label("quick_reply"), do: "Answer right away, no work"
  defp decision_label("ignore"), do: "No response"
  defp decision_label(action) when is_binary(action), do: String.replace(action, "_", " ")

  defp relation_fact(%{"episode_ref" => "candidate:" <> _ = ref}),
    do: %{label: "Selected work", value: ref, identifier: true}

  # A decision routed before candidates were opaque names the request it joined
  # by key; one a message started links by the message's id.
  defp relation_fact(%{"episode_ref" => ref}) when is_binary(ref) and ref != "",
    do: %{label: "Joins", value: ref, href: Paths.request_id(ref) && Paths.request(ref)}

  defp relation_fact(%{"relation" => relation}) when is_binary(relation),
    do: %{label: "Earlier work", value: relation_label(relation)}

  defp relation_fact(_candidate), do: nil

  defp relation_label("unrelated"), do: "Separate request"
  defp relation_label("same_work"), do: "Continuation"
  defp relation_label("history_only"), do: "Background context"
  defp relation_label(relation), do: readable_code(relation)

  defp source_fact(%{"repository_source" => %{"kind" => kind, "name" => name}})
       when is_binary(kind) and is_binary(name),
       do: %{label: "Source", value: "#{kind} #{name}"}

  defp source_fact(_candidate), do: nil

  # Every emoji routing chose and every message it wrote, in its order.
  defp reaction_fact(%{"reactions" => [_first | _rest] = reactions}) do
    emoji = for reaction <- reactions, is_binary(reaction), do: ":#{reaction}:"
    if emoji != [], do: %{label: "Reaction", value: Enum.join(emoji, " ")}
  end

  defp reaction_fact(_candidate), do: nil

  # How routing read the sender's feeling about Ryker's previous answer. The
  # committed decision never holds it, so it is read from the model's answer
  # with the parser the host kept it with (`Ryker.Admission.Sentiment`): one
  # it could not read is left out here as it was left out of the feedback.
  defp sentiment_fact(%{"assistant_message" => message}) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, %{"sentiment" => sentiment}} -> sentiment_fact(sentiment)
      _none -> nil
    end
  end

  defp sentiment_fact(%{} = sentiment) do
    case Sentiment.parse(sentiment) do
      %{feeling: feeling, reason: reason} ->
        %{
          label: "Felt about the last answer",
          value: feeling |> Atom.to_string() |> String.capitalize(),
          note: reason
        }

      nil ->
        nil
    end
  end

  defp sentiment_fact(_candidate), do: nil

  # A quick answer of one message reads "Answer"; of several, each message in
  # the order it was sent.
  defp answer_facts(%{"action" => "quick_reply", "messages" => [message]})
       when is_binary(message),
       do: [%{label: "Answer", value: message}]

  defp answer_facts(%{"action" => "quick_reply", "messages" => [_first | _rest] = messages}) do
    messages
    |> Enum.filter(&is_binary/1)
    |> Enum.zip(~w(First Second Third))
    |> Enum.map(fn {message, ordinal} -> %{label: "#{ordinal} message", value: message} end)
  end

  defp answer_facts(_candidate), do: []

  defp explanation(%{phase: :submission, source_kind: :admission}),
    do: "Use an AI model to classify this message and choose how to respond."

  defp explanation(%{phase: :submission, source_kind: :learning}) do
    "Use an AI model to learn from these messages and keep what Ryker knows up to date. Learning sends no reply."
  end

  defp explanation(%{phase: :submission, source_kind: :improvement}) do
    "Use an AI model to find what went wrong in this request after a person was unhappy with it. It sends no reply and changes nothing."
  end

  defp explanation(%{source_kind: kind, background: background}) when kind in @background_kinds,
    do: background[:reason]

  defp explanation(%{phase: :submission} = request) do
    case document(request, "context") do
      %{"mode" => "continuation"} ->
        "Continue with the new messages and the saved conversation context."

      _ ->
        work_purpose(request[:model_choice][:purpose])
    end
  end

  # A failed call says what failed as it was known when it failed; what an
  # operator did afterwards is its own later card.
  defp explanation(%{source_kind: :admission} = request) do
    case {document(request, "candidate"), document(request, "response")} do
      {%{"reason" => reason}, _response} when is_binary(reason) ->
        RoutingReason.plain(reason)

      {nil, %{"state" => "failed"} = response} ->
        failure_explanation(request[:failure], response)

      _ ->
        nil
    end
  end

  defp explanation(request) do
    case if(is_nil(document(request, "candidate")), do: document(request, "validation")) do
      %{"candidate_attempt" => attempt, "verdict" => %{"verdict" => verdict}}
      when is_integer(attempt) and verdict in ~w(accept reject) ->
        "Try #{attempt} " <>
          if(verdict == "accept",
            do: "passed Ryker's checks.",
            else: "was sent back to be fixed."
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
end
