defmodule Ryker.ControlPlane.SettingsPage do
  @moduledoc """
  The pages that connect and configure Ryker: onboarding at /setup (see
  `SetupPage`), the environments Ryker works in (see `EnvironmentsPage`), the
  Integrations overview and a page per integration (Slack, GitHub, Emisar,
  Webhooks), and a page per installation setting (Models, Data retention,
  Model prices, Advanced). The sidebar is the only menu; each page has one
  title, one sentence and plain sections.

  A connection reads as a dot and a word with the one action that fits it
  (see `Integrations`). Anything that disconnects or deletes asks first and
  says, in words, what it will do; the LiveView runs it only after that
  question was asked.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  alias Ryker.ControlPlane.{
    Components,
    Environments,
    EnvironmentsPage,
    Integrations,
    Kit,
    SettingsEditor,
    SettingsSections,
    SetupPage,
    SlackNames,
    WebhookPreview
  }

  @doc "The title of one page: the name it has in the sidebar, or Set up Ryker."
  @spec title(atom()) :: String.t()
  def title(section), do: page(section).title

  attr(:view, :any, required: true)
  attr(:commands, :map, required: true)
  attr(:section, :atom, required: true)
  attr(:body, :string, default: "")
  attr(:error, :string, default: nil)
  attr(:notice, :string, default: nil)
  attr(:failure, :string, default: nil)
  attr(:reveal, :map, default: nil)
  attr(:confirm, :any, default: nil, doc: "{action, ref} of the question now open, if any")
  attr(:slack_members, :list, default: [])
  attr(:emisar_edit_ref, :string, default: nil)
  attr(:webhook_credential_editing, :boolean, default: false)

  attr(:params, :map,
    default: %{},
    doc: "The page's query, for pages that search or edit in place"
  )

  def render(%{view: {:error, :settings_not_initialized}} = assigns) do
    assigns = assign(assigns, :page, page(assigns.section))

    ~H"""
    <div class="settings-page">
      <Components.page_header title={@page.title} description={@page.description} />
      <section class="settings-start">
        <Kit.section_head
          title="Start setup"
          lede="Ryker has no settings yet. Setup starts with safe defaults: learning is on, Ryker replies in Slack only when mentioned, and pull requests, joining conversations and weekly reports stay off."
        />
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
        description="Ryker could not read its settings database."
      />
      <section class="settings-start">
        <p class="settings-lede">
          Nothing was changed, and the running configuration keeps working. Try again when the
          database is back.
        </p>
        <button type="button" class="ui-button secondary" phx-click="refresh">Try again</button>
      </section>
    </div>
    """
  end

  def render(%{view: {:ok, view}} = assigns) do
    assigns =
      assigns
      |> assign(:view, view)
      |> assign(:page, page(assigns.section, view))

    ~H"""
    <div class="settings-page" id="settings-page" phx-hook="SettingsDraft">
      <Components.page_header title={@page.title} description={@page.description}>
        <:action :if={@section == :environments}><EnvironmentsPage.add /></:action>
      </Components.page_header>

      <Components.form_feedback :if={@error} message={@error} tone={:error} class="page-feedback" />
      <Components.form_feedback
        :if={@failure}
        message={@failure}
        tone={:error}
        class="page-feedback"
      />
      <Components.form_feedback
        :if={@notice}
        message={@notice}
        tone={:success}
        class="page-feedback"
      />
      <Components.form_feedback
        :if={@view.application == :pending}
        message="Applying the saved settings…"
        tone={:info}
        class="page-feedback"
      />
      <Components.form_feedback
        :if={match?({:failed, _}, @view.application)}
        message="The newest settings could not be applied. The previous configuration is still running."
        tone={:error}
        class="page-feedback"
      />
      <section :if={@reveal} class="secret-reveal" role="status">
        <p><strong>{@reveal.label}</strong> Copy it now. Ryker will not show it again.</p>
        <Components.copy_block label="Copy">
          <pre>{@reveal.value}</pre>
        </Components.copy_block>
      </section>

      <SetupPage.render :if={@section == :setup} view={@view} />
      <EnvironmentsPage.render
        :if={@section == :environments}
        view={@view}
        params={@params}
        confirm={@confirm}
      />
      <.integrations :if={@section == :integrations} view={@view} />
      <.slack
        :if={@section == :slack}
        view={@view}
        commands={@commands}
        confirm={@confirm}
        slack_members={@slack_members}
      />
      <.github :if={@section == :github} view={@view} commands={@commands} confirm={@confirm} />
      <.emisar
        :if={@section == :emisar}
        view={@view}
        confirm={@confirm}
        edit_ref={@emisar_edit_ref}
      />
      <.webhooks
        :if={@section == :webhooks}
        view={@view}
        commands={@commands}
        confirm={@confirm}
        editing={@webhook_credential_editing}
      />
      <.live_component
        :for={key <- editors(@section)}
        module={SettingsEditor}
        id={"settings-#{key}"}
        section={section!(key)}
        view={@view}
        commands={@commands}
        show_header={@section == :system}
      />
      <div :if={@section == :system} class="settings-running">
        {Phoenix.HTML.raw(@body)}
      </div>
    </div>
    """
  end

  # Integrations overview ----------------------------------------------------

  attr(:view, :map, required: true)

  # Every service Ryker works through, whatever its state: its state, what it
  # gives Ryker, what is connected and the one action that fits.
  defp integrations(assigns) do
    assigns = assign(assigns, :rows, Integrations.overview(assigns.view))

    ~H"""
    <Kit.entity_list label="Integrations" class="integrations-list">
      <Kit.entity_row
        :for={row <- @rows}
        id={"integration-#{row.key}"}
        name={row.name}
        href={row.href}
        navigate={true}
        state={row.state}
        tag={row.tag}
        text={row.text}
        meta={row.meta}
      >
        <:actions>
          <.link
            navigate={row.action.href}
            class={["ui-button", if(row.action.primary, do: "primary", else: "secondary")]}
          >{row.action.label}<span class="sr-only">{" " <> row.name}</span></.link>
        </:actions>
      </Kit.entity_row>
    </Kit.entity_list>
    """
  end

  # Slack ---------------------------------------------------------------------

  attr(:view, :map, required: true)
  attr(:commands, :map, required: true)
  attr(:confirm, :any, default: nil)
  attr(:slack_members, :list, required: true)

  defp slack(assigns) do
    view = assigns.view
    slack = Integrations.slack(view)

    assigns =
      assign(assigns,
        verified: slack.verified,
        connected: slack.connected,
        line: slack,
        operators: operator_names(view.snapshot.slack)
      )

    ~H"""
    <.connection state={@line.state} text={@line.text}>
      <:action :if={@verified and @confirm != {"disconnect-slack", "slack"}}>
        <button
          type="button"
          class="ui-button secondary"
          phx-click="confirm-settings-action"
          phx-value-action="disconnect-slack"
          phx-value-ref="slack"
        >Disconnect</button>
      </:action>
    </.connection>
    <.confirmation
      :if={@confirm == {"disconnect-slack", "slack"}}
      title="Disconnect Slack?"
      text="Ryker stops reading and replying in Slack, and the saved tokens are deleted. Channels, instructions and history stay."
      label="Disconnect Slack"
      phx-click="disconnect-integration"
      phx-value-kind="slack"
    />

    <section :if={!@verified} class="settings-section" aria-label="Connect Slack">
      <Kit.section_head
        title="Connect Slack"
        lede="Paste the two tokens from your Slack app. Ryker finds the workspace and the bot for you."
      />
      <.slack_form label="Verify Slack" />
    </section>

    <section :if={@verified} class="settings-section" aria-label="Who can manage Ryker">
      <Kit.section_head
        title="Who can manage Ryker"
        lede="These people can change Ryker's settings from Slack."
      />
      <div :if={@slack_members == []} class="settings-people">
        <p>{people_text(@operators)}</p>
        <button
          type="button"
          class={["ui-button", if(@connected, do: "secondary", else: "primary")]}
          phx-click="load-slack-members"
        >Choose people</button>
      </div>
      <form :if={@slack_members != []} phx-submit="save-slack-choices" class="settings-people-form">
        <div class="settings-people-list" role="group" aria-label="People who can manage Ryker">
          <label :for={member <- @slack_members} class="settings-option">
            <input
              type="checkbox"
              name="operators[]"
              value={member.id}
              checked={member.id in @view.snapshot.slack.operators}
            />
            <span><strong>{member.name}</strong></span>
          </label>
        </div>
        <div class="settings-actions">
          <button class="ui-button primary" type="submit">Save changes</button>
          <button type="button" class="ui-button secondary" phx-click="cancel-slack-members">
            Cancel
          </button>
        </div>
      </form>
    </section>

    <.live_component
      :if={@verified}
      module={SettingsEditor}
      id="settings-slack"
      section={section!(:slack)}
      view={@view}
      commands={@commands}
      show_header={false}
    />

    <section :if={@verified} class="settings-section" aria-label="Slack tokens">
      <Kit.section_head
        title="Slack tokens"
        lede="Replace them only when they changed in your Slack app."
      />
      <details class="settings-disclosure">
        <summary>Replace the tokens</summary>
        <.slack_form label="Replace tokens" />
      </details>
    </section>
    """
  end

  attr(:label, :string, required: true)

  defp slack_form(assigns) do
    assigns = assign(assigns, :key, key(assigns.label))

    ~H"""
    <form phx-submit="connect-slack" autocomplete="off" class="settings-form">
      <div class="settings-field">
        <label for={"slack-app-token-#{@key}"}>App token</label>
        <p class="settings-help">Starts with xapp-.</p>
        <input
          id={"slack-app-token-#{@key}"}
          type="password"
          name="connection[app_token]"
          placeholder="xapp-…"
          required
        />
      </div>
      <div class="settings-field">
        <label for={"slack-bot-token-#{@key}"}>Bot token</label>
        <p class="settings-help">Starts with xoxb-.</p>
        <input
          id={"slack-bot-token-#{@key}"}
          type="password"
          name="connection[bot_token]"
          placeholder="xoxb-…"
          required
        />
      </div>
      <div class="settings-actions">
        <button class="ui-button primary" type="submit">{@label}</button>
      </div>
    </form>
    """
  end

  # GitHub --------------------------------------------------------------------

  attr(:view, :map, required: true)
  attr(:commands, :map, required: true)
  attr(:confirm, :any, default: nil)

  defp github(assigns) do
    view = assigns.view

    assigns =
      assign(assigns,
        line: Integrations.github(view),
        ready: view.github_connection == :ready,
        repositories: length(view.snapshot.repositories)
      )

    ~H"""
    <.connection state={@line.state} text={@line.text}>
      <:action :if={@view.github_connection == :invalid}>
        <a href="#github-app" class="ui-button secondary">Repair</a>
      </:action>
      <:action :if={@ready and @confirm != {"disconnect-github", "github"}}>
        <button
          type="button"
          class="ui-button secondary"
          phx-click="confirm-settings-action"
          phx-value-action="disconnect-github"
          phx-value-ref="github"
        >Disconnect</button>
      </:action>
    </.connection>
    <.confirmation
      :if={@confirm == {"disconnect-github", "github"}}
      title="Disconnect GitHub?"
      text="Ryker stops receiving GitHub events and starting GitHub work, and the App's private key and webhook secret are deleted. Repositories and history stay."
      label="Disconnect GitHub"
      phx-click="disconnect-integration"
      phx-value-kind="github"
    />

    <section :if={!@ready} class="settings-section" aria-label="GitHub App">
      <Kit.section_head
        id="github-app"
        title={
          if @view.github_connection == :invalid,
            do: "Repair GitHub connection",
            else: "Connect the GitHub App"
        }
        lede={
          if @view.github_connection == :invalid,
            do: "Verify the App again with its current private key. Repositories stay as they are.",
            else:
              "Ryker checks the App ID and private key, and creates a webhook secret if you leave it empty."
        }
      />
      <.github_form label="Verify GitHub App" />
    </section>

    <section :if={@ready} class="settings-section" aria-label="Repositories">
      <Kit.section_head
        title="Repositories"
        lede="Anyone with write access to an added repository can ask Ryker to work there. GitHub checks that access on every request."
      >
        <:actions>
          <.link
            navigate="/repositories"
            class={["ui-button", if(@repositories == 0, do: "primary", else: "secondary")]}
          >{if @repositories == 0, do: "Add repositories", else: "Manage repositories"}</.link>
        </:actions>
      </Kit.section_head>
      <p class="settings-lede">{repository_count(@repositories)}</p>
    </section>

    <section :if={@ready} class="settings-section" aria-label="Webhook">
      <Kit.section_head
        title="Webhook"
        lede="Paste this callback URL into your GitHub App's webhook settings."
      />
      <Components.copy_block label="Copy the callback URL">
        <pre>{@view.github_callback_url}</pre>
      </Components.copy_block>
      <details class="settings-disclosure">
        <summary>Events and permissions the App needs</summary>
        <p>
          Subscribe to issues, pull requests, reviews, pushes, checks, workflow runs, releases,
          deployments, installation changes and repository changes.
        </p>
        <p>
          Keep Metadata on read. Grant only the issue, pull request, checks, actions, deployment
          and contents access needed for the work you enable.
        </p>
      </details>
      <p :if={@view.snapshot.github.app_slug} class="settings-lede">
        <a
          href={"https://github.com/apps/#{@view.snapshot.github.app_slug}/installations/new"}
          target="_blank"
          rel="noopener noreferrer"
        >Install the App in another organization</a>
      </p>
    </section>

    <.live_component
      :if={@ready}
      module={SettingsEditor}
      id="settings-publication"
      section={section!(:publication)}
      view={@view}
      commands={@commands}
    />

    <section :if={@ready} class="settings-section" aria-label="App credentials">
      <Kit.section_head
        title="App credentials"
        lede="Replace them only when the App ID, private key or webhook secret changed."
      />
      <details class="settings-disclosure">
        <summary>Replace the App credentials</summary>
        <.github_form label="Replace credentials" />
      </details>
    </section>
    """
  end

  attr(:label, :string, required: true)

  defp github_form(assigns) do
    assigns = assign(assigns, :key, key(assigns.label))

    ~H"""
    <form phx-submit="connect-github" autocomplete="off" class="settings-form github-connection-form">
      <fieldset>
        <legend class="sr-only">GitHub App</legend>
        <div class="settings-field">
          <label for={"github-app-id-#{@key}"}>App ID</label>
          <p class="settings-help">A number on the App's settings page in GitHub.</p>
          <input
            id={"github-app-id-#{@key}"}
            type="number"
            name="connection[app_id]"
            min="1"
            required
          />
        </div>
        <div class="settings-field">
          <label for={"github-private-key-file-#{@key}"}>Private key</label>
          <p class="settings-help">The .pem file GitHub gave you when you created a key.</p>
          <input
            id={"github-private-key-file-#{@key}"}
            type="file"
            accept=".pem,application/x-pem-file,text/plain"
            phx-hook="PrivateKeyFile"
            data-target={"github-private-key-#{@key}"}
            required
          />
          <textarea id={"github-private-key-#{@key}"} name="connection[private_key]" hidden></textarea>
        </div>
        <div class="settings-field">
          <label for={"github-webhook-secret-#{@key}"}>Webhook secret</label>
          <p class="settings-help">Leave empty and Ryker creates one.</p>
          <input
            id={"github-webhook-secret-#{@key}"}
            type="password"
            name="connection[webhook_secret]"
          />
        </div>
      </fieldset>
      <details class="settings-disclosure">
        <summary>GitHub Enterprise</summary>
        <div class="settings-field">
          <label for={"github-api-url-#{@key}"}>API URL</label>
          <p class="settings-help">Change it only for GitHub Enterprise Server.</p>
          <input
            id={"github-api-url-#{@key}"}
            type="url"
            name="connection[api_url]"
            value="https://api.github.com"
          />
        </div>
      </details>
      <div class="settings-actions">
        <button class="ui-button primary" type="submit">{@label}</button>
      </div>
    </form>
    """
  end

  # Emisar --------------------------------------------------------------------

  attr(:view, :map, required: true)
  attr(:confirm, :any, default: nil)
  attr(:edit_ref, :string, default: nil)

  defp emisar(assigns) do
    snapshot = assigns.view.snapshot

    assigns =
      assign(assigns,
        accounts: snapshot.emisar_connections,
        line: Integrations.emisar(assigns.view),
        snapshot: snapshot
      )

    ~H"""
    <.connection state={@line.state} text={@line.text}>
      <:facts :if={@line.facts != [] or @line.unassigned > 0}>
        {facts(@line.facts)}{if @line.facts != [] and @line.unassigned > 0, do: " · "}<.link
          :if={@line.unassigned > 0}
          navigate="/environments"
        >{Integrations.unassigned(@line.unassigned)}</.link>
      </:facts>
    </.connection>

    <section :if={@accounts == []} class="settings-section" aria-label="Connect an account">
      <Kit.section_head
        title="Connect an account"
        lede="Create an API token in your Emisar account and paste it here. Ryker starts watching it for approval decisions at once, and the first account serves every environment that has none."
      />
      <.emisar_form />
    </section>

    <section :if={@accounts != []} class="settings-section" aria-label="Accounts">
      <Kit.section_head
        title="Accounts"
        lede="Pause an account to stop sending it new work. Its history stays."
      >
        <:actions :if={is_nil(@edit_ref)}>
          <button
            type="button"
            class="ui-button secondary"
            phx-click="show-emisar-form"
            phx-value-ref="new"
          ><Components.icon name={:plus} />Add account</button>
        </:actions>
      </Kit.section_head>
      <Kit.entity_list label="Emisar accounts">
        <Kit.entity_row
          :for={account <- @accounts}
          name={account.display_name}
          state={if account.enabled_for_new_work, do: {:on, "Active"}, else: {:off, "Paused"}}
          meta={[
            account.account_label,
            used_by(@snapshot, account),
            if(account.monitoring_enabled,
              do: "Watching for approval decisions",
              else: "Not watching for approval decisions"
            )
          ]}
        >
          <:actions :if={@edit_ref != account.ref}>
            <button
              type="button"
              class="ui-button secondary"
              phx-click={if account.enabled_for_new_work, do: "disable-emisar", else: "enable-emisar"}
              phx-value-ref={account.ref}
            >{if account.enabled_for_new_work, do: "Pause", else: "Resume"}</button>
            <button
              type="button"
              class="ui-button secondary"
              phx-click="show-emisar-form"
              phx-value-ref={account.ref}
            >Manage</button>
          </:actions>
          <:details>
            <details class="settings-row-details">
              <summary>Details</summary>
              <dl>
                <div>
                  <dt>Account</dt>
                  <dd><code>{account.account_ref}</code></dd>
                </div>
                <div>
                  <dt>Address</dt>
                  <dd><code>{account.rpc_url}</code></dd>
                </div>
              </dl>
            </details>
            <.emisar_manage
              :if={@edit_ref == account.ref}
              account={account}
              confirm={@confirm}
            />
          </:details>
        </Kit.entity_row>
      </Kit.entity_list>
      <div :if={@edit_ref == "new"} class="settings-editor">
        <h3 class="settings-editor-heading">Add an account</h3>
        <.emisar_form />
        <button type="button" class="ui-button secondary" phx-click="hide-emisar-form">
          Cancel
        </button>
      </div>
    </section>
    """
  end

  attr(:account, :map, required: true)
  attr(:confirm, :any, default: nil)

  defp emisar_manage(assigns) do
    ~H"""
    <div class="settings-manage">
      <form phx-submit="rename-emisar" class="settings-inline-form">
        <input type="hidden" name="connection[ref]" value={@account.ref} />
        <div class="settings-field">
          <label for={"emisar-name-#{@account.ref}"}>Name</label>
          <input
            id={"emisar-name-#{@account.ref}"}
            type="text"
            name="connection[display_name]"
            value={@account.display_name}
            required
          />
        </div>
        <button class="ui-button secondary" type="submit">Save name</button>
      </form>
      <form phx-submit="rotate-emisar" autocomplete="off" class="settings-inline-form">
        <input type="hidden" name="connection[ref]" value={@account.ref} />
        <div class="settings-field">
          <label for={"emisar-token-#{@account.ref}"}>New API token</label>
          <p class="settings-help">Ryker checks it belongs to the same account before using it.</p>
          <input
            id={"emisar-token-#{@account.ref}"}
            type="password"
            name="connection[token]"
            required
          />
        </div>
        <button class="ui-button secondary" type="submit">Replace token</button>
      </form>
      <div class="settings-manage-line">
        <p>
          <strong>Approval monitoring</strong>
          {if @account.monitoring_enabled,
            do:
              "Ryker watches this account for approval decisions. If you turn this off, tasks waiting on its approvals stop and show on Failures.",
            else:
              "Ryker is not watching this account, so tasks waiting on its approvals are stopped. They show on Failures until you turn this on."}
        </p>
        <button
          type="button"
          class="ui-button secondary"
          phx-click={
            if @account.monitoring_enabled,
              do: "disable-emisar-monitoring",
              else: "enable-emisar-monitoring"
          }
          phx-value-ref={@account.ref}
        >{if @account.monitoring_enabled, do: "Turn off", else: "Turn on"}</button>
      </div>
      <div :if={@confirm != {"delete-emisar", @account.ref}} class="settings-manage-line">
        <p>
          <strong>Remove account</strong>
          The environments that use it are left without an Emisar account. An account that
          tasks or approvals still name cannot be removed; pause it instead.
        </p>
        <button
          type="button"
          class="ui-button quiet"
          phx-click="confirm-settings-action"
          phx-value-action="delete-emisar"
          phx-value-ref={@account.ref}
        >Remove account</button>
      </div>
      <.confirmation
        :if={@confirm == {"delete-emisar", @account.ref}}
        title={"Remove #{@account.display_name}?"}
        text="Ryker stops sending it work, the environments that use it are left without an Emisar account and its token is deleted."
        label="Remove account"
        phx-click="delete-emisar"
        phx-value-ref={@account.ref}
      />
      <div class="settings-actions">
        <button type="button" class="ui-button secondary" phx-click="hide-emisar-form">
          Close
        </button>
      </div>
    </div>
    """
  end

  defp emisar_form(assigns) do
    ~H"""
    <form phx-submit="connect-emisar" autocomplete="off" class="settings-form">
      <div class="settings-field">
        <label for="emisar-connect-token">API token</label>
        <p class="settings-help">Ryker checks the account, then stores the token encrypted.</p>
        <input id="emisar-connect-token" type="password" name="connection[token]" required />
      </div>
      <div class="settings-field">
        <label for="emisar-connect-url">Emisar address</label>
        <p class="settings-help">Keep this unless your Emisar is self-hosted.</p>
        <input
          id="emisar-connect-url"
          type="url"
          name="connection[rpc_url]"
          value="https://emisar.dev/api/mcp/rpc"
          required
        />
      </div>
      <div class="settings-actions">
        <button class="ui-button primary" type="submit">Connect account</button>
      </div>
    </form>
    """
  end

  # Webhooks ------------------------------------------------------------------

  attr(:view, :map, required: true)
  attr(:commands, :map, required: true)
  attr(:confirm, :any, default: nil)
  attr(:editing, :boolean, default: false)

  defp webhooks(assigns) do
    credentials = Enum.filter(assigns.view.credentials, &(&1.kind == :webhook))

    assigns =
      assign(assigns,
        credentials: credentials,
        users: credential_users(assigns.view.snapshot.webhook_sources)
      )

    ~H"""
    <section class="settings-section" aria-label="Signing credentials">
      <Kit.section_head
        title="Signing credentials"
        lede="Senders sign each request with a shared secret, so Ryker knows it is theirs."
      >
        <:actions :if={@credentials != [] and !@editing}>
          <button type="button" class="ui-button secondary" phx-click="show-webhook-credential-form">
            <Components.icon name={:plus} />Add signing credential
          </button>
        </:actions>
      </Kit.section_head>
      <Kit.entity_list :if={@credentials != []} label="Signing credentials">
        <Kit.entity_row
          :for={credential <- @credentials}
          name={credential.name}
          state={credential_state(credential)}
          meta={[credential_use(@users, credential.name)]}
        >
          <:actions :if={
            Map.get(@users, credential.name, []) == [] and
              @confirm != {"delete-webhook-credential", credential.name}
          }>
            <button
              type="button"
              class="ui-button quiet"
              phx-click="confirm-settings-action"
              phx-value-action="delete-webhook-credential"
              phx-value-ref={credential.name}
            >Delete</button>
          </:actions>
          <:details>
            <.confirmation
              :if={@confirm == {"delete-webhook-credential", credential.name}}
              title={"Delete #{credential.name}?"}
              text="Its secret is deleted. A sender still using it can no longer deliver events."
              label="Delete credential"
              phx-click="delete-webhook-credential"
              phx-value-name={credential.name}
            />
          </:details>
        </Kit.entity_row>
      </Kit.entity_list>
      <div :if={@credentials == [] or @editing} class="settings-editor">
        <h3 class="settings-editor-heading">Add a signing credential</h3>
        <form phx-submit="create-webhook-credential" autocomplete="off" class="settings-form">
          <div class="settings-field">
            <label for="webhook-credential-name">Name</label>
            <p class="settings-help">
              Lowercase letters, numbers, dots, dashes and colons, such as grafana.
            </p>
            <input
              id="webhook-credential-name"
              type="text"
              name="credential[name]"
              pattern="[a-z0-9][a-z0-9_.:-]{0,127}"
              required
            />
          </div>
          <div class="settings-field">
            <label for="webhook-credential-secret">Existing secret (optional)</label>
            <p class="settings-help">
              Leave empty and Ryker creates a strong one and shows it to you once.
            </p>
            <input id="webhook-credential-secret" type="password" name="credential[secret]" />
          </div>
          <div class="settings-actions">
            <button class="ui-button primary" type="submit">Create credential</button>
            <button
              :if={@credentials != []}
              type="button"
              class="ui-button secondary"
              phx-click="hide-webhook-credential-form"
            >Cancel</button>
          </div>
        </form>
      </div>
    </section>

    <.live_component
      module={SettingsEditor}
      id="settings-webhooks"
      section={section!(:webhooks)}
      view={@view}
      commands={@commands}
    />

    <.live_component
      module={WebhookPreview}
      id="webhook-preview"
      view={@view}
      check={@commands.preview_webhook}
    />
    """
  end

  # Shared parts --------------------------------------------------------------

  attr(:state, :any, required: true)
  attr(:text, :string, default: nil)
  slot(:facts, doc: "What is connected, on one line under the sentence")
  slot(:action)

  # The page's connection: a dot and a word, what it means when that is not
  # obvious, what is connected, and the one action that fits it.
  defp connection(assigns) do
    ~H"""
    <div class="settings-connection">
      <div class="settings-connection-body">
        <Kit.state tone={elem(@state, 0)} word={elem(@state, 1)} />
        <p :if={@text}>{@text}</p>
        <p :if={@facts != []}>{render_slot(@facts)}</p>
      </div>
      <div :if={@action != []} class="settings-connection-action">{render_slot(@action)}</div>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:text, :string, required: true)
  attr(:label, :string, required: true)
  attr(:rest, :global)

  @doc """
  The second step of anything that disconnects or deletes. The button that
  opened it only asked; this one does it, and Cancel closes the question.
  """
  def confirmation(assigns) do
    ~H"""
    <div
      class="settings-confirm"
      role="group"
      aria-label={@title}
      tabindex="-1"
      phx-mounted={JS.focus()}
    >
      <p><strong>{@title}</strong> {@text}</p>
      <div class="settings-confirm-actions">
        <button type="button" class="ui-button danger" {@rest}>{@label}</button>
        <button type="button" class="ui-button secondary" phx-click="cancel-settings-action">
          Cancel
        </button>
      </div>
    </div>
    """
  end

  # State lines ---------------------------------------------------------------

  defp credential_state(%{verification_status: :verified}), do: {:on, "Ready"}
  defp credential_state(_credential), do: {:warn, "Not verified"}

  defp credential_users(sources) do
    Enum.group_by(sources, & &1.secret_name, & &1.name)
  end

  defp credential_use(users, name) do
    case Map.get(users, name, []) do
      [] -> "Not used yet"
      sources -> "Used by " <> Enum.join(sources, ", ")
    end
  end

  # Helpers -------------------------------------------------------------------

  defp facts(facts), do: Enum.join(facts, " · ")

  # Which environments send their approvals to an account.
  defp used_by(snapshot, account) do
    case Environments.ordered(snapshot.environments)
         |> Enum.filter(&(&1.emisar_connection_ref == account.ref)) do
      [] ->
        "No environment uses it yet"

      environments ->
        "Used by " <> Environments.sentence(Enum.map(environments, & &1.display_name))
    end
  end

  # "Verify GitHub App" -> "verify-github-app": element ids never carry spaces.
  defp key(label), do: label |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  defp operator_names(%{operators: []}), do: []

  defp operator_names(%{operators: operators, workspace_ref: workspace})
       when is_binary(workspace),
       do: Enum.map(operators, &SlackNames.name(workspace, &1))

  defp operator_names(%{operators: operators}), do: operators

  defp people_text([]), do: "Nobody yet. Choose at least one person who can manage Ryker."
  defp people_text(names), do: Enum.join(names, ", ")

  defp repository_count(0), do: "No repositories yet."
  defp repository_count(count), do: Integrations.count(count, "repository") <> " added."

  defp editors(:model), do: [:model]
  defp editors(:retention), do: [:retention]
  defp editors(:pricing), do: [:pricing]
  defp editors(:system), do: [:work, :policies]
  defp editors(_section), do: []

  defp section!(key) do
    {:ok, section} = SettingsSections.fetch(key)
    section
  end

  # Titles are the sidebar's names; the sentence under each says what the
  # page is for. Setup's sentence follows how far setup is.
  defp page(:setup, view), do: %{title: "Set up Ryker", description: SetupPage.description(view)}
  defp page(section, _view), do: page(section)

  defp page(:setup),
    do: %{title: "Set up Ryker", description: "Connect Ryker to Slack and your code."}

  defp page(:environments),
    do: %{
      title: "Environments",
      description:
        "Where Ryker works: the repositories and integrations each channel or conversation uses."
    }

  defp page(:integrations),
    do: %{
      title: "Integrations",
      description:
        "The services Ryker works through: Slack to talk with your team, GitHub for your code, " <>
          "Emisar to act on running systems and webhooks for alerts from other tools."
    }

  defp page(:slack),
    do: %{
      title: "Slack",
      description: "Ryker reads and replies in the Slack channels it is invited to."
    }

  defp page(:github),
    do: %{
      title: "GitHub",
      description: "Ryker works in your repositories through a GitHub App."
    }

  defp page(:emisar),
    do: %{
      title: "Emisar",
      description:
        "Emisar lets Ryker act on your running systems. A person approves each risky action in Emisar before it runs; Ryker never approves on anyone's behalf."
    }

  defp page(:webhooks),
    do: %{
      title: "Webhooks",
      description: "Let other systems, like Grafana, send events to Ryker."
    }

  defp page(:model),
    do: %{
      title: "Models",
      description:
        "The model and reasoning effort for each kind of work. A change reaches new work within seconds."
    }

  defp page(:retention),
    do: %{
      title: "Data retention",
      description: "How many days Ryker keeps each kind of data before deleting it."
    }

  defp page(:pricing),
    do: %{
      title: "Model prices",
      description:
        "What each model costs per million tokens. Ryker uses these to estimate cost when the provider does not report it."
    }

  defp page(:system),
    do: %{
      title: "Advanced",
      description:
        "Worker placement, execution policies and what the running system loaded. The bundled worker sets these up for you."
    }
end
