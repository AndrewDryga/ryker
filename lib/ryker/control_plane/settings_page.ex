defmodule Ryker.ControlPlane.SettingsPage do
  @moduledoc """
  The settings page: what this installation decided, and what is actually running.

  Saved and applied are shown as two different facts. A revision that was saved
  but could not be assembled says so, because reading "saved" as "live" is the
  mistake the split between them exists to prevent.
  """

  use Phoenix.Component

  alias Ryker.ControlPlane.{Components, SettingsEditor, SettingsSections, WebhookPreview}

  @description "What this installation decided, and what is actually running."

  # The shell's one-line description under the Settings title, shared with the
  # static route that renders only the read-only evidence.
  def description, do: @description

  attr(:view, :any, required: true)
  attr(:commands, :map, required: true)
  attr(:body, :string, default: "")
  attr(:error, :string, default: nil)

  # Every state of the page — setup, unavailable, editable — has the one
  # shell title; what differs sits beneath it as content.
  def render(%{view: {:error, :settings_not_initialized}} = assigns) do
    assigns = assign(assigns, :description, @description)

    ~H"""
    <div class="settings-page">
      <Components.page_header title="Settings" description={@description} />
      <section class="settings-setup">
        <h2>Set up this installation</h2>
        <p>
          This database has no product settings yet. Creating them writes one installation
          identity and the shipped defaults: no integration is connected, no work is placed and
          nothing is submitted to a model until you say so.
        </p>
        <button type="button" class="ui-button primary" phx-click="initialize-settings">
          Create settings for this installation
        </button>
        <p :if={@error} class="settings-error" role="alert">{@error}</p>
      </section>
    </div>
    """
  end

  def render(%{view: {:error, :settings_unavailable}} = assigns) do
    assigns = assign(assigns, :description, @description)

    ~H"""
    <div class="settings-page">
      <Components.page_header title="Settings" description={@description} />
      <section class="settings-unavailable">
        <h2>Settings could not be read</h2>
        <p>
          The settings database did not answer. This is not an installation without settings:
          nothing has been reset, and the running configuration is whatever was last applied.
          Editing is disabled until the database answers again.
        </p>
      </section>
    </div>
    """
  end

  def render(%{view: {:ok, _view}} = assigns) do
    assigns = assign(assigns, view: elem(assigns.view, 1), description: @description)

    ~H"""
    <div class="settings-page" id="settings-page" phx-hook="SettingsDraft">
      <Components.page_header title="Settings" description={@description} />
      <div class="settings-status">
        <dl>
          <div>
            <dt>Installation</dt>
            <dd><code>{@view.host_ref}</code></dd>
          </div>
          <div>
            <dt>Saved revision</dt>
            <dd>{@view.revision}</dd>
          </div>
          <div>
            <dt>Running revision</dt>
            <dd>{@view.applied_revision}</dd>
          </div>
          <div>
            <dt>Last saved</dt>
            <dd>
              {Calendar.strftime(@view.saved_at, "%d %b %Y, %H:%M UTC")} by {@view.saved_by}
            </dd>
          </div>
        </dl>
        <p
          class={"settings-application settings-application-#{status_class(@view.application)}"}
          role="status"
        >
          {status_message(@view.application)}
        </p>
      </div>
      <nav class="settings-index" aria-label="Settings sections">
        <a :for={section <- SettingsSections.sections()} href={"#settings-#{section.key}"}>{section.title}</a>
        <a href="#webhook-preview">Check a payload</a>
      </nav>
      <.live_component
        :for={section <- SettingsSections.sections()}
        module={SettingsEditor}
        id={"settings-#{section.key}"}
        section={section}
        view={@view}
        commands={@commands}
      />
      <.live_component
        module={WebhookPreview}
        id="webhook-preview"
        view={@view}
        check={@commands.preview_webhook}
      />
      <div class="settings-effective">
        {Phoenix.HTML.raw(@body)}
      </div>
    </div>
    """
  end

  defp status_class(:applied), do: "applied"
  defp status_class(:pending), do: "pending"
  defp status_class({:failed, _code}), do: "failed"

  defp status_message(:applied), do: "The running configuration matches the saved settings."

  defp status_message(:pending),
    do: "Saved. The runtime has not applied this revision yet."

  defp status_message({:failed, code}),
    do:
      "The newest save could not be applied (#{code}). The previous configuration is still " <>
        "running, and the save is not live."
end
