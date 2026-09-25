defmodule Ryker.ControlPlane.SetupPageTest do
  @moduledoc """
  Onboarding at /setup and the Integrations overview, rendered from settings
  views built here: what counts as done comes from `SettingsView`, and these
  pages only decide what a person sees next.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Integrations, SettingsPage, SettingsView, SetupPage}

  @steps [:slack, :github, :repositories, :invited, :channel_environment, :request]

  test "setup's open step is the first unfinished one, even when a later step is already done" do
    # Ryker notices an invitation on its own, so a channel can be done before
    # GitHub is. The page must still open GitHub, the first step not done, and
    # keep the later step's check rather than skipping ahead to it.
    view = view(done: [:slack, :invited])

    assert Enum.map(SetupPage.steps(view), &{&1.key, &1.status}) == [
             slack: :done,
             github: :current,
             repositories: :later,
             invited: :done,
             channel_environment: :later,
             request: :later
           ]

    document = render_setup(view)

    assert LazyHTML.query(document, "ol.setup-steps > li") |> Enum.count() == 6

    current = LazyHTML.query(document, "ol.setup-steps > li[aria-current=step]")
    assert Enum.count(current) == 1
    assert LazyHTML.query(current, "h3") |> LazyHTML.text() == "Connect GitHub"

    assert LazyHTML.query(document, "#setup-progress-text") |> text() =~
             "2 of 6 required steps done · 1 recommended · about 10 minutes left"
  end

  test "only the open step offers an action, and it leads to where that step is done" do
    for {done, label, href} <- [
          {[], "Connect Slack", "/integrations/slack"},
          {[:slack], "Connect GitHub", "/integrations/github"},
          {[:slack, :github], "Add repositories", "/repositories"}
        ] do
      document = render_setup(view(done: done))

      actions = LazyHTML.query(document, "ol.setup-steps a.ui-button")
      assert Enum.count(actions) == 1, label
      assert LazyHTML.text(actions) == label
      assert LazyHTML.attribute(actions, "href") == [href]

      assert LazyHTML.query(document, "li[aria-current=step] a.ui-button.primary") |> Enum.count() ==
               1
    end
  end

  test "a done step folds to one line that names what got connected" do
    view =
      view(
        done: [:slack, :github, :repositories],
        slack: %{workspace_name: "Acme", bot_name: "ryker"},
        app_slug: "ryker-acme",
        repositories: [%{ref: "api", display_name: "acme/api"}]
      )

    lines =
      render_setup(view)
      |> LazyHTML.query("li[data-state=done] .setup-step-line")
      |> Enum.map(&text/1)

    assert lines == [
             "Done: Slack · Acme as @ryker",
             "Done: GitHub · App ryker-acme",
             "Done: Repositories · acme/api"
           ]
  end

  test "a step Ryker notices by itself says so and opens Slack instead of asking for a click" do
    # Inviting Ryker and the first reply happen in Slack. A "Mark as done"
    # button would prove nothing. The channel's environment is chosen on the
    # channel's own page, so that step leads there.
    channel = %{
      workspace_ref: "T0123456789",
      channel_ref: "C0123456789",
      environment_ref: nil,
      environment_name: nil
    }

    view =
      view(
        done: [:slack, :github, :repositories],
        slack: %{workspace_url: "https://acme.slack.com/", bot_name: "ryker"}
      )

    current = render_setup(view) |> LazyHTML.query("li[aria-current=step]")
    assert LazyHTML.query(current, "h3") |> LazyHTML.text() == "Invite Ryker to a channel"
    assert LazyHTML.query(current, ".setup-command code") |> LazyHTML.text() == "/invite @ryker"
    assert text(current) =~ "Ryker notices on its own"

    open = LazyHTML.query(current, "a.ui-button.primary[target=_blank]")
    assert LazyHTML.attribute(open, "href") == ["https://acme.slack.com/"]

    view =
      view(
        done: [:slack, :github, :repositories, :invited],
        slack: %{workspace_url: "https://acme.slack.com/", bot_name: "ryker"},
        channel: channel
      )

    current = render_setup(view) |> LazyHTML.query("li[aria-current=step]")
    assert LazyHTML.query(current, "h3") |> LazyHTML.text() == "Choose the channel's environment"
    assert text(current) =~ "Choose it on the channel's page in Ryker"
    assert text(current) =~ "press Customize on Ryker's welcome message"

    assert LazyHTML.query(current, "a.ui-button.primary") |> LazyHTML.attribute("href") ==
             ["/channels/T0123456789/C0123456789"]

    view =
      view(
        done: [:slack, :github, :repositories, :invited, :channel_environment],
        slack: %{workspace_url: "https://acme.slack.com/", bot_name: "ryker"},
        channel: %{channel | environment_ref: "production", environment_name: "Production"}
      )

    document = render_setup(view)

    assert document
           |> LazyHTML.query("li[data-state=done] .setup-step-line")
           |> Enum.map(&text/1)
           |> List.last() =~ "Done: Channel environment · "

    assert document |> LazyHTML.query("li[data-state=done]") |> text() =~ "works in Production"

    current = LazyHTML.query(document, "li[aria-current=step]")

    assert LazyHTML.query(current, "a.ui-button.primary") |> LazyHTML.attribute("href") ==
             ["https://acme.slack.com/archives/C0123456789"]
  end

  test "setup says adding a repository creates the Default environment, so it asks for none" do
    # Environments replaced repository groups on 2026-09-25. Importing a
    # repository puts it in the default environment and creates "Default"
    # when there is none, so an extra step would ask for something already
    # done; the step that adds repositories says so instead.
    assert SettingsView.setup_steps() == @steps

    current =
      render_setup(view(done: [:slack, :github])) |> LazyHTML.query("li[aria-current=step]")

    assert LazyHTML.query(current, "h3") |> LazyHTML.text() == "Add repositories"
    assert text(current) =~ "Each one joins the Default environment, which Ryker creates for you."
  end

  test "Emisar is offered as a recommended step with its own action and never blocks ready" do
    # "Optional: Connect Emisar for governed approvals." was one quiet line
    # under the checklist. Andrew, 2026-09-24: "yes it's optional but without
    # it ryker is way more limited so we really need to push users to connect
    # it". It has its own panel and primary action, counted apart from the six.
    refute :emisar in SettingsView.setup_steps()

    for done <- [[], @steps] do
      document = render_setup(view(done: done, complete: done == @steps))
      panel = LazyHTML.query(document, "#connect-emisar")

      assert LazyHTML.query(panel, "h2") |> LazyHTML.text() == "Connect Emisar"
      assert LazyHTML.query(panel, ".entity-tag") |> LazyHTML.text() == "Recommended"
      assert text(panel) =~ "it cannot act on anything that is running"

      assert LazyHTML.query(panel, "a.ui-button.primary[href='/integrations/emisar']")
             |> LazyHTML.text() == "Connect Emisar"
    end

    # Six segments for the required steps and one apart for Emisar.
    started = render_setup(view(done: []))
    assert LazyHTML.query(started, ".setup-meter > span") |> Enum.count() == 7
    assert LazyHTML.query(started, ".setup-meter > .setup-meter-extra") |> Enum.count() == 1

    ready = render_setup(view(done: @steps, complete: true))
    assert LazyHTML.query(ready, ".setup-ready h2") |> LazyHTML.text() == "Ryker is ready"
    assert Enum.empty?(LazyHTML.query(ready, "li[aria-current=step], #setup-progress-text"))
    assert LazyHTML.query(ready, "ol.setup-steps > li[data-state=done]") |> Enum.count() == 6

    assert LazyHTML.query(ready, ".setup-ready a") |> LazyHTML.attribute("href") ==
             ["/conversations", "/channels"]
  end

  test "a connected Emisar that no work can use says what is still missing" do
    # Connecting an account turns approval monitoring on and gives it to the
    # environments that have none, but either can be undone later: monitoring
    # turned off, no environment left with the account, the account paused.
    # Each state says the one thing missing.
    account = %{
      ref: "production",
      display_name: "Production approvals",
      enabled_for_new_work: true,
      monitoring_enabled: false
    }

    without = %{ref: "production", display_name: "Production", emisar_connection_ref: nil}
    using = %{without | emisar_connection_ref: "production"}

    for {accounts, environments, status, word, missing} <- [
          {[], [], :not_connected, "Not connected", nil},
          {[account], [without], :unfinished, "Not in use yet", "approval monitoring"},
          {[%{account | monitoring_enabled: true}], [without], :unfinished, "Not in use yet",
           "Give an environment this account"},
          {[account], [using], :unfinished, "Not in use yet", "Turn on approval monitoring"},
          {[%{account | enabled_for_new_work: false}], [using], :paused, "Paused", "paused"},
          {[%{account | monitoring_enabled: true}], [using], :ready, "Connected", nil}
        ] do
      emisar = Integrations.emisar(view(emisar: accounts, environments: environments))
      assert {emisar.status, elem(emisar.state, 1)} == {status, word}
      if missing, do: assert(emisar.text =~ missing), else: assert(is_nil(emisar.text))
    end

    ready =
      render_setup(view(emisar: [%{account | monitoring_enabled: true}], environments: [using]))

    panel = LazyHTML.query(ready, ".setup-emisar[data-state=ready]")
    assert text(panel) =~ "Production approvals"
    refute text(panel) =~ "without an Emisar account"
    assert Enum.empty?(LazyHTML.query(ready, "#connect-emisar"))
  end

  # Work in an environment without an account records no approvals at all.
  # Routes used to hide that behind "Connected"; the count of environments
  # without an account, with the way to fix it, replaces the unrouted
  # repositories the page counted before 2026-09-25.
  test "a connected Emisar counts the environments that have no account" do
    account = %{
      ref: "production",
      display_name: "Production approvals",
      enabled_for_new_work: true,
      monitoring_enabled: true
    }

    environments = [
      %{ref: "production", display_name: "Production", emisar_connection_ref: "production"},
      %{ref: "staging", display_name: "Staging", emisar_connection_ref: nil}
    ]

    view = view(emisar: [account], environments: environments)
    emisar = Integrations.emisar(view)

    assert {emisar.status, emisar.state} == {:ready, {:on, "Connected"}}
    assert emisar.facts == ["Production approvals"]
    assert emisar.unassigned == 1

    panel = render_setup(view) |> LazyHTML.query(".setup-emisar[data-state=ready]")
    assert text(panel) =~ "Production approvals · 1 environment without an Emisar account"

    assert LazyHTML.query(panel, "a[href='/environments']") |> LazyHTML.text() ==
             "1 environment without an Emisar account"

    overview =
      render_component(&SettingsPage.render/1,
        view: {:ok, view},
        commands: %{},
        section: :integrations
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(overview, "#integration-emisar .entity-meta") |> text() ==
             "Production approvals · 1 environment without an Emisar account"
  end

  test "connecting an Emisar account says which environments use it now" do
    # Connecting used to say only "Emisar account is connected." while the
    # routes it created stayed out of sight. The first account is given to
    # every environment without one and a later one to none, so the outcome
    # names where approvals now go, or that the account still has to be chosen.
    assert Integrations.emisar_connected(["Production"]) ==
             "Emisar account is connected. Production uses it now."

    assert Integrations.emisar_connected(["Production", "Staging", "Ops chat"]) ==
             "Emisar account is connected. Production, Staging and Ops chat use it now."

    assert Integrations.emisar_connected([]) ==
             "Emisar account is connected. No environment uses it yet: choose it for one on the Environments page."
  end

  test "each integration says its state, what it gives Ryker and the one action that fits" do
    view =
      view(
        done: [:slack],
        slack: %{workspace_name: "Acme", bot_name: "ryker", operators: ["U1", "U2"]},
        github_connection: :invalid
      )

    document =
      render_component(&SettingsPage.render/1,
        view: {:ok, view},
        commands: %{},
        section: :integrations
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, "h1") |> LazyHTML.text() == "Integrations"
    rows = LazyHTML.query(document, ".integrations-list .entity-row")

    assert Enum.map(rows, &(LazyHTML.query(&1, ".entity-name a") |> LazyHTML.text())) ==
             ["Slack", "GitHub", "Emisar", "Webhooks"]

    expected = [
      {"slack", "Connected", "Manage", "/integrations/slack", "Acme · @ryker · 2 people"},
      {"github", "Needs repair", "Repair", "/integrations/github#github-app", "no longer works"},
      {"emisar", "Not connected", "Connect", "/integrations/emisar",
       "cannot act on anything that is running"},
      {"webhooks", "Not set up", "Set up", "/integrations/webhooks", nil}
    ]

    for {key, word, label, href, fact} <- expected do
      row = LazyHTML.query(document, "#integration-#{key}")
      assert LazyHTML.query(row, ".state-word") |> LazyHTML.text() == word, key
      assert LazyHTML.query(row, ".entity-text") |> LazyHTML.text() != "", key

      action = LazyHTML.query(row, ".entity-actions a")
      assert action |> LazyHTML.text() |> String.trim() |> String.starts_with?(label), key
      assert LazyHTML.attribute(action, "href") == [href], key
      if fact, do: assert(LazyHTML.query(row, ".entity-meta") |> text() =~ fact, key)
    end

    # Emisar is optional, so it is the one integration marked Recommended, and
    # its Connect is the page's one primary action.
    assert LazyHTML.query(document, ".entity-tag") |> Enum.map(&LazyHTML.text/1) == [
             "Recommended"
           ]

    assert LazyHTML.query(document, "#integration-emisar .entity-tag") |> Enum.count() == 1

    assert LazyHTML.query(document, ".integrations-list a.ui-button.primary")
           |> LazyHTML.attribute("href") == ["/integrations/emisar"]
  end

  defp render_setup(view) do
    render_component(&SettingsPage.render/1, view: {:ok, view}, commands: %{}, section: :setup)
    |> LazyHTML.from_fragment()
  end

  defp text(node), do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  # A settings view with only what these pages read. `done` names the
  # required steps that are done, exactly as SettingsView reports them.
  defp view(options) do
    done = Keyword.get(options, :done, [])
    slack = Map.merge(slack(:slack in done), Keyword.get(options, :slack, %{}))

    github_connection =
      Keyword.get(options, :github_connection, if(:github in done, do: :ready, else: :missing))

    %{
      application: :applied,
      credentials:
        if(:slack in done,
          do:
            for(
              kind <- [:slack_app, :slack_bot],
              do: %{kind: kind, verification_status: :verified}
            ),
          else: []
        ),
      github_connection: github_connection,
      readiness: %{slack: %{state: :ready, title: "Slack is ready", detail: ""}},
      snapshot: %{
        slack: slack,
        github: %{
          enabled: :repositories in done,
          app_slug: Keyword.get(options, :app_slug, "ryker-acme")
        },
        repositories:
          Keyword.get(
            options,
            :repositories,
            if(:repositories in done, do: [%{ref: "api", display_name: nil}], else: [])
          ),
        environments: Keyword.get(options, :environments, []),
        emisar_connections: Keyword.get(options, :emisar, []),
        webhook_sources: []
      },
      setup: %{
        steps: Map.new(@steps, &{&1, &1 in done}),
        invited_channels: if(:invited in done, do: 1, else: 0),
        configured_channels: if(:channel_environment in done, do: 1, else: 0),
        successful_request: :request in done,
        channel: Keyword.get(options, :channel),
        complete: Keyword.get(options, :complete, false)
      }
    }
  end

  defp slack(connected) do
    %{
      enabled: connected,
      workspace_ref: if(connected, do: "T0123456789"),
      workspace_name: if(connected, do: "Acme"),
      workspace_url: nil,
      bot_name: if(connected, do: "ryker"),
      operators: if(connected, do: ["U1"], else: [])
    }
  end
end
