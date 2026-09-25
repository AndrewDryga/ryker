defmodule Ryker.ControlPlane.RunningSystem do
  @moduledoc """
  What the running process assembled, for the bottom of the Advanced settings
  page: whether code-changing work can run, then the loaded settings grouped
  by the part of Ryker they belong to and the tool grants by name.

  It is evidence, never a control. Product settings are changed on the
  settings pages above it and the deployment environment where Ryker is
  installed. The loaded values sit in one closed disclosure, because they
  matter for support rather than for everyday use; a problem that needs a
  person (code changes unavailable) stays outside it.
  """

  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{CodeEditingSetup, ConfigurationHelp, Kit}

  @doc "The evidence as HTML, ready for the settings page's body."
  @spec html(%{rows: [map()], grants: [map()], source: String.t()}) :: String.t()
  def html(%{rows: rows, grants: grants, source: source}) do
    %{
      __changed__: nil,
      groups: groups(rows),
      grants: grants,
      source: source,
      supported: CodeEditingSetup.checkpoint_supported?()
    }
    |> render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp render(assigns) do
    ~H"""
    <section id="code-editing" class="code-editing-setup" aria-label="Work execution">
      <Kit.section_head title="Work execution" lede="Whether Ryker can run work that changes code." />
      <p class="settings-state-line">
        <Kit.state
          tone={if @supported, do: :on, else: :bad}
          word={if @supported, do: "Ready", else: "Code changes are unavailable"}
        />
      </p>
      <p :if={@supported} class="settings-lede">
        Workspace recovery is configured. Worker health is shown on <a href="/working-copies">Working copies</a>.
      </p>
      <div :if={!@supported} class="settings-problem">
        <p>
          Code-changing work is unavailable because no workspace recovery service is configured.
          Docker Compose installations should provide work execution automatically. Check
          <code>scripts/compose.sh status</code>
          and <code>scripts/compose.sh logs</code>, then restart the installation.
        </p>
        <details class="settings-disclosure">
          <summary>Custom worker fleet</summary>
          <p>
            Only custom deployments need this. Enrol a persistent co:op workspace, connect it to
            Ryker's authenticated worker gateway, and choose its policies under Execution policies
            above.
          </p>
          <p>Inspect the existing co:op session service and policies:</p>
          <pre><code>coop sessions doctor --socket /var/lib/coop-sessions/control.sock
    coop sessions policies --policies /etc/coop/session-policies.yaml --json</code></pre>
          <p>
            Create a one-time enrolment token with <code>MIX_ENV=prod mix ryker.coop_worker enroll WORKER_ID WORKSPACE_REF OPERATOR_REF</code>. Store it in a private file with mode <code>0600</code>, then connect with <code>coop sessions connect --config /etc/coop/worker.json</code>.
          </p>
          <p>Confirm the saved settings were applied:</p>
          <pre><code>MIX_ENV=prod mix ryker.doctor</code></pre>
          <p>
            Then check that workspaces can be saved and restored, and that the repository's build
            tools are installed, before trying the work again.
          </p>
        </details>
      </div>
    </section>

    <section class="configuration-evidence" aria-label="Running system">
      <Kit.section_head
        title="Running system"
        lede="What the running process loaded. Read-only, for support and troubleshooting."
      />
      <details class="system-evidence">
        <summary>Show what is loaded</summary>
        <div class="configuration-values">
          <p class="settings-lede">
            This is read-only evidence. Product settings are changed on these pages and take effect
            without a deployment; the database, listeners and credentials are set where Ryker is
            installed. Configured means a setting was saved, not that its connection or workers are
            healthy, and a value can lag a save that has not been applied yet.
          </p>
          <p class="settings-lede">Loaded from <code>{@source}</code>.</p>
          <Kit.empty
            :if={@groups == []}
            title="Nothing loaded"
            text="No effective settings were published by the running process."
          />
          <div :for={group <- @groups} class="configuration-group" data-group={group.key}>
            <h3>{group.title}</h3>
            <div class="entity-list" role="list" aria-label={group.title}>
              <.setting :for={row <- group.rows} row={row} source={@source} />
            </div>
          </div>
        </div>
        <div class="configuration-grants">
          <h3>Tool grants</h3>
          <p class="settings-lede">
            An inventory of configured names, not a live tool-health check. Listing a tool does not
            grant permission to use it.
          </p>
          <Kit.empty
            :if={@grants == []}
            title="No tool grants"
            text="No MCP or tool grants are configured."
          />
          <Kit.entity_list :if={@grants != []} label="Tool grants">
            <Kit.entity_row
              :for={grant <- @grants}
              name={grant.name}
              text={ConfigurationHelp.grant(grant.kind)}
              meta={[grant.kind, "From " <> grant.source]}
            />
          </Kit.entity_list>
        </div>
      </details>
    </section>
    """
  end

  attr(:row, :map, required: true)
  attr(:source, :string, required: true)

  # One loaded setting: what it is and its value first, what it is for under
  # it, and the key, raw value and default in its own closed Details.
  defp setting(assigns) do
    assigns =
      assign(assigns,
        help: ConfigurationHelp.setting(assigns.row.key),
        value: ConfigurationHelp.value(assigns.row.key, assigns.row.value)
      )

    ~H"""
    <article class="entity-row configuration-setting" data-setting={@row.key} role="listitem">
      <div class="entity-body">
        <h4 class="entity-name">{@help.title}</h4>
        <p class="entity-text configuration-value">{@value}</p>
        <p class="entity-meta configuration-purpose">{@help.purpose}</p>
        <details class="settings-row-details">
          <summary>Details</summary>
          <p class="configuration-behavior">{@help.behavior}</p>
          <p class="configuration-default">Default: {@help.default}</p>
          <dl>
            <div>
              <dt>Key</dt>
              <dd><code>{@row.key}</code></dd>
            </div>
            <div>
              <dt>Loaded value</dt>
              <dd><code>{@row.value}</code></dd>
            </div>
            <div :if={@row.source != @source} class="configuration-provenance">
              <dt>Loaded from</dt>
              <dd><code>{@row.source}</code></dd>
            </div>
          </dl>
        </details>
      </div>
    </article>
    """
  end

  # Presence flags have bare keys; everything else groups by the prefix of its
  # dotted key, in the order an operator reads a deployment: what runs, then
  # how each part behaves.
  defp groups(rows) do
    rows
    |> Enum.group_by(&group/1)
    |> Enum.sort_by(fn {{order, _key, _title}, _rows} -> order end)
    |> Enum.map(fn {{_order, key, title}, rows} -> %{key: key, title: title, rows: rows} end)
  end

  defp group(%{key: key}) do
    case String.split(key, ".", parts: 2) do
      [_flag] -> {0, "subsystems", "Subsystems"}
      ["runtime", _] -> {1, "runtime", "Runtime"}
      ["admission", _] -> {2, "admission", "Admission"}
      ["work", _] -> {3, "work", "Work execution"}
      ["retention", _] -> {4, "retention", "Cleanup and retention"}
      _ -> {5, "other", "Other settings"}
    end
  end
end
