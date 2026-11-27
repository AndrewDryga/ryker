defmodule Ryker.ControlPlane.SettingsPage do
  @moduledoc """
  The pages that connect and configure Ryker: onboarding at /setup (see
  `SetupPage`), the environments Ryker works in (see `EnvironmentsPage`), the
  Integrations overview and a page per integration (Slack, GitHub, Emisar,
  Webhooks), and the Settings overview and a page per installation setting
  (Models, Data retention, Model prices, Weekly report, Access, Advanced). The sidebar is the
  only menu; each page has one title, one sentence and its parts in Kit section
  cards, the overviews and one-part pages included.

  Adding or editing one thing in a list, an environment, a price, an Emisar
  account, a signing credential or a webhook source, happens on a page of its
  own (`form`): its title says what it adds or edits, a link above it goes
  back to the list, and the form sits in one `Kit.form_card/1`.

  A connection reads as a dot and a word, why when it is not working, and the
  one action that fits it, in the words every page uses (see
  `Integrations`). Anything that disconnects or deletes asks first in
  `Kit.confirm_modal/1` and says, in words, what it will do; the LiveView runs
  it only after that question was asked.
  """
  use Phoenix.Component
  alias Ryker.BundledCoop
  alias Ryker.ControlPlane.{Components, Environments, EnvironmentsPage, Integrations, Kit, Paths}
  alias Ryker.ControlPlane.{RunningSystem, SettingsEditor, SettingsRows, SettingsSections}
  alias Ryker.ControlPlane.{SetupPage, ShortTime, WorkerConnect}
  alias Ryker.ControlPlane.{SlackMarkdown, WebhookPreview}
  alias Ryker.ConversationRef
  alias Ryker.GitHub
  alias Ryker.Settings
  alias Ryker.Slack
  alias Ryker.Wording
  alias Ryker.Work

  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  # The lists whose rows each have a page of their own, the settings editor's form.
  @item_forms [:pricing, :webhooks, :model_presets]

  @doc "The title of one page: the name it has in the sidebar, or Set up Ryker."
  @spec title(atom()) :: String.t()
  def title(section), do: page(section).title

  @doc """
  The title of a page, a page of one form included: what it adds, or
  "Edit" and the name of what it edits, read from the settings `view`.
  """
  @spec title(atom(), term(), {:ok, map()} | {:error, term()}) :: String.t()
  def title(section, nil, _view), do: title(section)
  def title(section, form, {:ok, view}), do: heading(section, form, view).title
  def title(section, _form, _unavailable), do: title(section)

  attr(:view, :any, required: true)
  attr(:commands, :map, required: true)
  attr(:section, :atom, required: true)
  attr(:model_usage, :map, default: nil)
  attr(:account_limits, :map, default: nil)
  attr(:running_system, :map, default: nil)
  attr(:error, :string, default: nil)
  attr(:notice, :string, default: nil)
  attr(:failure, :string, default: nil)
  attr(:reveal, :map, default: nil)
  attr(:github_feedback, :map, default: nil)

  attr(:github_webhook_secret, :string,
    default: nil,
    doc: "The webhook secret the GitHub page shows until the App is connected"
  )

  attr(:worker_connect, :map,
    default: nil,
    doc: "Advanced's steps to connect a worker while none has: connection, token and error"
  )

  attr(:emisar_form_feedback, :map, default: %{})
  attr(:confirm, :any, default: nil, doc: "{action, ref} of the question now open, if any")

  attr(:slack_people, :any,
    default: nil,
    doc: "Choose people: nil, :loading while Slack answers, or members, search and choice"
  )

  attr(:form, :any,
    default: nil,
    doc: "{kind, key}: the one thing a page of one form adds (key nil) or edits"
  )

  attr(:params, :map, default: %{}, doc: "The page's query, for pages that search")

  attr(:preview, :any,
    default: nil,
    doc: "The weekly report a send now would post (`Ryker.WeeklyReport.preview/1`), when asked"
  )

  attr(:preview_sent, :any,
    default: nil,
    doc: "What became of the preview last sent to the channel: {:ok | :error, words}"
  )

  attr(:access, :map,
    default: nil,
    doc: "On Access: the browsers signed in and the invites nobody has used yet"
  )

  attr(:viewer, :map, default: nil, doc: "The person signed in, to tell their own browser apart")

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
        <button
          type="button"
          class="ui-button primary"
          phx-click="initialize-settings"
          phx-disable-with="Starting…"
        >
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
        <button
          type="button"
          class="ui-button secondary"
          phx-click="refresh"
          phx-disable-with="Trying again…"
        >Try again</button>
      </section>
    </div>
    """
  end

  def render(%{view: {:ok, view}} = assigns) do
    assigns =
      assigns
      |> assign(:view, view)
      |> assign(:page, heading(assigns.section, assigns.form, view))
      |> assign(:notices, if(assigns.section == :model, do: model_notices(view), else: []))

    ~H"""
    <div class="settings-page" id="settings-page" phx-hook="SettingsDraft">
      <Components.page_header
        title={@page.title}
        description={@page.description}
        back={@page[:back]}
        navigate
        progress={if @view.applying and is_nil(@notice), do: "Applying…"}
      >
        <:action :if={@section == :skills and is_nil(@form)}>
          <.link navigate="/skills/install/github" class="ui-button primary"><Components.icon name={
            :plus
          } />Install skill</.link>
        </:action>
        <:action :if={@section == :environments and is_nil(@form)}>
          <EnvironmentsPage.add />
        </:action>
        <:action :if={@section == :pricing and is_nil(@form)}>
          <.link patch="/settings/prices/new" class="ui-button primary">
            <Components.icon name={:plus} />Add price
          </.link>
        </:action>
        <%!-- A file download, so a plain link: the browser saves what the
        router streams and the page stays where it is. --%>
        <:action :if={@section == :retention and @view.snapshot.retention.routing_examples_enabled}>
          <a
            id="download-routing-examples"
            href="/settings/retention/routing-examples.jsonl"
            class="ui-button secondary"
            download
          >
            <Components.icon name={:arrow_down} />Download routing examples
          </a>
        </:action>
        <:action :if={@section == :retention and @view.snapshot.retention.work_examples_enabled}>
          <a
            id="download-work-examples"
            href="/settings/retention/work-examples.jsonl"
            class="ui-button secondary"
            download
          >
            <Components.icon name={:arrow_down} />Download work examples
          </a>
        </:action>
      </Components.page_header>

      <Components.form_feedback :if={@error} message={@error} tone={:error} class="page-feedback" />
      <Components.form_feedback
        :if={@failure}
        message={@failure}
        tone={:error}
        class="page-feedback"
      />
      <%!-- A save is confirmed once: while the running Ryker picks it up, the same line says so
      (Andrew, 2026-10-01: "confirmation blocks are annoying … why there is always two of them"). --%>
      <Components.form_feedback
        :if={@notice}
        message={if @view.applying, do: @notice <> " Applying it now…", else: @notice}
        tone={:success}
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

      <.form_page
        :if={@form && @section != :skills}
        emisar_form_feedback={@emisar_form_feedback}
        section={@section}
        form={@form}
        view={@view}
        commands={@commands}
        confirm={@confirm}
        account_limits={@account_limits}
      />
      <.live_component
        :if={match?({:install, _}, @form)}
        module={Ryker.ControlPlane.SkillImport}
        id={"install-skill-" <> elem(@form, 1)}
        method={elem(@form, 1)}
        view={@view}
        commands={@commands}
      />
      <.live_component
        :if={match?({:skill, _}, @form)}
        module={Ryker.ControlPlane.SkillPage}
        id={"skill-" <> elem(@form, 1)}
        name={elem(@form, 1)}
        view={@view}
        commands={@commands}
      />
      <%= if is_nil(@form) do %>
        <SetupPage.render :if={@section == :setup} view={@view} params={@params} />
        <EnvironmentsPage.render :if={@section == :environments} view={@view} params={@params} />
        <Ryker.ControlPlane.SkillPage.catalog :if={@section == :skills} view={@view} />
        <.integrations :if={@section == :integrations} view={@view} />
        <.settings_overview :if={@section == :settings} view={@view} />
        <.slack
          :if={@section == :slack}
          view={@view}
          commands={@commands}
          confirm={@confirm}
          slack_people={@slack_people}
        />
        <.github
          :if={@section == :github}
          view={@view}
          commands={@commands}
          confirm={@confirm}
          feedback={@github_feedback}
          webhook_secret={@github_webhook_secret}
        />
        <.emisar :if={@section == :emisar} view={@view} />
        <.webhooks
          :if={@section == :webhooks}
          view={@view}
          commands={@commands}
          confirm={@confirm}
        />
        <div :if={@notices != []} id="model-notices">
          <p :for={notice <- @notices} class="settings-notice">
            {notice.text}
            <.link :if={notice[:href]} navigate={notice.href}>{notice.link}</.link>
          </p>
        </div>
        <p :if={@section == :model and @model_usage} class="settings-model-usage-note">
          Usage below shows live runs with recorded usage, including retries and previous model choices.
          <.link navigate="/usage?window=30d">Usage &amp; cost</.link>
        </p>
        <p
          :if={(@section == :model and @model_usage) && @model_usage.unattributed > 0}
          class="settings-model-usage-note"
        >
          {Wording.count(@model_usage.unattributed, "run")} could not be assigned to a category from retained history.
        </p>
        <WorkerConnect.card
          :if={@section == :system and @worker_connect}
          connection={@worker_connect.connection}
          accounts={@view.snapshot.work.model_accounts}
          token={@worker_connect.token}
          error={@worker_connect.error}
        />
        <.live_component
          :for={key <- editors(@section)}
          module={SettingsEditor}
          id={"settings-#{key}"}
          section={section!(key)}
          view={@view}
          commands={@commands}
          model_usage={@model_usage}
          account_limits={@account_limits}
          show_header={titled?(@section)}
          paths={paths(key)}
        />
        <div :if={@section == :system and @running_system} class="settings-running">
          <RunningSystem.card {@running_system} />
        </div>
        <.access :if={@section == :access and @access} access={@access} viewer={@viewer} />
        <.weekly_preview
          :if={@section == :report}
          preview={@preview}
          channel={report_channel(@view)}
          sent={@preview_sent}
        />
      <% end %>
    </div>
    """
  end

  # Access ---------------------------------------------------------------------

  attr(:access, :map, required: true)
  attr(:viewer, :map, default: nil)

  # Signing in from Slack, inviting someone, and the browsers signed in now (Andrew,
  # 2026-10-13: Ryker signs people in itself). An invite's link is shown once, above the page's
  # cards, the way a secret is; a list's buttons act on their own row.
  defp access(assigns) do
    assigns = assign(assigns, :now, DateTime.utc_now())

    ~H"""
    <Kit.section_card
      id="access-slack"
      title="Sign in from Slack"
      lede="Ryker's operators send Ryker /ryker sign-in, or open Ryker's App Home and press Open the console. Ryker replies with a link that signs them in on that browser."
    >
      <p class="settings-lede">
        The operators are the people chosen on <.link navigate="/integrations/slack">Slack</.link>,
        and the workspace's admins unless that page turns them off.
      </p>
    </Kit.section_card>

    <Kit.section_card
      id="access-invite"
      title="Invite someone"
      lede="For someone who isn't one of Ryker's operators in Slack. Their link signs them in once, within 7 days, under the name you give."
    >
      <form id="invite-form" class="settings-form access-invite-form" phx-submit="invite-person">
        <div class="settings-field">
          <label for="invite-name">Name</label>
          <input
            id="invite-name"
            name="invite[name]"
            type="text"
            maxlength="120"
            autocomplete="off"
            placeholder="Dana from Acme"
            required
          />
        </div>
        <div>
          <button type="submit" class="ui-button primary" phx-disable-with="Creating…">
            Create invite link
          </button>
        </div>
      </form>
      <Kit.entity_list :if={@access.invites != []} id="open-invites" label="Invites not used yet">
        <Kit.entity_row
          :for={invite <- @access.invites}
          id={"invite-#{invite.id}"}
          name={invite.person_name}
          text={"Works until " <> ShortTime.stamp(invite.expires_at, @now)}
        >
          <:actions>
            <button
              type="button"
              class="ui-button quiet"
              phx-click="withdraw-invite"
              phx-value-id={invite.id}
              phx-disable-with="Withdrawing…"
            >
              Withdraw
            </button>
          </:actions>
        </Kit.entity_row>
      </Kit.entity_list>
    </Kit.section_card>

    <Kit.section_card
      id="access-sessions"
      title="Signed in"
      lede="Browsers a link signed in. Each stays signed in until 30 days after it was last used."
    >
      <Kit.empty
        :if={@access.sessions == []}
        icon={:smile}
        title="Nobody is signed in with a link"
        text="People who sign in from Slack or with an invite show here."
      />
      <Kit.entity_list :if={@access.sessions != []} id="signed-in" label="Signed-in browsers">
        <Kit.entity_row
          :for={session <- @access.sessions}
          id={"session-#{session.id}"}
          name={session.person_name}
          text={signed_in_with(session.person_via)}
          meta={[
            "Browser #{String.slice(session.id, -8, 8)}",
            "Signed in #{ShortTime.stamp(session.inserted_at, @now)}",
            used(session, @viewer, @now)
          ]}
        >
          <:actions>
            <button
              type="button"
              class="ui-button quiet"
              phx-click="end-session"
              phx-value-id={session.id}
              phx-disable-with="Signing out…"
            >
              Sign out
            </button>
          </:actions>
        </Kit.entity_row>
      </Kit.entity_list>
    </Kit.section_card>
    """
  end

  defp signed_in_with(:slack_operator), do: "Signed in with a link from Slack"
  defp signed_in_with(:invite), do: "Signed in with an invite"
  defp signed_in_with(:owner), do: "Signed in with the host's link"

  defp used(session, %{session_id: id}, _now) when id == session.id, do: "This browser"
  defp used(session, _viewer, now), do: "Last used " <> ShortTime.text(session.last_seen_at, now)

  # Weekly report preview ------------------------------------------------------

  attr(:preview, :any, required: true)
  attr(:channel, :string, default: nil, doc: "The report's channel by name, when it can post")
  attr(:sent, :any, default: nil)

  # What a report sent now would say, in the words the channel would get,
  # rendered as the page renders any Slack message. Asking for it posts
  # nothing and records nothing; it is a link, so it reads the same on a
  # reload. Sending it posts it to the channel now, titled as a preview
  # (Andrew, 2026-09-28: "why not to send real report to configured channel
  # as a preview?").
  defp weekly_preview(assigns) do
    ~H"""
    <Kit.section_card
      id="weekly-report-preview"
      title="Preview"
      lede="What a report sent now would say, from the seven days before now. Nothing is posted until you send it."
    >
      <:actions>
        <.link
          :if={is_nil(@preview)}
          id="preview-weekly-report"
          patch="/settings/report?preview=week"
          class="ui-button secondary"
        >
          Preview this week's report
        </.link>
        <button
          :if={@preview && @channel}
          id="send-weekly-report-preview"
          type="button"
          class="ui-button secondary"
          phx-click="send-weekly-report-preview"
          phx-disable-with="Sending…"
        >
          Send to {@channel}
        </button>
        <.link :if={@preview} patch="/settings/report" class="ui-button quiet">
          Hide the preview
        </.link>
      </:actions>
      <Components.form_feedback
        :if={@sent}
        id="weekly-report-sent"
        message={elem(@sent, 1)}
        tone={if(elem(@sent, 0) == :ok, do: :success, else: :error)}
      />
      <p :if={@preview && is_nil(@channel)} class="settings-lede">
        Choose the report's channel above to send a preview there.
      </p>
      <div :if={@preview} id="weekly-report-text" class="markdown-preview weekly-report-preview">
        {SlackMarkdown.html(@preview.text)}
      </div>
    </Kit.section_card>
    """
  end

  # The report's channel by name, while Slack is connected: where a preview
  # would go.
  defp report_channel(%{snapshot: %{report: %{channel_ref: channel}, slack: slack}})
       when is_binary(channel) do
    if slack.enabled and is_binary(slack.workspace_ref),
      do: Slack.destination_name(ConversationRef.slack(slack.workspace_ref, channel))
  end

  defp report_channel(_view), do: nil

  # Pages of one form ------------------------------------------------------------

  attr(:section, :atom, required: true)
  attr(:emisar_form_feedback, :map, required: true)
  attr(:form, :any, required: true)
  attr(:view, :map, required: true)
  attr(:commands, :map, required: true)
  attr(:confirm, :any, default: nil)
  attr(:account_limits, :map, default: nil, doc: "What each account's provider last reported")

  # The one thing a page of one form adds or edits, in its card; a row that is
  # gone says so and leads back to its list instead of showing an empty form.
  defp form_page(%{form: {:environment, ref}} = assigns) do
    assigns = assign(assigns, :ref, ref)

    ~H"""
    <EnvironmentsPage.form view={@view} ref={@ref} confirm={@confirm} commands={@commands} />
    """
  end

  defp form_page(%{form: {key, item}} = assigns) when key in @item_forms do
    collection = section!(key)

    assigns =
      assign(assigns,
        key: key,
        item: item,
        collection: collection,
        found:
          is_nil(item) or
            Enum.any?(
              SettingsSections.items(collection, assigns.view),
              &(to_string(Map.get(&1, collection.item_key)) == item)
            )
      )

    ~H"""
    <.live_component
      :if={@found}
      module={SettingsEditor}
      id={"settings-#{@key}"}
      section={@collection}
      view={@view}
      commands={@commands}
      show_header={false}
      frame={:none}
      form={{:form, @item}}
      label={heading(@section, @form, @view).title}
      paths={paths(@key)}
      account_limits={@account_limits}
    />
    <.gone
      :if={!@found}
      noun={Map.get(@collection, :item_label, "entry")}
      back={paths(@key).list}
    />
    """
  end

  defp form_page(%{form: {:emisar, nil}} = assigns) do
    ~H"""
    <Kit.form_card label="Connect an Emisar account">
      <.emisar_form />
    </Kit.form_card>
    """
  end

  defp form_page(%{form: {:emisar, ref}} = assigns) do
    assigns =
      assign(
        assigns,
        :account,
        Enum.find(assigns.view.snapshot.emisar_connections, &(&1.ref == ref))
      )

    ~H"""
    <.emisar_manage
      :if={@account}
      account={@account}
      view={@view}
      confirm={@confirm}
      feedback={@emisar_form_feedback}
    />
    <.gone :if={!@account} noun="Emisar account" back="/integrations/emisar" />
    """
  end

  defp form_page(%{form: {:webhook_credential, nil}} = assigns) do
    ~H"""
    <Kit.form_card label="Add a signing credential">
      <.webhook_credential_form />
    </Kit.form_card>
    """
  end

  attr(:noun, :string, required: true)
  attr(:back, :string, required: true)

  # An address for something that is no longer there.
  defp gone(assigns) do
    ~H"""
    <Kit.empty
      id="form-not-found"
      icon={:search}
      title={"That #{@noun} was not found"}
      text="It may have been removed. Go back to the list to see what is there now."
    >
      <.link patch={@back} class="ui-button secondary">Back to the list</.link>
    </Kit.empty>
    """
  end

  # Where each list section of these pages lives: its list, and the address its
  # rows' forms are under (`/new` adds one, `/<key>/edit` edits one).
  defp paths(:pricing), do: %{list: "/settings/prices", items: "/settings/prices"}

  defp paths(:model_presets),
    do: %{list: "/settings/models", items: "/settings/models/presets"}

  defp paths(:webhooks),
    do: %{list: "/integrations/webhooks", items: "/integrations/webhooks/sources"}

  defp paths(_singleton), do: nil

  # Integrations overview ----------------------------------------------------

  attr(:view, :map, required: true)

  # Every service Ryker works through, whatever its state: its state, what it
  # gives Ryker, why it is not working or what is connected, and the one
  # action that fits. The list is the page's one card, as every settings
  # page shows its parts.
  defp integrations(assigns) do
    assigns = assign(assigns, :rows, Integrations.overview(assigns.view))

    ~H"""
    <Kit.section_card label="Integrations">
      <Kit.entity_list label="Integrations" class="integrations-list">
        <Kit.entity_row
          :for={row <- @rows}
          id={"integration-#{row.key}"}
          name={row.name}
          href={row.href}
          link_row={true}
          state={row.state}
          tag={row.tag}
          text={row.text}
          meta={row.meta}
        />
      </Kit.entity_list>
    </Kit.section_card>
    """
  end

  # Settings overview ---------------------------------------------------------

  attr(:view, :map, required: true)

  # Every installation setting in the rows the Integrations overview uses,
  # in its card: what its page sets and what it is set to now. A setting has
  # no connection to repair and so no next step of its own; the whole row
  # opens its page.
  defp settings_overview(assigns) do
    assigns = assign(assigns, :rows, settings_rows(assigns.view))

    ~H"""
    <Kit.section_card label="Settings">
      <Kit.entity_list label="Settings" class="settings-list">
        <Kit.entity_row
          :for={row <- @rows}
          id={"setting-#{row.key}"}
          name={row.name}
          href={row.href}
          link_row={true}
          text={row.text}
          meta={row.meta}
        />
      </Kit.entity_list>
    </Kit.section_card>
    """
  end

  @settings_pages [
    model: "/settings/models",
    retention: "/settings/retention",
    pricing: "/settings/prices",
    report: "/settings/report",
    access: "/settings/access",
    system: "/settings/advanced"
  ]

  defp settings_rows(view) do
    for {section, href} <- @settings_pages do
      %{
        key: section,
        name: title(section),
        href: href,
        text: sets(section),
        meta: [set_now(section, view)]
      }
    end
  end

  defp sets(:model),
    do: "The model, reasoning effort and account for each kind of work, and its fallbacks."

  defp sets(:retention), do: "How many days Ryker keeps each kind of data before deleting it."

  defp sets(:pricing),
    do: "What each model costs, for estimating cost when the provider does not report it."

  defp sets(:report),
    do: "Whether Ryker posts a weekly report of how its week went, where and when."

  defp sets(:system), do: "Where work runs and what each kind of work may do."

  defp sets(:access),
    do: "Who can open this console: Ryker's operators from Slack, and the people they invite."

  # The first model of each kind of work, then which kinds have fallbacks.
  defp set_now(:model, view) do
    lists =
      Enum.map(
        SettingsSections.ladder_fields(),
        &{&1.label, Map.get(view.snapshot.work, &1.name)}
      )

    models =
      lists
      |> Enum.flat_map(fn {_label, models} -> Enum.take(models || [], 1) end)
      |> Enum.map(&(Work.target_parts(&1) || %{})[:model])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    fallbacks = for {label, [_first, _fallback | _more]} <- lists, do: label

    cond do
      models == [] ->
        nil

      fallbacks == [] ->
        "Uses " <> Wording.list(models)

      true ->
        "Uses #{Wording.list(models)}, with fallbacks for #{Wording.list(fallbacks)}"
    end
  end

  defp set_now(:report, %{snapshot: %{report: report, slack: slack}}) do
    if report.weekly_self_report_enabled do
      "Posts #{Enum.at(@weekdays, report.weekday - 1)}s at " <>
        "#{Calendar.strftime(report.local_time, "%H:%M")} #{report.timezone}" <>
        report_channel(slack, report)
    else
      "Off"
    end
  end

  # Routing examples are a copy kept only while someone keeps them on, so
  # they are said apart from the limits every installation has.
  defp set_now(:retention, view) do
    retention = view.snapshot.retention

    days =
      Settings.retention_defaults()
      |> Map.keys()
      |> Kernel.--([
        :routing_examples_enabled,
        :routing_examples_seconds,
        :work_examples_enabled,
        :work_examples_seconds
      ])
      |> Enum.map(&Map.get(retention, &1))
      |> Enum.filter(&is_integer/1)
      |> Enum.map(&div(&1, 86_400))

    kept =
      case Enum.min_max(days, fn -> nil end) do
        nil -> nil
        {same, same} -> "Keeps every kind of data #{days(same)}"
        {shortest, longest} -> "Keeps each kind of data #{shortest} to #{days(longest)}"
      end

    examples =
      for {kind, enabled, seconds} <- [
            {"routing examples", retention.routing_examples_enabled,
             retention.routing_examples_seconds},
            {"work examples", retention.work_examples_enabled, retention.work_examples_seconds}
          ],
          enabled,
          do: "#{kind} #{days(div(seconds, 86_400))}"

    case {kept, examples} do
      {nil, _examples} -> nil
      {kept, []} -> kept
      {kept, [one]} -> "#{kept}, and #{one}"
      {kept, [first, second]} -> "#{kept}, #{first} and #{second}"
    end
  end

  defp set_now(:pricing, %{snapshot: %{pricing_rates: []}}), do: "No prices yet"

  defp set_now(:pricing, %{snapshot: %{pricing_rates: rates}}),
    do: Wording.count(length(rates), "price")

  defp set_now(:access, _view), do: nil

  defp set_now(:system, _view) do
    if BundledCoop.distribution?(),
      do: "Work runs on the bundled worker on this host",
      else: "Work runs on workers you run yourself"
  end

  # Where the weekly report posts, once a channel is chosen.
  defp report_channel(%{workspace_ref: workspace}, %{channel_ref: channel})
       when is_binary(workspace) and is_binary(channel),
       do: " in " <> Slack.destination_name(ConversationRef.slack(workspace, channel))

  defp report_channel(_slack, _report), do: ""

  defp days(1), do: "1 day"
  defp days(count), do: "#{count} days"

  # Slack ---------------------------------------------------------------------

  attr(:view, :map, required: true)
  attr(:commands, :map, required: true)
  attr(:confirm, :any, default: nil)
  attr(:slack_people, :any, required: true)

  defp slack(assigns) do
    view = assigns.view
    slack = Integrations.slack(view)

    assigns =
      assign(assigns,
        verified: slack.status != :not_set_up,
        connected: slack.status in [:on, :broken],
        line: slack,
        admins: view.snapshot.slack.workspace_admins_manage,
        managers: view.slack_managers
      )

    ~H"""
    <.connection state={@line.state} text={@line.reason}>
      <:facts :if={@line.facts != []}>{facts(@line.facts)}</:facts>
      <:action :if={@verified}>
        <button
          type="button"
          class="ui-button secondary"
          phx-click="confirm-settings-action"
          phx-value-action="disconnect-slack"
          phx-value-ref="slack"
        >{if @connected, do: "Disconnect", else: "Remove the tokens"}</button>
      </:action>
    </.connection>
    <%!-- Slack that was never switched on is not running, so removing its
    tokens stops nothing: the question says only what it deletes. --%>
    <Kit.confirm_modal
      :if={@confirm == {"disconnect-slack", "slack"}}
      id="confirm-disconnect-slack"
      title={if @connected, do: "Disconnect Slack?", else: "Remove the Slack tokens?"}
      text={
        if @connected,
          do:
            "Ryker stops reading and replying in Slack, and the saved tokens are deleted. Channels, instructions and history stay.",
          else: "The saved tokens are deleted. Channels, instructions and history stay."
      }
      label={if @connected, do: "Disconnect Slack", else: "Remove the tokens"}
      cancel="cancel-settings-action"
      phx-click="disconnect-integration"
      pending="Disconnecting…"
      phx-value-kind="slack"
    />

    <.slack_guide :if={!@verified} />

    <Kit.section_card
      :if={!@verified}
      class="settings-section"
      title="Connect Slack"
      lede="Paste the two tokens from your Slack app. Ryker finds the workspace and the bot for you."
    >
      <.slack_form label="Verify Slack" />
    </Kit.section_card>

    <Kit.section_card
      :if={@verified}
      class="settings-section"
      title="Who can manage Ryker"
      lede="These people can change Ryker's settings from Slack, and sign in to this console with /ryker sign-in."
    >
      <:actions :if={!is_map(@slack_people)}>
        <button
          type="button"
          class={["ui-button", if(@connected, do: "secondary", else: "primary")]}
          phx-click="load-slack-members"
          phx-disable-with="Loading people…"
          disabled={@slack_people == :loading}
        >{if @slack_people == :loading, do: "Loading people…", else: "Choose people"}</button>
      </:actions>
      <%!-- The switch saves as it changes, so it comes first; the people chosen by
      name follow with their own Save (Andrew, 2026-10-01: it sat under their buttons). --%>
      <.live_component
        module={SettingsEditor}
        id="settings-slack-admins"
        section={section!(:slack_admins)}
        view={@view}
        commands={@commands}
        show_header={false}
        frame={:none}
      />
      <%!-- Each group is said once: the people chosen here by name, and the
      workspace's admins and owners as the switch above. --%>
      <Kit.empty
        :if={@slack_people == :loading}
        id="slack-people-loading"
        variant={:hint}
        icon={:chat}
        title="Loading people from Slack…"
        text="Ryker reads every page of the workspace's people; a large workspace takes a little while."
      />
      <Kit.facts
        :if={!is_map(@slack_people) and @managers != []}
        id="slack-managers"
        facts={[{"Chosen people", people(@managers)}]}
      />
      <Kit.empty
        :if={is_nil(@slack_people) and !@admins and @managers == []}
        variant={:hint}
        icon={:chat}
        title="Nobody can manage Ryker yet"
        text="Choose at least one person who can change Ryker's settings from Slack."
      />
      <.people_picker :if={is_map(@slack_people)} people={@slack_people} />
    </Kit.section_card>

    <.live_component
      :for={key <- [:new_channels, :incident_rooms]}
      :if={@verified}
      module={SettingsEditor}
      id={"settings-" <> String.replace(Atom.to_string(key), "_", "-")}
      section={section!(key)}
      view={@view}
      commands={@commands}
    />

    <Kit.section_card
      :if={@verified}
      class="settings-section"
      title="Slack tokens"
      lede="Replace them only when they changed in your Slack app."
    >
      <.slack_form label="Replace tokens" />
    </Kit.section_card>

    <%!-- A Ryker that needs a new permission says which; the app takes it from the manifest. --%>
    <Kit.section_card
      :if={@verified}
      id="slack-app-manifest-update"
      class="settings-section"
      title="Ryker's Slack app manifest"
      lede="When Ryker needs a new permission, paste this on your app's App Manifest page in Slack, save it, then reinstall the app when Slack asks."
    >
      <Components.disclosure id="slack-app-manifest-current" label="Show the manifest">
        <.slack_manifest />
      </Components.disclosure>
    </Kit.section_card>
    """
  end

  # Andrew, 2026-11-21, of a new install's Slack page that only asked for two
  # tokens: "we need to show step by step setup guide ... and even slack
  # manifest to copy". The steps follow Slack's app pages as Slack's own
  # documentation names them, and the manifest is the one Ryker ships, whose
  # scopes are the ones connecting verifies (Ryker.Slack.AppManifest).
  defp slack_guide(assigns) do
    assigns = assign(assigns, :create_url, Slack.app_manifest_url())

    ~H"""
    <Kit.section_card
      id="slack-setup-guide"
      class="settings-section"
      title="Create Ryker's Slack app"
      lede="Ryker works in Slack through an app of its own. Create it once from Ryker's manifest, which asks Slack for every permission Ryker needs, then paste its two tokens below."
    >
      <ol class="setup-steps slack-guide" aria-label="Steps to create the Slack app">
        <.guide_step number={1} title="Create the app from Ryker's manifest">
          Slack's <strong>Create New App</strong>
          opens with Ryker's manifest already filled in. Pick
          the workspace Ryker should work in, choose <strong>Next</strong>, check what the app asks
          for, then choose <strong>Create</strong>.
          <:extra>
            <a
              class="ui-button primary slack-guide-create"
              href={@create_url}
              target="_blank"
              rel="noopener"
            >Create the app in Slack</a>
            <Components.disclosure id="slack-app-manifest" label="Or paste the manifest yourself">
              <p class="settings-help">
                In <a href="https://api.slack.com/apps" target="_blank" rel="noopener">your Slack apps</a>,
                choose <strong>Create New App</strong>, create it from a manifest, pick the workspace and
                paste this as YAML.
              </p>
              <.slack_manifest />
            </Components.disclosure>
          </:extra>
        </.guide_step>
        <.guide_step number={2} title="Make the app-level token">
          On the app's <strong>Basic Information</strong>
          page, under <strong>App-Level Tokens</strong>,
          generate a token with the <code>connections:write</code>
          scope. Copy it: it starts with <code>xapp-</code>.
        </.guide_step>
        <.guide_step number={3} title="Install the app">
          Open <strong>Install App</strong>, choose <strong>Install to Workspace</strong>
          and allow it.
          Copy the <strong>Bot User OAuth Token</strong>: it starts with <code>xoxb-</code>.
        </.guide_step>
        <.guide_step number={4} title="Give it Ryker's icon">
          On <strong>Basic Information</strong>, upload
          <a href="/assets/brand/avatar.png" download="ryker-slack-icon.png">Ryker's icon</a>
          as the app
          icon. A manifest can't set one.
        </.guide_step>
        <.guide_step number={5} title="Paste both tokens below">
          Choose <strong>Verify Slack</strong>. Then invite Ryker to each channel it should work in with <code>/invite @Ryker</code>.
        </.guide_step>
      </ol>
    </Kit.section_card>
    """
  end

  attr(:number, :integer, required: true)
  attr(:title, :string, required: true)
  slot(:inner_block, required: true)
  slot(:extra)

  defp guide_step(assigns) do
    ~H"""
    <li class="setup-step" data-state="guide" id={"slack-guide-#{@number}"}>
      <span class="setup-marker" aria-hidden="true"><span>{@number}</span></span>
      <div class="setup-step-body">
        <p class="setup-step-title">{@title}</p>
        <p class="setup-step-why">{render_slot(@inner_block)}</p>
        {render_slot(@extra)}
      </div>
    </li>
    """
  end

  # The manifest exactly as Ryker ships it, with the copy button the console's
  # other documents use.
  defp slack_manifest(assigns) do
    assigns = assign(assigns, :manifest, Slack.app_manifest())

    ~H"""
    <Components.copy_block label="Copy the manifest">
      <pre
        class="model-document-text slack-manifest"
        tabindex="0"
        aria-label="Ryker's Slack app manifest"
      >{@manifest}</pre>
    </Components.copy_block>
    """
  end

  # Everyone Slack lists, searched and shown a page at a time: a workspace can hold hundreds or
  # thousands (Andrew, 2026-10-01). The page's rows say who was shown, so a person chosen and then
  # searched past stays chosen.
  attr(:people, :map, required: true)

  defp people_picker(assigns) do
    %{members: members, query: query, shown: shown, chosen: chosen} = assigns.people
    needle = query |> String.trim() |> String.downcase()

    matching =
      if needle == "",
        do: members,
        else: Enum.filter(members, &String.contains?(String.downcase(&1.name), needle))

    chosen_names = for member <- members, MapSet.member?(chosen, member.id), do: member.name

    assigns =
      assign(assigns,
        rows: Enum.take(matching, shown),
        rest: max(length(matching) - shown, 0),
        total: length(members),
        matching: length(matching),
        chosen_names: chosen_names
      )

    ~H"""
    <form
      id="slack-people"
      phx-change="slack-people"
      phx-submit="save-slack-choices"
      class="settings-people-form"
      autocomplete="off"
    >
      <label class="settings-people-search">
        <span>Search {Wording.count(@total, "person", "people")}</span><input
          type="search"
          name="query"
          value={@people.query}
          placeholder="Name"
          phx-debounce="200"
        />
      </label>
      <p class="settings-help" id="slack-people-chosen">{chosen_line(@chosen_names)}</p>
      <div class="settings-people-list" role="group" aria-label="People who can manage Ryker">
        <label :for={member <- @rows} class="settings-option">
          <input type="hidden" name="shown[]" value={member.id} />
          <input
            type="checkbox"
            name="operators[]"
            value={member.id}
            checked={MapSet.member?(@people.chosen, member.id)}
          />
          <span><strong>{member.name}</strong></span>
        </label>
      </div>
      <p :if={@matching == 0} class="settings-help">Nobody's name matches "{@people.query}".</p>
      <button
        :if={@rest > 0}
        type="button"
        class="ui-button quiet"
        phx-click="slack-people-more"
        phx-disable-with="Loading…"
      >
        Show {min(@rest, 50)} more
      </button>
      <div class="settings-actions">
        <button class="ui-button primary" type="submit" phx-disable-with="Saving…">Save changes</button>
        <button type="button" class="ui-button secondary" phx-click="cancel-slack-members">
          Cancel
        </button>
      </div>
    </form>
    """
  end

  defp chosen_line([]), do: "Nobody chosen yet."

  defp chosen_line(names) do
    {first, rest} = Enum.split(names, 5)
    more = if rest == [], do: "", else: " and #{length(rest)} more"
    "#{length(names)} chosen: #{Enum.join(first, ", ")}#{more}"
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
        <button class="ui-button primary" type="submit" phx-disable-with="Connecting…">{@label}</button>
      </div>
    </form>
    """
  end

  # GitHub --------------------------------------------------------------------

  defp local_address?(url) do
    case URI.parse(url) do
      %URI{host: host} when host in ["127.0.0.1", "localhost", "::1"] -> true
      _public -> false
    end
  end

  defp github_events(%{received: 0}), do: "No events in the last day."

  defp github_events(%{received: received, unreadable: 0}),
    do: "#{Wording.count(received, "event")} in the last day."

  defp github_events(%{received: received, unreadable: unreadable}) do
    "#{Wording.count(received, "event")} in the last day, #{unreadable} couldn't be read."
  end

  attr(:view, :map, required: true)
  attr(:commands, :map, required: true)
  attr(:confirm, :any, default: nil)
  attr(:feedback, :map, default: nil)

  attr(:webhook_secret, :string,
    default: nil,
    doc: "The secret to put into GitHub before the App is connected; nil once it is"
  )

  # The steps follow GitHub's own form from top to bottom: what to fill in there,
  # in the order GitHub asks for it, then what to bring back. Andrew, 2026-11-20,
  # of the guide before it: "not logically ordered and all over the place". The
  # webhook secret was shown only after the App was saved here, so it had to be
  # pasted into GitHub on a second visit, and the Redirect URI waited in a
  # later step though GitHub asks for it before the webhook.
  defp github(assigns) do
    view = assigns.view
    line = Integrations.github(view)

    assigns =
      assign(assigns,
        line: line,
        usable: view.github_connection == :ready and line.status != :broken,
        ready: view.github_connection == :ready,
        repositories: length(view.snapshot.github_bindings),
        sign_in_configured: view.github_sign_in_configured,
        app_feedback: if(assigns.feedback && assigns.feedback.step == :app, do: assigns.feedback),
        sign_in_feedback:
          if(assigns.feedback && assigns.feedback.step == :sign_in, do: assigns.feedback)
      )

    ~H"""
    <Kit.section_card class="settings-section github-setup" title="GitHub setup">
      <.setup_step
        id="github-app"
        title={
          if @line.status == :broken,
            do: "1. Repair GitHub connection",
            else: "1. Connect the GitHub App"
        }
        open={!@ready or @line.status == :broken or not is_nil(@app_feedback)}
        state={
          cond do
            @line.status == :broken -> @line.state
            @ready -> {:on, "Verified"}
            true -> @line.state
          end
        }
      >
        <p :if={@line.reason && (!@ready || @line.status == :broken)}>{@line.reason}</p>
        <p :if={@ready}>
          Connected as <strong>@{@view.snapshot.github.app_slug}</strong>. To rotate its key, make a new one under
          <strong>Credentials → Key pairs</strong>
          and upload it below.
        </p>
        <%!-- What GitHub sent is the connection's state, so it reads with
        "Connected as", not squeezed between the form's button and Disconnect
        (Andrew, 2026-11-21: "text too close to button and looks ugly"). --%>
        <p id="github-events" class="settings-lede">
          <span :if={local_address?(@view.github_callback_url)}>
            GitHub can't reach this computer, so it lists every delivery to this address as failed.
            Ryker collects the same events from GitHub every 30 seconds instead.
          </span>
          {github_events(@view.github_events)}
        </p>
        <ol class="setup-instructions github-guide">
          <li>
            In the GitHub account or organization that will own the App, open <strong>Settings → Developer settings → GitHub Apps</strong>. Choose <strong>New GitHub App</strong>, or
            <strong>Edit</strong>
            beside an App you already have. A new App needs a name and a homepage address.
          </li>
          <li>
            Under <strong>Identifying and authorizing users</strong>, add this <strong>Redirect URI</strong>. People sign in through it to use Ryker's buttons on GitHub.
            <Components.copy_block label="Copy redirect URI">
              <pre>{@view.github_action_callback_url}</pre>
            </Components.copy_block>
          </li>
          <li>
            Under <strong>Webhook</strong>, keep <strong>Active</strong>
            ticked and fill in these two fields.
            <div class="github-guide-field">
              <span>Webhook URL</span>
              <Components.copy_block label="Copy webhook URL">
                <pre>{@view.github_callback_url}</pre>
              </Components.copy_block>
            </div>
            <div :if={@webhook_secret} id="github-webhook-secret" class="github-guide-field">
              <span>Secret</span>
              <Components.copy_block label="Copy webhook secret">
                <pre>{@webhook_secret}</pre>
              </Components.copy_block>
            </div>
            <p :if={@webhook_secret} class="github-guide-note">
              On an App you already have, choose <strong>Change secret</strong>
              to paste it, then <strong>Save changes</strong>: the permissions are on a page of their own.
            </p>
            <p :if={!@webhook_secret} class="github-guide-note">
              Keep the secret GitHub has. Replacing the key below leaves it as it is.
            </p>
          </li>
          <li>
            Set the <strong>Repository permissions</strong>. A new App lists them below Webhook;
            on an App you already have, open <strong>Permissions &amp; events</strong>.
            <ul class="github-guide-list">
              <li>
                <strong>Contents</strong>, <strong>Issues</strong>
                and <strong>Pull requests</strong>: Read and write
              </li>
              <li><strong>Actions</strong>: Read and write, so Ryker can re-run and cancel CI</li>
              <li>
                <strong>Checks</strong>, <strong>Commit statuses</strong>
                and <strong>Deployments</strong>: Read-only
              </li>
              <li>
                <strong>Workflows</strong>: Read and write, only if Ryker may change CI workflow files
              </li>
            </ul>
            <p class="github-guide-note">Metadata stays Read-only, as GitHub requires.</p>
          </li>
          <li>
            Under <strong>Subscribe to events</strong>, tick Check run, Check suite, Deployment,
            Deployment status, Issue comment, Issues, Pull request, Pull request review,
            Pull request review comment, Pull request review thread, Push, Release, Repository,
            Status, Workflow job and Workflow run.
            <p class="github-guide-note">GitHub lists each event once its permission is set.</p>
          </li>
          <li>
            Choose <strong>Create GitHub App</strong>, or <strong>Save changes</strong>
            on an App you already have.
          </li>
          <li>
            Copy the <strong>App ID</strong>
            from <strong>About</strong>
            at the top of the App's page into the form below.
          </li>
          <li>
            Open <strong>Credentials → Key pairs</strong>
            and choose <strong>New key</strong>. Upload the <code>.pem</code>
            file GitHub downloads.
          </li>
        </ol>
        <.github_form
          label={if @ready, do: "Replace credentials", else: "Verify GitHub App"}
          webhook_secret={@webhook_secret}
        >
          <:action :if={@ready}>
            <button
              type="button"
              class="ui-button secondary"
              phx-click="confirm-settings-action"
              phx-value-action="disconnect-github"
              phx-value-ref="github"
            >Disconnect</button>
          </:action>
        </.github_form>
        <Components.form_feedback
          :if={@app_feedback}
          tone={@app_feedback.tone}
          message={@app_feedback.message}
        />
      </.setup_step>
      <.setup_step
        id="github-repositories"
        title="2. Add repositories"
        open={@usable and @repositories == 0}
        state={
          cond do
            !@usable -> {:off, "Connect the App first"}
            @repositories == 0 -> {:warn, "Add a repository to start"}
            true -> {:on, Wording.count(@repositories, "repository")}
          end
        }
      >
        <p>
          Install the App on GitHub and choose the repositories Ryker may use. Then add them here.
        </p>
        <p :if={@usable && @view.snapshot.github.app_slug}>
          <a
            href={app_install_url(@view.snapshot.github.api_url, @view.snapshot.github.app_slug)}
            target="_blank"
            rel="noopener noreferrer"
          >Install the App on GitHub</a>
        </p>
        <.link
          :if={@usable}
          navigate={if @repositories == 0, do: "/repositories/new", else: "/repositories"}
          class="ui-button secondary"
        >{if @repositories == 0, do: "Add repositories", else: "Manage repositories"}</.link>
      </.setup_step>
      <.setup_step
        id="github-action-sign-in"
        title="3. Enable GitHub action buttons"
        open={@usable and (!@sign_in_configured or not is_nil(@sign_in_feedback))}
        state={
          cond do
            !@usable -> {:off, "Connect the App first"}
            @sign_in_configured -> {:on, "Credentials saved"}
            true -> {:warn, "Set up sign-in"}
          end
        }
      >
        <p>
          Repository writers sign in to choose review fixes or turn an issue plan into a pull request.
        </p>
        <ol :if={@usable} class="setup-instructions github-guide">
          <li>
            Check that the App lists this <strong>Redirect URI</strong>
            under <strong>Identifying and authorizing users</strong>.
            <Components.copy_block label="Copy redirect URI">
              <pre>{@view.github_action_callback_url}</pre>
            </Components.copy_block>
          </li>
          <li>
            Copy the <strong>Client ID</strong>
            from <strong>About</strong>
            at the top of the App's page into the field below.
          </li>
          <li>
            Open <strong>Credentials → Client secrets</strong>
            and choose <strong>New secret</strong>. Copy it while GitHub shows it and paste it below.
          </li>
        </ol>
        <div :if={@usable}>
          <form phx-submit="connect-github-actions" class="settings-form">
            <div class="settings-field">
              <label for="github-action-client-id">Client ID</label>
              <input
                id="github-action-client-id"
                name="connection[client_id]"
                required
                value={
                  (@sign_in_feedback && @sign_in_feedback[:client_id]) ||
                    @view.snapshot.github.oauth_client_id
                }
              />
            </div>
            <div class="settings-field">
              <label for="github-action-client-secret">Client secret</label>
              <input
                id="github-action-client-secret"
                name="connection[client_secret]"
                type="password"
                required
                autocomplete="new-password"
              />
            </div>
            <div class="settings-actions">
              <button type="submit" class="ui-button secondary" phx-disable-with="Saving…">Save GitHub sign-in</button>
              <Components.form_feedback
                :if={@sign_in_feedback}
                tone={@sign_in_feedback.tone}
                message={@sign_in_feedback.message}
              />
            </div>
          </form>
        </div>
      </.setup_step>
    </Kit.section_card>
    <Kit.confirm_modal
      :if={@confirm == {"disconnect-github", "github"}}
      id="confirm-disconnect-github"
      title="Disconnect GitHub?"
      text="Ryker stops receiving GitHub events and starting GitHub work, and the App's private key and webhook secret are deleted. Repositories and history stay."
      label="Disconnect GitHub"
      cancel="cancel-settings-action"
      phx-click="disconnect-integration"
      pending="Disconnecting…"
      phx-value-kind="github"
    />

    <.live_component
      :if={@ready}
      module={SettingsEditor}
      id="settings-repository-imports"
      section={section!(:repository_imports)}
      view={@view}
      commands={@commands}
    />
    <details :if={@ready} class="settings-disclosure github-examples">
      <summary>How to request work on GitHub</summary>
      <div id="github-usage">
        <p>
          In a pull request comment, type the App’s handle and your request.
          You can send it even when GitHub does not suggest the handle.
        </p>
        <Components.copy_block label="Copy review request">
          <pre>{@view.snapshot.github.app_slug && "@#{@view.snapshot.github.app_slug} review this PR"}</pre>
        </Components.copy_block>
        <p>For a specific change, include what you want done:</p>
        <Components.copy_block label="Copy change request">
          <pre>{@view.snapshot.github.app_slug && "@#{@view.snapshot.github.app_slug} add a regression test for the bug fixed in this PR"}</pre>
        </Components.copy_block>
        <p>
          You can also add <code>ryker:review</code>
          to request a review. Ryker removes it
          after accepting the request; add it again for another review. <code>ryker:working</code>
          appears while Ryker handles work on the PR, including
          automatic CI fixes and review follow-ups on its own PRs.
        </p>
      </div>
    </details>
    <.live_component
      :if={@ready}
      module={SettingsEditor}
      id="settings-publication"
      section={section!(:publication)}
      view={@view}
      commands={@commands}
    />
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:open, :boolean, required: true)
  attr(:state, :any, required: true)
  slot(:inner_block, required: true)

  defp setup_step(assigns) do
    ~H"""
    <details
      id={@id}
      open={@open}
      class="github-step"
      data-disclosure-state={"#{elem(@state, 1)}:#{@open}"}
    >
      <summary>
        <strong>{@title}</strong><span class="settings-connection"><Kit.state
          tone={elem(@state, 0)}
          word={elem(@state, 1)}
        /></span>
      </summary>
      <div class="github-step-body">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  @doc """
  Where a person installs the App: github.com, or the GitHub Enterprise server
  its API lives on. The link always led to github.com (2026-10-04 review).
  """
  @spec app_install_url(String.t() | nil, String.t()) :: String.t()
  def app_install_url(api_url, slug) do
    case GitHub.web_url(api_url) do
      "https://github.com" -> "https://github.com/apps/#{slug}/installations/new"
      enterprise -> enterprise <> "/github-apps/#{slug}/installations/new"
    end
  end

  attr(:label, :string, required: true)
  attr(:webhook_secret, :string, default: nil)
  slot(:action, doc: "A button beside the form's own, such as Disconnect")

  # The webhook secret travels with the form exactly as the guide above showed
  # it. Without one the connected App keeps its own.
  defp github_form(assigns) do
    assigns = assign(assigns, :key, key(assigns.label))

    ~H"""
    <form phx-submit="connect-github" autocomplete="off" class="settings-form github-connection-form">
      <input
        :if={@webhook_secret}
        type="hidden"
        name="connection[webhook_secret]"
        value={@webhook_secret}
      />
      <fieldset>
        <legend class="sr-only">GitHub App</legend>
        <div class="settings-field">
          <label for={"github-app-id-#{@key}"}>App ID</label>
          <p class="settings-help">A number under About, at the top of the App's page on GitHub.</p>
          <input
            id={"github-app-id-#{@key}"}
            type="number"
            name="connection[app_id]"
            min="1"
            placeholder="123456"
            required
          />
        </div>
        <div class="settings-field">
          <label for={"github-private-key-file-#{@key}"}>Private key</label>
          <p class="settings-help">
            The .pem file GitHub gave you when you created a key. It starts with
            -----BEGIN RSA PRIVATE KEY-----.
          </p>
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
      </fieldset>
      <details class="settings-disclosure">
        <summary>GitHub Enterprise</summary>
        <p class="settings-help">
          On older GitHub Enterprise Server versions, find Client secrets and Private keys on the App’s settings page.
        </p>
        <div class="settings-field">
          <label for={"github-api-url-#{@key}"}>API URL</label>
          <p class="settings-help">Change it only for GitHub Enterprise Server.</p>
          <input
            id={"github-api-url-#{@key}"}
            type="url"
            name="connection[api_url]"
            value="https://api.github.com"
            placeholder="https://github.example.com/api/v3"
          />
        </div>
      </details>
      <div class="settings-actions">
        <button class="ui-button primary" type="submit" phx-disable-with="Connecting…">{@label}</button>
        {render_slot(@action)}
      </div>
    </form>
    """
  end

  # Emisar --------------------------------------------------------------------

  attr(:view, :map, required: true)

  # The connection, then the accounts. Connecting another account and editing
  # one each happen on a page of its own.
  defp emisar(assigns) do
    snapshot = assigns.view.snapshot

    assigns =
      assign(assigns,
        accounts: snapshot.emisar_connections,
        account_states:
          Map.new(
            snapshot.emisar_connections,
            &{&1.ref, Integrations.emisar_account(assigns.view, &1)}
          ),
        line: Integrations.emisar(assigns.view),
        snapshot: snapshot
      )

    ~H"""
    <Kit.section_card
      class="settings-section"
      title="Accounts"
      lede={
        if @line.unassigned > 0,
          do: Integrations.unassigned(@line.unassigned),
          else: "Open an account to rename it, replace its key, pause it or remove it."
      }
    >
      <:actions :if={@line.unassigned > 0 || @accounts != []}>
        <.link :if={@line.unassigned > 0} navigate="/environments">Manage environments</.link>
        <.link :if={@accounts != []} patch="/integrations/emisar/new" class="ui-button secondary">
          <Components.icon name={:plus} />Add account
        </.link>
      </:actions>
      <div :if={@line.status != :on} class="settings-connection">
        <div class="settings-connection-body">
          <Kit.state tone={elem(@line.state, 0)} word={elem(@line.state, 1)} />
          <p :if={@line.reason}>{@line.reason}</p>
        </div>
      </div>
      <Kit.empty
        :if={@accounts == []}
        variant={:hint}
        icon={:plug}
        title="No Emisar account yet"
        text="Create an agent API key in Emisar under AI agents and connect it here. Then choose it for each environment that should use it."
      >
        <.link patch="/integrations/emisar/new" class="ui-button primary">Connect an account</.link>
      </Kit.empty>
      <Kit.entity_list :if={@accounts != []} label="Emisar accounts">
        <Kit.entity_row
          :for={account <- @accounts}
          id={"emisar-account-" <> account.ref}
          name={account.display_name}
          href={Paths.edit_emisar_account(account.ref)}
          link_row={true}
          state={@account_states[account.ref].state}
          text={@account_states[account.ref].reason}
          meta={
            [
              # An account named after its address says the address once.
              if(account.account_label != account.display_name, do: account.account_label),
              used_by(@snapshot, account),
              watching(account, @account_states[account.ref])
            ]
          }
        />
      </Kit.entity_list>
    </Kit.section_card>
    """
  end

  attr(:account, :map, required: true)
  attr(:view, :map, required: true)
  attr(:confirm, :any, default: nil)

  attr(:feedback, :map, required: true)

  # One account's page: each thing that can change about it is a part of its
  # own, saved on its own, and removing it asks first.
  defp emisar_manage(assigns) do
    assigns =
      assign(assigns,
        state: Integrations.emisar_account(assigns.view, assigns.account),
        used: used_by(assigns.view.snapshot, assigns.account)
      )

    ~H"""
    <Kit.section_card class="settings-section" title="Account">
      <Kit.status_line id="emisar-account-state" state={@state.state}>
        <span :if={@state.reason}>{" " <> @state.reason}</span>
      </Kit.status_line>
      <Kit.facts facts={[
        {"Address", @account.rpc_url},
        {"Emisar account", @account.account_label},
        {"Environments", @used}
      ]} />
      <form
        id={"emisar-rename-form-#{@account.ref}"}
        phx-hook="AccountField"
        phx-submit="rename-emisar"
        class="settings-inline-form"
        data-saved={@account.display_name}
        data-success={success_key(@feedback[:name])}
      >
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
        <button class="ui-button secondary" type="submit" phx-disable-with="Saving…" disabled>Save name</button>
        <Components.form_feedback
          :if={@feedback[:name]}
          message={@feedback.name.message}
          tone={@feedback.name.tone}
        />
      </form>
    </Kit.section_card>

    <Kit.section_card
      class="settings-section"
      title="API key"
      lede="Replace it when you create a new key in Emisar. Ryker checks the key with Emisar before it uses it."
    >
      <form
        id={"emisar-key-form-#{@account.ref}"}
        phx-hook="AccountField"
        phx-submit="rotate-emisar"
        autocomplete="off"
        class="settings-inline-form"
        data-saved=""
        data-success={success_key(@feedback[:key])}
      >
        <input type="hidden" name="connection[ref]" value={@account.ref} />
        <div class="settings-field">
          <label for={"emisar-token-#{@account.ref}"}>New API key</label>
          <input
            id={"emisar-token-#{@account.ref}"}
            type="password"
            name="connection[token]"
            placeholder="emk-…"
            required
          />
        </div>
        <button class="ui-button secondary" type="submit" phx-disable-with="Replacing…" disabled>Replace key</button>
        <Components.form_feedback
          :if={@feedback[:key]}
          message={@feedback.key.message}
          tone={@feedback.key.tone}
        />
      </form>
    </Kit.section_card>

    <Kit.section_card
      class="settings-section"
      id="emisar-new-work"
      title="New work"
      lede={
        if @account.enabled_for_new_work,
          do:
            "Ryker sends new work to this account. Pause it to stop that; work already sent to it and its history stay.",
          else: "Paused, so Ryker sends it no new work. Work already sent to it and its history stay."
      }
    >
      <:actions>
        <button
          type="button"
          class="ui-button secondary"
          phx-click={if @account.enabled_for_new_work, do: "disable-emisar", else: "enable-emisar"}
          phx-value-ref={@account.ref}
          phx-disable-with={if @account.enabled_for_new_work, do: "Pausing…", else: "Resuming…"}
        >{if @account.enabled_for_new_work, do: "Pause", else: "Resume"}</button>
      </:actions>
    </Kit.section_card>

    <Kit.section_card
      class="settings-section"
      title="Approval monitoring"
      lede={
        if @account.monitoring_enabled,
          do:
            "Ryker watches this account for approval decisions. If you turn this off, tasks waiting on its approvals stop and show on Failures.",
          else:
            "Ryker is not watching this account, so tasks waiting on its approvals are stopped. They show on Failures until you turn this on."
      }
    >
      <:actions>
        <button
          type="button"
          class="ui-button secondary"
          phx-click={
            if @account.monitoring_enabled,
              do: "disable-emisar-monitoring",
              else: "enable-emisar-monitoring"
          }
          phx-value-ref={@account.ref}
          phx-disable-with={if @account.monitoring_enabled, do: "Turning off…", else: "Turning on…"}
        >{if @account.monitoring_enabled, do: "Turn off", else: "Turn on"}</button>
      </:actions>
    </Kit.section_card>

    <Kit.remove_card
      id="remove-emisar-account"
      title="Remove account"
      text="The environments that use it are left without an Emisar account. An account that tasks or approvals still name cannot be removed; pause it instead."
      phx-click="confirm-settings-action"
      phx-value-action="delete-emisar"
      phx-value-ref={@account.ref}
    />
    <Kit.confirm_modal
      :if={@confirm == {"delete-emisar", @account.ref}}
      id="confirm-delete-emisar"
      title={"Remove #{@account.display_name}?"}
      text="Ryker stops sending it work, the environments that use it are left without an Emisar account and its token is deleted."
      label="Remove account"
      cancel="cancel-settings-action"
      phx-click="delete-emisar"
      pending="Removing…"
      phx-value-ref={@account.ref}
    />
    """
  end

  defp success_key(%{tone: :success, key: key}), do: key
  defp success_key(_other), do: nil

  # The form on its own page: the key and where Emisar answers.
  defp emisar_form(assigns) do
    ~H"""
    <form phx-submit="connect-emisar" autocomplete="off" class="settings-form">
      <%!-- Emisar cannot say which account a key belongs to, so its name is asked for here
      (Andrew, 2026-10-01). --%>
      <div class="settings-field">
        <label for="emisar-connect-name">Name (optional)</label>
        <p class="settings-help">
          How Ryker names this account, such as your company in Emisar. Empty uses its address.
        </p>
        <input
          id="emisar-connect-name"
          type="text"
          name="connection[display_name]"
          maxlength="120"
          placeholder="Acme, Inc."
        />
      </div>
      <div class="settings-field">
        <label for="emisar-connect-token">API key</label>
        <p class="settings-help">
          Create one in Emisar under AI agents. Ryker checks the key with Emisar, then stores it encrypted.
        </p>
        <input
          id="emisar-connect-token"
          type="password"
          name="connection[token]"
          placeholder="emk-…"
          required
        />
      </div>
      <div class="settings-field">
        <label for="emisar-connect-url">Emisar address</label>
        <p class="settings-help">Keep this unless your Emisar is self-hosted.</p>
        <input
          id="emisar-connect-url"
          type="url"
          name="connection[rpc_url]"
          value="https://emisar.dev/api/mcp/rpc"
          placeholder="https://emisar.dev/api/mcp/rpc"
          required
        />
      </div>
      <div class="settings-actions">
        <button class="ui-button primary" type="submit" phx-disable-with="Connecting…">
          Connect account
        </button>
        <.link patch="/integrations/emisar" class="ui-button secondary">Cancel</.link>
      </div>
    </form>
    """
  end

  # Webhooks ------------------------------------------------------------------

  attr(:view, :map, required: true)
  attr(:commands, :map, required: true)
  attr(:confirm, :any, default: nil)

  defp webhooks(assigns) do
    credentials = Enum.filter(assigns.view.credentials, &(&1.kind == :webhook))

    assigns =
      assign(assigns,
        credentials: credentials,
        sources?: assigns.view.snapshot.webhook_sources != [],
        deleting:
          case assigns.confirm do
            {"delete-webhook-credential", name} -> name
            _other -> nil
          end,
        line: Integrations.webhooks(assigns.view),
        users: credential_users(assigns.view.snapshot.webhook_sources)
      )

    ~H"""
    <.connection :if={@sources?} state={@line.state} text={@line.reason}>
      <:facts :if={@line.facts != []}>{facts(@line.facts)}</:facts>
    </.connection>

    <Kit.section_card
      class="settings-section"
      title="Signing credentials"
      lede="Senders sign each request with a shared secret, so Ryker knows it is theirs."
    >
      <:actions :if={@credentials != []}>
        <.link patch="/integrations/webhooks/credentials/new" class="ui-button secondary">
          <Components.icon name={:plus} />Add signing credential
        </.link>
      </:actions>
      <Kit.empty
        :if={@credentials == []}
        variant={:hint}
        icon={:plug}
        title="No signing credential yet"
        text="A webhook source needs one: its sender signs each request with the credential's secret."
      >
        <.link patch="/integrations/webhooks/credentials/new" class="ui-button primary">
          Add signing credential
        </.link>
      </Kit.empty>
      <Kit.entity_list :if={@credentials != []} label="Signing credentials">
        <Kit.entity_row
          :for={credential <- @credentials}
          id={"webhook-credential-" <> credential.name}
          name={credential.name}
          state={credential_state(credential)}
          meta={[credential_use(@users, credential.name)]}
        >
          <:actions :if={Map.get(@users, credential.name, []) == []}>
            <button
              type="button"
              class="ui-button quiet"
              phx-click="confirm-settings-action"
              phx-value-action="delete-webhook-credential"
              phx-value-ref={credential.name}
            >Delete<span class="sr-only">{" " <> credential.name}</span></button>
          </:actions>
        </Kit.entity_row>
      </Kit.entity_list>
    </Kit.section_card>
    <Kit.confirm_modal
      :if={@deleting}
      id="confirm-delete-webhook-credential"
      title={"Delete #{@deleting}?"}
      text="Its secret is deleted. A sender still using it can no longer deliver events."
      label="Delete credential"
      cancel="cancel-settings-action"
      phx-click="delete-webhook-credential"
      pending="Deleting…"
      phx-value-name={@deleting}
    />

    <.live_component
      :if={@credentials != [] or @sources?}
      module={SettingsEditor}
      id="settings-webhooks"
      section={section!(:webhooks)}
      view={@view}
      commands={@commands}
      paths={paths(:webhooks)}
    />

    <.live_component
      :if={@sources?}
      module={WebhookPreview}
      id="webhook-preview"
      view={@view}
      check={@commands.preview_webhook}
    />
    """
  end

  # The form on its own page: a name, and a secret to keep or one Ryker makes.
  defp webhook_credential_form(assigns) do
    ~H"""
    <form phx-submit="create-webhook-credential" autocomplete="off" class="settings-form">
      <div class="settings-field">
        <label for="webhook-credential-name">Name</label>
        <p class="settings-help">
          Lowercase letters, numbers, dots, dashes, underscores and colons, such as grafana.
        </p>
        <input
          id="webhook-credential-name"
          type="text"
          name="credential[name]"
          pattern="[a-z0-9][a-z0-9_.:\-]{0,127}"
          title="Lowercase letters, numbers, dots, dashes, underscores and colons, starting with a letter or number"
          placeholder="grafana"
          required
        />
      </div>
      <div class="settings-field">
        <label for="webhook-credential-secret">Existing secret (optional)</label>
        <p class="settings-help">
          At least 32 characters. Leave empty and Ryker creates a strong one and shows it to you once.
        </p>
        <input
          id="webhook-credential-secret"
          type="password"
          name="credential[secret]"
          minlength="32"
          placeholder="32 characters or more"
        />
      </div>
      <div class="settings-actions">
        <button class="ui-button primary" type="submit" phx-disable-with="Creating…">
          Create credential
        </button>
        <.link patch="/integrations/webhooks" class="ui-button secondary">Cancel</.link>
      </div>
    </form>
    """
  end

  # Shared parts --------------------------------------------------------------

  attr(:state, :any, required: true)
  attr(:text, :string, default: nil)
  slot(:facts, doc: "What is connected, on one line under the sentence")
  slot(:action)

  # The page's first card, its connection: a dot and a word, what it means
  # when that is not obvious, what is connected and the one action that fits
  # it. An action that disconnects asks first, in a modal the page renders.
  defp connection(assigns) do
    ~H"""
    <Kit.section_card class="settings-section" title="Connection">
      <div class="settings-connection">
        <div class="settings-connection-body">
          <Kit.state tone={elem(@state, 0)} word={elem(@state, 1)} />
          <p :if={@text}>{@text}</p>
          <p :if={@facts != []}>{render_slot(@facts)}</p>
        </div>
        <div :if={@action != []} class="settings-connection-action">{render_slot(@action)}</div>
      </div>
    </Kit.section_card>
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
    environments =
      snapshot.environments
      |> Environments.ordered()
      |> Enum.filter(&(&1.emisar_connection_ref == account.ref))

    case environments do
      [] ->
        "No environment uses it yet"

      [_ | _] ->
        "Used by " <> Wording.list(Enum.map(environments, & &1.display_name))
    end
  end

  # Whether Ryker watches an account for approval decisions. One the running
  # system left out is not watched, and its row says why instead.
  defp watching(%{monitoring_enabled: false}, _state), do: "Not watching for approval decisions"
  defp watching(_account, %{reason: nil}), do: "Watching for approval decisions"
  defp watching(_account, _left_out), do: nil

  # "Verify GitHub App" -> "verify-github-app": element ids never carry spaces.
  defp key(label), do: label |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  # A person as a row's name: the one rendering every page uses for people.
  defp people(people), do: Kit.people(%{people: people, more: [], __changed__: nil})

  defp editors(:model),
    do: [:request_models, :other_models, :model_presets, :model_accounts, :local_routing]

  defp editors(:retention), do: [:retention]
  defp editors(:pricing), do: [:pricing]
  defp editors(:report), do: [:report]
  defp editors(:system), do: [:work]
  defp editors(_section), do: []

  # Every settings page shows its parts as cards (Andrew, 2026-09-27: "why
  # some pages like this have islands while others dont"). A page of several
  # cards titles each one; a page that is one card, such as Data retention or
  # Model prices, leaves it untitled under the page's own title.
  # Advanced and Weekly report have other parts beside their one editor, so
  # its card keeps a title.
  defp titled?(section) when section in [:system, :report], do: true
  defp titled?(section), do: length(editors(section)) > 1

  # Any model or fallback no price covers. The notice is the page's, above its
  # cards, since it can be about any of them.
  defp model_notices(view), do: Enum.reject([unpriced_notice(view)], &is_nil/1)

  # A model or fallback no price covers still runs; its cost reads as not
  # priced, and the page says which one before anyone wonders why.
  defp unpriced_notice(view) do
    unpriced =
      for field <- SettingsSections.ladder_fields(),
          phrase = unpriced(field, Map.fetch!(view.snapshot.work, field.name), view),
          do: phrase

    if unpriced != [] do
      %{
        text:
          "No price covers #{Wording.list(unpriced)}, so " <>
            Wording.word(length(unpriced), "its", "their") <>
            " cost will show as not priced.",
        link: "Add a price",
        href: "/settings/prices"
      }
    end
  end

  defp unpriced(field, [first | _fallbacks] = models, view) do
    case Enum.reject(models, &SettingsSections.priced?(&1, view)) do
      [] -> nil
      [^first | _others] -> "the model for #{field.label}"
      _fallbacks -> "a fallback for #{field.label}"
    end
  end

  defp unpriced(_field, _models, _view), do: nil

  defp section!(key) do
    {:ok, section} = SettingsSections.fetch(key)
    section
  end

  # Titles are the sidebar's names; the sentence under each says what the
  # page is for. Setup's sentence follows how far setup is.
  defp page(:setup, view), do: %{title: "Set up Ryker", description: SetupPage.description(view)}
  defp page(section, _view), do: page(section)

  # A page's heading: its own, or for a page of one form what the form adds
  # or edits, with the list it returns to above the title.
  defp heading(section, nil, view), do: page(section, view)

  defp heading(:skills, {:install, _method}, _view),
    do: %{
      title: "Install skill",
      description: nil,
      back: {"All skills", "/skills"}
    }

  defp heading(:skills, {:skill, name}, view) do
    skill = Ryker.Skills.find(view.snapshot.work.installed_skills, name)

    %{
      title: if(skill, do: Ryker.ControlPlane.SkillPage.title(name), else: "Skill unavailable"),
      description: nil,
      back: {"All skills", "/skills"}
    }
  end

  defp heading(_section, {:environment, nil}, _view),
    do: %{
      title: "Add an environment",
      description:
        "Name it, choose the repositories work in it may use and how, and its Emisar account.",
      back: {"All environments", "/environments"}
    }

  defp heading(_section, {:environment, ref}, view),
    do: %{
      title: edit_title(Environments.find(view.snapshot, ref), "environment"),
      description: "What work in this environment may use: its repositories and Emisar account.",
      back: {"All environments", "/environments"}
    }

  defp heading(_section, {:emisar, nil}, _view),
    do: %{
      title: "Connect an Emisar account",
      description:
        "Paste an agent API key from Emisar. Ryker starts watching the account for approval decisions at once.",
      back: {"Emisar", "/integrations/emisar"}
    }

  defp heading(_section, {:emisar, ref}, view),
    do: %{
      title:
        edit_title(
          Enum.find(view.snapshot.emisar_connections, &(&1.ref == ref)),
          "Emisar account"
        ),
      description: "Its name, its API key, whether Ryker watches it for approvals, or remove it.",
      back: {"Emisar", "/integrations/emisar"}
    }

  defp heading(_section, {:webhook_credential, nil}, _view),
    do: %{
      title: "Add a signing credential",
      description:
        "A shared secret a sender signs each request with, so Ryker knows it is theirs.",
      back: {"Webhooks", "/integrations/webhooks"}
    }

  defp heading(section, {key, item_key}, view) when key in @item_forms do
    collection = section!(key)
    noun = Map.get(collection, :item_label, "entry")

    title =
      case item_key do
        nil ->
          "Add a " <> noun

        item_key ->
          collection
          |> SettingsSections.items(view)
          |> Enum.find(&(to_string(Map.get(&1, collection.item_key)) == item_key))
          |> then(&(&1 && SettingsRows.present(collection, &1, view)))
          |> edit_title(noun)
      end

    %{
      title: title,
      description: form_description(key),
      back: {back(section, key), paths(key).list}
    }
  end

  # A preset's page returns to the Models page, of which presets are one card.
  defp back(section, :model_presets), do: page(section).title
  defp back(section, _key), do: "All " <> String.downcase(page(section).title)

  defp edit_title(%{display_name: name}, _noun), do: "Edit " <> name
  defp edit_title(%{name: name}, _noun), do: "Edit " <> name
  defp edit_title(nil, noun), do: "Edit " <> noun

  defp form_description(:pricing),
    do: "What one model costs per million tokens, from the day the price applies."

  defp form_description(:webhooks),
    do: "Where a sender posts its events, how Ryker reads them and where Ryker works on them."

  defp form_description(:model_presets),
    do: "A lead model and the roles it can call, on the models and accounts of the Models page."

  defp page(:setup),
    do: %{title: "Set up Ryker", description: "Connect Ryker to Slack and your code."}

  defp page(:skills),
    do: %{
      title: "Skills",
      description: "Skills you enable globally are available in every Ryker session."
    }

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

  defp page(:settings),
    do: %{
      title: "Settings",
      description:
        "How Ryker itself runs: the models it uses, how long it keeps data, what models " <>
          "cost, its weekly report and where its work runs."
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
        "Emisar lets Ryker act on your running systems. A person approves each risky action in Emisar before it runs, and Ryker can't approve for anyone."
    }

  defp page(:webhooks),
    do: %{
      title: "Webhooks",
      description: "Let other systems, like Grafana, send events to Ryker."
    }

  # A list of models no longer names its first choice and fallbacks, so the
  # sentence says how the list is used.
  defp page(:model),
    do: %{
      title: "Models",
      description:
        "The model, reasoning effort and account for each kind of work. Ryker uses the first " <>
          "model on each list, and the next only when the one above it hits a usage limit or " <>
          "its sign-in stops working. A change reaches new work within seconds."
    }

  defp page(:retention),
    do: %{
      title: "Data retention",
      description: "How many days Ryker keeps each kind of data before deleting it."
    }

  defp page(:report),
    do: %{
      title: "Weekly report",
      description:
        "Once a week Ryker can post a short update in a Slack channel, written the way a " <>
          "teammate would: the PRs it opened and merged, the ones waiting for review, how " <>
          "much it handled and how fast, what it cost, and what it is waiting on people for."
    }

  defp page(:access),
    do: %{
      title: "Access",
      description:
        "Who can open this console. Ryker's operators sign in from Slack; anyone else needs " <>
          "an invite from someone signed in."
    }

  defp page(:pricing),
    do: %{
      title: "Model prices",
      description:
        "What each model costs per million tokens. Ryker uses these to estimate cost when the provider does not report it."
    }

  # What a worker is comes first, because everything on the page is about
  # one. Only the Compose distribution has a worker set up for the reader.
  defp page(:system) do
    worker =
      "Ryker runs its work on a worker: a machine with your code checked out that runs the " <>
        "model and its tools."

    %{
      title: "Advanced",
      description:
        if BundledCoop.distribution?() do
          worker <>
            " The bundled worker on this host is set up for you; change these only if you " <>
            "run your own workers."
        else
          worker <>
            " This installation uses workers you run yourself; choose their install below. " <>
            "Ryker supplies the code and settings for each job."
        end
    }
  end
end
