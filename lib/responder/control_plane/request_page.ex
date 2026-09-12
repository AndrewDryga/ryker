defmodule Responder.ControlPlane.RequestPage do
  @moduledoc "Continuous inspector of retained model calls, honoring artifact deep links."
  use Phoenix.Component
  import Responder.ControlPlane.Components
  alias Responder.ControlPlane.RequestContextHTML

  def render(assigns) do
    assigns =
      assigns
      |> pin_selection()
      |> assign_sections()

    ~H"""
    <section class="model-inspector" aria-label="Model calls">
      <div class="inspector-intro">
        <div>
          <p class="ui-eyebrow">THE MODEL'S DESK</p><h2>What the model received</h2><p>
            Read the retained request, then follow the response through host validation.
          </p>
        </div><span class="ui-label">SECRETS REDACTED</span>
      </div>
      <div class="inspector-layout">
        <aside class="request-directory">
          <nav class="ui-tabs" aria-label="Model call type">
            <.link
              :if={@view.episode_ref}
              patch={path(@path, %{}, %{kind: "work"})}
              aria-current={if @view.kind == :work, do: "page"}
            >Work</.link><.link
              patch={path(@path, %{}, %{kind: "admission"})}
              aria-current={if @view.kind == :admission, do: "page"}
            >Admission</.link>
          </nav>
          <p class="request-count">{@view.total} retained model calls</p>
          <.link
            :for={{request, index} <- Enum.with_index(@view.items)}
            patch={path(@path, @params, %{attempt: request.id})}
            class="request-directory-item"
            aria-current={if @view.selected && request.id == @view.selected.id, do: "page"}
          ><span>Model call {@view.total - ((@view.page - 1) * 20 + index)}</span><strong>{label(
            request.status
          )}</strong><time>{timestamp(request.at)}</time></.link>
          <.paging path={@path} params={@params} page={@view.page} pages={@view.pages} key="page" />
        </aside>
        <article
          :if={@view.selected}
          class="request-reader"
          data-request-id={@view.selected.id}
          data-generation={@view.selected[:generation]}
        >
          <div class="request-reader-heading">
            <div>
              <span>{@view.selected.title}</span><h3>{@view.selected.target}</h3>
            </div><.status state={to_string(@view.selected.status)} />
          </div>
          <p class="coverage-note">{@view.selected.coverage}</p>
          <section :if={@view.selected[:recovery]} class="admission-recovery story-stop">
            <h3>Admission needs attention</h3><p>{label(@view.selected.recovery.summary)}</p>
            <p>The input is retained. Review recovery to reconcile the same model call.</p>
            <.action_button path={@view.selected.recovery.href} label="Review recovery" />
          </section>
          <.paging
            :if={Map.has_key?(@view.selected, :generation)}
            path={@path}
            params={@params}
            page={@view.selected[:generation]}
            pages={@view.selected[:generations]}
            key="generation"
          />
          <div class="request-document-flow">
            <div :if={!@params["section"]} class="prompt-assembly" aria-label="Briefing sources">
              {Phoenix.HTML.raw(
                RequestContextHTML.briefing(
                  @view.selected.sections,
                  @view.kind,
                  "selected-#{@view.selected.id}",
                  @view.selected[:counts] || %{}
                )
              )}
            </div>
            <.artifact
              :for={
                section <-
                  Enum.reject(
                    @sections,
                    &(!@params["section"] && &1.id in ~w(instructions context contract) &&
                        &1.artifact.state == :retained && !&1.artifact.truncated)
                  )
              }
              section={section}
              sections={@view.selected.sections}
              prefix={"selected-#{@view.selected.id}"}
              expanded_source={@params["section"] == section.id}
            />
          </div>
          <section class="retained-tools" id="retained-tools">
            <div class="rail-heading">
              <h3>Tool activity</h3><span>{@view.selected.tools.total} records</span>
            </div><p>
              Public events only. An observed completion is not a retained tool result body.
            </p><p :if={@view.selected.tools.items == []}>
              No retained tool activity for this request.
            </p><details
              :for={tool <- @view.selected.tools.items}
              id={"retained-tool-#{tool.id}"}
              data-artifact={
                if tool.artifact.state in [:collapsed, :retained], do: tool[:artifact_id]
              }
              data-revoked={if tool.artifact.state in [:expired, :not_recorded], do: "true"}
            >
              <summary>{label(tool.kind)} <time>{timestamp(tool.at)}</time></summary><pre class="model-document-text">{tool.artifact.text ||
                if(tool.artifact.state == :collapsed,
                  do: "Loading…",
                  else: "Not recorded"
                )}</pre>
            </details><.paging
              path={@path}
              params={@params}
              page={@view.selected.tools.page}
              pages={@view.selected.tools.pages}
              key="tools_page"
            />
          </section>
          <details class="document-provenance">
            <summary>Model call identity and policy</summary><dl>
              <dt>Request</dt><dd>{@view.selected.id}</dd><dt>Policy</dt><dd>
                {@view.selected.policy}
              </dd><dt>Fingerprint</dt><dd>{@view.selected.fingerprint || "Not recorded"}</dd>
            </dl>
          </details>
        </article>
        <div :if={!@view.selected} class="document-unavailable">
          <.icon name={:book} /><h3>No model calls recorded</h3><p>
            This episode may still be preparing its first request. Live updates will show it when it is retained.
          </p>
        </div>
      </div>
    </section>
    """
  end

  def artifact(assigns) do
    assigns =
      assigns
      |> assign_new(:sections, fn -> [assigns.section] end)
      |> assign(:heading, artifact_heading(assigns.section))
      |> assign(:validation_steps, validation_steps(assigns.section, assigns[:sections] || []))
      |> assign(
        :readable_context,
        readable_artifact(
          assigns.section,
          assigns[:sections] || [assigns.section],
          assigns.prefix,
          assigns[:expanded_source] || false
        )
      )

    ~H"""
    <section
      :if={@section.id == "request"}
      class="inspector-document artifact-request final-prompt"
      id={"#{@prefix}-#{@section.id}"}
    >
      <header class="document-heading document-heading-fixed">
        <h4>{@heading}</h4><span>{artifact_label(@section.artifact)}{if @section.artifact.truncated,
          do: " · truncated display"}</span>
      </header>
      <.artifact_body
        prefix={@prefix}
        readable_context={@readable_context}
        section={@section}
        validation_steps={@validation_steps}
      />
    </section>
    <details
      :if={@section.id != "request"}
      class={"inspector-document artifact-#{@section.id}"}
      id={"#{@prefix}-#{@section.id}"}
      open={assigns[:expanded_source] || @section.id == "validation"}
    >
      <summary class="document-heading">
        <h4>{@heading}</h4><span>{artifact_label(@section.artifact)}{if @section.artifact.truncated,
          do: " · truncated display"}</span>
      </summary>
      <.artifact_body
        prefix={@prefix}
        readable_context={@readable_context}
        section={@section}
        validation_steps={@validation_steps}
      />
    </details>
    """
  end

  # The submitted request is the whole point of this page, so it is a section
  # with a heading rather than a disclosure that is always open and whose
  # summary had to be made unfocusable to stop it behaving like a control.
  # Everything below the heading is identical either way.
  defp artifact_body(assigns) do
    ~H"""
    <p :if={@section.artifact.state != :retained} class="artifact-unavailable">
      {if @section.artifact.state == :expired,
        do: "This artifact has expired",
        else: "This artifact was not recorded"}. No reconstructed substitute is shown.
    </p>
    <div
      :if={@section.artifact.state == :retained}
      id={if @section.id == "candidate", do: "#{@prefix}-candidate-body"}
    >
      <.validation_checks
        :if={@section.id == "validation"}
        steps={@validation_steps}
        prefix={@prefix}
        page={@section[:response_page]}
      />
      <div :if={@readable_context != ""} class="readable-model-context">
        {Phoenix.HTML.raw(@readable_context)}
      </div>
      <pre
        :if={@readable_context == "" && @section.id != "validation"}
        class="model-document-text"
        tabindex="0"
      >{@section.artifact.text}</pre>
      <details
        class={["document-provenance", @section.id == "validation" && "validation-raw"]}
        id={"#{@prefix}-#{@section.id}-provenance"}
      >
        <summary>
          {if @section.id == "validation", do: "Raw validation record", else: "Artifact identity"}{if @section.artifact.redacted,
            do: " · redacted display"}
        </summary>
        <p>Original retained bytes: {@section.artifact.bytes}</p><code>{@section.artifact.sha256}</code>
        <pre :if={@section.id in ["context", "validation"]} class="model-document-text" tabindex="0">{@section.artifact.text}</pre>
      </details>
    </div>
    """
  end

  defp validation_checks(assigns) do
    ~H"""
    <nav :if={@page && @page.pages > 1} class="ui-pagination" aria-label="Response checks">
      <span>Checks {@page.first}–{@page.last} of {@page.total}</span>
      <a :if={@page.previous} href={@page.previous}>Earlier attempts</a>
      <a :if={@page.next} href={@page.next}>Later attempts</a>
    </nav>
    <p :if={@steps == []} class="artifact-unavailable">
      Validation details are unavailable. The retained record below is not a substitute for a complete check receipt.
    </p>
    <div :if={@steps != []} class="memory-cards">
      <section
        :for={step <- @steps}
        class="memory-card validation-attempt"
        data-candidate-attempt={step.attempt}
      >
        <header class="case-event-heading">
          <h3>{step.title}</h3><time :if={step.at}>{timestamp(step.at)}</time>
        </header>
        <ul :if={step.violations != []}>
          <li :for={violation <- step.violations}>{violation}</li>
        </ul>
        <p :if={step.attempt && step.violations == []}>No violations recorded.</p>
        <.candidate_response
          :if={step.response}
          response={step.response}
          attempt={step.attempt}
          prefix={@prefix}
        />
        <p :if={!step.response && step.response_retained}>
          <a href={"##{@prefix}-candidate-body"}>View the retained response for this attempt →</a>
        </p>
        <p :if={step.attempt && !step.response && !step.response_retained}>
          Response body not retained for this attempt. Its check receipt is preserved here.
        </p>
      </section>
    </div>
    """
  end

  defp validation_steps(
         %{id: "validation", artifact: %{state: :retained, truncated: false, text: text}} =
           section,
         sections
       ) do
    case Jason.decode(text) do
      {:ok, %{"history" => history} = document} when is_list(history) ->
        Enum.map(history, &validation_step(&1, document, sections, section[:responses] || %{}))

      _ ->
        []
    end
  end

  defp validation_steps(_section, _sections), do: []

  defp validation_step(
         %{"candidate_attempt" => attempt, "verdict" => verdict, "violations" => violations} =
           entry,
         document,
         sections,
         responses
       )
       when is_integer(attempt) and attempt > 0 and verdict in ["accept", "reject"] and
              is_list(violations) do
    if Enum.all?(violations, &is_binary/1) && (verdict != "accept" || violations == []) do
      %{
        attempt: attempt,
        title:
          "Attempt #{attempt} #{if verdict == "accept", do: "passed checks", else: "needs correction"}",
        violations: violations,
        at: validation_time(entry["recorded_at"]),
        response: exact_response(entry, responses),
        response_retained: retained_response?(entry, document, sections)
      }
    else
      unavailable_validation()
    end
  end

  defp validation_step(_entry, _document, _sections, _responses), do: unavailable_validation()

  defp unavailable_validation,
    do: %{
      attempt: nil,
      title: "Validation details unavailable",
      violations: [],
      at: nil,
      response: nil,
      response_retained: false
    }

  defp exact_response(entry, responses) do
    case responses[entry["candidate_attempt"]] do
      %{state: :retained, sha256: digest} = artifact ->
        if digest == entry["candidate_sha256"], do: artifact

      %{state: :expired} = artifact ->
        artifact

      _ ->
        nil
    end
  end

  def candidate_response(assigns) do
    assigns = assign(assigns, :document, candidate_document(assigns.response))

    ~H"""
    <details
      :if={@response.state == :retained}
      class="candidate-response inspector-document"
      id={"#{@prefix}-response-#{@attempt}"}
    >
      <summary>
        Response for attempt {@attempt}
        <span :if={@response.redacted}> · Secrets redacted</span>
        <span :if={@response.truncated}> · Display truncated</span>
      </summary>
      <div id={"#{@prefix}-response-#{@attempt}-body"} tabindex="-1">
        <div :if={@document && is_binary(@document["message"])} class="markdown-preview">
          {Phoenix.HTML.raw(Responder.ControlPlane.SlackMarkdown.preview(@document["message"]))}
        </div>
        <p :if={@document && is_binary(@document["decision_reason"])}>
          {@document["decision_reason"]}
        </p>
        <details :if={@document} id={"#{@prefix}-response-#{@attempt}-json"}>
          <summary>Full response document</summary>
          <pre class="model-document-text" tabindex="0">{@response.text}</pre>
        </details>
        <pre :if={!@document} class="model-document-text" tabindex="0">{@response.text}</pre>
        <p><a href={"##{@prefix}-response-#{@attempt}-body"}>Link to this response</a></p>
      </div>
    </details>
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

  defp validation_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp validation_time(_), do: nil

  defp retained_response?(entry, document, sections) do
    case Enum.find(sections, &(&1.id == "candidate")) do
      %{artifact: %{state: :retained, sha256: digest}} when is_binary(digest) ->
        document["candidate_attempt"] == entry["candidate_attempt"] &&
          entry["candidate_sha256"] == digest

      _ ->
        false
    end
  end

  defp artifact_heading(%{id: "request"}), do: "Full submitted request"
  defp artifact_heading(%{id: "validation"}), do: "Response checks"
  defp artifact_heading(section), do: section.title

  defp readable_artifact(%{id: "request"}, sections, prefix, _open),
    do: IO.iodata_to_binary(RequestContextHTML.submitted(sections, prefix <> "-submitted"))

  defp readable_artifact(%{id: "context", artifact: artifact} = section, _sections, prefix, _open) do
    root = if section[:source_kind] == :work, do: "$.work", else: "$.context"
    IO.iodata_to_binary(RequestContextHTML.render(artifact, root, prefix))
  end

  defp readable_artifact(
         %{id: "instructions", artifact: artifact} = section,
         _sections,
         prefix,
         open
       ),
       do:
         IO.iodata_to_binary(
           RequestContextHTML.instructions(artifact, section[:source_kind], prefix, open)
         )

  defp readable_artifact(_section, _sections, _prefix, _open), do: ""

  defp paging(assigns) do
    ~H"""
    <div :if={@pages > 1} class="ui-pagination">
      <span>{label(@key)} {@page} / {@pages}</span><.link
        :if={@page > 1}
        patch={path(@path, @params, %{@key => @page - 1})}
      >Previous</.link><.link :if={@page < @pages} patch={path(@path, @params, %{@key => @page + 1})}>Next</.link>
    </div>
    """
  end

  defp pin_selection(%{view: %{selected: %{id: id} = selected}} = assigns) do
    params = Map.merge(assigns.params, %{"attempt" => id, "kind" => to_string(assigns.view.kind)})

    params =
      if selected[:generation],
        do: Map.put(params, "generation", selected.generation),
        else: params

    assign(assigns, :params, params)
  end

  defp pin_selection(assigns), do: assigns

  defp assign_sections(%{view: %{selected: nil}} = assigns),
    do: assign(assigns, :sections, [])

  defp assign_sections(assigns) do
    sections = assigns.view.selected.sections

    sections =
      if assigns.params["section"] != "candidate" && latest_archived_response(sections),
        do: Enum.reject(sections, &(&1.id == "candidate")),
        else: sections

    {focused, rest} =
      Enum.split_with(sections, &(&1.id == assigns.params["section"]))

    assign(assigns, :sections, focused ++ rest)
  end

  defp path(path, params, changes),
    do:
      path <>
        "?" <>
        URI.encode_query(
          Map.merge(
            Map.take(params, ~w(kind attempt page generation section tools_page responses_page)),
            Map.new(changes, fn {key, value} -> {to_string(key), value} end)
          )
        )

  defp artifact_label(%{state: :expired}), do: "Expired"
  defp artifact_label(%{state: :not_recorded}), do: "Not recorded"
  defp artifact_label(%{redacted: true}), do: "Retained · redacted"
  defp artifact_label(_), do: "Retained"
end
