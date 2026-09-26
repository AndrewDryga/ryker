defmodule Ryker.ControlPlane.ManageConnectionsLiveTest do
  @moduledoc """
  The live shell around the Channels and Repositories lists: the one line
  that says whether Slack or GitHub is connected, the Add repositories panel
  and the outcome of what was done in it. Channel defaults and publishing
  settings live on the Slack and GitHub integration pages now, not in a
  disclosure under these lists.
  """
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection, RepositoryImport}
  alias Ryker.Settings

  @endpoint Endpoint
  @actor "control-plane:local"

  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub.Server,
       live_view: [signing_salt: "manage-connections-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    {:ok, snapshot} = Settings.initialize(@actor)
    %{snapshot: snapshot}
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
    refute has_element?(view, ".page-action a[href='#add-repositories']")
    refute has_element?(view, "details#add-repositories")
    refute has_element?(view, "details.area-settings")
  end

  test "an import's outcome is said inside the Add repositories panel" do
    # Until 2026-09-24 the result of an import ("2 added · 0 already present
    # · 0 failed") was assigned and never rendered on this page: people
    # pressed Add and saw nothing happen, whether it had worked or not.
    view = %{
      github_connection: :ready,
      snapshot: %{repositories: [], github: %{auto_add_repositories: false}}
    }

    for {tone, message, role} <- [
          {:error, "Connection could not be verified.", "alert"},
          {:info, "No repositories were selected.", "status"}
        ] do
      document =
        render_component(&RepositoryImport.repository_import/1,
          view: view,
          repositories: [],
          notice: {tone, message}
        )
        |> LazyHTML.from_fragment()

      assert document
             |> LazyHTML.query(
               "details#add-repositories #repository-import-notice.form-feedback-#{tone}[role=#{role}]"
             )
             |> LazyHTML.text() =~ message
    end
  end

  # Andrew, 2026-09-26: 37 repositories started ticked, so choosing 5 meant
  # unticking 32, and "Add all 37" beside his 5 read as a wrong count.
  # Selection itself is test/js/repository_picker_test.mjs; this pins what the
  # server draws before the hook runs.
  test "the repository picker starts with nothing ticked and counts what it will add" do
    view = %{
      github_connection: :ready,
      snapshot: %{repositories: [], github: %{auto_add_repositories: false}}
    }

    repositories =
      for {name, id, present} <- [
            {"acme/api", 1, false},
            {"acme/web", 2, true},
            {"acme/docs", 3, false}
          ] do
        %{full_name: name, repository_id: id, default_branch: "main", already_present: present}
      end

    picker =
      render_component(&RepositoryImport.repository_import/1,
        view: view,
        repositories: repositories
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

  test "adding repositories says they join the default environment" do
    # Channels choose environments, not repositories, since 2026-09-25. An
    # imported repository joins the default environment (Ryker creates
    # "Default" when there is none), which is what makes it usable at once;
    # the panel says so rather than leaving people to look for a channel
    # setting that no longer exists.
    view = %{
      github_connection: :ready,
      snapshot: %{repositories: [], github: %{auto_add_repositories: false}}
    }

    lede =
      render_component(&RepositoryImport.repository_import/1, view: view, repositories: [])
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".repository-import-lede")
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

    assert lede =~ "Each one joins the default environment, where new channels work."
  end

  test "a retry that cannot run says why at the top of the list" do
    {:ok, view, _html} = open("/repositories")
    render_hook(view, "retry-github-onboarding", %{"repository" => "no-such-repository"})

    assert has_element?(
             view,
             "#repository-retry-notice.form-feedback-error[role=alert]",
             "That repository is no longer added."
           )

    refute has_element?(view, "#repository-import-notice")
  end

  defp open(path), do: live(build_conn() |> Map.put(:host, "localhost"), path)
end
