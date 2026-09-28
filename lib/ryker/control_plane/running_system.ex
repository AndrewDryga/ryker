defmodule Ryker.ControlPlane.RunningSystem do
  @moduledoc """
  What the running process assembled, for the bottom of the Advanced settings
  page: whether tasks that change code can run, then the loaded settings
  grouped by the part of Ryker they belong to and the tools it names.

  It is evidence, never a control. Product settings are changed on the
  settings pages above it and the deployment environment where Ryker is
  installed. The loaded values sit in one closed disclosure, because they
  matter for support rather than for everyday use; a problem that needs a
  person (code changes unavailable) stays outside it. Everything a reader
  sees before opening a Details says it in plain words; keys, raw values and
  the precise behaviour of each setting stay under that setting's Details.

  Slack, GitHub, Emisar and webhooks are listed as integrations, in the state
  and words their own pages show (`Integrations`), with whether the running
  Ryker loaded them under Details. Until 2026-09-25 they were four bare
  "Not configured" lines that contradicted those pages: Slack with verified
  tokens, and webhooks with a signing credential, both read as nothing.
  """

  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{ConfigurationHelp, Integrations, Kit}
  alias Ryker.Work.CodeEditingSetup

  @integrations ~w(slack github emisar webhooks)

  @doc """
  The evidence as HTML, ready for the settings page's body. `integrations`
  are the states `Integrations.all/1` read from the same settings the page
  shows.
  """
  @spec html(%{
          rows: [map()],
          grants: [map()],
          source: String.t(),
          integrations: [Integrations.t()]
        }) :: String.t()
  def html(%{rows: rows, grants: grants, source: source, integrations: integrations}) do
    %{
      __changed__: nil,
      groups: groups(rows, integrations),
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
    <Kit.section_card
      id="code-editing"
      class="code-editing-setup"
      title="Tasks that change code"
      lede="Whether Ryker can run tasks that change code."
    >
      <p class="settings-state-line">
        <Kit.state
          tone={if @supported, do: :on, else: :bad}
          word={if @supported, do: "Supported", else: "Code changes are unavailable"}
        />
      </p>
      <p :if={@supported} class="settings-lede">
        This installation supports saving and restoring a task's working copy. Check each worker's health on <a href="/working-copies">Working copies</a>.
      </p>
      <div :if={!@supported} class="settings-problem">
        <p>
          Tasks that change code cannot run, because this installation cannot save and restore
          the copy of the code they work in. Docker Compose installations set this up on their
          own: check <code>scripts/compose.sh status</code>
          and <code>scripts/compose.sh logs</code>, then restart the installation.
        </p>
        <details class="settings-disclosure">
          <summary>If you run your own workers</summary>
          <p>
            Only installations with their own workers need this. Enrol a co:op worker install,
            connect it to Ryker's worker gateway, and select its worker install above.
            Ryker supplies the code and settings for each job; workers need no policy files.
          </p>
          <p>
            On the machine running Ryker, create a one-time enrolment token with <code>scripts/compose.sh worker-token WORKER_ID WORKSPACE_REF OPERATOR_REF</code>. Store it on the worker in a private file with mode <code>0600</code>, then connect to your reachable HTTPS gateway:
          </p>
          <pre><code>coop sessions connect --controller https://ryker.example:4322 --token-file /etc/coop/enrollment-token --state /var/lib/coop-sessions</code></pre>
          <p>
            For a private certificate authority, also pass
            <code>--ca-file /etc/coop/worker-ca.pem</code>
            with the CA supplied by your Ryker installation. Do not disable certificate verification.
          </p>
          <p>Check the worker locally:</p>
          <pre><code>coop sessions doctor --socket /var/lib/coop-sessions/control.sock</code></pre>
          <p>Confirm the saved settings were applied:</p>
          <pre><code>scripts/compose.sh doctor</code></pre>
          <p>
            Then check that working copies can be saved and restored, and that the repository's
            build tools are installed, before trying the task again.
          </p>
        </details>
      </div>
    </Kit.section_card>

    <Kit.section_card
      class="configuration-evidence"
      title="What is running"
      lede="What the running Ryker loaded, for support and troubleshooting."
    >
      <details class="system-evidence">
        <summary>Show what is loaded</summary>
        <div class="configuration-values">
          <p class="settings-lede">
            Nothing here can be changed. Settings saved on these pages take effect without a
            deployment; the database, network addresses and secrets are set where Ryker is
            installed. Configured means a setting was saved, not that its connection or workers are
            healthy, and a value can lag a save that has not been applied yet.
          </p>
          <p class="settings-lede">Loaded from <code>{@source}</code>.</p>
          <Kit.empty
            :if={@groups == []}
            variant={:hint}
            icon={:settings}
            title="Nothing loaded"
            text="The running Ryker published no settings."
          />
          <div :for={group <- @groups} class="configuration-group" data-group={group.key}>
            <h3>{group.title}</h3>
            <Kit.entity_list :if={group[:integrations]} label={group.title}>
              <.integration
                :for={integration <- group.integrations}
                integration={integration}
                row={Enum.find(group.rows, &(&1.key == Atom.to_string(integration.key)))}
              />
            </Kit.entity_list>
            <div :if={!group[:integrations]} class="entity-list" role="list" aria-label={group.title}>
              <.setting :for={row <- group.rows} row={row} source={@source} />
            </div>
          </div>
        </div>
        <div class="configuration-grants">
          <h3>Tools</h3>
          <p class="settings-lede">
            The tools this installation names. This is not a health check, and listing a tool does
            not give permission to use it.
          </p>
          <Kit.empty
            :if={@grants == []}
            variant={:hint}
            icon={:code}
            title="No tools"
            text="This installation names no tools."
          />
          <Kit.entity_list :if={@grants != []} label="Tools">
            <Kit.entity_row
              :for={grant <- @grants}
              name={grant.name}
              text={ConfigurationHelp.grant(grant.kind)}
              meta={[grant.kind, "From " <> grant.source]}
            />
          </Kit.entity_list>
        </div>
      </details>
    </Kit.section_card>
    """
  end

  attr(:integration, :map, required: true)
  attr(:row, :map, default: nil, doc: "Whether the running Ryker loaded it, when it said")

  # One integration in the words of its own page, with what the running
  # process holds for it under Details.
  defp integration(assigns) do
    assigns =
      assign(assigns, :help, ConfigurationHelp.setting(Atom.to_string(assigns.integration.key)))

    ~H"""
    <Kit.entity_row
      id={"running-#{@integration.key}"}
      name={@integration.name}
      href={@integration.href}
      link_row
      state={@integration.state}
      text={@integration.reason}
      meta={@integration.facts}
    >
      <:details>
        <details class="settings-row-details">
          <summary>Details</summary>
          <p class="configuration-behavior">{@help.behavior}</p>
          <dl>
            <div>
              <dt>Name in the settings file</dt>
              <dd><code>{@integration.key}</code></dd>
            </div>
            <div :if={@row}>
              <dt>Running now</dt>
              <dd><code>{if @row.value == "enabled", do: "yes", else: "no"}</code></dd>
            </div>
          </dl>
        </details>
      </:details>
    </Kit.entity_row>
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
              <dt>Name in the settings file</dt>
              <dd><code>{@row.key}</code></dd>
            </div>
            <div>
              <dt>Value as loaded</dt>
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
  # dotted key, in the order an operator reads a deployment: what runs, the
  # services it works through, then how each part behaves.
  defp groups(rows, integrations) do
    rows
    |> Enum.group_by(&group/1)
    |> Map.put_new({1, "integrations", "Integrations"}, [])
    |> Enum.sort_by(fn {{order, _key, _title}, _rows} -> order end)
    |> Enum.map(fn
      {{_order, "integrations", title}, rows} ->
        %{key: "integrations", title: title, rows: rows, integrations: integrations}

      {{_order, key, title}, rows} ->
        %{key: key, title: title, rows: rows}
    end)
    |> Enum.reject(&(&1[:integrations] == []))
  end

  defp group(%{key: key}) when key in @integrations, do: {1, "integrations", "Integrations"}

  defp group(%{key: key}) do
    case String.split(key, ".", parts: 2) do
      [_flag] -> {0, "subsystems", "Parts of Ryker"}
      ["runtime", _] -> {2, "runtime", "Installation"}
      ["admission", _] -> {3, "admission", "Routing"}
      ["work", _] -> {4, "work", "Running work"}
      ["retention", _] -> {5, "retention", "Cleanup and retention"}
      _ -> {6, "other", "Other settings"}
    end
  end
end
