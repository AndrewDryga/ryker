defmodule Ryker.ControlPlane.EnvironmentsLiveTest do
  @moduledoc """
  Environments at /environments. Andrew, 2026-09-25: "We need something
  called Environment. You connect repos, emisar, gh, etc to each of those,
  and channels select environments, not a specific repo." The page is where a
  person sees what each environment holds and who uses it, and changes it.
  """
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Credentials
  alias Ryker.Settings

  @endpoint Endpoint
  @actor "control-plane:local"

  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub,
       live_view: [signing_salt: "environments-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    :ok
  end

  test "the Environments page lists each environment with its repositories, Emisar account and channels" do
    # Channels used to name one repository each, and Emisar accounts were
    # bound to repositories through routes nobody could see from a channel.
    # An environment now holds both, so its row has to say what it holds and
    # who depends on it before anyone changes it.
    installation!()
    environment!("production", "Production", ~w(api docs), emisar: "approvals", default: true)
    environment!("staging", "Staging", ~w(api), description: "Pre-release checks")
    environment!("ops", "Ops chat", [])
    channel_in!("CPAY", "production")
    channel_in!("CINFRA", "production")
    channel_in!("CSTAGE", "staging")

    {:ok, view, html} = open("/environments")
    document = LazyHTML.from_document(html)

    assert LazyHTML.query(document, "main h1") |> LazyHTML.text() == "Environments"

    assert LazyHTML.query(document, "main .page-description") |> LazyHTML.text() ==
             "Where Ryker works: the repositories and integrations each channel or conversation uses."

    rows = LazyHTML.query(document, ".entity-list[aria-label=Environments] > .entity-row")

    # The default comes first; the rest follow by name.
    assert Enum.map(rows, &(LazyHTML.query(&1, ".entity-name a") |> text())) ==
             ["Production", "Ops chat", "Staging"]

    production = LazyHTML.query(document, "#environment-production")

    assert LazyHTML.query(production, ".entity-name a") |> LazyHTML.attribute("href") ==
             ["/environments?edit=production"]

    assert LazyHTML.query(production, ".entity-tag") |> LazyHTML.text() == "Default"
    assert LazyHTML.query(production, ".entity-icon") |> Enum.count() == 1

    # Every repository is there to work in, and a task picks the one it
    # changes; the first is only the default, so the row says so.
    assert LazyHTML.query(production, ".entity-meta") |> text() ==
             "2 repositories · default acme/api · Emisar: Production approvals · Used by 2 channels"

    assert LazyHTML.query(document, "#environment-staging .entity-text") |> text() ==
             "Pre-release checks"

    assert LazyHTML.query(document, "#environment-staging .entity-meta") |> text() ==
             "1 repository · default acme/api · No Emisar account · Used by 1 channel"

    assert LazyHTML.query(document, "#environment-ops .entity-meta") |> text() ==
             "No repositories · No Emisar account · Not used by any channel yet"

    # The default cannot be made the default again; every other row can.
    refute has_element?(
             view,
             "#environment-production button[phx-click=make-default-environment]"
           )

    assert has_element?(
             view,
             "#environment-staging button[phx-click=make-default-environment]",
             "Use as default"
           )

    for ref <- ~w(production staging ops) do
      assert has_element?(view, "#environment-#{ref} .entity-actions a", "Edit")

      assert has_element?(
               view,
               "#environment-#{ref} button[phx-value-action=delete-environment]",
               "Remove"
             )
    end

    # A list page's search sits in the one Kit toolbar row; its count leads
    # the page as a Kit count, never a second number in the toolbar.
    assert has_element?(view, ".kit-toolbar > .filter-toolbar input[name=q]")
    assert has_element?(view, ".environments-page > .kit-counts .kit-count", "3 environments")
    refute has_element?(view, ".kit-toolbar-count")

    assert has_element?(
             view,
             ".page-action a[href='/environments?edit=new']",
             "Add an environment"
           )

    view |> element("#environment-staging button", "Use as default") |> render_click()

    assert has_element?(
             view,
             ".form-feedback-success",
             "Staging is the default environment now."
           )

    assert %{ref: "staging"} = Settings.Environment.default(Settings.fetch!())
  end

  # Andrew, 2026-09-25: "One place for counts." The page leads with how many
  # environments there are and how many channels chose none, so work there
  # runs without code; a search narrows the first count to what matches.
  test "the Environments page leads with its environments and the channels that chose none" do
    installation!()
    environment!("production", "Production", ~w(api), default: true)
    environment!("staging", "Staging", ~w(api))
    channel_in!("CPAY", "production")
    channel_in!("CQUIET", nil)
    channel_in!("CHUSH", nil)

    {:ok, _view, html} = open("/environments")

    assert counts(html) == [
             {"2 environments", nil},
             {"2 channels without an environment", "/channels"}
           ]

    {:ok, _view, html} = open("/environments?q=stag")
    assert [{"1 matching", nil} | _channels] = counts(html)
  end

  defp counts(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(".environments-page > .kit-counts > .kit-count")
    |> Enum.map(&{text(&1), &1 |> LazyHTML.attribute("href") |> List.first()})
  end

  test "an installation without environments says the real first step toward one" do
    # QA, 2026-09-25: the empty page said "Adding a repository creates the
    # Default environment" while Repositories could add nothing until GitHub
    # was repaired. The first step is the one GitHub's state says it is.
    installation!()
    {:ok, view, _html} = open("/environments")

    assert has_element?(view, ".entity-empty-title", "No environments yet")

    assert has_element?(
             view,
             ".entity-empty",
             "Connect GitHub, then add a repository: Ryker creates the Default environment for it."
           )

    assert has_element?(view, ".entity-empty a[href='/integrations/github']", "Connect GitHub")

    for kind <- [:github_private_key, :github_webhook] do
      {:ok, _} = Credentials.put(kind, "primary", "not-a-working-key-long-enough", @actor)
    end

    {:ok, view, _html} = open("/environments")

    assert has_element?(
             view,
             ".entity-empty",
             "Repair the GitHub connection, then add a repository: Ryker creates the Default environment for it."
           )

    assert has_element?(
             view,
             ".entity-empty a[href='/integrations/github#github-app']",
             "Repair GitHub"
           )

    assert has_element?(
             view,
             ".page-action a[href='/environments?edit=new']",
             "Add an environment"
           )

    # Adding the first one opens its form where the empty list was.
    view |> element(".page-action a", "Add an environment") |> render_click()
    assert has_element?(view, "#environment-editor-new")
    refute has_element?(view, ".entity-empty")
  end

  test "an address for an environment that is gone says so above the list" do
    # QA, 2026-09-25: /environments?edit=<a ref nobody has> quietly showed the
    # list, as if the link had worked.
    installation!()
    environment!("production", "Production", ~w(api), default: true)

    {:ok, view, _html} = open("/environments?edit=staging")

    assert has_element?(
             view,
             "#environment-not-found",
             "That environment was not found. It may have been removed."
           )

    assert has_element?(view, "#environment-production")
    refute has_element?(view, "[id^=environment-editor]")

    {:ok, view, _html} = open("/environments?edit=production")
    refute has_element?(view, "#environment-not-found")
  end

  test "removing an environment channels use is refused and says who uses it" do
    # The settings guard refused such a removal with a reason only a log
    # could read; the page has to name who still depends on the environment
    # so the person knows what to change first.
    installation!()
    environment!("production", "Production", ~w(api), default: true)
    environment!("staging", "Staging", ~w(api))
    environment!("scratch", "Scratch", [])
    channel_in!("CSTAGE", "staging")
    channel_in!("CSTAGE2", "staging")
    channel_in!("CQA", "staging")
    webhook_source_in!("alerts", "staging")

    {:ok, view, _html} = open("/environments")

    view |> element("#environment-staging button", "Remove") |> render_click()
    assert has_element?(view, "#environment-staging .settings-confirm", "Remove Staging?")
    assert Enum.any?(Settings.fetch!().environments, &(&1.ref == "staging"))

    view
    |> element("#environment-staging .settings-confirm button", "Remove environment")
    |> render_click()

    assert has_element?(
             view,
             ".form-feedback-error",
             "Staging is used by 3 channels and 1 webhook source. Change them first."
           )

    assert Enum.any?(Settings.fetch!().environments, &(&1.ref == "staging"))

    view |> element("#environment-scratch button", "Remove") |> render_click()

    view
    |> element("#environment-scratch .settings-confirm button", "Remove environment")
    |> render_click()

    assert has_element?(view, ".form-feedback-success", "Scratch was removed.")
    refute Enum.any?(Settings.fetch!().environments, &(&1.ref == "scratch"))
    refute has_element?(view, "#environment-scratch")
  end

  test "Add an environment opens its form above the list, and Edit opens under its row" do
    # Andrew, 2026-09-25, of Model prices and every list like it: an Add
    # button at the top that opens its form under the whole list reads as a
    # button that does nothing.
    installation!()
    environment!("production", "Production", ~w(api), default: true)
    environment!("staging", "Staging", ~w(api))
    {:ok, view, _html} = open("/environments")

    add = ".page-action a"
    assert has_element?(view, "#{add}[href='/environments?edit=new'][aria-expanded=false]")

    view |> element(add, "Add an environment") |> render_click()
    assert_patch(view, "/environments?edit=new")

    assert has_element?(view, ".environments-page > #environment-editor-new ~ .entity-list")
    refute has_element?(view, ".environments-page > .entity-list ~ #environment-editor-new")

    # The same button closes it again.
    assert has_element?(view, "#{add}[href='/environments'][aria-expanded=true]")
    view |> element(add, "Add an environment") |> render_click()
    assert_patch(view, "/environments")
    refute has_element?(view, "#environment-editor-new")

    view |> element("#environment-staging .entity-actions a", "Edit") |> render_click()
    assert has_element?(view, "#environment-staging .entity-meta ~ #environment-editor-staging")
    refute has_element?(view, ".environments-page > [id^=environment-editor]")
  end

  test "an environment's repositories are saved in the order shown, and the first is the default" do
    # Every repository in an environment is there to work in, and a task
    # picks the one it changes; the first is only the default. Until
    # 2026-09-25 the editor said changes went to the first and the others
    # were read only, which stopped being true when tasks began choosing.
    installation!()
    environment!("production", "Production", ~w(api), default: true)

    {:ok, view, _html} = open("/environments?edit=new")
    assert has_element?(view, "#environment-editor-new h3", "Add an environment")

    assert has_element?(
             view,
             "#environment-editor-new .settings-help",
             "Every repository here is available to work in this environment. " <>
               "The first one is the default; a task picks the one it changes."
           )

    view
    |> form("#environment-editor-new form",
      environment: %{
        display_name: "Staging",
        description: "",
        repositories: ["", "api", "docs"],
        emisar_connection_ref: "approvals",
        is_default: "false"
      }
    )
    |> render_change()

    assert has_element?(view, "#environment-editor-new li[data-repository=api] small", "Default")
    refute has_element?(view, "#environment-editor-new li[data-repository=docs] small")

    for words <- ["Changes go", "Read only"],
        do: refute(has_element?(view, "#environment-editor-new", words))

    view
    |> element("#environment-editor-new li[data-repository=docs] button[phx-value-direction=up]")
    |> render_click()

    assert has_element?(view, "#environment-editor-new li[data-repository=docs] small", "Default")
    refute has_element?(view, "#environment-editor-new li[data-repository=api] small")

    view |> form("#environment-editor-new form") |> render_submit()

    assert has_element?(view, ".form-feedback-success", "Staging was saved.")
    refute has_element?(view, "#environment-editor-new")

    staging = Enum.find(Settings.fetch!().environments, &(&1.display_name == "Staging"))
    assert staging.ref == "staging"
    assert Settings.Environment.repository_refs(staging) == ["docs", "api"]
    assert staging.emisar_connection_ref == "approvals"
    refute staging.is_default
  end

  test "a refused environment keeps the draft and says what to fix in words" do
    installation!()
    environment!("production", "Production", ~w(api), default: true)

    {:ok, view, _html} = open("/environments?edit=production")

    view
    |> form("#environment-editor-production form",
      environment: %{display_name: "", repositories: ["", "api", "docs"], is_default: "true"}
    )
    |> render_submit()

    assert has_element?(
             view,
             "#environment-editor-production .form-feedback-error",
             "Give the environment a name."
           )

    # The refused draft is still on the page, as typed.
    assert has_element?(
             view,
             "#environment-editor-production input[value=''][name='environment[display_name]']"
           )

    assert has_element?(
             view,
             "#environment-editor-production li[data-repository=api] + li[data-repository=docs]"
           )

    assert has_element?(
             view,
             "#environment-editor-production li[data-repository=api] small",
             "Default"
           )

    assert %{display_name: "Production"} =
             production = Settings.Environment.default(Settings.fetch!())

    assert Settings.Environment.repository_refs(production) == ["api"]

    # Manual testing, 2026-09-26: a second "Production" was saved beside the first.
    {:ok, view, _html} = open("/environments?edit=new")

    view
    |> form("#environment-editor-new form",
      environment: %{display_name: "production", repositories: ["", "api"]}
    )
    |> render_submit()

    assert has_element?(
             view,
             "#environment-editor-new .form-feedback-error",
             "Another environment already has this name. Choose a different one."
           )
  end

  test "a repository work cannot open beside the others is refused in words, the default too" do
    # A task picks which of an environment's repositories it changes, so any
    # of them, the default included, may be opened beside another under its
    # own name. The refusal used to say only the ones after the first had to
    # fit, and to move the misfit first, which no longer helps.
    installation!()

    {:ok, _snapshot} =
      Settings.put_repository(
        %{ref: "primary", display_name: "acme/primary", github_repository: "acme/primary"},
        Settings.fetch!().installation.revision,
        @actor
      )

    {:ok, view, _html} = open("/environments?edit=new")

    view
    |> form("#environment-editor-new form",
      environment: %{display_name: "Mixed", repositories: ["", "primary", "api"]}
    )
    |> render_change()

    view |> form("#environment-editor-new form") |> render_submit()

    assert has_element?(
             view,
             "#environment-editor-new .form-feedback-error",
             "With more than one repository, each name has to be up to 48 lowercase letters, " <>
               "numbers, dashes or underscores, so Ryker can open it beside the others."
           )

    refute Enum.any?(Settings.fetch!().environments, &(&1.display_name == "Mixed"))
  end

  defp open(path), do: live(build_conn() |> Map.put(:host, "localhost"), path)

  defp text(node), do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp installation! do
    {:ok, snapshot} = Settings.initialize(@actor)

    {:ok, snapshot} =
      Settings.put_repository(
        %{ref: "api", display_name: "acme/api", github_repository: "acme/api"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, snapshot} =
      Settings.put_repository(
        %{ref: "docs", display_name: "acme/docs", github_repository: "acme/docs"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, snapshot} =
      Settings.put_emisar_connection(
        %{
          ref: "approvals",
          display_name: "Production approvals",
          rpc_url: "https://emisar.example/api/mcp/rpc",
          account_ref: "account-production",
          enabled_for_new_work: true,
          monitoring_enabled: true,
          verified_at: ~U[2026-09-19 12:00:00.000000Z]
        },
        snapshot.installation.revision,
        @actor
      )

    snapshot
  end

  defp environment!(ref, name, repositories, options \\ []) do
    snapshot = Settings.fetch!()

    {:ok, snapshot} =
      Settings.put_environment(
        %{
          ref: ref,
          display_name: name,
          description: Keyword.get(options, :description),
          repositories: repositories,
          emisar_connection_ref: Keyword.get(options, :emisar),
          is_default: Keyword.get(options, :default, false)
        },
        snapshot.installation.revision,
        @actor
      )

    snapshot
  end

  # The channel's own setting row, written the way the Slack setup saves it.
  # Only the environment matters here.
  defp channel_in!(channel, environment) do
    Repo.query!(
      "INSERT INTO slack_channel_configurations " <>
        "(id, workspace_ref, channel_ref, environment_ref, alert_policy, saved_at, inserted_at, updated_at) " <>
        "VALUES ($1, 'T123', $2, $3, 'reply', now(), now(), now())",
      [Ecto.UUID.dump!(Ecto.UUID.generate()), channel, environment]
    )
  end

  defp webhook_source_in!(name, environment) do
    snapshot = Settings.fetch!()

    {:ok, _snapshot} =
      Settings.put_webhook_source(
        %{
          name: name,
          adapter_kind: :universal,
          auth_kind: :hmac_sha256,
          secret_name: "alertmanager",
          destination_transport: "slack",
          destination_conversation_ref: "slack:T123:CALERTS",
          environment_ref: environment
        },
        snapshot.installation.revision,
        @actor
      )
  end
end
