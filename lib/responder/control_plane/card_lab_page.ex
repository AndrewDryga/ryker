defmodule Responder.ControlPlane.CardLabPage do
  @moduledoc "The native specimen workbench: choose a surface, inspect its state, review in Slack."
  use Phoenix.Component
  import Responder.ControlPlane.Components
  alias Responder.ControlPlane.HTML

  def render(assigns) do
    assigns = assign(assigns, :specimen, assigns.view.snapshot)

    ~H"""
    <div class="specimen-workbench">
      <aside class="specimen-directory">
        <p class="ui-eyebrow">DESIGN & INTERACTION</p><h1>Slack Card Lab</h1>
        <p>Every surface. Every state.</p>
        <span class="specimen-total">{Enum.sum(Enum.map(@specimen.catalog, & &1.state_count))} specimens · {length(
          @specimen.catalog
        )} families</span>
        <nav aria-label="Slack card families">
          <.link
            :for={card <- @specimen.catalog}
            patch={path(card.id, card.first_state_id)}
            aria-current={if card.id == @specimen.card.id, do: "page"}
          >
            <strong>{card.title}</strong><span>{card.state_count} states · {surface(card.surface)}</span>
          </.link>
        </nav>
      </aside>
      <section class="specimen-stage">
        <div class="specimen-heading">
          <p class="ui-eyebrow">{surface(@specimen.card.surface)} / PRODUCTION RENDERER</p>
          <h2>{@specimen.card.title}</h2><p>{@specimen.card.description}</p>
        </div>
        <nav class="specimen-states" aria-label="Card states">
          <.link
            :for={state <- @specimen.card.states}
            patch={path(@specimen.card.id, state.id)}
            aria-current={if state.id == @specimen.state.id, do: "page"}
          >{state.label}</.link>
        </nav>
        <div class="specimen-state-heading">
          <div>
            <span class="ui-eyebrow">SELECTED STATE</span><h3>{@specimen.state.label}</h3>
          </div><p>{@specimen.state.description}</p>
        </div>
        <div class="specimen-preview-toolbar">
          <nav class="ui-tabs" aria-label="Specimen view">
            <.link
              patch={option_path(@specimen, @params, "view", "preview")}
              aria-current={if @params["view"] != "payload", do: "page"}
            >Preview</.link>
            <.link
              patch={option_path(@specimen, @params, "view", "payload")}
              aria-current={if @params["view"] == "payload", do: "page"}
            >Block Kit payload</.link>
          </nav>
          <nav class="preview-width" aria-label="Preview width">
            <.link
              patch={option_path(@specimen, @params, "width", "wide")}
              aria-current={if @params["width"] != "compact", do: "page"}
            >Wide</.link>
            <.link
              patch={option_path(@specimen, @params, "width", "compact")}
              aria-current={if @params["width"] == "compact", do: "page"}
            >Compact</.link>
          </nav>
        </div>
        <div
          :if={@params["view"] != "payload"}
          class={"specimen-canvas #{if @params["width"] == "compact", do: "compact"}"}
        >
          {Phoenix.HTML.raw(HTML.card_lab_preview(@specimen.rendered, @specimen.card.surface))}
        </div>
        <pre :if={@params["view"] == "payload"} class="specimen-payload" tabindex="0">{Jason.encode!(@specimen.rendered, pretty: true)}</pre>
        <p class="specimen-approximation">
          <.icon name={:incident} />Browser approximation. Slack is the rendering authority. Preview buttons are inert; use the state controls below.
        </p>
        <section class="specimen-transitions">
          <div class="rail-heading">
            <h3>Try the next state</h3><span>Local preview only</span>
          </div>
          <p :if={@specimen.state.transitions == []}>
            This state has no outgoing transition. Choose any state above to inspect it.
          </p>
          <button
            :for={transition <- @specimen.state.transitions}
            type="button"
            phx-click="card-transition"
            phx-value-id={transition.id}
          >
            <span>{transition.label}</span><small>{state_label(@specimen, transition.to)}
            <.icon name={:arrow} /></small>
          </button>
        </section>
      </section>
      <aside class="specimen-review">
        {Phoenix.HTML.raw(@view.slack_panel)}
        <section class="specimen-feedback" id="feedback">
          <p class="ui-eyebrow">REVIEW NOTES</p><h2>Feedback on this state</h2>
          <p>{@specimen.card.title} · {@specimen.state.label}</p>
          <form
            id={"specimen-feedback-#{@specimen.card.id}-#{@specimen.state.id}"}
            phx-update="ignore"
            method="post"
            action={path(@specimen.card.id, @specimen.state.id) <> "/feedback"}
          >
            <input type="hidden" name="_token" value={@view.feedback_token} />
            <label for="specimen-verdict">Verdict</label><select id="specimen-verdict" name="verdict"><option value="needs_work">
              Needs work
            </option><option value="good">Good</option><option value="approved">Approved</option></select>
            <label for="specimen-note">What should change?</label><textarea
              id="specimen-note"
              name="note"
              maxlength="4000"
              rows="5"
              required
              placeholder="Layout, copy, missing context, or state behavior…"
            ></textarea>
            <button type="submit" class="ui-button secondary">Save feedback <.icon name={:check} /></button>
          </form>
          <p :if={@view.feedback == []} class="specimen-no-feedback">
            No feedback on this state yet.
          </p>
          <article :for={note <- @view.feedback} class="specimen-feedback-note">
            <strong>{label(note.verdict)}</strong><time>{timestamp(note.inserted_at)}</time><p>
              {note.note}
            </p>
          </article>
        </section>
      </aside>
    </div>
    """
  end

  defp path(card, state),
    do: "/card-lab/#{URI.encode_www_form(card)}/#{URI.encode_www_form(state)}"

  defp option_path(specimen, params, key, value),
    do:
      path(specimen.card.id, specimen.state.id) <>
        "?" <> URI.encode_query(Map.put(Map.take(params, ~w(view width)), key, value))

  defp state_label(specimen, id), do: Enum.find(specimen.card.states, &(&1.id == id)).label
  defp surface(:message), do: "Message"
  defp surface(:app_home), do: "App Home"
  defp surface(:modal), do: "Modal"
  defp surface(:thread_status), do: "Thread status"
end
