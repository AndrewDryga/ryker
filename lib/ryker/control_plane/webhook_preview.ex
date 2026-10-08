defmodule Ryker.ControlPlane.WebhookPreview do
  @moduledoc """
  Checks a saved webhook source against a pasted payload, and nothing else.

  Running the check records no input, opens no incident and submits no model
  work; it reports what the mapping would produce, or names the field that could
  not be mapped. The button says so, because an operator about to paste a
  production alert deserves to know whether it will do something.
  """
  use Phoenix.LiveComponent
  alias Ryker.ControlPlane.{Components, Kit, SettingsSections}
  alias Ryker.Webhooks
  alias Ryker.Wording

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
    {:noreply, assign(socket, :sample, Webhooks.preset_sample(adapter_kind(socket)))}
  end

  def handle_event("check", params, socket) do
    socket =
      assign(socket,
        sample: Map.get(params, "sample", socket.assigns.sample),
        source_name: Map.get(params, "source_name", socket.assigns.source_name)
      )

    case run(socket) do
      {:ok, mapped} ->
        {:noreply, assign(socket, error: nil, mapped: mapped)}

      {:error, reason} ->
        {:noreply, assign(socket, error: message(reason, adapter_kind(socket)), mapped: nil)}
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

  defp message(:invalid_json, _shape), do: "That is not valid JSON. Nothing was sent or recorded."

  defp message(:sample_too_large, _shape),
    do: "A sample must be under 40 KB. Paste one delivery, cut down if it is longer."

  defp message(:invalid_sample, _shape), do: "Paste the JSON body of one delivery."
  defp message(:unknown_webhook_source, _shape), do: "That source is no longer saved."

  defp message(:unavailable, _shape),
    do: "Settings could not be read, so there was nothing to check against."

  # A missing field is named in the form's words, with where to look for
  # the shape the source reads: the mapping for custom JSON, the sender's own
  # format otherwise. It said "no usable event_id" and "check the mapping
  # path" even for a Grafana source, which has no mapping.
  defp message({:invalid_webhook_transform, field}, :mapped_json) do
    label = label(field)
    "This payload has no usable #{label}. Check where the mapping says the #{label} is."
  end

  defp message({:invalid_webhook_transform, field}, :grafana) do
    "This is not a Grafana alert delivery Ryker can read: it has no usable " <>
      "#{lower(label(field))}."
  end

  defp message({:invalid_webhook_transform, field}, _universal),
    do: "This is not in Ryker's own format: it has no usable #{lower(label(field))}."

  defp message({:invalid_webhook_route, _field}, _shape) do
    "This source's settings are not complete, so it cannot read anything yet. Edit it, then check again."
  end

  defp message(_reason, _shape) do
    "Ryker could not turn this payload into an event. Check that the sender sends the shape " <>
      "this source expects."
  end

  defp label(:alerts), do: "Alerts"
  defp label(:metadata), do: "Labels and annotations"
  defp label(field), do: SettingsSections.subfield_label(to_string(field))

  defp lower(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- A card on the Webhooks page; a live component's root must be a
    plain tag, so the root carries the Kit card. --%>
    <section id={@id} class="kit-card webhook-preview" aria-label="Check a payload">
      <Kit.section_head
        title="Check a payload"
        lede="Paste one delivery to see the event Ryker would record. Nothing is saved or sent."
      />
      <Kit.empty
        :if={sources(@view) == []}
        variant={:hint}
        icon={:code}
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
          {Wording.count(length(@mapped), "event")} would be recorded
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
