defmodule Ryker.ControlPlane.WebhookPreview do
  @moduledoc """
  Checks a saved webhook source against a pasted payload, and nothing else.

  Running the check records no input, opens no incident and submits no model
  work; it reports what the mapping would produce, or names the field that could
  not be mapped. The button says so, because an operator about to paste a
  production alert deserves to know whether it will do something.
  """

  use Phoenix.LiveComponent

  alias Ryker.ControlPlane.{Components, Kit}
  alias Ryker.Webhooks.Presets

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if Map.has_key?(socket.assigns, :sample) do
      {:ok, socket}
    else
      {:ok,
       assign(socket, error: nil, mapped: nil, sample: "", source_name: default_source(assigns))}
    end
  end

  @impl true
  def handle_event("edit", params, socket) do
    {:noreply,
     assign(socket,
       sample: Map.get(params, "sample", ""),
       source_name: Map.get(params, "source_name", socket.assigns.source_name)
     )}
  end

  def handle_event("load-sample", _params, socket) do
    {:noreply, assign(socket, :sample, Presets.sample(adapter_kind(socket)))}
  end

  def handle_event("check", params, socket) do
    socket =
      assign(socket,
        sample: Map.get(params, "sample", socket.assigns.sample),
        source_name: Map.get(params, "source_name", socket.assigns.source_name)
      )

    case run(socket) do
      {:ok, mapped} -> {:noreply, assign(socket, error: nil, mapped: mapped)}
      {:error, reason} -> {:noreply, assign(socket, error: message(reason), mapped: nil)}
    end
  end

  defp run(socket) do
    socket.assigns.check.(socket.assigns.source_name, socket.assigns.sample)
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  end

  defp default_source(assigns) do
    case assigns.view.snapshot.webhook_sources do
      [%{name: name} | _rest] -> name
      [] -> ""
    end
  end

  defp adapter_kind(socket) do
    case Enum.find(sources(socket.assigns.view), &(&1.name == socket.assigns.source_name)) do
      nil -> :universal
      source -> source.adapter_kind
    end
  end

  defp sources(view), do: view.snapshot.webhook_sources

  defp message(:invalid_json), do: "That is not valid JSON. Nothing was sent or recorded."

  defp message(:sample_too_large),
    do: "A sample must be under 40 KB, the same bound a real request has."

  defp message(:invalid_sample), do: "Paste the JSON body of one delivery."
  defp message(:unknown_webhook_source), do: "That source is no longer saved."

  defp message(:unavailable),
    do: "Settings could not be read, so there was nothing to check against."

  defp message({:invalid_webhook_transform, field}),
    do: "The payload has no usable #{field}. Check the mapping path for that field."

  defp message({:invalid_webhook_input, field}),
    do: "The mapped #{field} is not usable as event identity."

  defp message({:invalid_webhook_route, field}),
    do: "This source's #{field} is not valid, so it cannot map anything yet."

  defp message({:invalid_input, field}), do: "The mapped #{field} is not a valid input field."
  defp message(_reason), do: "This payload could not be mapped."

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="webhook-preview" aria-label="Check a payload">
      <Kit.section_head
        title="Check a payload"
        lede="Paste one delivery to see the event Ryker would record. Nothing is saved or sent."
      />
      <Kit.empty
        :if={sources(@view) == []}
        title="Nothing to check yet"
        text="Add a webhook source first, then paste one of its deliveries here."
      />
      <form
        :if={sources(@view) != []}
        id={"#{@id}-form"}
        class="settings-form"
        phx-change="edit"
        phx-submit="check"
        phx-target={@myself}
      >
        <div class="settings-field">
          <label for={"#{@id}-source"}>Source</label>
          <select id={"#{@id}-source"} name="source_name">
            <option
              :for={source <- sources(@view)}
              value={source.name}
              selected={source.name == @source_name}
            >
              {source.name}
            </option>
          </select>
        </div>
        <div class="settings-field settings-field-wide">
          <label for={"#{@id}-sample"}>Sample delivery</label>
          <p class="settings-help" id={"#{@id}-sample-help"}>The JSON body of one request.</p>
          <textarea
            id={"#{@id}-sample"}
            name="sample"
            rows="10"
            aria-describedby={"#{@id}-sample-help"}
          >{@sample}</textarea>
        </div>
        <div class="settings-actions">
          <button type="submit" class="ui-button primary">Check this payload</button>
          <button
            type="button"
            class="ui-button secondary"
            phx-click="load-sample"
            phx-target={@myself}
          >
            Use an example
          </button>
        </div>
      </form>
      <Components.form_feedback :if={@error} message={@error} tone={:error} class="settings-error" />
      <div :if={@mapped} class="webhook-preview-result" role="status">
        <h3>
          {length(@mapped)} {if length(@mapped) == 1, do: "event", else: "events"} would be recorded
        </h3>
        <div :for={event <- @mapped} class="webhook-preview-event">
          <p class="entity-meta">
            <strong>{event.event_ref}</strong>
            · occurred
            <time
              datetime={DateTime.to_iso8601(event.occurred_at)}
              title={DateTime.to_iso8601(event.occurred_at)}
            >{Calendar.strftime(event.occurred_at, "%-d %b %Y, %H:%M UTC")}</time>
            · revision {event.revision}
          </p>
          <Components.copy_block label="Copy the event content">
            <pre>{content(event.summary)}</pre>
          </Components.copy_block>
        </div>
      </div>
    </section>
    """
  end

  # What the event would carry, as the JSON a person pasted it as.
  defp content(summary) do
    case Jason.encode(summary, pretty: true) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(summary, pretty: true, limit: 40)
    end
  end
end
