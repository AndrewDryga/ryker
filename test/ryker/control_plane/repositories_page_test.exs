defmodule Ryker.ControlPlane.RepositoriesPageTest do
  @moduledoc """
  The Repositories list: one search box over Kit rows that say whether each
  repository is ready, still being set up, or needs a person and what to do,
  and where its RYKER.md stands, with the exact support facts in one closed
  Details disclosure per row.
  """
  use ExUnit.Case, async: true

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Pages, RepositoriesPage}

  @now ~U[2026-08-28 14:00:00Z]

  @repository %{
    channels: 2,
    environments: ["Production", "Staging"],
    configured: %{
      action_grants: ["merge_pull_request"],
      contributor_policy: "ryker-write",
      github_access: :available,
      github_bound: true,
      github_health: %{
        duplicate_count: 0,
        failed: 0,
        last_event_at: ~U[2026-08-28 13:00:00Z],
        pending: 0
      },
      github_permissions:
        Map.new(
          ~w(metadata contents pull_requests checks actions deployments issues),
          &{&1, "write"}
        ),
      github_repository: "acme/checkout-api",
      knowledge_pull_request_url: nil,
      knowledge_source_commit: String.duplicate("b", 40),
      knowledge_status: :accepted,
      onboarding_error: nil,
      onboarding_state: :ready,
      ref: "acme-checkout-api",
      updated_at: ~U[2026-08-28 13:56:00Z]
    },
    knowledge: %{
      phase: :idle,
      reason: "These files changed: README.md.",
      document_by: :model,
      document_commit: "783fc48" <> String.duplicate("0", 33),
      document_at: ~U[2026-08-28 13:00:00Z],
      published_at: ~U[2026-08-28 13:01:00Z],
      publication: :opened,
      pull_request_url: "https://github.com/acme/checkout-api/pull/84",
      pull_request_number: 84,
      pull_request_state: :merged,
      checked_at: ~U[2026-08-28 13:00:00Z],
      next_check_at: ~U[2026-08-29 13:00:00Z],
      error: nil
    },
    freshness: %{
      fetched_at: "2026-08-28T12:00:00Z",
      recorded_at: ~U[2026-08-28 12:01:00Z],
      remote_identity: "origin",
      requested_revision: "refs/heads/main",
      resolved_revision: "3f9a1c2e" <> String.duplicate("a", 32),
      stale_base_revision: nil,
      stale_base_status: "current",
      version: 2,
      workspace_base_revision: String.duplicate("a", 40)
    },
    publications: 1,
    ref: "acme-checkout-api",
    schedules: 1,
    sessions: 14
  }

  test "repositories are a search over Kit rows, never a comparison table" do
    # Before 2026-09-24 this was a six-column table of counts with the access
    # policy and a frozen freshness receipt in "details" rows under each one.
    document = render([@repository, %{@repository | ref: "emisar", configured: nil}])

    assert outline(document, "div.repositories-page > *") == [
             "p.kit-counts",
             "div.kit-toolbar",
             "div.entity-list"
           ]

    assert Enum.count(LazyHTML.query(document, "article.entity-row[role=listitem]")) == 2
    assert Enum.empty?(LazyHTML.query(document, "table, h1, h2, .result-count"))
    refute LazyHTML.text(document) =~ "Work policies"
    refute LazyHTML.text(document) =~ "ryker-write"
  end

  test "the page leads with how many repositories it lists, like every list page" do
    # QA, 2026-09-25: Repositories had no counts row while Environments said
    # "0 environments"; the list's size and what needs a person come first.
    needs = put_in(@repository, [:configured, :github_access], :removed)

    for {items, params, counts} <- [
          {[], %{}, ["0 repositories"]},
          {[@repository], %{}, ["1 repository"]},
          {[@repository, %{needs | ref: "acme/billing-api"}], %{},
           ["2 repositories", "1 needs attention"]},
          {[@repository], %{"q" => "checkout"}, ["1 matching"]}
        ] do
      document = render(items, params)

      assert document
             |> LazyHTML.query(".kit-counts .kit-count")
             |> Enum.map(&(&1 |> LazyHTML.text() |> squeeze())) == counts

      if counts |> List.last() |> String.ends_with?("attention") do
        assert LazyHTML.query(document, ".kit-count[data-tone=warn]") |> Enum.count() == 1
      end
    end
  end

  test "a ready repository names itself as owner/repo and says where it is used" do
    row = render([@repository]) |> LazyHTML.query("article.entity-row")

    assert LazyHTML.query(row, "h3.entity-name") |> LazyHTML.text() =~ "acme/checkout-api"
    assert state(row) == {"Ready", ["on"]}
    assert Enum.empty?(LazyHTML.query(row, "p.entity-text"))

    # Refreshing its RYKER.md and removing it are its actions, quiet, and
    # both only ask.
    assert row |> LazyHTML.query(".entity-actions .ui-button") |> Enum.map(&LazyHTML.text/1) ==
             ["Refresh knowledge of acme/checkout-api", "Remove acme/checkout-api"]

    assert LazyHTML.query(
             row,
             ".entity-actions button.quiet[phx-click=confirm-settings-action][phx-value-action=refresh-knowledge][phx-value-ref=acme-checkout-api]"
           )
           |> Enum.count() == 1

    assert LazyHTML.query(
             row,
             ".entity-actions button.quiet[phx-click=confirm-settings-action][phx-value-action=remove-repository][phx-value-ref=acme-checkout-api]"
           )
           |> Enum.count() == 1

    assert row |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze() ==
             "In Production, Staging · used in 2 channels and 1 schedule · 14 tasks · code from 3f9a1c2e, fetched 2 h ago · Knowledge updated 1 h ago · pull request #84"

    assert LazyHTML.query(row, "p.entity-meta strong") |> LazyHTML.text() == "3f9a1c2e"
  end

  test "each repository says which environments it is in, or that it is in none" do
    # Channels choose an environment, not a repository, so a repository in no
    # environment is code no channel's work can reach. The row says so rather
    # than leaving the person to find out from a channel that cannot read it.
    alone = %{@repository | environments: [], channels: 0, schedules: 0}
    row = render([alone]) |> LazyHTML.query("article.entity-row")

    assert row |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze() ==
             "In no environment yet · 14 tasks · code from 3f9a1c2e, fetched 2 h ago · Knowledge updated 1 h ago · pull request #84"
  end

  test "a repository still being set up says which step it is on and since when" do
    setting_up = put_in(@repository, [:configured, :onboarding_state], :cloning)
    row = render([setting_up]) |> LazyHTML.query("article.entity-row")

    assert state(row) == {"Setting up", ["busy"]}

    assert row |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze() ==
             "Copying the code · since 4 min ago"

    # Its RYKER.md comes once it is set up: nothing to refresh yet.
    assert Enum.empty?(LazyHTML.query(row, "button[phx-value-action=refresh-knowledge]"))
  end

  test "a repository that needs a person says what is wrong and exactly what to do" do
    removed = put_in(@repository, [:configured, :github_access], :removed)
    row = render([removed]) |> LazyHTML.query("article.entity-row")
    assert state(row) == {"Needs attention", ["warn"]}

    assert LazyHTML.query(row, "p.entity-text") |> LazyHTML.text() ==
             "GitHub access was removed. Give the Ryker GitHub App access to this repository again, then retry."

    # Retrying while access is gone could only fail, so it is not offered.
    assert Enum.empty?(LazyHTML.query(row, "button[phx-click=retry-github-onboarding]"))

    document =
      @repository
      |> put_in([:configured, :github_permissions], %{"metadata" => "read"})
      |> render()

    # Andrew, 2026-09-26, of "missing permission for deployments. Grant it in
    # the app's settings on GitHub": "completely unclear how to fix it". The
    # row names each permission with the level to set, where in GitHub that
    # is, and the approval GitHub then asks for on the installation.
    text = document |> LazyHTML.query("p.entity-text") |> LazyHTML.text() |> squeeze()

    assert text =~
             "The Ryker GitHub App cannot use this repository without Contents (Read and write) and Pull requests (Read and write)."

    assert text =~
             "In GitHub, open Settings › Developer settings › GitHub Apps, choose the Ryker app, and set them under Permissions & events."

    assert text =~
             "Then approve the new permissions where the app is installed (Settings › Applications › Installed GitHub Apps); Ryker sees the change on its own."

    assert state(LazyHTML.query(document, "article.entity-row")) == {"Needs attention", ["warn"]}
  end

  # Andrew's AndrewDryga/AndrewDryga read "Needs attention: the Ryker GitHub App
  # is missing permission for deployments" (2026-09-26), though deployments
  # only feed rules that watch deployments. A permission that turns on one
  # feature is a detail; only what the repository cannot work without needs a
  # person.
  test "a permission that only turns on one feature is a detail, not a problem" do
    document =
      @repository
      |> put_in(
        [:configured, :github_permissions],
        Map.new(~w(metadata contents pull_requests checks actions issues), &{&1, "write"})
      )
      |> render()

    row = LazyHTML.query(document, "article.entity-row")
    refute state(row) == {"Needs attention", ["warn"]}
    assert Enum.empty?(LazyHTML.query(row, "p.entity-text"))

    details = row |> LazyHTML.query("details") |> LazyHTML.text() |> squeeze()
    assert details =~ "Enough to work here. Not shared: deployments"
  end

  test "a blocked setup offers Retry setup on its row, bound to that repository" do
    blocked =
      @repository
      |> put_in([:configured, :onboarding_state], :blocked)
      |> put_in([:configured, :onboarding_error], "Cloning failed: repository is empty.")

    row = render([blocked]) |> LazyHTML.query("article.entity-row")
    assert state(row) == {"Needs attention", ["warn"]}

    assert LazyHTML.query(row, "p.entity-text") |> LazyHTML.text() ==
             "Setup stopped. Cloning failed: repository is empty. Fix the cause, then retry setup."

    retry =
      LazyHTML.query(
        row,
        ".entity-actions button.ui-button.secondary[phx-click=retry-github-onboarding][phx-value-repository=acme-checkout-api]"
      )

    assert LazyHTML.text(retry) == "Retry setup"
  end

  test "the support facts wait in one closed Details disclosure per row" do
    details = render([@repository]) |> LazyHTML.query("article.entity-row details:not([open])")
    assert Enum.count(details) == 1
    assert LazyHTML.query(details, "summary") |> LazyHTML.text() == "Details"

    text = details |> LazyHTML.text() |> squeeze()
    assert text =~ "acme/checkout-api · access available"
    assert text =~ "Written by a model from 783fc48; Work reads it as merged."
    assert text =~ "Pull request #84"
    assert text =~ "Last written because These files changed: README.md."
    assert text =~ "Last 1 h ago, next tomorrow 13:00 UTC"
    assert text =~ "Everything Ryker needs"
    assert text =~ "merge pull request"
    assert text =~ "Up to date"
    refute text =~ "tasks use ryker-write"
    assert text =~ "from refs/heads/main"
    assert text =~ "not a live check"
    assert text =~ "1 pull request opened by Ryker"

    assert LazyHTML.query(details, "a[href='/activity?repository=acme-checkout-api']")
           |> Enum.count() == 1
  end

  test "a repository Ryker only saw in past work is not ready, and invents no receipt or worker" do
    observed = %{@repository | configured: nil, freshness: nil, sessions: 0}
    row = render([observed]) |> LazyHTML.query("article.entity-row")

    assert LazyHTML.query(row, "h3.entity-name") |> LazyHTML.text() =~ "acme-checkout-api"
    assert state(row) == {"Not added", ["off"]}
    text = row |> LazyHTML.query("details") |> LazyHTML.text() |> squeeze()
    assert text =~ "None yet. It appears after Ryker's first task in this repository."
    refute text =~ "No worker reports this repository"
  end

  test "an empty list says how to add one, and a search miss says so" do
    bare = render([])

    assert LazyHTML.query(bare, ".kit-empty-title") |> LazyHTML.text() ==
             "No repositories yet"

    assert LazyHTML.query(bare, "form.filter-toolbar input[type=search][disabled]")
           |> Enum.count() == 1

    miss = render([], %{"q" => "absent"})

    assert LazyHTML.query(miss, ".kit-empty-title") |> LazyHTML.text() ==
             "No repositories match “absent”"
  end

  test "without a working GitHub App the page offers no Add repositories action" do
    # The header action and the import panel both led to "Repair the GitHub
    # connection first", beside the status line that already said so.
    page =
      Pages.page(["repositories"], %{}, %{
        projection: %{
          repositories: fn _params -> [] end,
          settings: fn -> {:ok, %{github_connection: :invalid}} end
        }
      })

    refute Map.has_key?(page, :action)

    assert LazyHTML.from_fragment(page.body)
           |> LazyHTML.query(".kit-empty")
           |> LazyHTML.text() =~ "Once GitHub is connected"
  end

  test "with GitHub working, the route carries the search and offers Add repositories as the page's one action" do
    parent = self()

    page =
      Pages.page(["repositories"], %{"q" => " checkout "}, %{
        projection: %{
          repositories: fn params ->
            send(parent, {:repositories, params})
            [@repository]
          end,
          settings: fn -> {:ok, %{github_connection: :ready}} end
        }
      })

    assert_received {:repositories, %{"q" => "checkout"}}
    assert page.title == "Repositories"
    assert page.description == "Code Ryker can read and work in."

    assert LazyHTML.from_fragment(page.body)
           |> LazyHTML.query("form.filter-toolbar input[name=q]")
           |> LazyHTML.attribute("value") == ["checkout"]

    action = LazyHTML.from_fragment(page.action)

    assert LazyHTML.query(action, "a.ui-button.primary[href='/repositories/new']")
           |> LazyHTML.text() == "Add repositories"

    refute page.body =~ "Publishing settings"
  end

  # AndrewDryga/andrewdryga.github.com was saved without its GitHub binding
  # when an import failed half-way (2026-09-26), and its row read "Setup
  # stopped: GitHub binding is missing" with a Retry that stopped there again.
  test "a repository whose adding stopped half-way reads Not fully added, with Add it again" do
    half =
      @repository
      |> put_in([:configured, :github_bound], false)
      |> put_in([:configured, :github_permissions], nil)
      |> put_in([:configured, :onboarding_state], :blocked)
      |> put_in([:configured, :onboarding_error], "GitHub binding is missing.")

    document = render([half])
    row = LazyHTML.query(document, "article.entity-row")

    assert state(row) == {"Not fully added", ["warn"]}

    assert LazyHTML.query(row, "p.entity-text") |> LazyHTML.text() ==
             "Adding it stopped before it finished, so Ryker cannot use it yet. Add it again, or remove it."

    refute LazyHTML.text(row) =~ "binding"
    assert Enum.empty?(LazyHTML.query(row, "button[phx-click=retry-github-onboarding]"))

    assert LazyHTML.query(
             row,
             ".entity-actions button.secondary[phx-click=add-repository-again][phx-value-repository=acme-checkout-api]"
           )
           |> LazyHTML.text() == "Add it again"

    assert LazyHTML.query(row, "button[phx-value-action=remove-repository]") |> Enum.count() == 1

    assert document |> LazyHTML.query(".kit-count[data-tone=warn]") |> LazyHTML.text() =~
             "needs attention"
  end

  # A reason that already says how to go on is not followed by a second
  # instruction (2026-09-27: an archived repository's setup read "Unarchive it
  # on GitHub and retry, or remove it. Fix the cause, then retry setup.").
  test "a stopped setup whose reason says what to do reads as one instruction, with Retry and Remove" do
    stopped =
      @repository
      |> put_in([:configured, :onboarding_state], :blocked)
      |> put_in(
        [:configured, :onboarding_error],
        "Repository setup could not finish. Check GitHub access and retry."
      )

    row = render([stopped]) |> LazyHTML.query("article.entity-row")
    assert state(row) == {"Needs attention", ["warn"]}

    assert LazyHTML.query(row, "p.entity-text") |> LazyHTML.text() ==
             "Setup stopped. Repository setup could not finish. Check GitHub access and retry."

    assert row |> LazyHTML.query(".entity-actions .ui-button") |> Enum.map(&LazyHTML.text/1) ==
             ["Retry setup", "Remove acme/checkout-api"]
  end

  # Andrew, 2026-09-27: "also when those are updated?" The row says when
  # Ryker last updated RYKER.md and links its pull request, or says what is
  # under way, or why the last step failed, in plain words.
  test "a ready repository says where its RYKER.md stands" do
    for {knowledge, meta} <- [
          {%{pull_request_state: :open}, "Knowledge updated 1 h ago · open pull request #84"},
          {%{phase: :write}, "Writing RYKER.md"},
          {%{phase: :publish}, "Writing RYKER.md"},
          {%{document_by: :outline}, "Outline written 1 h ago · pull request #84"},
          {%{published_at: nil}, "RYKER.md not proposed yet"}
        ] do
      row =
        @repository
        |> update_in([:knowledge], &Map.merge(&1, knowledge))
        |> render_row()

      assert row |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze() =~
               "fetched 2 h ago · " <> meta
    end

    fresh = render_row(%{@repository | knowledge: nil})

    assert fresh |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze() =~
             "· RYKER.md not written yet"

    # The link opens the pull request on GitHub.
    assert @repository
           |> render_row()
           |> LazyHTML.query(
             "p.entity-meta a[href='https://github.com/acme/checkout-api/pull/84'][target=_blank]"
           )
           |> LazyHTML.text() == "pull request #84"

    # While a model writes it, it cannot be asked for again.
    writing = @repository |> put_in([:knowledge, :phase], :write) |> render_row()
    assert Enum.empty?(LazyHTML.query(writing, "button[phx-value-action=refresh-knowledge]"))
  end

  test "a failed RYKER.md step says why on the row, and the repository stays ready" do
    error =
      "The repository is archived on GitHub, so Ryker cannot propose its RYKER.md. " <>
        "Unarchive it on GitHub, then refresh knowledge."

    row = @repository |> put_in([:knowledge, :error], error) |> render_row()

    assert state(row) == {"Ready", ["on"]}
    assert LazyHTML.query(row, "p.entity-text") |> LazyHTML.text() == error

    # A problem that needs a person comes first.
    removed =
      @repository
      |> put_in([:knowledge, :error], error)
      |> put_in([:configured, :github_access], :removed)
      |> render_row()

    assert LazyHTML.query(removed, "p.entity-text") |> LazyHTML.text() =~
             "GitHub access was removed"
  end

  test "refreshing knowledge asks what it does before a model reads the repository" do
    assert RepositoriesPage.refresh_question(@repository) == %{
             title: "Refresh knowledge of acme/checkout-api?",
             text:
               "A model reads the repository again now and Ryker rewrites RYKER.md from what " <>
                 "it finds, checking every path and command against the code. If the new " <>
                 "version says something the default branch does not, Ryker proposes it in a " <>
                 "pull request, or updates the one already open."
           }
  end

  # Andrew, 2026-09-27: "how do I remove repositories?!"
  test "removing a repository asks what it does, and history Ryker only saw cannot be removed" do
    assert RepositoriesPage.removal(@repository) == %{
             title: "Remove acme/checkout-api?",
             text:
               "Work in Production and Staging can no longer use its code. Schedules that " <>
                 "work in it stop running. Ryker deletes the copy of its code it keeps. Past " <>
                 "requests stay, and you can add it again later."
           }

    setting_up = put_in(@repository, [:configured, :onboarding_state], :cloning)

    assert RepositoriesPage.removal(%{setting_up | environments: [], schedules: 0}).text ==
             "Its setup stops, and Ryker deletes the copy of its code it keeps. Past requests " <>
               "stay, and you can add it again later."

    observed = %{@repository | configured: nil}

    assert render([observed])
           |> LazyHTML.query("button[phx-value-action=remove-repository]")
           |> Enum.empty?()
  end

  test "the GitHub line says what the GitHub page says and where to change it" do
    # It said "GitHub needs repair. Ryker cannot read repositories…" while the
    # GitHub page said "Needs repair. The saved App ID or private key no
    # longer works." (QA, 2026-09-25). Both read Integrations now.
    for {github_connection, enabled, words, link, href} <- [
          {:ready, true, "GitHub Connected App ryker-acme · 1 repository", "Manage",
           "/integrations/github"},
          # Add repositories is the list's own action; the line opens GitHub's
          # page instead of offering it a second time.
          {:ready, false,
           "GitHub Add a repository to start The App is verified. Ryker starts GitHub work once a repository is added.",
           "Manage", "/integrations/github"},
          {:invalid, true, "GitHub Needs repair The saved App ID or private key no longer works.",
           "Repair GitHub", "/integrations/github#github-app"},
          {:missing, false,
           "GitHub Not connected Ryker cannot read your code or open pull requests until you connect it.",
           "Connect GitHub", "/integrations/github"}
        ] do
      view = %{
        github_connection: github_connection,
        readiness: %{left_out: %{}},
        snapshot: %{github: %{app_slug: "ryker-acme", enabled: enabled}, repositories: [%{}]}
      }

      line = github_line({:ok, view})
      assert line |> LazyHTML.query("p") |> LazyHTML.text() |> squeeze() == words
      assert LazyHTML.query(line, "a[href='#{href}']") |> LazyHTML.text() == link
    end

    assert github_line({:error, :settings_not_initialized})
           |> LazyHTML.query(".state-word")
           |> LazyHTML.text() == "Not connected"

    assert github_line({:error, :settings_unavailable}) |> LazyHTML.query("p") |> LazyHTML.text() =~
             "unknown, because settings could not be read"
  end

  defp github_line(settings) do
    %{__changed__: nil, settings: settings}
    |> RepositoriesPage.github_status()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
  end

  defp state(row) do
    state = LazyHTML.query(row, ".entity-side .state-word")
    {LazyHTML.text(state), LazyHTML.attribute(state, "data-tone")}
  end

  defp render(items, params \\ %{}) do
    %{items: List.wrap(items), view: RepositoriesPage.view(params), now: @now}
    |> RepositoriesPage.html()
    |> LazyHTML.from_fragment()
  end

  defp render_row(item), do: [item] |> render() |> LazyHTML.query("article.entity-row")

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # "tag.first-class" for each matched element, in document order.
  defp outline(document, selector) do
    nodes = LazyHTML.query(document, selector)

    nodes
    |> LazyHTML.tag()
    |> Enum.zip(LazyHTML.attributes(nodes))
    |> Enum.map(fn {tag, attributes} ->
      case List.keyfind(attributes, "class", 0) do
        {"class", class} -> tag <> "." <> hd(String.split(class))
        nil -> tag
      end
    end)
  end
end
