defmodule Ryker.ControlPlane.RepositoriesPageTest do
  @moduledoc """
  The Repositories list: one search box over Kit rows that say whether each
  repository is ready, still being set up, or needs a person and what to do,
  and where its knowledge stands. Each row opens the repository's own page,
  which holds its buttons and every fact in cards.
  """
  use ExUnit.Case, async: true

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Pages, RepositoriesPage}

  @now ~U[2026-08-28 14:00:00Z]

  @repository %{
    channels: 2,
    environments: ["Production", "Staging"],
    in_environments: [
      %{ref: "production", name: "Production"},
      %{ref: "staging", name: "Staging"}
    ],
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

    # Andrew, 2026-09-28: "same here http://127.0.0.1:4321/repositories but
    # repos missing their own page where that buttons will move to". The
    # whole row opens the repository's page; the row has no buttons and no
    # Details disclosure of its own.
    assert LazyHTML.attribute(row, "class") |> hd() =~ "entity-row-link"

    assert LazyHTML.query(row, "h3.entity-name a") |> LazyHTML.attribute("href") ==
             ["/repositories/acme-checkout-api"]

    assert Enum.empty?(LazyHTML.query(row, "button, details, .entity-actions"))

    assert row |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze() ==
             "In Production, Staging · used in 2 channels and 1 schedule · 14 tasks · code from 3f9a1c2e, fetched 2 h ago · Knowledge updated 1 h ago"

    assert LazyHTML.query(row, "p.entity-meta strong") |> LazyHTML.text() == "3f9a1c2e"
  end

  test "each repository says which environments it is in, or that it is in none" do
    # Channels choose an environment, not a repository, so a repository in no
    # environment is code no channel's work can reach. The row says so rather
    # than leaving the person to find out from a channel that cannot read it.
    alone = %{@repository | environments: [], channels: 0, schedules: 0}
    row = render([alone]) |> LazyHTML.query("article.entity-row")

    assert row |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze() ==
             "In no environment yet · 14 tasks · code from 3f9a1c2e, fetched 2 h ago · Knowledge updated 1 h ago"
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

    github =
      @repository
      |> put_in(
        [:configured, :github_permissions],
        Map.new(~w(metadata contents pull_requests checks actions issues), &{&1, "write"})
      )
      |> detail()
      |> LazyHTML.query("#repository-github")

    assert github |> LazyHTML.text() |> squeeze() =~
             "Permissions Enough to work here. Not shared: deployments"
  end

  test "a blocked setup offers Retry setup on its page, bound to that repository" do
    blocked =
      @repository
      |> put_in([:configured, :onboarding_state], :blocked)
      |> put_in([:configured, :onboarding_error], "Cloning failed: repository is empty.")

    row = render([blocked]) |> LazyHTML.query("article.entity-row")
    assert state(row) == {"Needs attention", ["warn"]}

    assert LazyHTML.query(row, "p.entity-text") |> LazyHTML.text() ==
             "Setup stopped. Cloning failed: repository is empty. Fix the cause, then retry setup."

    # What needs a person comes first on the page, with the button that fixes it.
    attention = blocked |> detail() |> LazyHTML.query("#repository-attention")
    assert LazyHTML.query(attention, "h2") |> LazyHTML.text() == "What to do"

    assert LazyHTML.query(attention, ".section-head p") |> LazyHTML.text() ==
             "Setup stopped. Cloning failed: repository is empty. Fix the cause, then retry setup."

    retry =
      LazyHTML.query(
        attention,
        "button.ui-button.primary[phx-click=retry-github-onboarding][phx-value-repository=acme-checkout-api]"
      )

    assert LazyHTML.text(retry) == "Retry setup"
  end

  # Andrew, 2026-09-28, of the closed Details under every row: the "ugly
  # collapsible" content belongs on the repository's own page. Each part of it
  # is a card there, in the order it matters, and removing it comes last. The
  # knowledge, how it was written and where it is used are parts of one card
  # (Andrew, 2026-10-04: "we should merge Knowledge How it was written Where it
  # is used into one section").
  test "a repository's page holds its facts in cards, in the order they matter" do
    page = detail(@repository)

    assert outline(page, "div.repository-page > *") == [
             "p.kit-status-line",
             "section.kit-card#repository-knowledge",
             "section.kit-card#repository-github",
             "section.kit-card#repository-code",
             "section.kit-card#remove-repository"
           ]

    assert outline(page, "#repository-knowledge > *") == [
             "header.section-head",
             "dl.kit-facts",
             "section.kit-card-part#repository-use"
           ]

    assert LazyHTML.query(page, "details") |> Enum.empty?()
    assert LazyHTML.query(page, "#repository-state .state-word") |> LazyHTML.text() == "Ready"

    knowledge = page |> LazyHTML.query("#repository-knowledge") |> LazyHTML.text() |> squeeze()
    assert knowledge =~ "Written By a model from 783fc48, 1 h ago"
    assert knowledge =~ "Why These files changed: README.md."
    assert knowledge =~ "Checks Last 1 h ago, next tomorrow 13:00 UTC"

    # Refreshing it only asks, from the card it refreshes.
    assert LazyHTML.query(
             page,
             "#repository-knowledge .section-actions button.secondary[phx-click=confirm-settings-action][phx-value-action=refresh-knowledge][phx-value-ref=acme-checkout-api]"
           )
           |> LazyHTML.text() == "Refresh knowledge"

    use = page |> LazyHTML.query("#repository-use") |> LazyHTML.text() |> squeeze()
    assert use =~ "Environments Production, Staging"
    assert use =~ "Channels 2 channels"
    assert use =~ "Schedules 1 schedule"
    assert use =~ "Tasks 14 tasks · See its requests"
    assert use =~ "Pull requests 1 pull request opened by Ryker"

    assert LazyHTML.query(page, "#repository-use a") |> LazyHTML.attribute("href") == [
             "/environments/production/edit",
             "/environments/staging/edit",
             "/activity?repository=acme-checkout-api"
           ]

    github = page |> LazyHTML.query("#repository-github") |> LazyHTML.text() |> squeeze()
    assert github =~ "Repository acme/checkout-api"
    assert github =~ "Access Available"
    assert github =~ "Permissions Everything Ryker needs"
    assert github =~ "Allowed actions merge pull request"
    assert github =~ "Events Up to date, last received 1 h ago"
    refute github =~ "ryker-write"

    assert LazyHTML.query(page, "#repository-github a[target=_blank]")
           |> LazyHTML.attribute("href") == ["https://github.com/acme/checkout-api"]

    # A commit by its short name and a branch as people name it; no base
    # status or full hash (Andrew, 2026-09-28: no raw hashes on a page).
    code = page |> LazyHTML.query("#repository-code") |> LazyHTML.text() |> squeeze()
    assert code =~ "not a live check"
    assert code =~ "Last used 3f9a1c2 from main, fetched 2 h ago"
    refute code =~ "Base"
    refute code =~ String.duplicate("a", 40)

    remove = LazyHTML.query(page, "#remove-repository")

    assert LazyHTML.query(remove, ".section-head p") |> LazyHTML.text() ==
             RepositoriesPage.removal(@repository).text

    assert LazyHTML.query(
             remove,
             "button.ui-button.danger[phx-click=confirm-settings-action][phx-value-action=remove-repository][phx-value-ref=acme-checkout-api]"
           )
           |> LazyHTML.text() == "Remove repository"
  end

  test "a repository in no environment says so on its page and where to add it" do
    page = detail(%{@repository | environments: [], in_environments: [], channels: 0})
    use = page |> LazyHTML.query("#repository-use") |> LazyHTML.text() |> squeeze()

    assert use =~
             "Environments None yet, so no channel's work can use it. Add it to an environment"

    assert use =~ "Channels None"
    assert LazyHTML.query(page, "#repository-use a[href='/environments']") |> Enum.count() == 1
  end

  test "the route opens a repository's page under its name, and one not added is not found" do
    options = %{
      projection: %{
        repository_detail: fn
          "acme-checkout-api" -> {:ok, @repository}
          _other -> :error
        end
      }
    }

    page = Pages.page(["repositories", "acme-checkout-api"], %{}, options)
    assert page.status == 200
    assert page.title == "acme/checkout-api"
    assert page.back == {"All repositories", "/repositories"}
    assert IO.iodata_to_binary(page.body) =~ ~s(id="remove-repository")

    assert Pages.page(["repositories", "gone"], %{}, options).status == 404
  end

  # Andrew, 2026-09-28: every model call shows the exact prompt it was sent,
  # as routing, work and learning do on the Timeline. The runs that write a
  # repository's knowledge were shown nowhere. Each run was then one long line
  # of facts joined by dots, until Andrew asked for cards "like cards we do in
  # episode timeline, with nice collapsibles and well structured/formatted
  # text" (2026-10-04): a row per run, the timeline's call table inside, and
  # the prompt read as instructions and the context it was given.
  test "each knowledge run is a row with the timeline's call table and what it was sent" do
    prompt =
      ~s({"instructions":"Write the repository knowledge.\\nRead it; change nothing.","context":{"repository":{"name":"acme/checkout-api","commit":"0123456789abcdef"}}})

    answer = ~s({\n  "purpose": "The checkout service."\n})

    call = %{
      target: "codex:gpt-5.3/medium",
      tokens: "12,000 in · 800 out",
      cost: "≈ $0.021",
      checks: "Passed first time",
      corrections: [],
      segments: [%{kind: :model, label: "Model", ms: 40_000}],
      total_ms: 42_000
    }

    runs = [
      %{
        id: "run-2",
        at: @now,
        status: :applied,
        commit: "0123456789abcdef",
        call: call,
        error_code: nil,
        dropped: 2,
        prompt: prompt,
        result: answer
      },
      %{
        id: "run-1",
        at: DateTime.add(@now, -86_400, :second),
        status: :rejected,
        commit: nil,
        call: %{
          call
          | target: nil,
            tokens: nil,
            cost: nil,
            checks: nil,
            segments: [],
            total_ms: nil
        },
        error_code: "repository_knowledge_result_invalid",
        dropped: nil,
        prompt: "An older prompt, not JSON.",
        result: ~s({"purpose":1})
      }
    ]

    card =
      @repository
      |> Map.put(:knowledge_runs, runs)
      |> detail()
      |> LazyHTML.query("#repository-knowledge #repository-knowledge-runs")

    summaries =
      card
      |> LazyHTML.query("details.knowledge-run > summary")
      |> Enum.map(&squeeze(LazyHTML.text(&1)))

    assert [written, refused] = summaries
    assert written =~ ~r/^Written .+ gpt-5\.3 · medium reasoning ≈ \$0\.021 · 42\.0 s$/
    assert refused =~ ~r/^Not used /
    refute refused =~ "reasoning"

    # Opened, a run is the call table the timeline draws for every model call.
    table =
      card |> LazyHTML.query("#knowledge-run-run-2 dl.call-run") |> LazyHTML.text() |> squeeze()

    assert table ==
             "Model gpt-5.3 · medium reasoning Tokens 12,000 in · 800 out Cost ≈ $0.021 " <>
               "Checks Passed first time Code 0123456 Model 40.0 s"

    assert card
           |> LazyHTML.query("#knowledge-run-run-2 dl.call-run a")
           |> LazyHTML.attribute("href") ==
             ["https://github.com/acme/checkout-api/commit/0123456789abcdef"]

    notes = card |> LazyHTML.query(".knowledge-run-note") |> Enum.map(&LazyHTML.text/1)

    assert notes == [
             "Ryker left out 2 paths or commands it could not find in the repository.",
             "The answer did not match what Ryker asked for, so Ryker did not use it."
           ]

    # The prompt reads as its instructions and the context it was given, in the
    # order it was sent; the exact prompt is one click away.
    sent = LazyHTML.query(card, "#knowledge-run-run-2-prompt")

    assert sent |> LazyHTML.query(".knowledge-prompt-instructions") |> LazyHTML.text() ==
             "Write the repository knowledge.\nRead it; change nothing."

    assert sent |> LazyHTML.query("pre.knowledge-run-text") |> LazyHTML.text() ==
             ~s({\n  "repository": {\n    "name": "acme/checkout-api",\n    "commit": "0123456789abcdef"\n  }\n})

    assert sent
           |> LazyHTML.query("button[data-copy-value]")
           |> LazyHTML.attribute("data-copy-value") ==
             [prompt]

    # A prompt of any other shape shows as it was sent.
    assert card |> LazyHTML.query("#knowledge-run-run-1-prompt pre") |> LazyHTML.text() ==
             "An older prompt, not JSON."

    assert card |> LazyHTML.query("#knowledge-run-run-2-answer pre") |> LazyHTML.text() == answer
    refute squeeze(LazyHTML.text(card)) =~ "repository_knowledge_result_invalid"

    assert @repository
           |> Map.put(:knowledge_runs, [])
           |> detail()
           |> LazyHTML.query("#repository-knowledge-runs")
           |> Enum.count() == 0
  end

  test "an empty list says how to add one, and a search miss says so" do
    bare = render([])

    assert LazyHTML.query(bare, ".kit-empty-title") |> LazyHTML.text() ==
             "No repositories yet"

    assert LazyHTML.query(bare, "form.filter-toolbar input[type=search][disabled]")
           |> Enum.count() == 1

    miss = render([], %{"q" => "absent"})

    assert LazyHTML.query(miss, ".kit-empty-title") |> LazyHTML.text() ==
             ~s(No repositories match "absent")
  end

  test "without a working GitHub App the page offers no Add repositories action" do
    # The header action and the import panel both led to "Repair the GitHub
    # connection first", beside the status line that already said so.
    page =
      Pages.page(["repositories"], %{}, %{
        projection: %{
          repositories: fn _params -> %{items: [], total: 0} end,
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
            %{items: [@repository], total: 1}
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

    page = detail(half)
    attention = LazyHTML.query(page, "#repository-attention")
    assert LazyHTML.query(attention, "h2") |> LazyHTML.text() == "What to do"
    refute LazyHTML.text(page) =~ "binding"
    assert Enum.empty?(LazyHTML.query(page, "button[phx-click=retry-github-onboarding]"))

    assert LazyHTML.query(
             attention,
             "button.primary[phx-click=add-repository-again][phx-value-repository=acme-checkout-api]"
           )
           |> LazyHTML.text() == "Add it again"

    assert LazyHTML.query(page, "#remove-repository button[phx-value-action=remove-repository]")
           |> Enum.count() == 1

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

    assert stopped |> detail() |> LazyHTML.query("button") |> Enum.map(&LazyHTML.text/1) ==
             ["Retry setup", "Remove repository"]
  end

  # Andrew, 2026-09-27: "also when those are updated?" The row says when
  # Ryker last updated the repository's knowledge, or says what is under way,
  # or why the last step failed, in plain words.
  test "a ready repository says where its knowledge stands" do
    for {knowledge, meta} <- [
          {%{}, "Knowledge updated 1 h ago"},
          {%{phase: :write}, "Writing knowledge"},
          {%{document_by: :outline}, "Knowledge outline written 1 h ago"}
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
             "· Knowledge not written yet"

    # While a model writes it, it cannot be asked for again.
    writing = @repository |> put_in([:knowledge, :phase], :write) |> detail()
    assert Enum.empty?(LazyHTML.query(writing, "button[phx-value-action=refresh-knowledge]"))

    assert LazyHTML.query(writing, "#repository-knowledge") |> LazyHTML.text() |> squeeze() =~
             "1 h ago · being rewritten now"
  end

  # A write that waits because no worker takes the repository's sessions, or
  # GitHub does not answer, said only "Writing knowledge" (2026-10-04 review).
  test "a RYKER.md write that waits says why on the row and the page" do
    reason =
      "No Coop worker takes this repository's sessions. Check that a worker is online and offers its policy."

    waiting =
      @repository
      |> put_in([:knowledge, :phase], :write)
      |> put_in([:knowledge, :error], reason)

    row = render_row(waiting)
    assert state(row) == {"Ready", ["on"]}
    assert LazyHTML.query(row, "p.entity-text") |> LazyHTML.text() == reason

    assert waiting
           |> detail()
           |> LazyHTML.query("#repository-knowledge")
           |> LazyHTML.text()
           |> squeeze() =~
             "Waiting " <> reason
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

  # Andrew, 2026-09-28: "I don't want to make daily PRs to update those
  # files." Ryker keeps each repository's knowledge itself, so the
  # repository's page is the place a person reads it. It showed as raw
  # Markdown, "## Purpose" and all, until Andrew asked for "well
  # structured/formatted text" with collapsibles like the timeline's
  # (2026-10-04).
  test "a repository's knowledge reads as formatted text on its page, its Markdown a click away" do
    document =
      "# RYKER.md\n\nWritten by Ryker from `783fc48` on 2026-08-28.\n\n## Purpose\n\n" <>
        "It works. Start at [the README](README.md).\n"

    page = @repository |> put_in([:knowledge, :document], document) |> detail()
    row = LazyHTML.query(page, "#repository-knowledge details#repository-knowledge-document")

    assert row |> LazyHTML.query("summary .ui-disclosure-label") |> LazyHTML.text() == "RYKER.md"

    text = LazyHTML.query(row, "#repository-knowledge-text")
    assert text |> LazyHTML.query("h4.knowledge-heading") |> LazyHTML.text() == "Purpose"
    refute LazyHTML.text(text) =~ "#"
    # The title is the row's, so the text does not say it again.
    refute LazyHTML.text(text) =~ "RYKER.md"

    assert LazyHTML.query(text, "a") |> LazyHTML.attribute("href") == [
             "https://github.com/acme/checkout-api/blob/783fc48#{String.duplicate("0", 33)}/README.md"
           ]

    assert LazyHTML.query(row, "button[data-copy-value]") |> LazyHTML.attribute("data-copy-value") ==
             [document]
  end

  test "refreshing knowledge asks what it does before a model reads the repository" do
    assert RepositoriesPage.refresh_question(@repository) == %{
             title: "Refresh knowledge of acme/checkout-api?",
             text:
               "A model reads the repository again now and Ryker rewrites its knowledge from " <>
                 "what it finds, checking every path and command against the code. Work in the " <>
                 "repository starts from the new version as soon as it is written. Nothing is " <>
                 "written to the repository."
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

    assert detail(observed)
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
           "GitHub Add a repository to start The App is verified. Add a repository for Ryker to work in.",
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

  # A row has no buttons, so its state sits at the far edge.
  defp state(row) do
    state = LazyHTML.query(row, ".entity-side .state-word")
    {LazyHTML.text(state), LazyHTML.attribute(state, "data-tone")}
  end

  # Past a hundred repositories the list showed a hundred and counted those
  # as all of them (2026-10-04 review).
  test "a list past its first hundred says how many it shows of how many" do
    rows = for index <- 1..100, do: %{@repository | ref: "repo-#{index}"}

    document =
      %{items: rows, total: 101, view: RepositoriesPage.view(%{}), now: @now}
      |> RepositoriesPage.html()
      |> LazyHTML.from_fragment()

    assert LazyHTML.text(LazyHTML.query(document, ".kit-counts")) =~ "101"

    assert LazyHTML.text(LazyHTML.query(document, ".kit-list-note")) =~
             "Showing the first 100 of 101 repositories."

    assert render(@repository) |> LazyHTML.query(".kit-list-note") |> Enum.empty?()
  end

  defp render(items, params \\ %{}) do
    items = List.wrap(items)

    %{items: items, total: length(items), view: RepositoriesPage.view(params), now: @now}
    |> RepositoriesPage.html()
    |> LazyHTML.from_fragment()
  end

  defp render_row(item), do: [item] |> render() |> LazyHTML.query("article.entity-row")

  defp detail(item),
    do:
      item
      |> RepositoriesPage.detail_html(@now)
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # "tag.first-class" for each matched element, in document order.
  defp outline(document, selector) do
    nodes = LazyHTML.query(document, selector)

    nodes
    |> LazyHTML.tag()
    |> Enum.zip(LazyHTML.attributes(nodes))
    |> Enum.map(fn {tag, attributes} ->
      id =
        case List.keyfind(attributes, "id", 0) do
          {"id", id} when tag == "section" -> "#" <> id
          _other -> ""
        end

      case List.keyfind(attributes, "class", 0) do
        {"class", class} -> tag <> "." <> hd(String.split(class)) <> id
        nil -> tag <> id
      end
    end)
  end
end
