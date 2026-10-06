defmodule Ryker.ControlPlane.ManageConnectionsLiveTest do
  @moduledoc """
  The live shell around the Channels and Repositories lists: the one line
  that says whether Slack or GitHub is connected; Add repositories, a page of
  its own that lists what the GitHub App reaches when it opens and again on
  Refresh; and what a repository's row can do: retry its setup, finish an
  add that stopped half-way, have its RYKER.md written again, and remove it
  after a question over the list.
  Channel defaults and publishing settings live on the Slack and GitHub
  integration pages, not in a disclosure under these lists.
  """
  use Ryker.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Actions, Endpoint, Projection, RepositoryImport}
  alias Ryker.{Credentials, IntegrationSetup, RepositoryKnowledge, Settings}

  @endpoint Endpoint
  @actor "control-plane:local"

  setup do
    # What the GitHub App reaches, as Add repositories and Add it again ask
    # for it, with how many times they asked. A held answer waits until the
    # test that holds it gives one.
    github = start_supervised!({Agent, fn -> %{asked: 0, answer: {:ok, []}} end})

    actions =
      Map.put(Actions.callbacks(), :github_repositories, fn ->
        case Agent.get_and_update(github, &{&1.answer, %{&1 | asked: &1.asked + 1}}) do
          {:held, test} ->
            send(test, {:listing, self()})

            receive do
              {:answer, answer} -> answer
            end

          answer ->
            answer
        end
      end)

    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub.Server,
       live_view: [signing_salt: "manage-connections-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: actions,
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    {:ok, snapshot} = Settings.initialize(@actor)
    %{snapshot: snapshot, github: github}
  end

  test "the Channels page says whether Slack is connected, and its defaults live in Integrations" do
    {:ok, view, _html} = open("/channels")

    assert has_element?(view, "#slack-status strong", "Slack")
    assert has_element?(view, "#slack-status .state-word[data-tone=off]", "Not connected")
    assert has_element?(view, "#slack-status a[href='/integrations/slack']", "Connect Slack")
    refute has_element?(view, "#new-channels-default")
    refute has_element?(view, ".page-action")
    refute has_element?(view, "details.area-settings")
  end

  test "the Repositories page says whether GitHub is connected, and publishing lives in Integrations" do
    {:ok, view, _html} = open("/repositories")

    assert has_element?(view, "#github-status strong", "GitHub")
    assert has_element?(view, "#github-status .state-word[data-tone=off]", "Not connected")
    assert has_element?(view, "#github-status a[href='/integrations/github']", "Connect GitHub")

    # Adding repositories needs the App: until it works, the status line is
    # the one way forward, with no second prompt beside it.
    refute has_element?(view, "a[href='/repositories/new']")
    refute has_element?(view, "#add-repositories")
    refute has_element?(view, "details.area-settings")

    # The page of the form says the same, rather than an empty form, and asks
    # GitHub nothing.
    {:ok, view, _html} = open("/repositories/new")
    assert has_element?(view, "#github-status a[href='/integrations/github']", "Connect GitHub")
    refute has_element?(view, "#add-repositories")
    refute has_element?(view, "button[phx-click=refresh-github-repositories]")
  end

  # Andrew, 2026-09-27: "what is the point to show two add repositories
  # buttons here?" The header and the GitHub line each offered it, and the
  # page it opened listed nothing until Find repositories was pressed.
  test "the Repositories page offers Add repositories once, and it opens its own page" do
    connect_github!()
    {:ok, view, _html} = open("/repositories")

    main = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("main")
    assert main |> LazyHTML.query("a[href='/repositories/new']") |> Enum.count() == 1

    # The GitHub line still says a repository is needed, and opens GitHub's
    # page rather than a second way to add one.
    assert has_element?(view, "#github-status", "Add a repository to start")
    assert has_element?(view, "#github-status a[href='/integrations/github']", "Manage")

    view |> element(".page-action a", "Add repositories") |> render_click()
    assert_patch(view, "/repositories/new")

    assert has_element?(view, "main h1", "Add repositories")
    assert has_element?(view, "nav.kit-back a[href='/repositories']", "All repositories")

    assert has_element?(
             view,
             "main .page-description",
             "Work uses one once you choose it in an environment."
           )

    refute has_element?(view, "[phx-click=discover-github-repositories]")
    refute has_element?(view, ".entity-list")
    refute has_element?(view, "#operator-search")
  end

  # Andrew, 2026-09-27: "add repositories can be separate page so it's not
  # below table and you can load list of repos on load and have button to
  # refresh the list when needed."
  test "Add repositories lists what the GitHub App reaches when it opens, and again on Refresh",
       %{github: github} do
    connect_github!()
    answer!(github, [repository("acme/api", 11), repository("acme/web", 12, true)])

    {:ok, view, _html} = open("/repositories/new")
    render_async(view)

    assert has_element?(view, "#repository-picker li[data-repository-name='acme/api']")

    assert has_element?(
             view,
             "#repository-picker li[data-repository-name='acme/web'] input[disabled]"
           )

    assert has_element?(view, "#repository-picker li", "Already added")
    assert asked(github) == 1

    # Given access to another repository, the App lists it after a Refresh.
    answer!(github, [
      repository("acme/api", 11),
      repository("acme/docs", 13),
      repository("acme/web", 12, true)
    ])

    view |> element(".page-action button", "Refresh") |> render_click()
    render_async(view)

    assert has_element?(view, "#repository-picker li[data-repository-name='acme/docs']")
    assert asked(github) == 2
  end

  test "an App that lists nothing, or cannot be asked, says so on the Add page", %{github: github} do
    connect_github!()

    {:ok, view, _html} = open("/repositories/new")
    render_async(view)
    assert has_element?(view, "#repository-discovery-empty", "No repositories found")

    Agent.update(github, &%{&1 | answer: {:error, {:github_verification_failed, :installations}}})
    view |> element(".page-action button", "Refresh") |> render_click()
    render_async(view)

    assert has_element?(view, ".repository-discovery-error .form-feedback-error")
    refute has_element?(view, "#repository-picker")
  end

  # Leaving Add repositories while GitHub was still answering, then coming
  # back, started a second listing beside the first, which went on asking
  # GitHub for an answer nothing would read.
  test "coming back to Add repositories gives up the listing the last visit left under way",
       %{github: github} do
    connect_github!()
    test = self()
    Agent.update(github, &%{&1 | answer: {:held, test}})

    {:ok, view, _html} = open("/repositories/new")
    assert_receive {:listing, first}
    watch = Process.monitor(first)

    render_patch(view, "/repositories")
    render_patch(view, "/repositories/new")

    assert_receive {:DOWN, ^watch, :process, ^first, _given_up}
    assert_receive {:listing, second}

    send(second, {:answer, {:ok, [repository("acme/api", 11)]}})
    render_async(view)
    assert has_element?(view, "#repository-picker li[data-repository-name='acme/api']")
  end

  # A listing given up with no new one after it, because GitHub was
  # disconnected meanwhile, must not read as "Ryker could not list the
  # repositories": the page would then never list them once GitHub is back.
  test "a listing given up with none after it is not a failed listing", %{github: github} do
    connect_github!()
    test = self()
    Agent.update(github, &%{&1 | answer: {:held, test}})

    {:ok, view, _html} = open("/repositories/new")
    assert_receive {:listing, first}
    watch = Process.monitor(first)

    render_patch(view, "/repositories")
    {:ok, _disconnected} = IntegrationSetup.disconnect(:github, "control-plane:local")
    render_patch(view, "/repositories/new")
    assert_receive {:DOWN, ^watch, :process, ^first, _given_up}

    connect_github!()
    assert_receive {:listing, second}, 1_000

    send(second, {:answer, {:ok, [repository("acme/api", 11)]}})
    render_async(view)
    assert has_element?(view, "#repository-picker li[data-repository-name='acme/api']")
  end

  # Andrew, 2026-09-27, of every add form opened in place over a list: "it
  # blends into the content". An import that adds what was chosen returns to
  # the list, which says where the repositories went; one that adds nothing
  # stays on the page and says why.
  test "adding repositories goes back to the list, which says where they went", %{github: github} do
    connect_github!()
    answer!(github, [repository("acme/api", 11), repository("acme/docs", 13)])

    {:ok, view, _html} = open("/repositories/new")
    render_async(view)

    render_hook(view, "import-github-repositories", %{"import_mode" => "selected"})

    assert has_element?(
             view,
             ".kit-form-card #repository-import-notice[role=status]",
             "No repositories were selected."
           )

    view
    |> form("#repository-picker", %{"repository_ids" => ["11"]})
    |> render_submit(%{"import_mode" => "selected"})

    assert_patch(view, "/repositories")

    assert has_element?(
             view,
             "#repository-notice.form-feedback-success",
             "Added 1 repository. Choose it in an environment so work can use it."
           )

    assert has_element?(view, "#repository-acme-api")
    refute has_element?(view, "#repository-acme-docs")
    refute has_element?(view, "#repository-import-notice")
  end

  test "an import's outcome is said inside the Add repositories form" do
    # Until 2026-09-24 the result of an import ("2 added · 0 already present
    # · 0 failed") was assigned and never rendered on this page: people
    # pressed Add and saw nothing happen, whether it had worked or not.
    for {tone, message, role} <- [
          {:error, "Connection could not be verified.", "alert"},
          {:info, "No repositories were selected.", "status"}
        ] do
      document =
        render_component(&RepositoryImport.repository_import/1,
          view: ready_view(),
          repositories: [],
          discovery: :complete,
          notice: {tone, message}
        )
        |> LazyHTML.from_fragment()

      assert document
             |> LazyHTML.query(
               "#add-repositories #repository-import-notice.form-feedback-#{tone}[role=#{role}]"
             )
             |> LazyHTML.text() =~ message
    end
  end

  # Andrew, 2026-09-26: 37 repositories started ticked, so choosing 5 meant
  # unticking 32, and "Add all 37" beside his 5 read as a wrong count.
  # Selection itself is test/js/repository_picker_test.mjs; this pins what the
  # server draws before the hook runs.
  test "the repository picker starts with nothing ticked and counts what it will add" do
    picker =
      render_component(&RepositoryImport.repository_import/1,
        view: ready_view(),
        repositories: [
          repository("acme/api", 1),
          repository("acme/web", 2, true),
          repository("acme/docs", 3)
        ],
        discovery: :complete
      )
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("form#repository-picker[phx-hook=RepositoryPicker]")

    assert Enum.empty?(LazyHTML.query(picker, "input[name='repository_ids[]'][checked]"))

    assert LazyHTML.query(picker, "button[data-repository-select=all]") |> LazyHTML.text() =~
             "Select all shown"

    assert LazyHTML.query(picker, "button[data-repository-select=none]") |> LazyHTML.text() =~
             "Select none"

    add_selected = LazyHTML.query(picker, "button[data-repository-add-selected][disabled]")
    assert LazyHTML.text(add_selected) =~ "Add 0 selected"
    assert LazyHTML.query(picker, "button[value=all]") |> LazyHTML.text() =~ "Add all 2"
  end

  test "a retry that cannot run says why at the top of the list" do
    {:ok, view, _html} = open("/repositories")
    render_hook(view, "retry-github-onboarding", %{"repository" => "no-such-repository"})

    assert has_element?(
             view,
             "#repository-notice.form-feedback-error[role=alert]",
             "That repository is no longer added."
           )

    refute has_element?(view, "#repository-import-notice")
  end

  # Andrew, 2026-09-27: "how do I remove repositories?!", and 2026-09-28:
  # "repos missing their own page where that buttons will move to". Remove
  # is the last card on the repository's page, and asks over it.
  test "a repository is removed from its page only after the question is answered" do
    connect_github!()

    {:ok, %{added: ["acme/api", "acme/web"]}} =
      IntegrationSetup.import_github_repositories(
        [
          repository("acme/api", 11),
          repository("acme/web", 12)
        ],
        "control-plane:local"
      )

    {:ok, _snapshot} =
      Settings.put_environment(
        %{
          ref: "default",
          display_name: "Default",
          is_default: true,
          repositories: ["acme-api", "acme-web"]
        },
        Settings.fetch!().installation.revision,
        @actor
      )

    {:ok, view, _html} = open("/repositories")
    refute has_element?(view, "#repository-acme-api button")

    {:ok, view, _html} = open("/repositories/acme-api")
    remove = "#remove-repository button[phx-value-action=remove-repository]"
    view |> element(remove, "Remove repository") |> render_click()

    question = "#confirm-remove-repository"
    assert has_element?(view, "#{question} .kit-modal-title", "Remove acme/api?")

    assert has_element?(
             view,
             "#{question} .kit-modal-text",
             "Work in Default can no longer use its code."
           )

    assert Enum.map(Settings.fetch!().repositories, & &1.ref) == ["acme-api", "acme-web"]

    # Cancel closes it and removes nothing.
    view |> element("#{question} button", "Cancel") |> render_click()
    refute has_element?(view, question)
    assert Enum.map(Settings.fetch!().repositories, & &1.ref) == ["acme-api", "acme-web"]

    view |> element(remove, "Remove repository") |> render_click()
    view |> element("#{question} button", "Remove repository") |> render_click()

    # Its page is gone, so the removal returns to the list, which says so.
    assert_patch(view, "/repositories")
    refute has_element?(view, question)

    assert has_element?(
             view,
             "#repository-notice.form-feedback-success",
             "Removed acme/api. Its past requests stay in Activity."
           )

    refute has_element?(view, "#repository-acme-api")
    assert Enum.map(Settings.fetch!().repositories, & &1.ref) == ["acme-web"]

    # A remove that was never asked about only asks.
    render_click(view, "remove-repository", %{"repository" => "acme-web"})
    assert has_element?(view, "#{question} .kit-modal-title", "Remove acme/web?")
    assert Enum.map(Settings.fetch!().repositories, & &1.ref) == ["acme-web"]
  end

  # The question read the repository from the whole list searched for its
  # ref, and the list stops at a hundred. A repository whose ref is part of
  # more than a hundred other refs fell off the end, so its Remove answered
  # "That repository is no longer added." about a repository that was. The
  # question reads the one repository it asks about.
  test "a repository's question finds it however many other refs contain its own" do
    connect_github!()

    {:ok, %{added: ["acme/api"]}} =
      IntegrationSetup.import_github_repositories(
        [repository("acme/api", 11)],
        "control-plane:local"
      )

    {:ok, _snapshot} =
      Settings.put_repository(%{ref: "acme-api", onboarding_state: :ready}, :current, @actor)

    now = DateTime.utc_now()

    Repo.insert_all(
      Settings.Repository,
      for(index <- 1..100, do: %{ref: "a-acme-api-#{index}", inserted_at: now, updated_at: now})
    )

    {:ok, view, _html} = open("/repositories/acme-api")

    view
    |> element("#remove-repository button[phx-value-action=remove-repository]")
    |> render_click()

    assert has_element?(view, "#confirm-remove-repository .kit-modal-title", "Remove acme/api?")
    refute has_element?(view, "#repository-notice")

    view |> element("#confirm-remove-repository button", "Cancel") |> render_click()

    view
    |> element("#repository-knowledge button[phx-value-action=refresh-knowledge]")
    |> render_click()

    assert has_element?(
             view,
             "#confirm-refresh-knowledge .kit-modal-title",
             "Refresh knowledge of acme/api?"
           )
  end

  # Andrew, 2026-09-27: RYKER.md was written once, at setup, and never
  # again. Refresh knowledge has a model read the repository again now, after
  # a question over the list that says what it does.
  test "Refresh knowledge asks first, then has RYKER.md written again" do
    connect_github!()

    {:ok, %{added: ["acme/api"]}} =
      IntegrationSetup.import_github_repositories(
        [repository("acme/api", 11)],
        "control-plane:local"
      )

    {:ok, _snapshot} =
      Settings.put_repository(%{ref: "acme-api", onboarding_state: :ready}, :current, @actor)

    {:ok, view, _html} = open("/repositories/acme-api")
    button = "#repository-knowledge button[phx-value-action=refresh-knowledge]"
    question = "#confirm-refresh-knowledge"

    view |> element(button, "Refresh knowledge") |> render_click()
    assert has_element?(view, "#{question} .kit-modal-title", "Refresh knowledge of acme/api?")

    assert has_element?(
             view,
             "#{question} .kit-modal-text",
             "A model reads the repository again now"
           )

    # Cancel closes it and asks for nothing.
    view |> element("#{question} button", "Cancel") |> render_click()
    refute has_element?(view, question)
    assert RepositoryKnowledge.entry("acme-api") == nil

    view |> element(button, "Refresh knowledge") |> render_click()
    view |> element("#{question} button", "Refresh knowledge") |> render_click()

    refute has_element?(view, question)

    assert has_element?(
             view,
             "#repository-notice.form-feedback-success",
             "Ryker is reading acme/api again to rewrite its knowledge."
           )

    entry = RepositoryKnowledge.entry("acme-api")
    assert {entry.phase, entry.requested_by} == {:write, @actor}

    # While it is written, the page says so and it cannot be asked again.
    assert has_element?(view, "#repository-knowledge", "being rewritten now")
    refute has_element?(view, button)

    # A refresh never asked about only asks.
    render_click(view, "refresh-knowledge", %{"repository" => "acme-api"})
    assert has_element?(view, "#{question} .kit-modal-title", "Refresh knowledge of acme/api?")
  end

  # Approving was granted wherever the App could write pull requests and could
  # not be turned off (2026-10-04 review). It is the repository's own choice,
  # made on its page after a question that says what an approval can do.
  test "Allow approvals asks first, then lets Ryker's reviews approve until Stop approvals" do
    connect_github!()

    {:ok, %{added: ["acme/api"]}} =
      IntegrationSetup.import_github_repositories(
        [repository("acme/api", 11)],
        "control-plane:local"
      )

    {:ok, view, _html} = open("/repositories/acme-api")
    question = "#confirm-approvals"
    approvals_allowed? = fn -> hd(Settings.fetch!().github_bindings).approvals_allowed end

    assert has_element?(view, "#repository-github", "do not approve")
    view |> element("#repository-github button", "Allow approvals") |> render_click()

    assert has_element?(
             view,
             "#{question} .kit-modal-title",
             "Let Ryker approve pull requests in acme/api?"
           )

    assert has_element?(view, "#{question} .kit-modal-text", "stand in for a person's")

    # Cancel closes it and changes nothing.
    view |> element("#{question} button", "Cancel") |> render_click()
    refute has_element?(view, question)
    refute approvals_allowed?.()

    view |> element("#repository-github button", "Allow approvals") |> render_click()
    view |> element("#{question} button", "Allow approvals") |> render_click()
    refute has_element?(view, question)
    assert approvals_allowed?.()

    assert has_element?(
             view,
             "#repository-notice.form-feedback-success",
             "Ryker's reviews may now approve pull requests in acme/api."
           )

    assert has_element?(view, "#repository-github", "may approve pull requests here")

    view |> element("#repository-github button", "Stop approvals") |> render_click()
    view |> element("#{question} button", "Stop approvals") |> render_click()
    refute approvals_allowed?.()

    # A change never asked about only asks.
    render_click(view, "allow-approvals", %{"repository" => "acme-api"})

    assert has_element?(
             view,
             "#{question} .kit-modal-title",
             "Let Ryker approve pull requests in acme/api?"
           )

    refute approvals_allowed?.()
  end

  test "a removal that would leave an environment nothing to change says why in its question" do
    connect_github!()

    {:ok, %{added: ["acme/api", "acme/docs"]}} =
      IntegrationSetup.import_github_repositories(
        [
          repository("acme/api", 11),
          repository("acme/docs", 13)
        ],
        "control-plane:local"
      )

    {:ok, _snapshot} =
      Settings.put_environment(
        %{
          ref: "default",
          display_name: "Default",
          is_default: true,
          repositories: ["acme-api", "acme-docs"],
          access: %{"acme-docs" => :read_only}
        },
        Settings.fetch!().installation.revision,
        @actor
      )

    {:ok, view, _html} = open("/repositories/acme-api")

    view
    |> element("#remove-repository button[phx-value-action=remove-repository]")
    |> render_click()

    view
    |> element("#confirm-remove-repository button", "Remove repository")
    |> render_click()

    assert has_element?(
             view,
             "#confirm-remove-repository .form-feedback-error",
             "Work in Default can change only this repository."
           )

    assert Enum.map(Settings.fetch!().repositories, & &1.ref) == ["acme-api", "acme-docs"]
  end

  # AndrewDryga/andrewdryga.github.com was saved without its GitHub binding
  # on 2026-09-26 and read "GitHub binding is missing" with a Retry that
  # stopped at the same place every time.
  test "a repository whose adding stopped half-way is finished with Add it again",
       %{github: github} do
    connect_github!()

    {:ok, _snapshot} =
      Settings.put_repository(
        %{
          ref: "acme-site",
          display_name: "acme/site",
          github_repository: "acme/site",
          onboarding_state: :blocked,
          onboarding_error: "GitHub binding is missing."
        },
        Settings.fetch!().installation.revision,
        @actor
      )

    answer!(github, [repository("acme/site", 31)])
    {:ok, view, _html} = open("/repositories")

    row = "#repository-acme-site"
    assert has_element?(view, "#{row} .state-word[data-tone=warn]", "Not fully added")
    assert has_element?(view, "#{row} .entity-text", "Add it again, or remove it.")

    {:ok, view, _html} = open("/repositories/acme-site")
    attention = "#repository-attention"
    assert has_element?(view, "#{attention} h2", "What to do")
    refute has_element?(view, "button[phx-click=retry-github-onboarding]")
    assert has_element?(view, "#remove-repository button", "Remove repository")

    view
    |> element("#{attention} button[phx-click=add-repository-again]", "Add it again")
    |> render_click()

    assert has_element?(
             view,
             "#repository-notice.form-feedback-success",
             "Added 1 repository. Choose it in an environment so work can use it."
           )

    # Finished, its setup starts over instead of reading as stopped.
    assert has_element?(view, "#repository-state .state-word", "Setting up")
    refute has_element?(view, attention)
    assert [%{repository_ref: "acme-site"}] = Settings.fetch!().github_bindings
  end

  defp open(path), do: live(build_conn() |> Map.put(:host, "localhost"), path)

  defp answer!(github, repositories),
    do: Agent.update(github, &%{&1 | answer: {:ok, repositories}})

  defp asked(github), do: Agent.get(github, & &1.asked)

  defp repository(full_name, id, present \\ false) do
    %{
      already_present: present,
      default_branch: "main",
      full_name: full_name,
      installation_id: 41,
      permissions: %{"contents" => "write", "metadata" => "read", "pull_requests" => "write"},
      repository_id: id
    }
  end

  defp ready_view,
    do: %{
      github_connection: :ready,
      snapshot: %{repositories: [], github: %{auto_add_repositories: false}}
    }

  # A verified GitHub App as Connect leaves it before any repository is added.
  defp connect_github! do
    key = :public_key.generate_key({:rsa, 2_048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    snapshot = Settings.fetch!()

    {:ok, _snapshot} =
      Settings.save_github(
        %{app_id: 1_234, app_slug: "ryker-acme", bot_actor_id: 99, bot_login: "ryker-acme[bot]"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, _} = Credentials.put(:github_private_key, "primary", pem, @actor)
    {:ok, _} = Credentials.verify(:github_private_key, "primary", :verified, @actor)

    {:ok, _} =
      Credentials.put(:github_webhook, "primary", "test-webhook-secret-long-enough", @actor)

    {:ok, _} = Credentials.verify(:github_webhook, "primary", :verified, @actor)
    :ok
  end
end
