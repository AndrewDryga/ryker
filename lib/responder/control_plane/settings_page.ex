defmodule Responder.ControlPlane.SettingsPage do
  @moduledoc """
  The settings page: what this installation decided, and what is actually running.

  Saved and applied are shown as two different facts. A revision that was saved
  but could not be assembled says so, because reading "saved" as "live" is the
  mistake the split between them exists to prevent.
  """

  use Phoenix.Component

  alias Responder.ControlPlane.{SettingsEditor, SettingsSections}

  attr(:view, :any, required: true)
  attr(:commands, :map, required: true)
  attr(:body, :string, default: "")
  attr(:error, :string, default: nil)

  def render(%{view: {:error, :settings_not_initialized}} = assigns) do
    ~H"""
    <section class="settings-setup">
      <h1>Set up this installation</h1>
      <p>
        This database has no product settings yet. Creating them writes one installation
        identity and the shipped defaults: no integration is connected, no work is placed and
        nothing is submitted to a model until you say so.
      </p>
      <p>
        If this deployment already ran with an application YAML file, import it instead — a new
        identity would re-key the worker, delivery and publication custody that history belongs to.
      </p>
      <button type="button" class="ui-button primary" phx-click="initialize-settings">
        Create settings for this installation
      </button>
      <p :if={@error} class="settings-error" role="alert">{@error}</p>
    </section>
    """
  end

  def render(%{view: {:error, :settings_unavailable}} = assigns) do
    ~H"""
    <section class="settings-unavailable">
      <h1>Settings could not be read</h1>
      <p>
        The settings database did not answer. This is not an installation without settings:
        nothing has been reset, and the running configuration is whatever was last applied.
        Editing is disabled until the database answers again.
      </p>
    </section>
    """
  end

  def render(%{view: {:ok, _view}} = assigns) do
    assigns = assign(assigns, :view, elem(assigns.view, 1))

    ~H"""
    <div class="settings-page">
      <header class="settings-status">
        <h1>Settings</h1>
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
      </header>
      <.live_component
        :for={section <- SettingsSections.sections()}
        module={SettingsEditor}
        id={"settings-#{section.key}"}
        section={section}
        view={@view}
        commands={@commands}
      />
      <section class="settings-effective">
        <h2>Effective host configuration</h2>
        <p>
          What the running process assembled from these settings, the deployment environment
          and the shipped defaults. This part is read-only: it is evidence, not a second place
          to change something.
        </p>
        {Phoenix.HTML.raw(@body)}
      </section>
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
