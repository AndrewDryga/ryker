defmodule Ryker.ControlPlane.SettingsPage do
  @moduledoc "Focused settings pages and the single clean-install checklist."

  use Phoenix.Component

  alias Ryker.ControlPlane.{Components, SettingsEditor, SettingsSections, WebhookPreview}

  @description "Connect services and choose how Ryker works."

  def description, do: @description

  attr(:view, :any, required: true)
  attr(:commands, :map, required: true)
  attr(:section, :atom, default: :overview)
  attr(:body, :string, default: "")
  attr(:error, :string, default: nil)
  attr(:notice, :string, default: nil)
  attr(:reveal, :map, default: nil)
  attr(:github_repositories, :list, default: [])
  attr(:slack_members, :list, default: [])
  attr(:emisar_edit_ref, :string, default: nil)
  attr(:webhook_credential_editing, :boolean, default: false)

  def render(%{view: {:error, :settings_not_initialized}} = assigns) do
    ~H"""
    <div class="settings-page">
      <Components.page_header title="Finish setup" description="Start with Ryker's safe defaults." />
      <section class="settings-panel setup-empty">
        <h2>Create this installation</h2>
        <p>
          This creates the local settings record. Learning starts on; Slack responds only when
          mentioned; publication, proactive participation and scheduled reports stay off.
        </p>
        <button type="button" class="ui-button primary" phx-click="initialize-settings">
          Start setup
        </button>
        <Components.form_feedback :if={@error} message={@error} tone={:error} />
      </section>
    </div>
    """
  end

  def render(%{view: {:error, :settings_unavailable}} = assigns) do
    ~H"""
    <div class="settings-page">
      <Components.page_header
        title="Settings unavailable"
        description="Ryker could not read the settings database."
      />
      <section class="settings-panel">
        <p>
          The running configuration was not changed. Try this page again when the database is available.
        </p>
      </section>
    </div>
    """
  end

  def render(%{view: {:ok, view}} = assigns) do
    assigns =
      assigns
      |> assign(:view, view)
      |> assign(:page, page(assigns.section))
      |> assign(:sections, sections(assigns.section))

    ~H"""
    <div class="settings-page" id="settings-page" phx-hook="SettingsDraft">
      <Components.page_header title={@page.title} description={@page.description} />

      <Components.form_feedback :if={@error} message={@error} tone={:error} />
      <Components.form_feedback :if={@notice} message={@notice} tone={:success} />
      <Components.form_feedback
        :if={@view.application == :pending}
        message="Applying the saved settings…"
        tone={:warning}
        class="page-feedback"
      />
      <Components.form_feedback
        :if={match?({:failed, _}, @view.application)}
        message="The newest settings could not be applied. The previous configuration is still running."
        tone={:error}
        class="page-feedback"
      />
      <section :if={@reveal} class="secret-reveal" role="status">
        <div>
          <strong>{@reveal.label}</strong>
          <p>Copy this now. Ryker will not show it again.</p>
        </div>
        <code>{@reveal.value}</code>
      </section>

      <.overview :if={@section == :overview} view={@view} />
      <.connections
        :if={@section in [:slack, :github, :emisar]}
        section={@section}
        view={@view}
        slack_members={@slack_members}
        emisar_edit_ref={@emisar_edit_ref}
      />
      <.webhook_credentials
        :if={@section == :webhooks}
        view={@view}
        editing={@webhook_credential_editing}
      />

      <details :if={@section == :system && @sections != []} class="settings-panel system-panel" open>
        <summary>
          <span><strong>Work execution</strong><small>Worker placement and advanced policy controls.</small></span><span>Configure</span>
        </summary>
        <p class="system-panel-intro">
          The bundled worker is configured automatically. Use these controls only for a separately managed worker fleet.
        </p>
        <.live_component
          :for={section <- @sections}
          module={SettingsEditor}
          id={"settings-#{section.key}"}
          section={section}
          view={@view}
          commands={@commands}
        />
      </details>

      <.live_component
        :for={section <- if(@section == :system, do: [], else: @sections)}
        module={SettingsEditor}
        id={"settings-#{section.key}"}
        section={section}
        view={@view}
        commands={@commands}
        show_header={section.title != @page.title}
      />

      <.live_component
        :if={@section == :webhooks}
        module={WebhookPreview}
        id="webhook-preview"
        view={@view}
        check={@commands.preview_webhook}
      />

      <details :if={@section == :system} class="settings-panel system-panel system-evidence">
        <summary>
          <span><strong>Running system</strong><small>Loaded components, capabilities and technical evidence.</small></span><span>Inspect</span>
        </summary>
        <div class="settings-effective">{Phoenix.HTML.raw(@body)}</div>
      </details>
    </div>
    """
  end

  attr(:view, :map, required: true)

  defp overview(assigns) do
    slack =
      assigns.view.snapshot.slack.enabled and
        verified?(assigns.view, [:slack_app, :slack_bot])

    github = assigns.view.github_connection == :ready

    repositories = length(assigns.view.snapshot.repositories)

    assigns =
      assign(assigns,
        steps: [
          %{
            done: slack,
            title: "Connect Slack",
            text: "Verify the app and bot tokens, then choose the operators.",
            href: "/settings/slack"
          },
          %{
            done: github,
            title: "Connect GitHub",
            text: "Verify the GitHub App and its webhook.",
            href: "/settings/github"
          },
          %{
            done: repositories > 0,
            title: "Add repositories",
            text: repository_text(repositories),
            href: "/repositories"
          },
          %{
            done: assigns.view.setup.invited_channels > 0,
            title: "Invite Ryker in Slack",
            text: "Add Ryker to a channel, then return here. Ryker detects the channel.",
            href: "/channels"
          },
          %{
            done: assigns.view.setup.configured_channels > 0,
            title: "Choose the channel repository",
            text: "Connect the detected channel to one of the imported repositories.",
            href: "/channels"
          },
          %{
            done: assigns.view.setup.successful_request,
            title: "Send a real request",
            text: "Mention Ryker in that channel to verify routing, work and delivery.",
            href: nil
          }
        ]
      )

    assigns = assign(assigns, :complete, Enum.all?(assigns.steps, & &1.done))

    ~H"""
    <section :if={!@complete} class="settings-panel setup-checklist" aria-labelledby="setup-title">
      <header>
        <div>
          <h2 id="setup-title">Finish setup</h2>
          <p>Complete these in order. Values Ryker can discover are filled in automatically.</p>
        </div>
        <span>{Enum.count(@steps, & &1.done)} of {length(@steps)} complete</span>
      </header>
      <ol>
        <li :for={{step, index} <- Enum.with_index(@steps, 1)} class={if step.done, do: "done"}>
          <span class="setup-step-number" aria-label={if step.done, do: "Completed"}>{if step.done,
            do: "✓",
            else: index}</span>
          <div>
            <strong>{step.title}</strong><p>{step.text}</p>
          </div>
          <.link :if={step.href && !step.done} navigate={step.href} class="ui-button secondary">Continue</.link>
        </li>
      </ol>
    </section>
    <p :if={!@complete} class="setup-optional-link">
      <span>Optional:</span> <.link navigate="/settings/emisar">Connect Emisar</.link>
      for governed approvals.
    </p>
    <nav :if={@complete} class="settings-directory" aria-label="Settings areas">
      <a href="/settings/slack"><strong>Slack</strong><span>Workspace connection and operators</span></a>
      <a href="/settings/github"><strong>GitHub</strong><span>App connection and repository access</span></a>
      <a href="/settings/emisar"><strong>Emisar</strong><span>Governed approval accounts</span></a>
      <a href="/settings/webhooks"><strong>Webhooks</strong><span>External event sources</span></a>
      <a href="/settings/retention"><strong>Retention</strong><span>Data and cleanup horizons</span></a>
      <a href="/settings/token-rates"><strong>Token rates</strong><span>Fallback cost rates</span></a>
      <a href="/settings/system"><strong>System</strong><span>Runtime evidence and advanced deployment</span></a>
    </nav>
    """
  end

  attr(:view, :map, required: true)
  attr(:section, :atom, required: true)
  attr(:slack_members, :list, required: true)
  attr(:emisar_edit_ref, :string, default: nil)

  defp connections(assigns) do
    assigns =
      assign(assigns,
        slack_verified: verified?(assigns.view, [:slack_app, :slack_bot]),
        slack_connected:
          assigns.view.snapshot.slack.enabled and
            verified?(assigns.view, [:slack_app, :slack_bot]),
        slack_readiness: assigns.view.readiness.slack,
        github_verified: assigns.view.github_connection == :ready,
        github_invalid: assigns.view.github_connection == :invalid,
        github_connected:
          assigns.view.snapshot.github.enabled and
            verified?(assigns.view, [:github_private_key, :github_webhook]),
        emisar_edit:
          Enum.find(
            assigns.view.snapshot.emisar_connections,
            &(&1.ref == assigns.emisar_edit_ref)
          )
      )

    ~H"""
    <div class="connection-grid">
      <section :if={@section == :slack} class="settings-panel integration-panel">
        <header class="integration-overview">
          <div>
            <span class="integration-eyebrow">Connection</span>
            <h2>{if @slack_verified, do: @slack_readiness.title, else: "Connect Slack"}</h2>
            <p :if={!@slack_verified}>
              Paste your Slack app tokens. Ryker detects the workspace, app and bot for you.
            </p>
            <p :if={@slack_verified && !@slack_connected}>
              Choose who can operate Ryker to finish setup.
            </p>
            <p :if={@slack_connected && @slack_readiness.state == :ready}>
              {@view.snapshot.slack.bot_name || "Ryker"} is connected to {@view.snapshot.slack.workspace_name ||
                @view.snapshot.slack.workspace_ref}.
            </p>
            <p :if={@slack_connected && @slack_readiness.state != :ready}>
              {@slack_readiness.detail}
            </p>
          </div>
          <.connection_state state={
            cond do
              @slack_readiness.state == :ready -> :connected
              @slack_connected -> :starting
              @slack_verified -> :pending
              true -> :missing
            end
          } />
        </header>

        <section :if={!@slack_verified} class="integration-step">
          <div class="integration-step-copy">
            <span>Step 1</span><h3>Add the app tokens</h3>
            <p>You need one app-level token and one bot token from the same Slack app.</p>
          </div>
          <.slack_connection_form action_label="Verify Slack" />
        </section>

        <section :if={@slack_verified} class="integration-step integration-step-primary">
          <div class="integration-step-copy">
            <span>{if @slack_connected, do: "Access", else: "Next step"}</span>
            <h3>Operators</h3>
            <p>Choose the people allowed to run installation-level commands in Slack.</p>
          </div>
          <button
            :if={@slack_members == []}
            type="button"
            class={"ui-button #{if @slack_connected, do: "secondary", else: "primary"}"}
            phx-click="load-slack-members"
          >Choose operators</button>
          <form :if={@slack_members != []} phx-submit="save-slack-choices" class="operator-form">
            <div class="operator-list" role="group" aria-label="Slack operators">
              <label :for={member <- @slack_members} class="operator-choice">
                <input
                  type="checkbox"
                  name="operators[]"
                  value={member.id}
                  checked={member.id in @view.snapshot.slack.operators}
                />
                <span><strong>{member.name}</strong><small>{member.id}</small></span>
              </label>
            </div>
            <div class="integration-actions">
              <button class="ui-button primary" type="submit">Save operators</button>
            </div>
          </form>
        </section>

        <details :if={@slack_verified} class="integration-maintenance">
          <summary>Connection settings</summary>
          <div class="integration-maintenance-body">
            <section>
              <h3>Replace credentials</h3>
              <p>Use this only when the Slack app tokens have changed.</p>
              <.slack_connection_form action_label="Replace credentials" />
            </section>
            <section class="integration-danger-zone">
              <div>
                <h3>Disconnect Slack</h3><p>
                  Ryker will stop receiving and replying to Slack messages.
                </p>
              </div>
              <button
                type="button"
                class="ui-button danger"
                phx-click="disconnect-integration"
                phx-value-kind="slack"
              >Disconnect</button>
            </section>
          </div>
        </details>
      </section>

      <section :if={@section == :github} class="settings-panel integration-panel">
        <header class="integration-overview">
          <div>
            <span class="integration-eyebrow">Connection</span>
            <h2>
              {cond do
                @github_verified -> "GitHub App verified"
                @github_invalid -> "Repair GitHub connection"
                true -> "Connect GitHub"
              end}
            </h2>
            <p :if={!@github_verified && !@github_invalid}>
              Add the GitHub App credentials once. Ryker verifies the app and detects its identity.
            </p>
            <p :if={@github_invalid}>
              The saved GitHub identity or private key is incomplete. Verify the App again before importing repositories.
            </p>
            <p :if={@github_verified && !@github_connected}>
              Add a repository to enable GitHub work.
            </p>
            <p :if={@github_connected}>
              Connected as {@view.snapshot.github.app_slug || "your GitHub App"}.
            </p>
          </div>
          <.connection_state state={
            cond do
              @github_connected -> :connected
              @github_verified -> :verified
              true -> :missing
            end
          } />
        </header>

        <section :if={!@github_verified} class="integration-step">
          <div class="integration-step-copy">
            <span>Step 1</span><h3>Verify the GitHub App</h3>
            <p>
              Ryker checks the App ID and private key, then creates a webhook secret if you leave it blank.
            </p>
          </div>
          <.github_connection_form action_label="Verify GitHub App" />
        </section>

        <div :if={@github_verified} class="integration-columns">
          <section class="integration-step integration-step-primary">
            <div class="integration-step-copy">
              <span>{if @github_connected, do: "Repositories", else: "Next step"}</span>
              <h3>{if @github_connected, do: "Repository access", else: "Add repositories"}</h3>
              <p>
                Anyone with write access to an added repository can ask Ryker to work there. Access is checked with GitHub for every request.
              </p>
            </div>
            <.link navigate="/repositories" class="ui-button primary">
              {if @github_connected, do: "Manage repositories", else: "Add repositories"}
            </.link>
          </section>
          <section class="integration-step">
            <div class="integration-step-copy">
              <span>GitHub App</span><h3>Webhook</h3>
              <p>Use this callback URL in the GitHub App.</p>
            </div>
            <div class="connection-guidance">
              <code>{@view.github_callback_url}</code>
              <details class="connection-permissions">
                <summary>Required events and permissions</summary>
                <p>
                  Subscribe to issues, pull requests, reviews, pushes, checks, workflow runs, releases, deployments, installation changes and repository changes.
                </p>
                <p>
                  Keep Metadata on read. Grant only the issue, pull request, checks, actions, deployment and contents access needed for the work you enable.
                </p>
              </details>
              <a
                :if={@view.snapshot.github.app_slug}
                href={"https://github.com/apps/#{@view.snapshot.github.app_slug}/installations/new"}
                target="_blank"
                rel="noopener noreferrer"
              >Install the app in another organization</a>
            </div>
          </section>
        </div>

        <details :if={@github_verified} class="integration-maintenance">
          <summary>Connection settings</summary>
          <div class="integration-maintenance-body">
            <section>
              <h3>Replace credentials</h3>
              <p>Use this only when the GitHub App ID, private key, or webhook secret has changed.</p>
              <.github_connection_form action_label="Replace credentials" />
            </section>
            <section class="integration-danger-zone">
              <div>
                <h3>Disconnect GitHub</h3><p>
                  Ryker will stop receiving GitHub events and starting GitHub work.
                </p>
              </div>
              <button
                type="button"
                class="ui-button danger"
                phx-click="disconnect-integration"
                phx-value-kind="github"
              >Disconnect</button>
            </section>
          </div>
        </details>
      </section>

      <section :if={@section == :emisar} class="settings-panel integration-panel">
        <header class="integration-overview">
          <div>
            <span class="integration-eyebrow">Approval service</span>
            <h2>
              {if @view.snapshot.emisar_connections == [],
                do: "Connect Emisar",
                else: "Emisar accounts"}
            </h2>
            <p :if={@view.snapshot.emisar_connections == []}>
              Connect an account when governed actions need approval outside Ryker.
            </p>
            <p :if={@view.snapshot.emisar_connections != []}>
              {length(@view.snapshot.emisar_connections)} connected {if length(
                                                                          @view.snapshot.emisar_connections
                                                                        ) == 1,
                                                                        do: "account",
                                                                        else: "accounts"}.
            </p>
          </div>
          <.connection_state state={
            if @view.snapshot.emisar_connections == [], do: :missing, else: :connected
          } />
        </header>

        <div :if={@view.snapshot.emisar_connections == []} class="integration-columns emisar-guide">
          <section class="integration-step integration-step-primary">
            <div class="integration-step-copy">
              <span>How it works</span><h3>Send governed actions for approval</h3>
              <p>
                Ryker sends only the work you route here. Emisar approves or rejects it; Ryker never approves on your behalf.
              </p>
            </div>
            <ol class="setup-guide-steps">
              <li>
                <span>1</span><p>Create an API token in the Emisar account.</p>
              </li>
              <li>
                <span>2</span><p>Connect that account here.</p>
              </li>
              <li>
                <span>3</span><p>Choose which repositories and work types use it.</p>
              </li>
            </ol>
          </section>
          <section class="integration-step">
            <div class="integration-step-copy">
              <span>Step 1</span><h3>Account details</h3>
            </div>
            <.emisar_connection_form />
          </section>
        </div>

        <section :if={@view.snapshot.emisar_connections != []} class="integration-step">
          <div class="integration-section-heading">
            <div class="integration-step-copy">
              <span>Accounts</span><h3>Connected accounts</h3><p>
                Pause an account to keep its history and routes without sending it new work.
              </p>
            </div>
            <button
              :if={is_nil(@emisar_edit_ref)}
              type="button"
              class="ui-button secondary"
              phx-click="show-emisar-form"
              phx-value-ref="new"
            >Add account</button>
          </div>
          <ul class="integration-account-list">
            <li :for={connection <- @view.snapshot.emisar_connections}>
              <div>
                <strong>{connection.display_name}</strong>
                <span>
                  {connection.account_label || connection.account_ref} · Monitoring {if connection.monitoring_enabled,
                    do: "on",
                    else: "off"}
                </span>
              </div>
              <Components.status state={
                if connection.enabled_for_new_work, do: :active, else: :paused
              } />
              <div class="integration-row-actions">
                <button
                  type="button"
                  class="ui-button quiet"
                  phx-click={
                    if connection.enabled_for_new_work, do: "disable-emisar", else: "enable-emisar"
                  }
                  phx-value-ref={connection.ref}
                >{if connection.enabled_for_new_work, do: "Pause", else: "Resume"}</button>
                <button
                  type="button"
                  class="ui-button secondary"
                  phx-click="show-emisar-form"
                  phx-value-ref={connection.ref}
                >Manage</button>
              </div>
            </li>
          </ul>
        </section>

        <section :if={@emisar_edit_ref == "new"} class="integration-step integration-editor">
          <div class="integration-section-heading">
            <div class="integration-step-copy">
              <span>New account</span><h3>Connect another Emisar account</h3>
            </div>
            <button type="button" class="ui-button quiet" phx-click="hide-emisar-form">Cancel</button>
          </div>
          <.emisar_connection_form />
        </section>

        <section :if={@emisar_edit} class="integration-step integration-editor">
          <div class="integration-section-heading">
            <div class="integration-step-copy">
              <span>Account settings</span><h3>{@emisar_edit.display_name}</h3>
            </div>
            <button type="button" class="ui-button quiet" phx-click="hide-emisar-form">Close</button>
          </div>
          <div class="integration-editor-grid">
            <form phx-submit="rename-emisar">
              <input type="hidden" name="connection[ref]" value={@emisar_edit.ref} />
              <label>Display name<input
                type="text"
                name="connection[display_name]"
                value={@emisar_edit.display_name}
                required
              /></label>
              <button class="ui-button secondary" type="submit">Save name</button>
            </form>
            <form phx-submit="rotate-emisar" autocomplete="off">
              <input type="hidden" name="connection[ref]" value={@emisar_edit.ref} />
              <label>New API token<input type="password" name="connection[token]" required /></label>
              <button class="ui-button secondary" type="submit">Replace token</button>
            </form>
          </div>
          <section class="integration-account-option">
            <div>
              <h3>Approval monitoring</h3>
              <p>
                {if @emisar_edit.monitoring_enabled,
                  do: "Ryker is watching this account for approval decisions.",
                  else: "Turn this on when Ryker should watch this account for approval decisions."}
              </p>
            </div>
            <button
              type="button"
              class="ui-button secondary"
              phx-click={
                if @emisar_edit.monitoring_enabled,
                  do: "disable-emisar-monitoring",
                  else: "enable-emisar-monitoring"
              }
              phx-value-ref={@emisar_edit.ref}
            >{if @emisar_edit.monitoring_enabled, do: "Turn off", else: "Turn on"}</button>
          </section>
          <section class="integration-danger-zone">
            <div>
              <h3>Remove account</h3><p>
                Existing audit history stays, but its approval routes are removed.
              </p>
            </div>
            <button
              type="button"
              class="ui-button danger"
              phx-click="delete-emisar"
              phx-value-ref={@emisar_edit.ref}
            >Remove</button>
          </section>
        </section>
      </section>

      <section
        :if={@section == :emisar && @view.snapshot.emisar_connections != []}
        class="settings-panel integration-panel"
      >
        <header class="integration-overview">
          <div>
            <span class="integration-eyebrow">Routing</span><h2>Approval routes</h2><p>
              Choose exactly which work each Emisar account receives.
            </p>
          </div>
          <span class="integration-count">{length(@view.snapshot.emisar_bindings)} {if length(
                                                                                         @view.snapshot.emisar_bindings
                                                                                       ) == 1,
                                                                                       do: "route",
                                                                                       else: "routes"}</span>
        </header>
        <ul
          :if={@view.snapshot.emisar_bindings != []}
          class="integration-account-list integration-route-list"
        >
          <li :for={binding <- @view.snapshot.emisar_bindings}>
            <div>
              <strong>{humanize(binding.purpose)}</strong><span>{emisar_scope_label(
                @view.snapshot,
                binding
              )} to {emisar_connection_label(@view.snapshot, binding.connection_ref)}</span>
            </div>
            <button
              type="button"
              class="ui-button quiet danger-text"
              phx-click="delete-emisar-binding"
              phx-value-id={binding.id}
            >Remove</button>
          </li>
        </ul>
        <section class="integration-step integration-step-primary">
          <div class="integration-step-copy">
            <span>New route</span><h3>Choose where approvals go</h3><p>
              More specific routes can send different repositories or work types to different accounts.
            </p>
          </div>
          <form phx-submit="bind-emisar" class="routing-form">
            <div class="connection-fields routing-fields">
              <label>Use for<select name="binding[scope]" required>
                <option value="installation_purpose">Work without a repository</option>
                <optgroup :if={@view.snapshot.repositories != []} label="Repositories">
                  <option
                    :for={repository <- @view.snapshot.repositories}
                    value={"repository:#{repository.ref}"}
                  >
                    {repository.display_name}
                  </option>
                </optgroup>
                <optgroup :if={@view.snapshot.contexts != []} label="Repository groups">
                  <option :for={context <- @view.snapshot.contexts} value={"context:#{context.ref}"}>
                    {context.display_name}
                  </option>
                </optgroup>
              </select></label>
              <label>Work type<select name="binding[purpose]" required>
                <option :for={purpose <- Ryker.Settings.EmisarBinding.purposes()} value={purpose}>
                  {humanize(purpose)}
                </option>
              </select></label>
              <label>Send to<select name="binding[connection_ref]" required>
                <option :for={connection <- @view.snapshot.emisar_connections} value={connection.ref}>
                  {connection.display_name}
                </option>
              </select></label>
            </div>
            <button class="ui-button primary" type="submit">Save route</button>
          </form>
        </section>
      </section>
    </div>
    """
  end

  attr(:view, :map, required: true)
  attr(:repositories, :list, required: true)
  attr(:discovery, :any, default: :idle)

  def repository_import(assigns) do
    assigns =
      assign(
        assigns,
        :github_connected,
        assigns.view.github_connection == :ready
      )

    ~H"""
    <section class="settings-panel repository-import" aria-labelledby="repository-import-title">
      <header>
        <div>
          <h2 id="repository-import-title">Add repositories</h2>
          <p>Import repositories the connected GitHub App can access.</p>
        </div>
        <span :if={@discovery == :complete && @repositories != []}>
          {length(@repositories)} found
        </span>
      </header>
      <div :if={!@github_connected} class="repository-connect-prompt">
        <p>
          {if @view.github_connection == :invalid,
            do: "Repair the GitHub connection before importing repositories.",
            else: "Connect GitHub before importing repositories."}
        </p>
        <.link navigate="/settings/github" class="ui-button secondary">
          {if @view.github_connection == :invalid,
            do: "Repair GitHub connection",
            else: "Connect GitHub"}
        </.link>
      </div>
      <button
        :if={@github_connected && @discovery == :idle}
        type="button"
        class="ui-button secondary"
        phx-click="discover-github-repositories"
        phx-disable-with="Finding repositories…"
      >Find repositories</button>
      <div
        :if={@github_connected && @discovery == :complete && @repositories == []}
        class="repository-discovery-result"
      >
        <div>
          <strong>No repositories found</strong>
          <p>Give the GitHub App access to at least one repository, then try again.</p>
        </div>
        <button
          type="button"
          class="ui-button secondary"
          phx-click="discover-github-repositories"
          phx-disable-with="Checking again…"
        >Try again</button>
      </div>
      <div
        :if={@github_connected && match?({:error, _}, @discovery)}
        class="repository-discovery-result repository-discovery-error"
      >
        <Components.form_feedback
          message={elem(@discovery, 1)}
          tone={:error}
          class="repository-discovery-feedback"
        />
        <div class="repository-discovery-actions">
          <button
            type="button"
            class="ui-button secondary"
            phx-click="discover-github-repositories"
            phx-disable-with="Trying again…"
          >Try again</button>
          <.link navigate="/settings/github" class="ui-button secondary">
            Review GitHub connection
          </.link>
        </div>
      </div>
      <form :if={@github_connected && @repositories != []} phx-submit="import-github-repositories">
        <label class="repository-search">Search repositories<input
          id="repository-search"
          type="search"
          placeholder="Owner or repository name"
          phx-hook="RepositorySearch"
        /></label>
        <ul>
          <li :for={repository <- @repositories} data-repository-name={repository.full_name}>
            <label><input
              type="checkbox"
              name="repository_ids[]"
              value={repository.repository_id}
              checked={!repository.already_present}
              disabled={repository.already_present}
            />
            <strong>{repository.full_name}</strong><span>{if repository.already_present,
              do: "Already added",
              else: repository.default_branch}</span></label>
          </li>
        </ul>
        <label class="member-choice"><input
          type="checkbox"
          name="auto_add_repositories"
          value="true"
          checked={@view.snapshot.github.auto_add_repositories}
        /> Automatically add newly available repositories</label>
        <div class="repository-import-actions">
          <button class="ui-button secondary" type="submit" name="import_mode" value="selected">
            Add selected
          </button>
          <button class="ui-button primary" type="submit" name="import_mode" value="all">Add all {Enum.count(
            @repositories,
            &(!&1.already_present)
          )}</button>
        </div>
      </form>
    </section>
    """
  end

  attr(:view, :map, required: true)
  attr(:editing, :boolean, required: true)

  defp webhook_credentials(assigns) do
    assigns =
      assign(assigns, :credentials, Enum.filter(assigns.view.credentials, &(&1.kind == :webhook)))

    ~H"""
    <section class="settings-panel connection-card">
      <header>
        <div>
          <h2>Signing credential</h2><p>
            Generate a strong secret or import the one your sender already uses.
          </p>
        </div>
      </header>
      <ul :if={@credentials != []} class="credential-list">
        <li :for={credential <- @credentials}>
          <span><strong>{credential.name}</strong><small>{credential.verification_status}</small></span>
          <button
            type="button"
            class="ui-button danger"
            phx-click="delete-webhook-credential"
            phx-value-name={credential.name}
          >Delete</button>
        </li>
      </ul>
      <button
        :if={@credentials != [] and !@editing}
        type="button"
        class="ui-button secondary"
        phx-click="show-webhook-credential-form"
      >+ Add signing credential</button>
      <div :if={@credentials == [] or @editing} class="settings-inline-editor">
        <div class="settings-editor-heading">
          <h3>Add signing credential</h3>
          <button
            :if={@credentials != []}
            type="button"
            class="ui-button quiet"
            phx-click="hide-webhook-credential-form"
          >Close</button>
        </div>
        <form phx-submit="create-webhook-credential" autocomplete="off" class="connection-form">
          <label>Name<input
            type="text"
            name="credential[name]"
            pattern="[a-z0-9][a-z0-9_.:-]{0,127}"
            required
          /></label>
          <label>Existing secret
          <span>Optional — leave empty to generate one.</span><input
            type="password"
            name="credential[secret]"
          /></label>
          <button class="ui-button primary" type="submit">Create credential</button>
        </form>
      </div>
    </section>
    """
  end

  attr(:state, :atom, required: true)

  defp connection_state(assigns) do
    ~H"""
    <span class={"connection-state #{@state}"}>
      {case @state do
        :connected -> "Connected"
        :verified -> "App verified"
        :pending -> "Finish setup"
        :starting -> "Starting"
        :missing -> "Not connected"
      end}
    </span>
    """
  end

  attr(:action_label, :string, default: "Connect Slack")

  defp slack_connection_form(assigns) do
    ~H"""
    <form phx-submit="connect-slack" autocomplete="off" class="connection-form">
      <fieldset>
        <legend>Slack app</legend>
        <p>Paste the two tokens from your Slack app. Workspace and bot IDs are detected for you.</p>
        <div class="connection-fields">
          <label>App token<input
            type="password"
            name="connection[app_token]"
            placeholder="xapp-…"
            required
          /></label>
          <label>Bot token<input
            type="password"
            name="connection[bot_token]"
            placeholder="xoxb-…"
            required
          /></label>
        </div>
      </fieldset>
      <button class="ui-button primary" type="submit">{@action_label}</button>
    </form>
    """
  end

  attr(:action_label, :string, default: "Connect GitHub")

  defp github_connection_form(assigns) do
    ~H"""
    <form
      phx-submit="connect-github"
      autocomplete="off"
      class="connection-form github-connection-form"
    >
      <fieldset>
        <legend>GitHub App</legend>
        <p>Ryker verifies the App and detects its identity from these credentials.</p>
        <div class="connection-fields">
          <label>App ID<input type="number" name="connection[app_id]" min="1" required /></label>
          <label>
            Private key (.pem)
            <input
              id="github-private-key-file"
              type="file"
              accept=".pem,application/x-pem-file,text/plain"
              phx-hook="PrivateKeyFile"
              data-target="github-private-key"
              required
            />
            <textarea id="github-private-key" name="connection[private_key]" hidden></textarea>
          </label>
          <label>
            Webhook secret <span>Leave empty and Ryker will generate one.</span>
            <input type="password" name="connection[webhook_secret]" />
          </label>
        </div>
      </fieldset>
      <details class="connection-advanced">
        <summary>GitHub Enterprise</summary><label>API URL<input
          type="url"
          name="connection[api_url]"
          value="https://api.github.com"
        /></label>
      </details>
      <button class="ui-button primary" type="submit">{@action_label}</button>
    </form>
    """
  end

  defp emisar_connection_form(assigns) do
    ~H"""
    <form phx-submit="connect-emisar" autocomplete="off" class="connection-form">
      <div class="connection-fields">
        <label>
          API token <span>Ryker verifies the account, then stores this encrypted.</span>
          <input type="password" name="connection[token]" required />
        </label>
        <label>
          Emisar URL <span>Keep the default unless this account is self-hosted.</span>
          <input
            type="url"
            name="connection[rpc_url]"
            value="https://emisar.dev/api/mcp/rpc"
            required
          />
        </label>
      </div>
      <button class="ui-button primary" type="submit">Connect account</button>
    </form>
    """
  end

  defp verified?(view, kinds) do
    Enum.all?(kinds, fn kind ->
      Enum.any?(view.credentials, &(&1.kind == kind and &1.verification_status == :verified))
    end)
  end

  defp repository_text(0), do: "Import one or more repositories available to the GitHub App."
  defp repository_text(1), do: "1 repository added."
  defp repository_text(count), do: "#{count} repositories added."

  defp page(:overview), do: %{title: "Settings", description: @description}

  defp page(:slack),
    do: %{
      title: "Slack",
      description: "Connect Ryker to your workspace and choose who can operate it."
    }

  defp page(:github),
    do: %{
      title: "GitHub",
      description: "Connect the GitHub App and verify repository access."
    }

  defp page(:emisar),
    do: %{
      title: "Emisar",
      description: "Connect approval accounts for work that needs governed actions."
    }

  defp page(:webhooks),
    do: %{
      title: "Webhooks",
      description: "Connect an external system and choose where its events should go."
    }

  defp page(:retention),
    do: %{
      title: "Retention",
      description: "Set how many days Ryker keeps each kind of operational and historical data."
    }

  defp page(:pricing),
    do: %{
      title: "Token rates",
      description: "Fallback rates used only when a provider does not report cost."
    }

  defp page(:system),
    do: %{
      title: "System",
      description: "Advanced installation controls and running technical evidence."
    }

  defp sections(section) when section in [:slack, :github, :emisar], do: []
  defp sections(:webhooks), do: section_list([:webhooks])
  defp sections(:retention), do: section_list([:retention])
  defp sections(:pricing), do: section_list([:pricing])
  defp sections(:system), do: section_list([:work, :policies])
  defp sections(:overview), do: []

  defp section_list(keys) do
    Enum.map(keys, fn key ->
      {:ok, section} = SettingsSections.fetch(key)
      section
    end)
  end

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp emisar_scope_label(snapshot, %{scope_kind: :repository, scope_ref: ref}) do
    case Enum.find(snapshot.repositories, &(&1.ref == ref)) do
      nil -> "Unavailable repository"
      repository -> repository.display_name
    end
  end

  defp emisar_scope_label(snapshot, %{scope_kind: :context, scope_ref: ref}) do
    case Enum.find(snapshot.contexts, &(&1.ref == ref)) do
      nil -> "Unavailable repository group"
      context -> context.display_name
    end
  end

  defp emisar_scope_label(_snapshot, %{scope_kind: :installation_purpose}),
    do: "Work without a repository"

  defp emisar_connection_label(snapshot, ref) do
    case Enum.find(snapshot.emisar_connections, &(&1.ref == ref)) do
      nil -> "unavailable account"
      connection -> connection.display_name
    end
  end
end
