defmodule Responder.ControlPlane.RequestPage do
  @moduledoc "Continuous inspector of retained requests, honoring artifact deep links."
  use Phoenix.Component
  import Responder.ControlPlane.Components
  alias Responder.ControlPlane.RequestContextHTML

  def render(assigns) do
    assigns =
      assigns
      |> pin_selection()
      |> assign_sections()

    ~H"""
    <section class="model-inspector" aria-label="Model request inspector">
      <div class="inspector-intro">
        <div>
          <p class="ui-eyebrow">THE MODEL'S DESK</p><h2>What the model received</h2><p>
            Read the retained request, then follow the response through host validation.
          </p>
        </div><span class="ui-label">SECRETS REDACTED</span>
      </div>
      <div class="inspector-layout">
        <aside class="request-directory">
          <nav class="ui-tabs" aria-label="Request type">
            <.link
              :if={@view.episode_ref}
              patch={path(@path, %{}, %{kind: "work"})}
              aria-current={if @view.kind == :work, do: "page"}
            >Work</.link><.link
              patch={path(@path, %{}, %{kind: "admission"})}
              aria-current={if @view.kind == :admission, do: "page"}
            >Admission</.link>
          </nav>
          <p class="request-count">{@view.total} retained requests</p>
          <.link
            :for={{request, index} <- Enum.with_index(@view.items)}
            patch={path(@path, @params, %{attempt: request.id})}
            class="request-directory-item"
            aria-current={if @view.selected && request.id == @view.selected.id, do: "page"}
          ><span>Request {@view.total - ((@view.page - 1) * 20 + index)}</span><strong>{label(
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
            <p>The input is retained. Review recovery to reconcile the same request.</p>
            <a class="ui-button secondary" href={@view.selected.recovery.href}>Review recovery
            <.icon name={:arrow} /></a>
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
            <.artifact
              :for={section <- @sections}
              section={section}
              prefix={"selected-#{@view.selected.id}"}
            />
          </div>
          <section class="retained-tools" id="retained-tools">
            <div class="rail-heading">
              <h3>Tool activity</h3><span>{@view.selected.tools.total} records</span>
            </div><p>
              Public events only. An observed completion is not a retained tool result body.
            </p><p :if={@view.selected.tools.items == []}>
              No retained tool activity for this request.
            </p><details :for={tool <- @view.selected.tools.items} id={"retained-tool-#{tool.id}"}>
              <summary>{label(tool.kind)} <time>{timestamp(tool.at)}</time></summary><pre class="model-document-text">{tool.artifact.text || "Not recorded"}</pre>
            </details><.paging
              path={@path}
              params={@params}
              page={@view.selected.tools.page}
              pages={@view.selected.tools.pages}
              key="tools_page"
            />
          </section>
          <details class="document-provenance">
            <summary>Request identity and policy</summary><dl>
              <dt>Request</dt><dd>{@view.selected.id}</dd><dt>Policy</dt><dd>
                {@view.selected.policy}
              </dd><dt>Fingerprint</dt><dd>{@view.selected.fingerprint || "Not recorded"}</dd>
            </dl>
          </details>
        </article>
        <div :if={!@view.selected} class="document-unavailable">
          <.icon name={:book} /><h3>No requests recorded</h3><p>
            This episode may still be preparing its first request. Live updates will show it when it is retained.
          </p>
        </div>
      </div>
    </section>
    """
  end

  def artifact(assigns) do
    assigns =
      assign(
        assigns,
        :readable_context,
        readable_artifact(assigns.section, assigns.prefix)
      )

    ~H"""
    <section class={"inspector-document artifact-#{@section.id}"} id={"#{@prefix}-#{@section.id}"}>
      <div class="document-heading">
        <h4>{@section.title}</h4><span>{artifact_label(@section.artifact)}{if @section.artifact.truncated,
          do: " · truncated display"}</span>
      </div>
      <p :if={@section.artifact.state != :retained} class="artifact-unavailable">
        {if @section.artifact.state == :expired,
          do: "This artifact has expired",
          else: "This artifact was not recorded"}. No reconstructed substitute is shown.
      </p>
      <div :if={@section.artifact.state == :retained}>
        <div :if={@readable_context != ""} class="readable-model-context">
          {Phoenix.HTML.raw(@readable_context)}
        </div>
        <pre :if={@readable_context == ""} class="model-document-text" tabindex="0">{@section.artifact.text}</pre>
        <details class="document-provenance" id={"#{@prefix}-#{@section.id}-provenance"}>
          <summary>
            Artifact identity{if @section.artifact.redacted, do: " · redacted display"}
          </summary>
          <p>Original retained bytes: {@section.artifact.bytes}</p><code>{@section.artifact.sha256}</code>
          <pre :if={@section.id == "context"} class="model-document-text" tabindex="0">{@section.artifact.text}</pre>
        </details>
      </div>
    </section>
    """
  end

  defp readable_artifact(%{id: "context", artifact: artifact} = section, prefix) do
    root = if section[:source_kind] == :work, do: "$.work", else: "$.context"
    IO.iodata_to_binary(RequestContextHTML.render(artifact, root, prefix))
  end

  defp readable_artifact(%{id: "instructions", artifact: artifact} = section, prefix),
    do:
      IO.iodata_to_binary(
        RequestContextHTML.instructions(artifact, section[:source_kind], prefix)
      )

  defp readable_artifact(_section, _prefix), do: ""

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
    {focused, rest} =
      Enum.split_with(assigns.view.selected.sections, &(&1.id == assigns.params["section"]))

    assign(assigns, :sections, focused ++ rest)
  end

  defp path(path, params, changes),
    do:
      path <>
        "?" <>
        URI.encode_query(
          Map.merge(
            Map.take(params, ~w(kind attempt page generation section tools_page)),
            Map.new(changes, fn {key, value} -> {to_string(key), value} end)
          )
        )

  defp artifact_label(%{state: :expired}), do: "Expired"
  defp artifact_label(%{state: :not_recorded}), do: "Not recorded"
  defp artifact_label(%{redacted: true}), do: "Retained · redacted"
  defp artifact_label(_), do: "Retained"
end
